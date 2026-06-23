import io
import subprocess
import tempfile
import os
from PIL import Image, ExifTags


_ORIENT_TAG = next(k for k, v in ExifTags.TAGS.items() if v == "Orientation")


def _apply_exif_orientation(img: Image.Image) -> Image.Image:
    try:
        exif = img._getexif()
        if exif is None:
            return img
        orient = exif.get(_ORIENT_TAG, 1)
    except Exception:
        return img
    ops = {
        2: Image.FLIP_LEFT_RIGHT,
        3: Image.ROTATE_180,
        4: Image.FLIP_TOP_BOTTOM,
        5: lambda i: i.transpose(Image.FLIP_LEFT_RIGHT).transpose(Image.ROTATE_90),
        6: Image.ROTATE_270,
        7: lambda i: i.transpose(Image.FLIP_LEFT_RIGHT).transpose(Image.ROTATE_270),
        8: Image.ROTATE_90,
    }
    op = ops.get(orient)
    if op is None:
        return img
    return img.transpose(op) if callable(op) else img.transpose(op)


def generate_thumbnail(path: str) -> bytes | None:
    """
    Resize to fit 256×256 (LANCZOS), preserve aspect, JPEG q=85.
    Returns None if the file cannot be decoded (e.g. HEIC without libheif).
    """
    try:
        with Image.open(path) as img:
            img = _apply_exif_orientation(img)
            img = img.convert("RGB")
            img.thumbnail((256, 256), Image.LANCZOS)
            buf = io.BytesIO()
            img.save(buf, format="JPEG", quality=85)
            return buf.getvalue()
    except Exception:
        return None


def generate_video_thumbnail(path: str) -> bytes | None:
    with tempfile.NamedTemporaryFile(suffix=".jpg", delete=False) as tmp:
        tmp_path = tmp.name
    try:
        result = subprocess.run(
            ["ffmpeg", "-i", path, "-ss", "00:00:01", "-vframes", "1",
             "-vf", "scale=256:256:force_original_aspect_ratio=decrease",
             "-y", tmp_path],
            capture_output=True, timeout=30,
        )
        if result.returncode != 0 or not os.path.exists(tmp_path):
            return None
        with open(tmp_path, "rb") as f:
            return f.read()
    except FileNotFoundError:
        return None
    except Exception:
        return None
    finally:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
