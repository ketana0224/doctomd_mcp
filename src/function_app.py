"""
MCP Server on Azure Functions - PDF レイアウト解析パイプライン

Tools:
  - upload_pdf   : base64 PDF を受け取り、ページ分割して Blob に保存。job_id を返却。
  - analyze_page : (job_id, page) を受け取り、CU + Vision で Markdown 化。本文を返却。
  - cleanup_job  : job_id 配下の Blob を一括削除。

Claim-Check パターンをサーバ内部に隠蔽。クライアントは job_id だけで操作する。
"""

from __future__ import annotations

import base64
import json
import logging
import os
import re
import tempfile
import uuid
from pathlib import Path
from typing import Any

import azure.functions as func
import fitz  # PyMuPDF
from azure.ai.contentunderstanding import ContentUnderstandingClient
from azure.ai.contentunderstanding.models import AnalysisInput, AnalysisResult
from azure.ai.projects import AIProjectClient
from azure.core.exceptions import AzureError, ResourceNotFoundError
from azure.identity import DefaultAzureCredential
from azure.storage.blob import BlobServiceClient
from openai import OpenAI

from _common.polygon_cut import crop_image_from_file

# ---------------------------------------------------------------------------
# 設定
# ---------------------------------------------------------------------------

LOG = logging.getLogger("mcp_pdf")
LOG.setLevel(logging.INFO)

BLOB_ACCOUNT_URL = os.environ["BLOB_ACCOUNT_URL"]
CONTAINER_PDFCUT = os.getenv("BLOB_CONTAINER_PDFCUT", "pdf-cut")
CONTAINER_CUMD = os.getenv("BLOB_CONTAINER_CUMD", "cu-md")
CONTAINER_FIGURES = os.getenv("BLOB_CONTAINER_FIGURES", "figures")
META_BLOB_NAME = "_meta.json"  # cu-md/{job_id}/_meta.json

CU_ENDPOINT = os.environ["AZURE_CONTENT_UNDERSTANDING_ENDPOINT"]
CU_API_VERSION = os.getenv("AZURE_CONTENT_UNDERSTANDING_API_VERSION", "2025-11-01")
FOUNDRY_PROJECT_ENDPOINT = os.environ["AZURE_FOUNDRY_PROJECT_ENDPOINT"]
AOAI_DEPLOYMENT = os.environ["AOAI_GA_DEPLOYMENT"]

MAX_PDF_BYTES = int(os.getenv("MAX_PDF_BYTES", str(50 * 1024 * 1024)))  # 50 MB

# ---------------------------------------------------------------------------
# クライアント (lazy / cached)
# ---------------------------------------------------------------------------

_credential: DefaultAzureCredential | None = None
_blob_service: BlobServiceClient | None = None
_cu_client: ContentUnderstandingClient | None = None
_project_client: AIProjectClient | None = None
_openai_client: OpenAI | None = None


def credential() -> DefaultAzureCredential:
    global _credential
    if _credential is None:
        _credential = DefaultAzureCredential()
    return _credential


def blob_service() -> BlobServiceClient:
    global _blob_service
    if _blob_service is None:
        _blob_service = BlobServiceClient(account_url=BLOB_ACCOUNT_URL, credential=credential())
        # コンテナを起動時に保証
        for c in (CONTAINER_PDFCUT, CONTAINER_CUMD, CONTAINER_FIGURES):
            try:
                _blob_service.create_container(c)
            except Exception:
                pass  # 既存
    return _blob_service


def cu_client() -> ContentUnderstandingClient:
    global _cu_client
    if _cu_client is None:
        _cu_client = ContentUnderstandingClient(
            endpoint=CU_ENDPOINT,
            credential=credential(),
            api_version=CU_API_VERSION,
        )
    return _cu_client


def project_client() -> AIProjectClient:
    """Foundry project client (Responses API / Agents / Connections の基点)"""
    global _project_client
    if _project_client is None:
        _project_client = AIProjectClient(
            endpoint=FOUNDRY_PROJECT_ENDPOINT,
            credential=credential(),
        )
    return _project_client


def openai_client() -> OpenAI:
    """Foundry project 経由で OpenAI-compatible client を取得。
    /api/projects/{project}/openai/v1 ルートにヒットし、
    Foundry catalog のモデル (gpt-5.5 など) + Foundry ツールを使える。
    """
    global _openai_client
    if _openai_client is None:
        _openai_client = project_client().get_openai_client()
    return _openai_client


# ---------------------------------------------------------------------------
# ヘルパ
# ---------------------------------------------------------------------------

def _parse_args(context: str) -> dict[str, Any]:
    """MCP trigger context (JSON 文字列) から arguments を取り出す"""
    if not context:
        return {}
    try:
        ctx = json.loads(context)
    except json.JSONDecodeError:
        return {}
    args = ctx.get("arguments")
    if isinstance(args, str):
        try:
            return json.loads(args)
        except json.JSONDecodeError:
            return {}
    return args or {}


def _err(code: int, message: str, **extra: Any) -> str:
    body = {"error": {"code": code, "message": message, **extra}}
    return json.dumps(body, ensure_ascii=False)


def _ok(payload: dict[str, Any]) -> str:
    return json.dumps(payload, ensure_ascii=False)


def _meta_blob(job_id: str):
    return blob_service().get_blob_client(CONTAINER_CUMD, f"{job_id}/{META_BLOB_NAME}")


def _load_meta(job_id: str) -> dict[str, Any] | None:
    try:
        data = _meta_blob(job_id).download_blob().readall()
        return json.loads(data.decode("utf-8"))
    except ResourceNotFoundError:
        return None


def _save_meta(job_id: str, meta: dict[str, Any]) -> None:
    _meta_blob(job_id).upload_blob(
        json.dumps(meta, ensure_ascii=False).encode("utf-8"),
        overwrite=True,
    )


def _page_pdf_name(stem: str, page: int, pad: int) -> str:
    return f"{stem}_p{page:0{pad}d}.pdf"


def _safe_stem(name: str) -> str:
    base = Path(name).stem
    return re.sub(r"[^\w\-]+", "_", base) or "doc"


# ---------------------------------------------------------------------------
# 図版説明 (010 から移植)
# ---------------------------------------------------------------------------

def parse_source_to_page_bbox(source: str):
    """CU の source 文字列 'D(1,x1,y1,...)' を (page_index, bbox) に分解"""
    if not source:
        return None
    nums = re.findall(r"[-+]?\d*\.?\d+", source)
    if len(nums) < 9:
        return None
    page_number = int(float(nums[0]))
    coords = [float(x) for x in nums[1:]]
    xs = coords[0::2]
    ys = coords[1::2]
    bbox = (min(xs), min(ys), max(xs), max(ys))
    return page_number - 1, bbox


def describe_figure(image_path: Path) -> str:
    img_b64 = base64.b64encode(image_path.read_bytes()).decode("ascii")
    resp = openai_client().chat.completions.create(
        model=AOAI_DEPLOYMENT,
        messages=[
            {
                "role": "user",
                "content": [
                    {
                        "type": "text",
                        "text": "この図版の内容を日本語で3-5文で要約してください。数値や軸、凡例、主メッセージを優先してください。",
                    },
                    {
                        "type": "image_url",
                        "image_url": {"url": f"data:image/png;base64,{img_b64}"},
                    },
                ],
            }
        ],
    )
    return (resp.choices[0].message.content or "").strip()


def enrich_markdown(
    result_dict: dict[str, Any],
    page_pdf_path: Path,
    job_id: str,
    page_stem: str,
) -> tuple[str, list[dict[str, str]]]:
    """CU 結果に Vision 説明を差し込み、figure を Blob にアップロード"""
    contents = result_dict.get("contents", [])
    if not contents:
        return "", []

    markdown = contents[0].get("markdown", "")
    figures = contents[0].get("figures", [])
    descriptions: list[dict[str, str]] = []
    if not figures:
        return markdown, descriptions

    bsvc = blob_service()
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        for figure in figures:
            figure_id = figure.get("id")
            source = figure.get("source", "")
            parsed = parse_source_to_page_bbox(source)
            if not figure_id or not parsed:
                continue

            page_idx, bbox = parsed
            try:
                img = crop_image_from_file(str(page_pdf_path), page_idx, bbox)
            except Exception as ex:  # noqa: BLE001
                LOG.warning("figure crop failed: job=%s fig=%s err=%s", job_id, figure_id, ex)
                continue

            local_png = tmp / f"{page_stem}_{figure_id}.png"
            img.save(local_png)

            # Blob upload
            blob_name = f"{job_id}/{page_stem}_{figure_id}.png"
            with open(local_png, "rb") as f:
                bsvc.get_blob_client(CONTAINER_FIGURES, blob_name).upload_blob(f, overwrite=True)

            try:
                description = describe_figure(local_png)
            except Exception as ex:  # noqa: BLE001
                LOG.warning("vision describe failed: job=%s fig=%s err=%s", job_id, figure_id, ex)
                description = ""

            descriptions.append({"id": figure_id, "description": description})

            ref = f"figures/{figure_id}"
            marker = f"]({ref})"
            addition = f"]({ref})\n\n> Figure {figure_id} description: {description}"
            if marker in markdown:
                markdown = markdown.replace(marker, addition, 1)
            else:
                markdown += f"\n\n> Figure {figure_id} description: {description}"

    return markdown, descriptions


# ---------------------------------------------------------------------------
# Function App
# ---------------------------------------------------------------------------

app = func.FunctionApp()

# ---- Tool 1: upload_pdf ---------------------------------------------------

_TOOL_UPLOAD_PDF_PROPS = json.dumps(
    [
        {
            "propertyName": "pdf_base64",
            "propertyType": "string",
            "description": "PDF を base64 エンコードした文字列 (最大 50MB のデコード後サイズ)",
        },
        {
            "propertyName": "file_name",
            "propertyType": "string",
            "description": "元の PDF ファイル名 (例: report.pdf)",
        },
    ]
)


@app.generic_trigger(
    arg_name="context",
    type="mcpToolTrigger",
    toolName="upload_pdf",
    description=(
        "PDF (base64) を受け取り、サーバ内部で 1 ページずつ分割し Blob に保存する。"
        "後続の analyze_page 呼出に使う job_id と総ページ数を返却する。"
    ),
    toolProperties=_TOOL_UPLOAD_PDF_PROPS,
)
def upload_pdf(context) -> str:
    args = _parse_args(context)
    pdf_b64 = args.get("pdf_base64") or ""
    file_name = args.get("file_name") or "document.pdf"

    if not pdf_b64:
        return _err(-32602, "pdf_base64 is required")

    try:
        pdf_bytes = base64.b64decode(pdf_b64, validate=True)
    except Exception as ex:  # noqa: BLE001
        return _err(-32602, f"pdf_base64 decode failed: {ex}")

    if len(pdf_bytes) > MAX_PDF_BYTES:
        return _err(
            -32602,
            f"pdf too large: {len(pdf_bytes)} bytes (limit={MAX_PDF_BYTES})",
        )

    job_id = uuid.uuid4().hex
    stem = _safe_stem(file_name)
    bsvc = blob_service()

    try:
        with fitz.open(stream=pdf_bytes, filetype="pdf") as src:
            total = src.page_count
            pad = max(2, len(str(total)))

            for p in range(total):
                with fitz.open() as dst:
                    dst.insert_pdf(src, from_page=p, to_page=p, links=0, annots=0, widgets=0)
                    out_bytes = dst.tobytes()
                blob_name = f"{job_id}/{_page_pdf_name(stem, p + 1, pad)}"
                bsvc.get_blob_client(CONTAINER_PDFCUT, blob_name).upload_blob(
                    out_bytes, overwrite=True
                )
    except Exception as ex:  # noqa: BLE001
        LOG.exception("upload_pdf failed: job=%s", job_id)
        return _err(-32000, f"split failed: {ex}", job_id=job_id)

    meta = {
        "job_id": job_id,
        "file_name": file_name,
        "stem": stem,
        "total_pages": total,
        "pad": pad,
    }
    _save_meta(job_id, meta)

    LOG.info(
        "upload_pdf ok: job=%s file=%s size=%d pages=%d",
        job_id, file_name, len(pdf_bytes), total,
    )
    return _ok({"job_id": job_id, "total_pages": total, "file_name": file_name})


# ---- Tool 2: analyze_page -------------------------------------------------

_TOOL_ANALYZE_PAGE_PROPS = json.dumps(
    [
        {
            "propertyName": "job_id",
            "propertyType": "string",
            "description": "upload_pdf が返した job_id",
        },
        {
            "propertyName": "page",
            "propertyType": "number",
            "description": "解析するページ番号 (1 始まり, total_pages 以下)",
        },
    ]
)


@app.generic_trigger(
    arg_name="context",
    type="mcpToolTrigger",
    toolName="analyze_page",
    description=(
        "(job_id, page) に対応するページ PDF を Azure Content Understanding で解析し、"
        "図版を GPT Vision で日本語要約して Markdown に注入。"
        "完成 Markdown 本文と図版説明一覧を返す。再呼出時はキャッシュから返却。"
    ),
    toolProperties=_TOOL_ANALYZE_PAGE_PROPS,
)
def analyze_page(context) -> str:
    args = _parse_args(context)
    job_id = (args.get("job_id") or "").strip()
    page_raw = args.get("page")

    if not job_id:
        return _err(-32602, "job_id is required")
    try:
        page = int(page_raw)
    except (TypeError, ValueError):
        return _err(-32602, "page must be integer")

    meta = _load_meta(job_id)
    if meta is None:
        return _err(-32004, "job not found or expired", job_id=job_id)

    total = int(meta["total_pages"])
    if page < 1 or page > total:
        return _err(-32602, f"page out of range (1..{total})", job_id=job_id)

    stem = meta["stem"]
    pad = int(meta.get("pad", max(2, len(str(total)))))
    page_pdf_name = _page_pdf_name(stem, page, pad)
    page_stem = Path(page_pdf_name).stem  # report_p01

    bsvc = blob_service()
    md_blob = bsvc.get_blob_client(CONTAINER_CUMD, f"{job_id}/{page_stem}.md")
    fig_meta_blob = bsvc.get_blob_client(CONTAINER_CUMD, f"{job_id}/{page_stem}.figures.json")

    # キャッシュヒット
    try:
        cached_md = md_blob.download_blob().readall().decode("utf-8")
        try:
            cached_figs = json.loads(fig_meta_blob.download_blob().readall().decode("utf-8"))
        except ResourceNotFoundError:
            cached_figs = []
        LOG.info("analyze_page cache hit: job=%s page=%d", job_id, page)
        return _ok({
            "job_id": job_id,
            "page": page,
            "markdown": cached_md,
            "figures": cached_figs,
            "cached": True,
        })
    except ResourceNotFoundError:
        pass

    # ページ PDF を一時 DL
    page_pdf_blob = bsvc.get_blob_client(CONTAINER_PDFCUT, f"{job_id}/{page_pdf_name}")
    try:
        pdf_bytes = page_pdf_blob.download_blob().readall()
    except ResourceNotFoundError:
        return _err(-32004, "page pdf not found", job_id=job_id, page=page)

    with tempfile.TemporaryDirectory() as td:
        tmp_pdf = Path(td) / page_pdf_name
        tmp_pdf.write_bytes(pdf_bytes)

        try:
            poller = cu_client().begin_analyze(
                analyzer_id="prebuilt-layout",
                inputs=[
                    AnalysisInput(
                        name=page_pdf_name,
                        data=pdf_bytes,
                        mime_type="application/pdf",
                    )
                ],
            )
            result: AnalysisResult = poller.result()
        except AzureError as ex:
            LOG.exception("CU failed: job=%s page=%d", job_id, page)
            return _err(-32000, f"content understanding failed: {ex.message}", job_id=job_id, page=page)

        result_dict = result.as_dict()

        try:
            markdown, descriptions = enrich_markdown(
                result_dict=result_dict,
                page_pdf_path=tmp_pdf,
                job_id=job_id,
                page_stem=page_stem,
            )
        except Exception as ex:  # noqa: BLE001
            LOG.exception("enrich failed: job=%s page=%d", job_id, page)
            return _err(-32000, f"figure enrichment failed: {ex}", job_id=job_id, page=page)

    # キャッシュへ保存
    md_blob.upload_blob(markdown.encode("utf-8"), overwrite=True)
    fig_meta_blob.upload_blob(
        json.dumps(descriptions, ensure_ascii=False).encode("utf-8"),
        overwrite=True,
    )

    LOG.info(
        "analyze_page ok: job=%s page=%d figures=%d",
        job_id, page, len(descriptions),
    )
    return _ok({
        "job_id": job_id,
        "page": page,
        "markdown": markdown,
        "figures": descriptions,
        "cached": False,
    })


# ---- Tool 3: cleanup_job --------------------------------------------------

_TOOL_CLEANUP_JOB_PROPS = json.dumps(
    [
        {
            "propertyName": "job_id",
            "propertyType": "string",
            "description": "削除対象の job_id",
        }
    ]
)


@app.generic_trigger(
    arg_name="context",
    type="mcpToolTrigger",
    toolName="cleanup_job",
    description="job_id 配下の Blob (pdf-cut / cu-md / figures) を即時削除する。",
    toolProperties=_TOOL_CLEANUP_JOB_PROPS,
)
def cleanup_job(context) -> str:
    args = _parse_args(context)
    job_id = (args.get("job_id") or "").strip()
    if not job_id:
        return _err(-32602, "job_id is required")

    bsvc = blob_service()
    deleted = 0
    for container in (CONTAINER_PDFCUT, CONTAINER_CUMD, CONTAINER_FIGURES):
        client = bsvc.get_container_client(container)
        try:
            for blob in client.list_blobs(name_starts_with=f"{job_id}/"):
                client.delete_blob(blob.name)
                deleted += 1
        except Exception as ex:  # noqa: BLE001
            LOG.warning("cleanup partial failure: container=%s err=%s", container, ex)

    LOG.info("cleanup_job ok: job=%s deleted=%d", job_id, deleted)
    return _ok({"job_id": job_id, "deleted_count": deleted})
