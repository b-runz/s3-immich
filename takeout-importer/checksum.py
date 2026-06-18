import hashlib
import base64


def sha1_base64(path: str) -> str:
    """Return SHA-1 of file bytes as base64 string (e.g. '06U1WtAbh20DgNHq0l2UszF7zS0=')."""
    h = hashlib.sha1()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return base64.b64encode(h.digest()).decode()
