from PIL import Image  # Pillow
import fitz  # PyMuPDF
import mimetypes


def crop_image_from_image(image_path, page_number, bounding_box):
    """Crop a region from an image file (TIFF 対応)。"""
    with Image.open(image_path) as img:
        if img.format == "TIFF":
            img.seek(page_number)
            img = img.copy()
        return img.crop(bounding_box)


def crop_image_from_pdf_page(pdf_path, page_number, bounding_box):
    """PDF の指定ページから矩形を 300 DPI で切り出して PIL Image を返す。

    bounding_box は inch 単位 (x0, y0, x1, y1)。
    """
    doc = fitz.open(pdf_path)
    try:
        page = doc.load_page(page_number)
        bbx = [x * 72 for x in bounding_box]
        rect = fitz.Rect(bbx)
        pix = page.get_pixmap(matrix=fitz.Matrix(300 / 72, 300 / 72), clip=rect)
        img = Image.frombytes("RGB", [pix.width, pix.height], pix.samples)
    finally:
        doc.close()
    return img


def crop_image_from_file(file_path, page_number, bounding_box):
    """ファイル種別に応じて crop する。"""
    mime_type = mimetypes.guess_type(file_path)[0]
    if mime_type == "application/pdf":
        return crop_image_from_pdf_page(file_path, page_number, bounding_box)
    return crop_image_from_image(file_path, page_number, bounding_box)
