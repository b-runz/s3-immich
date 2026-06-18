def load_ocr(backend: str, languages: list[str]):
    if backend == "easyocr":
        import easyocr
        return EasyOCRBackend(easyocr.Reader(languages, gpu=False))
    if backend == "pytesseract":
        return TesseractBackend()
    return None


class EasyOCRBackend:
    def __init__(self, reader):
        self._r = reader

    def read(self, img_path: str) -> str:
        results = self._r.readtext(img_path, detail=0)
        return " ".join(results)


class TesseractBackend:
    def read(self, img_path: str) -> str:
        import pytesseract
        from PIL import Image
        return pytesseract.image_to_string(Image.open(img_path))
