# MCP PDF Pipeline (Plan B)

`000_PDF_CUT.py` + `010_CU_by_page_to_md.py` をリモート MCP サーバとして
Azure Functions (Flex Consumption) 上で動かす実装。

**設計のキモ**: Claim-Check パターンを **サーバ内部に閉じ込めた** ので、
クライアントは Blob/SAS を一切知らずに `job_id` だけで操作できる。

```
┌────────────┐                 ┌─────────────────────────────┐
│ MCP Client │  upload_pdf ───▶│  Azure Functions (MCP host) │──▶ Blob: pdf-cut/{job}/p01.pdf...
│ (Claude/   │ ◀── job_id ─────│    ├─ PyMuPDF split         │
│  Inspector)│                 │    ├─ Content Understanding │──▶ Blob: cu-md/{job}/p01.md (cache)
│            │  analyze_page ─▶│    └─ GPT Vision figures    │──▶ Blob: figures/{job}/...
│            │ ◀── markdown ───│                              │
│            │  cleanup_job ──▶│  (3 containers wiped)        │
└────────────┘                 └─────────────────────────────┘
```

---

## 1. ツール

| Tool          | 引数                              | 返却                                        |
|---------------|-----------------------------------|---------------------------------------------|
| `upload_pdf`  | `pdf_base64`, `file_name`         | `job_id`, `total_pages`, `file_name`        |
| `analyze_page`| `job_id`, `page` (1 始まり)        | `job_id`, `page`, `markdown`, `figures[]`   |
| `cleanup_job` | `job_id`                          | `job_id`, `deleted_count`                   |

- 最大 PDF サイズ: 50 MB (decode 後)。
- `analyze_page` はキャッシュ済みなら CU/Vision を呼ばずに Blob から即返却。
- 7 日後に Storage Lifecycle で全 Blob を自動削除。明示的に消したい時は `cleanup_job`。

---

## 2. ディレクトリ構成

```
create_mcp/
├── azure.yaml                       # azd 用 (services.api → src/)
├── README.md                        # このファイル
├── infra/
│   ├── main.bicep                   # orchestrator
│   ├── main.parameters.json
│   └── modules/
│       ├── storage.bicep
│       ├── function.bicep
│       ├── roleAssignments.bicep
│       └── roleAssignmentsAi.bicep
└── src/                             # Functions プロジェクト
    ├── host.json                    # Experimental Extension Bundle (MCP)
    ├── requirements.txt
    ├── local.settings.json.sample
    ├── .funcignore
    ├── function_app.py              # 3 ツール本体
    └── _common/
        ├── __init__.py
        └── polygon_cut.py
```

---

## 3. デプロイ

### 3.1 前提
- Azure CLI ログイン済 (`az login`)
- Azure Developer CLI v1.10+
- AI Foundry アカウント (例: `ketana-ext-new-aif`) と `gpt-4o` などの GA デプロイが存在
- 同サブスクリプションに対する Contributor + RBAC 管理権限

### 3.2 azd init / up
```powershell
cd c:\vscodepy\ai_di\create_mcp

azd init                       # 既存テンプレとして検出される
azd env new mcp-pdf-dev
azd env set AZURE_LOCATION japaneast
azd env set AI_FOUNDRY_ACCOUNT_NAME ketana-ext-new-aif
# AI Foundry が別 RG にある場合だけ:
# azd env set AI_FOUNDRY_RESOURCE_GROUP <rg-name>
azd env set AOAI_GA_DEPLOYMENT gpt-4o

azd up                         # provision + deploy
```

成功時、出力に Function App ホスト名が出る:
```
FUNCTION_APP_HOSTNAME: func-mcp-xxxxxx.azurewebsites.net
```

### 3.3 MCP エンドポイント
- URL: `https://<FUNCTION_APP_HOSTNAME>/runtime/webhooks/mcp/sse`
- **Transport は必ず `Streamable HTTP`** (Azure Functions MCP は SSE 単体接続非対応)

> Functions Key (`x-functions-key`) 経由のアクセスに後で切り替えたい場合は
> `function.bicep` の `siteConfig.functionAppScaleLimit` / Auth 設定を拡張する。

---

## 4. ローカル実行 (Azurite + venv)

```powershell
cd c:\vscodepy\ai_di\create_mcp\src

# サンプルから local.settings.json を作る
Copy-Item .\local.settings.json.sample .\local.settings.json

# 値を編集 (BLOB_ACCOUNT_URL を本物 or Azurite、AI Foundry 関連を本物に)
notepad .\local.settings.json

# venv & deps (既存 .venv を再利用)
.\..\..\.venv\Scripts\Activate.ps1
pip install -r requirements.txt

# Azurite + Functions
func start
```

> Content Understanding と Azure OpenAI は実環境必須 (エミュレータなし)。
> `az login` 済みの `DefaultAzureCredential` が拾われるので、ご自身のアカウントに
> `Cognitive Services User` / `Cognitive Services OpenAI User` が割当済か確認。

---

## 5. MCP Inspector で動作確認

```powershell
npx @modelcontextprotocol/inspector
```

Inspector UI で:
- Transport Type: **Streamable HTTP** ← 必須
- URL: `https://<FUNCTION_APP_HOSTNAME>/runtime/webhooks/mcp`

ツール一覧に `upload_pdf` / `analyze_page` / `cleanup_job` が見えれば OK。
`upload_pdf` の引数欄に `pdf_base64` を貼って実行 → `job_id` 取得。

---

## 6. クライアント サンプル (asyncio で並列解析)

```python
import asyncio, base64, json
from pathlib import Path
from mcp import ClientSession
from mcp.client.streamable_http import streamablehttp_client

ENDPOINT = "https://func-mcp-xxxxxx.azurewebsites.net/runtime/webhooks/mcp"
PDF = Path("sample.pdf")

async def main():
    pdf_b64 = base64.b64encode(PDF.read_bytes()).decode("ascii")
    async with streamablehttp_client(ENDPOINT) as (r, w, _):
        async with ClientSession(r, w) as sess:
            await sess.initialize()

            up = await sess.call_tool("upload_pdf", {
                "pdf_base64": pdf_b64,
                "file_name": PDF.name,
            })
            meta = json.loads(up.content[0].text)
            job_id, total = meta["job_id"], meta["total_pages"]
            print(f"job={job_id} pages={total}")

            async def one(p: int):
                res = await sess.call_tool("analyze_page", {"job_id": job_id, "page": p})
                return json.loads(res.content[0].text)

            pages = await asyncio.gather(*(one(p) for p in range(1, total + 1)))
            Path("out.md").write_text(
                "\n\n---\n\n".join(p["markdown"] for p in pages),
                encoding="utf-8",
            )
            print("wrote out.md")

            await sess.call_tool("cleanup_job", {"job_id": job_id})

asyncio.run(main())
```

---

## 7. 注意点 / 既知の制約

1. **HTTP ペイロード上限**: Azure Functions の HTTP ボディは ~100 MB だが、
   JSON-RPC + base64 (+33%) で膨らむので **PDF 実体は 50 MB まで**。
   大きいファイルはローカルで PyMuPDF 分割してから複数 `upload_pdf` を直列実行。
2. **タイムアウト**: 1 ページの CU + Vision で 30〜90 秒。
   `analyze_page` を 1 ページずつ呼ぶ設計にしているのは Flex Consumption の
   既定タイムアウト (10 分) 内で確実に終わらせるため。
3. **コスト**: CU + Vision がドライバ。再呼出はキャッシュで CU をスキップする。
4. **Inspector の SSE は NG**: 必ず Streamable HTTP を選ぶ
   (Functions の MCP 拡張は Streamable HTTP のみ)。
5. **Cold start**: 初回 `upload_pdf` で SDK ロード + Storage 接続が走るため 5〜15 秒。
   `func.FunctionApp` のグローバル変数で client を lazy-cache 済み。

---

## 8. 後片付け

```powershell
azd down --purge --force
```
# doctomd_mcp
