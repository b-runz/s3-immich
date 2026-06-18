# Google Takeout → S3 Migration Tool — Python Spec

**Purpose:** A standalone Python 3.10+ CLI that reads a Google Photos Takeout export and
populates an S3 bucket plus a SQLite database so the server-free Immich fork can use the
photos immediately — no Dart, Flutter, or app installation required.

**Sister spec:** `takeout_migrate_spec.md` covers the same migration in Dart. Refer to it for
the authoritative SQLite schema (section 6). This spec translates the same logic to Python and
adds full ML pipeline support (face detection, OCR, labeling).

---

## 1. Project Structure

```
takeout_python/
  migrate.py              ← entry point (main)
  config.py               ← .env loading + TakeoutConfig dataclass
  scanner.py              ← Takeout directory walk + sidecar resolution
  sidecar.py              ← JSON sidecar parser
  checksum.py             ← SHA-1 base64 helper
  thumbnail.py            ← Pillow thumbnail + EXIF orient
  face_pipeline.py        ← MediaPipe / InsightFace detection + crop
  ocr_pipeline.py         ← EasyOCR / pytesseract
  label_pipeline.py       ← CLIP / torchvision labels
  db_builder.py           ← sqlite3 schema creation + row insertion
  s3_uploader.py          ← boto3 upload pool
  progress.py             ← .migrate_progress.json tracker
  requirements.txt
  .env                    ← not committed
  .gitignore
```

---

## 2. `requirements.txt`

```
# Core — always required
boto3>=1.34
Pillow>=10.3
python-dotenv>=1.0

# Face detection — install ONE of:
# mediapipe>=0.10          # recommended; pure-Python wheels on Linux/macOS/Windows
# insightface>=0.7; onnxruntime>=1.17   # heavier but richer embeddings

# OCR — install ONE of:
# easyocr>=1.7
# pytesseract>=0.3

# Image labeling — install ONE of:
# torch>=2.1; torchvision>=0.16; open-clip-torch>=2.24   # CLIP zero-shot
# imageai>=3.0                                            # simpler but older

# Optional — width/height without full decode
# piexif>=1.1              # already pulled by Pillow
```

`mediapipe` and `easyocr` are the defaults in this spec. All ML dependencies are optional;
the tool runs fine with `--skip-faces --skip-ocr --skip-labels`.

---

## 3. `.env` Configuration

```ini
# S3
S3_ENDPOINT=https://s3.eu-central-1.amazonaws.com   # for MinIO/R2: https://…r2.cloudflarestorage.com
S3_BUCKET=my-immich-bucket
S3_ACCESS_KEY=AKIA…
S3_SECRET_KEY=…
S3_REGION=eu-central-1
S3_USE_SSL=true
S3_PREFIX=                    # optional key prefix, e.g. "photos"

# Source
TAKEOUT_DIR=/path/to/Takeout/Google_Photos

# Owner identity (must match user_entity row)
OWNER_ID=local-user
OWNER_EMAIL=me@example.com
OWNER_NAME=My Name

# Concurrency
UPLOAD_WORKERS=8

# ML
FACE_BACKEND=mediapipe        # mediapipe | insightface | none
OCR_BACKEND=easyocr           # easyocr | pytesseract | none
LABEL_BACKEND=clip            # clip | none
OCR_LANGUAGES=en,da           # comma-separated language codes for easyocr
LABEL_THRESHOLD=0.20          # minimum CLIP confidence to store a label
```

---

## 4. `config.py`

```python
import os
from dataclasses import dataclass, field
from dotenv import load_dotenv

@dataclass
class TakeoutConfig:
    endpoint: str
    bucket: str
    access_key: str
    secret_key: str
    region: str = "us-east-1"
    use_ssl: bool = True
    prefix: str = ""           # optional bucket key prefix
    takeout_dir: str = ""
    owner_id: str = "local-user"
    owner_email: str = "local@immich.app"
    owner_name: str = "Local User"
    upload_workers: int = 8
    face_backend: str = "mediapipe"   # mediapipe | insightface | none
    ocr_backend: str = "easyocr"      # easyocr | pytesseract | none
    label_backend: str = "clip"       # clip | none
    ocr_languages: list[str] = field(default_factory=lambda: ["en"])
    label_threshold: float = 0.20

    @classmethod
    def from_env(cls, env_file: str = ".env") -> "TakeoutConfig":
        load_dotenv(env_file)
        def req(k: str) -> str:
            v = os.getenv(k)
            if not v:
                raise SystemExit(f"Missing required env var: {k}")
            return v
        return cls(
            endpoint=req("S3_ENDPOINT"),
            bucket=req("S3_BUCKET"),
            access_key=req("S3_ACCESS_KEY"),
            secret_key=req("S3_SECRET_KEY"),
            region=os.getenv("S3_REGION", "us-east-1"),
            use_ssl=os.getenv("S3_USE_SSL", "true").lower() != "false",
            prefix=os.getenv("S3_PREFIX", ""),
            takeout_dir=req("TAKEOUT_DIR"),
            owner_id=os.getenv("OWNER_ID", "local-user"),
            owner_email=os.getenv("OWNER_EMAIL", "local@immich.app"),
            owner_name=os.getenv("OWNER_NAME", "Local User"),
            upload_workers=int(os.getenv("UPLOAD_WORKERS", "8")),
            face_backend=os.getenv("FACE_BACKEND", "mediapipe"),
            ocr_backend=os.getenv("OCR_BACKEND", "easyocr"),
            label_backend=os.getenv("LABEL_BACKEND", "clip"),
            ocr_languages=os.getenv("OCR_LANGUAGES", "en").split(","),
            label_threshold=float(os.getenv("LABEL_THRESHOLD", "0.20")),
        )
```

---

## 5. S3 Key Layout

Identical to the Dart implementation. The asset ID IS the S3 key.

| Content | S3 Key |
|---------|--------|
| Original | `{year}/{mm}/{dd}/{filename}` (with prefix: `{prefix}/{year}/…`) |
| Thumbnail | `.thumbs/{year}/{mm}/{dd}/{filename}` |
| Face crop | `.thumbs/faces/{personId}.jpg` |
| Database | `.meta/s3immich.db` |

```python
import os
from datetime import datetime

def s3_key_for(filename: str, taken_at: datetime, prefix: str = "") -> str:
    name = os.path.basename(filename)
    path = f"{taken_at.year:04d}/{taken_at.month:02d}/{taken_at.day:02d}/{name}"
    return f"{prefix}/{path}" if prefix else path

def thumbnail_key_for(filename: str, taken_at: datetime, prefix: str = "") -> str:
    return f".thumbs/{s3_key_for(filename, taken_at, prefix)}"
```

---

## 6. Checksum — `checksum.py`

The app stores SHA-1 of raw file bytes, **base64-encoded** (not hex). Must match exactly.

```python
import hashlib, base64

def sha1_base64(path: str) -> str:
    """Return SHA-1 of file bytes as base64 string (e.g. '06U1WtAbh20DgNHq0l2UszF7zS0=')."""
    h = hashlib.sha1()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return base64.b64encode(h.digest()).decode()
```

---

## 7. Takeout Scanner — `scanner.py`

### 7.1 Overview

Immich-go's approach (borrowed here):

1. **Pass 1 — directory walk:** Collect all media files and JSON sidecars into per-directory
   catalogs. Use `os.walk()` recursively. Store each directory's files and JSON metadata
   separately.
2. **Pass 2 — solve puzzle:** For each directory, match JSON sidecars to their media files
   using an ordered list of matcher functions (fast-track, normal, edited-name, forgotten-
   duplicates). This handles the 51-char filename truncation, duplicate-in-multiple-albums, and
   `-edited` suffix patterns.
3. **Pass 3 — emit assets:** Yield resolved `TakeoutPhoto` objects, one per unique file.
   Duplicate files (same basename + size) found across multiple album folders are yielded once
   but carry all album names.

### 7.2 Sidecar Name Matchers (from immich-go `matchers.go`)

These matchers are applied in priority order:

```python
import re, os

def _strip_ext(name: str) -> str:
    return os.path.splitext(name)[0]

def _get_index(name: str) -> tuple[str, str]:
    """Extract trailing (N) from filenames like IMG_001(1).jpg → ('IMG_001.jpg', '1')."""
    m = re.search(r'\((\d+)\)(\.[^.]+)?$', name)
    if m:
        idx = m.group(1)
        clean = name[:m.start()] + (m.group(2) or "")
        return clean, idx
    return name, ""

def match_fast_track(json_name: str, file_name: str) -> bool:
    """json_name without .json == file_name exactly."""
    return _strip_ext(json_name) == file_name

def match_normal(json_name: str, file_name: str) -> bool:
    """Handles supplemental-metadata suffix, index numbers, 46-rune truncation."""
    file_name, file_idx = _get_index(file_name)
    json_name, json_idx = _get_index(json_name)
    if file_idx != json_idx:
        return False
    # Strip supplemental-metadata or supplemental-metada suffix
    # e.g. "IMG_001.jpg.supplemental-metadata.json" → "IMG_001.jpg"
    parts = json_name.rsplit(".", 2)
    if len(parts) == 3 and "supplemental-metada".startswith(parts[1]):
        json_name = parts[0] + "." + parts[2]
    json_name = _strip_ext(json_name)
    if json_name == file_name:
        return True
    # 46-rune truncation rule
    runes = list(file_name)
    if len(runes) > 46:
        truncated = "".join(runes[:46])
        if truncated == json_name:
            return True
    return False

def match_edited_name(json_name: str, file_name: str, media_exts: set) -> bool:
    """Match PXL_20220405.PORTRAIT.jpg.json → PXL_20220405.PORTRAIT-edited.jpg."""
    _, idx = _get_index(file_name)
    if idx:
        return False
    base = _strip_ext(json_name)
    # strip supplemental-metadata prefix
    p = base.rfind(".")
    if p > 1 and "supplemental-metada".startswith(base[p+1:]):
        base = json_name[:p]
    ext = os.path.splitext(base)[1]
    if ext.lstrip(".").lower() in media_exts:
        base = _strip_ext(base)
        file_name = _strip_ext(file_name)
    return file_name.startswith(base)

def match_forgotten_duplicates(json_name: str, file_name: str) -> bool:
    """original_uuid_.json matches original_uuid_P.jpg and original_uuid_P(1).jpg."""
    j = _strip_ext(json_name)
    f = _strip_ext(file_name)
    if f.startswith(j) and len(f) - len(j) < 10:
        return True
    return False
```

### 7.3 TakeoutPhoto Dataclass

```python
from dataclasses import dataclass, field

IMAGE_EXTS = {"jpg", "jpeg", "png", "heic", "heif", "gif", "mp"}
VIDEO_EXTS = {"mp4", "mov", "3gp", "avi", "mkv"}
MEDIA_EXTS = IMAGE_EXTS | VIDEO_EXTS

@dataclass
class TakeoutSidecar:
    title: str
    photo_taken_at: datetime        # UTC
    latitude: float | None
    longitude: float | None
    altitude: float | None
    description: str | None
    trashed: bool = False
    archived: bool = False
    favorited: bool = False

@dataclass
class TakeoutPhoto:
    local_path: str                 # absolute path on disk
    filename: str                   # basename
    extension: str                  # lowercase, no dot
    is_video: bool
    sidecar: TakeoutSidecar | None
    album_names: list[str] = field(default_factory=list)  # may be in multiple albums
```

### 7.4 Scanner Implementation (sketch)

```python
import os, re
from typing import Generator

_YEAR_FOLDER_RE = re.compile(r'^Photos from \d{4}$')
_BANNED = {"metadata.json", "shared_album_comments.json"}

def is_album_folder(folder_name: str) -> bool:
    return not _YEAR_FOLDER_RE.match(folder_name)

def scan_takeout(root: str) -> list[TakeoutPhoto]:
    # Pass 1: collect per-directory catalogs
    catalogs: dict[str, dict] = {}   # dir → {jsons: {name: raw_json}, files: {name: path}}
    file_tracker: dict[tuple, list[str]] = {}  # (basename, size) → [dirs]

    for dirpath, dirnames, filenames in os.walk(root):
        jsons = {}
        files = {}
        for fname in filenames:
            if fname in _BANNED:
                continue
            ext = fname.rsplit(".", 1)[-1].lower() if "." in fname else ""
            fpath = os.path.join(dirpath, fname)
            if ext == "json":
                try:
                    with open(fpath, encoding="utf-8") as fh:
                        data = json.load(fh)
                    if _is_asset_json(data):
                        jsons[fname] = data
                except Exception:
                    pass
            elif ext in MEDIA_EXTS:
                size = os.path.getsize(fpath)
                key = (fname, size)
                file_tracker.setdefault(key, []).append(dirpath)
                if fname not in files:  # skip local duplicates within same dir
                    files[fname] = fpath
        if jsons or files:
            catalogs[dirpath] = {"jsons": jsons, "files": files}

    # Pass 2: solve puzzle
    matchers = [match_fast_track, match_normal, match_edited_name, match_forgotten_duplicates]
    resolved: dict[str, TakeoutPhoto] = {}  # canonical path → photo

    for dirpath, cat in catalogs.items():
        unmatched = dict(cat["files"])  # fname → path
        matched: dict[str, TakeoutSidecar | None] = {}

        for json_name, json_data in cat["jsons"].items():
            sidecar = _parse_sidecar(json_data, json_name)
            for fname in list(unmatched):
                ext = fname.rsplit(".", 1)[-1].lower()
                hit = (
                    match_fast_track(json_name, fname)
                    or match_normal(json_name, fname)
                    or match_edited_name(json_name, fname, MEDIA_EXTS)
                    or match_forgotten_duplicates(json_name, fname)
                )
                if hit:
                    matched[fname] = sidecar
                    del unmatched[fname]
                    break
        # Files with no JSON get None sidecar (if --include-unmatched, include them)
        for fname in unmatched:
            matched[fname] = None

        folder_name = os.path.basename(dirpath)
        album = folder_name if is_album_folder(folder_name) else None

        for fname, sidecar in matched.items():
            fpath = cat["files"].get(fname) or os.path.join(dirpath, fname)
            if fpath in resolved:
                # Same physical file already seen — just add album
                if album and album not in resolved[fpath].album_names:
                    resolved[fpath].album_names.append(album)
                continue
            ext = fname.rsplit(".", 1)[-1].lower()
            photo = TakeoutPhoto(
                local_path=fpath,
                filename=fname,
                extension=ext,
                is_video=ext in VIDEO_EXTS,
                sidecar=sidecar,
                album_names=[album] if album else [],
            )
            resolved[fpath] = photo

    return list(resolved.values())
```

**Deduplication across album folders:** The `file_tracker` maps `(basename, size)` to the
list of directories where it appears. When a file is found for the second time (same path via
a different album folder), we skip the insert and just append the album name. This matches
immich-go's approach: one S3 object per unique photo, multiple `remote_album_asset_entity`
rows.

---

## 8. Sidecar Parser — `sidecar.py`

```python
import json
from datetime import datetime, timezone

def _is_asset_json(data: dict) -> bool:
    """True if this JSON represents a media asset (has photoTakenTime with a timestamp)."""
    pt = data.get("photoTakenTime")
    return isinstance(pt, dict) and bool(pt.get("timestamp", ""))

def _parse_geo(data: dict) -> tuple[float | None, float | None, float | None]:
    """GPS rule: prefer geoDataExif if non-zero, else geoData, else None."""
    for key in ("geoDataExif", "geoData"):
        g = data.get(key)
        if not isinstance(g, dict):
            continue
        lat = float(g.get("latitude", 0))
        lon = float(g.get("longitude", 0))
        if lat != 0.0 or lon != 0.0:
            return lat, lon, float(g.get("altitude", 0)) or None
    return None, None, None

def _parse_sidecar(data: dict, json_filename: str) -> TakeoutSidecar:
    """Parse a GoogleMetaData JSON dict into a TakeoutSidecar."""
    # Date rule: photoTakenTime → creationTime → file mtime (handled by caller)
    taken_at = _epoch_to_dt(data.get("photoTakenTime")) \
             or _epoch_to_dt(data.get("creationTime"))
    if taken_at is None:
        taken_at = datetime.now(tz=timezone.utc)

    lat, lon, alt = _parse_geo(data)
    desc = data.get("description") or None
    title = data.get("title", "") or json_filename

    return TakeoutSidecar(
        title=title,
        photo_taken_at=taken_at,
        latitude=lat,
        longitude=lon,
        altitude=alt,
        description=desc,
        trashed=bool(data.get("trashed", False)),
        archived=bool(data.get("archived", False)),
        favorited=bool(data.get("favorited", False)),
    )

def _epoch_to_dt(obj: dict | None) -> datetime | None:
    if not isinstance(obj, dict):
        return None
    ts_str = obj.get("timestamp", "")
    try:
        ts = int(ts_str)
    except (ValueError, TypeError):
        return None
    if ts == 0:
        return None
    return datetime.fromtimestamp(ts, tz=timezone.utc)
```

**Note:** `photoTakenTime.timestamp` is seconds since epoch (not milliseconds). Multiply by
1000 for SQLite `INTEGER` ms-epoch columns.

---

## 9. Thumbnail Generator — `thumbnail.py`

Use Pillow. Always apply EXIF orientation before resizing. Output: 256×256 JPEG, quality 85.

```python
from PIL import Image, ExifTags
import io

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
            img.save(buf, format="JPEG", quality=85, optimize=True)
            return buf.getvalue()
    except Exception:
        return None
```

**HEIC files:** Pillow without `pillow-heif` cannot open HEIC. Install `pillow-heif` and
register it: `from pillow_heif import register_heif_opener; register_heif_opener()`.
If that package is unavailable, `generate_thumbnail` returns `None` — the app will generate
the thumbnail on first open.

**Video thumbnails:** Use `ffmpeg` via subprocess:

```python
import subprocess, tempfile, os

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
    except Exception:
        return None
    finally:
        try: os.unlink(tmp_path)
        except OSError: pass
```

---

## 10. Face Detection Pipeline — `face_pipeline.py`

### 10.1 Backend Selection

```python
def load_face_detector(backend: str):
    if backend == "mediapipe":
        return MediaPipeFaceDetector()
    if backend == "insightface":
        return InsightFaceDetector()
    return None
```

### 10.2 Bounding Box Convention

All face coordinates entering the DB are stored at **0–10000 scale** with:
- `image_width = 10000`, `image_height = 10000` (the normalized coordinate space)
- `bounding_box_x1 = round(norm_left   * 10000)`
- `bounding_box_y1 = round(norm_top    * 10000)`
- `bounding_box_x2 = round(norm_right  * 10000)`
- `bounding_box_y2 = round(norm_bottom * 10000)`

MediaPipe returns normalized floats (0.0–1.0) directly — just multiply by 10000.
InsightFace returns pixel coordinates — divide by image width/height first.

### 10.3 Square Face Crop — Python port of `_cropFace`

The Dart `_cropFace` method (in `ml_worker.service.dart` lines 153–206) uses this algorithm.
The Python equivalent uses Pillow:

```python
from PIL import Image
import io

def crop_face(img_path: str, norm_left: float, norm_top: float,
              norm_right: float, norm_bottom: float) -> bytes | None:
    """
    Square crop centred on face with 1.4× padding, resized to 256×256 JPEG.
    norm_* are normalized 0.0–1.0 coordinates of the bounding box.

    Algorithm mirrors ml_worker.service.dart _cropFace:
      cx = (left + right) / 2
      cy = (top + bottom) / 2
      half = max(width, height) / 2 * 1.4
      src = clamp([cx-half .. cx+half] × [cy-half .. cy+half] to image bounds)
      resize src region to 256×256
    """
    try:
        with Image.open(img_path) as img:
            img = _apply_exif_orientation(img)
            img = img.convert("RGB")
            iw, ih = img.size

            cx = (norm_left + norm_right) / 2.0
            cy = (norm_top + norm_bottom) / 2.0
            bbox_w = norm_right - norm_left
            bbox_h = norm_bottom - norm_top
            half = max(bbox_w, bbox_h) / 2.0 * 1.4

            # Convert to pixel coords and clamp
            left   = max(0,  int((cx - half) * iw))
            top    = max(0,  int((cy - half) * ih))
            right  = min(iw, int((cx + half) * iw))
            bottom = min(ih, int((cy + half) * ih))

            if right <= left or bottom <= top:
                return None

            crop = img.crop((left, top, right, bottom))
            crop = crop.resize((256, 256), Image.LANCZOS)

            buf = io.BytesIO()
            crop.save(buf, format="JPEG", quality=85)
            return buf.getvalue()
    except Exception:
        return None
```

### 10.4 MediaPipe Detector

```python
# pip install mediapipe
import mediapipe as mp
from dataclasses import dataclass

@dataclass
class NormBBox:
    left: float; top: float; right: float; bottom: float

class MediaPipeFaceDetector:
    def __init__(self, min_confidence: float = 0.5):
        self._detector = mp.solutions.face_detection.FaceDetection(
            model_selection=1,  # full-range model
            min_detection_confidence=min_confidence,
        )

    def detect(self, img_path: str) -> list[NormBBox]:
        import cv2
        img = cv2.imread(img_path)
        if img is None:
            return []
        rgb = cv2.cvtColor(img, cv2.COLOR_BGR2RGB)
        result = self._detector.process(rgb)
        if not result.detections:
            return []
        boxes = []
        for det in result.detections:
            bb = det.location_data.relative_bounding_box
            boxes.append(NormBBox(
                left=max(0.0, bb.xmin),
                top=max(0.0, bb.ymin),
                right=min(1.0, bb.xmin + bb.width),
                bottom=min(1.0, bb.ymin + bb.height),
            ))
        return boxes

    def close(self):
        self._detector.close()
```

### 10.5 InsightFace Detector (alternative)

```python
# pip install insightface onnxruntime
import insightface, cv2

class InsightFaceDetector:
    def __init__(self):
        self._app = insightface.app.FaceAnalysis(
            name="buffalo_s", providers=["CPUExecutionProvider"]
        )
        self._app.prepare(ctx_id=0)

    def detect(self, img_path: str) -> list[NormBBox]:
        img = cv2.imread(img_path)
        if img is None:
            return []
        ih, iw = img.shape[:2]
        faces = self._app.get(img)
        boxes = []
        for face in faces:
            x1, y1, x2, y2 = face.bbox
            boxes.append(NormBBox(
                left=max(0.0, x1 / iw),
                top=max(0.0, y1 / ih),
                right=min(1.0, x2 / iw),
                bottom=min(1.0, y2 / ih),
            ))
        return boxes

    def close(self):
        pass
```

---

## 11. OCR Pipeline — `ocr_pipeline.py`

```python
def load_ocr(backend: str, languages: list[str]):
    if backend == "easyocr":
        import easyocr
        return EasyOCRBackend(easyocr.Reader(languages, gpu=False))
    if backend == "pytesseract":
        return TesseractBackend()
    return None

class EasyOCRBackend:
    def __init__(self, reader): self._r = reader
    def read(self, img_path: str) -> str:
        results = self._r.readtext(img_path, detail=0)
        return " ".join(results)

class TesseractBackend:
    def read(self, img_path: str) -> str:
        import pytesseract
        from PIL import Image
        return pytesseract.image_to_string(Image.open(img_path))
```

---

## 12. Label Pipeline — `label_pipeline.py`

```python
# CLIP zero-shot labels
# pip install torch torchvision open-clip-torch

IMAGENET_LABELS = [
    "person", "animal", "dog", "cat", "bird", "car", "bicycle", "food",
    "building", "landscape", "beach", "mountain", "forest", "city", "night",
    "indoor", "outdoor", "sport", "celebration", "document", "text",
]

class CLIPLabeler:
    def __init__(self, threshold: float = 0.20):
        import open_clip, torch
        self._model, _, self._preprocess = open_clip.create_model_and_transforms(
            "ViT-B-32", pretrained="openai"
        )
        self._tokenizer = open_clip.get_tokenizer("ViT-B-32")
        self._threshold = threshold
        self._model.eval()
        self._text_features = None  # lazy init on first call

    def label(self, img_path: str) -> list[tuple[str, float]]:
        """Returns list of (label, confidence) pairs above threshold."""
        import torch
        from PIL import Image
        if self._text_features is None:
            texts = self._tokenizer(IMAGENET_LABELS)
            with torch.no_grad():
                self._text_features = self._model.encode_text(texts)
                self._text_features /= self._text_features.norm(dim=-1, keepdim=True)

        img = self._preprocess(Image.open(img_path).convert("RGB")).unsqueeze(0)
        with torch.no_grad():
            img_feat = self._model.encode_image(img)
            img_feat /= img_feat.norm(dim=-1, keepdim=True)
            probs = (img_feat @ self._text_features.T).softmax(dim=-1)[0]

        return [
            (IMAGENET_LABELS[i], float(probs[i]))
            for i in range(len(IMAGENET_LABELS))
            if float(probs[i]) >= self._threshold
        ]
```

---

## 13. SQLite Schema — `db_builder.py`

Create a fresh SQLite database matching **schema version 28** exactly. Use the `sqlite3`
standard-library module — no ORM.

The full `CREATE TABLE` statements are in `takeout_migrate_spec.md` section 6. This section
documents the Python layer around them and highlights Python-specific code snippets.

### 13.1 Schema Version Pragma

```python
import sqlite3

def set_schema_version(conn: sqlite3.Connection, version: int = 28) -> None:
    conn.execute(f"PRAGMA user_version = {version}")
```

Must be called **after** all `CREATE TABLE` statements, **before** closing.

### 13.2 PRAGMA Settings (match app's `beforeOpen`)

```python
def apply_pragmas(conn: sqlite3.Connection) -> None:
    conn.execute("PRAGMA foreign_keys = ON")
    conn.execute("PRAGMA journal_mode = WAL")
    conn.execute("PRAGMA synchronous = NORMAL")
    conn.execute("PRAGMA cache_size = -32000")
    conn.execute("PRAGMA temp_store = MEMORY")
```

### 13.3 `asset_fts` FTS5 Insert

FTS5 virtual tables require a special `INSERT` syntax:

```python
def insert_ocr_text(conn: sqlite3.Connection, asset_id: str,
                    ocr_text: str, labels: str = "") -> None:
    """
    FTS5 insert. The rowid is auto-assigned; asset_id is UNINDEXED so it
    cannot be the rowid — use a regular INSERT with all columns.
    On re-run use INSERT OR REPLACE (FTS5 supports REPLACE via the content table).
    """
    conn.execute(
        "INSERT OR REPLACE INTO asset_fts(asset_id, ocr_text, labels) VALUES (?, ?, ?)",
        (asset_id, ocr_text, labels),
    )
```

To delete a stale FTS row (e.g. on retry):

```python
# FTS5 delete: INSERT with special value -1 for the implicit rowid column
conn.execute(
    "INSERT INTO asset_fts(asset_fts, rowid, asset_id, ocr_text, labels) "
    "VALUES('delete', ?, ?, ?, ?)",
    (rowid, asset_id, ocr_text, labels),
)
```

In practice for a fresh migration, `INSERT OR REPLACE` is sufficient.

### 13.4 `local_asset_entity` — `face_processed` Column

The `face_processed` column is added by `FaceMlSchema.ensureColumns()` as an `ALTER TABLE`
(not part of the original Drift schema). To pre-populate it (so the app does not re-detect
faces already in the DB), either:

- **Option A (simplest):** Create `local_asset_entity` with `face_processed` already in the
  schema. The migration tool owns the DB from scratch, so this is safe.
- **Option B:** Create without it, then run the ALTER after schema creation.

Use Option A. Include `face_processed INTEGER NOT NULL DEFAULT 0` in the
`CREATE TABLE local_asset_entity` statement. After inserting face data for an asset, update:

```python
conn.execute(
    "UPDATE local_asset_entity SET face_processed = 1 WHERE id = ?",
    (local_asset_id,),
)
```

**Note:** `local_asset_entity` is populated by the Flutter app from the device photo library.
The migration tool populates `remote_asset_entity`. If you do NOT populate
`local_asset_entity`, set `face_processed` in `remote_asset_entity` is irrelevant — the ML
worker reads `local_asset_entity.face_processed`. When `--skip-faces` is used, leave
`face_processed = 0` so the app detects faces on-device after the first sync.

### 13.5 DB Builder Sketch

```python
class DbBuilder:
    def __init__(self, path: str):
        self._conn = sqlite3.connect(path)
        self._conn.row_factory = sqlite3.Row
        apply_pragmas(self._conn)
        self._create_schema()
        set_schema_version(self._conn, 28)

    def _create_schema(self):
        # Copy all CREATE TABLE and CREATE INDEX statements verbatim from
        # takeout_migrate_spec.md section 6. Use IF NOT EXISTS throughout.
        stmts = [CREATE_USER_ENTITY, CREATE_REMOTE_ASSET_ENTITY, ...]
        for stmt in stmts:
            self._conn.execute(stmt)
        self._conn.commit()

    def checksum_exists(self, owner_id: str, checksum: str) -> bool:
        row = self._conn.execute(
            "SELECT id FROM remote_asset_entity "
            "WHERE owner_id = ? AND checksum = ? LIMIT 1",
            (owner_id, checksum),
        ).fetchone()
        return row is not None

    def insert_asset(self, asset_id: str, photo: TakeoutPhoto,
                     checksum: str, owner_id: str, now_ms: int) -> None:
        sidecar = photo.sidecar
        if sidecar:
            created_ms = int(sidecar.photo_taken_at.timestamp() * 1000)
        else:
            created_ms = int(os.path.getmtime(photo.local_path) * 1000)

        asset_type = 1 if not photo.is_video else 2
        self._conn.execute("""
            INSERT OR IGNORE INTO remote_asset_entity
              (id, name, type, created_at, updated_at, checksum,
               is_favorite, owner_id, local_date_time, visibility,
               uploaded_at, source_device_id)
            VALUES (?, ?, ?, ?, ?, ?, 0, ?, ?, 0, ?, 'google-takeout')
        """, (asset_id, photo.filename, asset_type, created_ms,
              now_ms, checksum, owner_id, created_ms, now_ms))

        self._conn.execute("""
            INSERT OR IGNORE INTO remote_exif_entity
              (asset_id, date_time_original, latitude, longitude,
               description, file_size)
            VALUES (?, ?, ?, ?, ?, ?)
        """, (asset_id,
              created_ms,
              sidecar.latitude if sidecar else None,
              sidecar.longitude if sidecar else None,
              sidecar.description if sidecar else None,
              os.path.getsize(photo.local_path)))

    def insert_face(self, face_id: str, asset_id: str, person_id: str,
                    bbox: NormBBox) -> None:
        def sc(v): return round(v * 10000)
        self._conn.execute("""
            INSERT OR IGNORE INTO asset_face_entity
              (id, asset_id, person_id, image_width, image_height,
               bounding_box_x1, bounding_box_y1, bounding_box_x2, bounding_box_y2,
               source_type, is_visible)
            VALUES (?, ?, ?, 10000, 10000, ?, ?, ?, ?, 'ml_kit', 1)
        """, (face_id, asset_id, person_id,
              sc(bbox.left), sc(bbox.top), sc(bbox.right), sc(bbox.bottom)))

    def insert_person(self, person_id: str, owner_id: str,
                      face_asset_key: str | None) -> None:
        """face_asset_key is 'faces/{personId}.jpg' (without .thumbs/ prefix)."""
        now_ms = int(datetime.now(tz=timezone.utc).timestamp() * 1000)
        self._conn.execute("""
            INSERT OR IGNORE INTO person_entity
              (id, created_at, updated_at, owner_id, name,
               face_asset_id, is_favorite, is_hidden)
            VALUES (?, ?, ?, ?, '', ?, 0, 0)
        """, (person_id, now_ms, now_ms, owner_id, face_asset_key))

    def insert_label(self, asset_id: str, label: str, confidence: float) -> None:
        self._conn.execute("""
            INSERT INTO asset_label_entity (asset_id, label, source, confidence)
            VALUES (?, ?, 'imageLabeler', ?)
        """, (asset_id, label, confidence))

    def insert_album(self, album_id: str, name: str) -> None:
        now_ms = int(datetime.now(tz=timezone.utc).timestamp() * 1000)
        self._conn.execute("""
            INSERT OR IGNORE INTO remote_album_entity
              (id, name, description, created_at, updated_at, "order")
            VALUES (?, ?, '', ?, ?, 0)
        """, (album_id, name, now_ms, now_ms))

    def link_asset_album(self, asset_id: str, album_id: str) -> None:
        self._conn.execute("""
            INSERT OR IGNORE INTO remote_album_asset_entity (asset_id, album_id)
            VALUES (?, ?)
        """, (asset_id, album_id))

    def insert_owner(self, owner_id: str, name: str, email: str) -> None:
        self._conn.execute("""
            INSERT OR IGNORE INTO user_entity (id, name, email, has_profile_image, avatar_color)
            VALUES (?, ?, ?, 0, 0)
        """, (owner_id, name, email))

    def commit(self):
        self._conn.commit()

    def close(self):
        self._conn.commit()
        self._conn.close()
```

### 13.6 Album ID — Deterministic UUID from Folder Name

```python
import hashlib, uuid as uuid_mod

def album_id_for(folder_name: str) -> str:
    """Stable UUID v5-style from folder name so re-runs don't create duplicate albums."""
    digest = hashlib.sha1(folder_name.encode()).digest()
    # Lay 16 bytes into UUID hex format
    hex_ = digest[:16].hex()
    return f"{hex_[:8]}-{hex_[8:12]}-{hex_[12:16]}-{hex_[16:20]}-{hex_[20:32]}"
```

---

## 14. S3 Uploader — `s3_uploader.py`

### 14.1 boto3 Client Setup

```python
import boto3
from botocore.config import Config

def build_s3_client(cfg: TakeoutConfig):
    """
    Works for AWS S3, MinIO, and Cloudflare R2.
    For R2: endpoint_url = 'https://{account_id}.r2.cloudflarestorage.com'
    For MinIO: endpoint_url = 'http://localhost:9000'
    """
    kwargs = dict(
        aws_access_key_id=cfg.access_key,
        aws_secret_access_key=cfg.secret_key,
        region_name=cfg.region,
        config=Config(
            retries={"max_attempts": 3, "mode": "adaptive"},
            max_pool_connections=cfg.upload_workers + 2,
        ),
    )
    # Only set endpoint_url for non-AWS providers
    # For AWS standard endpoints, omit endpoint_url (boto3 derives it from region).
    # If endpoint looks like amazonaws.com, skip it; otherwise always set it.
    import re
    if not re.search(r'amazonaws\.com', cfg.endpoint):
        scheme = "https" if cfg.use_ssl else "http"
        ep = cfg.endpoint
        if not ep.startswith("http"):
            ep = f"{scheme}://{ep}"
        kwargs["endpoint_url"] = ep

    return boto3.client("s3", **kwargs)
```

### 14.2 Multithreaded Upload Pool

```python
from concurrent.futures import ThreadPoolExecutor, as_completed

def upload_all(s3, bucket: str, uploads: list[tuple[str, bytes, str]],
               workers: int = 8, progress_cb=None) -> list[str]:
    """
    uploads: list of (s3_key, data_bytes, content_type)
    Returns list of keys that failed.
    """
    failed = []

    def _put(item):
        key, data, ct = item
        s3.put_object(Bucket=bucket, Key=key, Body=data, ContentType=ct)
        return key

    with ThreadPoolExecutor(max_workers=workers) as pool:
        futures = {pool.submit(_put, item): item[0] for item in uploads}
        for fut in as_completed(futures):
            key = futures[fut]
            try:
                fut.result()
                if progress_cb:
                    progress_cb(key)
            except Exception as e:
                print(f"\n  FAILED {key}: {e}")
                failed.append(key)
    return failed
```

### 14.3 Content-Type Mapping

```python
CONTENT_TYPES = {
    "jpg": "image/jpeg", "jpeg": "image/jpeg",
    "png": "image/png",
    "heic": "image/heic", "heif": "image/heif",
    "gif": "image/gif",
    "mp4": "video/mp4",
    "mov": "video/quicktime",
    "3gp": "video/3gpp",
    "avi": "video/x-msvideo",
    "mkv": "video/x-matroska",
    "mp": "image/jpeg",   # Google Motion Photo = JPEG with embedded MP4
}

def content_type_for(ext: str) -> str:
    return CONTENT_TYPES.get(ext.lower(), "application/octet-stream")
```

---

## 14.4 Local Output Mode — `local_writer.py`

`--no-upload OUTPUT_DIR` replaces the S3 client with a `LocalWriter` that mirrors the exact S3
key structure on disk. No S3 credentials required. Useful for testing the pipeline, inspecting
output, or copying to S3 manually later.

Output folder layout matches S3 exactly:

```
output_dir/
  2024/08/01/IMG_001.jpg          ← original
  .thumbs/
    2024/08/01/IMG_001.jpg        ← thumbnail
    faces/
      {personId}.jpg              ← face crop
  .meta/
    s3immich.db                   ← SQLite database
```

```python
import shutil
from pathlib import Path

class LocalWriter:
    """Writes files to a local directory mirroring the S3 key structure."""

    def __init__(self, output_dir: str):
        self.root = Path(output_dir).resolve()
        self.root.mkdir(parents=True, exist_ok=True)

    def put(self, key: str, data: bytes, content_type: str = "") -> None:
        """Write bytes to output_dir/key, creating parent dirs as needed."""
        dest = self.root / key.lstrip("/\\")
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(data)

    def put_file(self, key: str, src_path: str, content_type: str = "") -> None:
        """Copy a file to output_dir/key (avoids reading large originals into RAM)."""
        dest = self.root / key.lstrip("/\\")
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src_path, dest)

    def put_all(self, items: list[tuple[str, bytes, str]], workers: int = 1,
                progress_cb=None) -> list[str]:
        """Write a batch of (key, data, content_type) items. Returns failed keys."""
        failed = []
        for key, data, ct in items:
            try:
                self.put(key, data, ct)
                if progress_cb:
                    progress_cb(key)
            except Exception as e:
                print(f"\n  FAILED {key}: {e}")
                failed.append(key)
        return failed
```

### Unified sink helper (`s3_uploader.py` addition)

Add this at the bottom of `s3_uploader.py` so `migrate.py` can write identical phase code for
both S3 and local modes:

```python
def write_all(sink, items: list[tuple[str, bytes, str]], workers: int = 8,
              progress_cb=None) -> list[str]:
    """
    sink: either a boto3 S3 client dict wrapper or a LocalWriter.
    Dispatches to upload_all (S3) or local_writer.put_all.
    items: list of (key, data_bytes, content_type)
    """
    if isinstance(sink, LocalWriter):
        return sink.put_all(items, workers=1, progress_cb=progress_cb)
    # S3 path: sink is (s3_client, bucket_name)
    s3_client, bucket = sink
    return upload_all(s3_client, bucket, items, workers, progress_cb)

def write_file(sink, key: str, src_path: str, content_type: str = "") -> None:
    """Copy/upload a single file without reading it into RAM (for large originals)."""
    if isinstance(sink, LocalWriter):
        sink.put_file(key, src_path, content_type)
    else:
        s3_client, bucket = sink
        with open(src_path, "rb") as f:
            s3_client.put_object(Bucket=bucket, Key=key, Body=f,
                                 ContentType=content_type)
```

### S3 credentials in `--no-upload` mode

When `--no-upload` is set, skip all S3 env-var validation in `TakeoutConfig.from_env()` so the
tool works without any `.env` S3 settings:

```python
# In config.py
@classmethod
def from_env(cls, env_file=".env", require_s3=True):
    ...
    if require_s3:
        access_key = _require(env, "S3_ACCESS_KEY")
        secret_key = _require(env, "S3_SECRET_KEY")
        endpoint   = _require(env, "S3_ENDPOINT")
        bucket     = _require(env, "S3_BUCKET")
    else:
        access_key = env.get("S3_ACCESS_KEY", "")
        secret_key = env.get("S3_SECRET_KEY", "")
        endpoint   = env.get("S3_ENDPOINT", "")
        bucket     = env.get("S3_BUCKET", "")
    ...
```

---

## 15. Progress Tracker — `progress.py`

```python
import json, os
from threading import Lock

class ProgressTracker:
    """Thread-safe JSON-backed progress store."""

    def __init__(self, path: str = ".migrate_progress.json"):
        self._path = path
        self._lock = Lock()
        self._data = self._load()

    def _load(self) -> dict:
        if os.path.exists(self._path):
            with open(self._path) as f:
                return json.load(f)
        return {"version": 1, "originals": set(), "thumbs": set(), "files": {}}

    def _save(self):
        # Convert sets to sorted lists for JSON
        out = {
            "version": 1,
            "originals": sorted(self._data["originals"]),
            "thumbs": sorted(self._data["thumbs"]),
            "files": self._data["files"],
        }
        with open(self._path, "w") as f:
            json.dump(out, f, indent=2)

    def _deserialize(self, raw: dict) -> dict:
        raw["originals"] = set(raw.get("originals", []))
        raw["thumbs"] = set(raw.get("thumbs", []))
        return raw

    def is_original_done(self, asset_id: str) -> bool:
        with self._lock:
            return asset_id in self._data["originals"]

    def is_thumb_done(self, asset_id: str) -> bool:
        with self._lock:
            return asset_id in self._data["thumbs"]

    def mark_original_done(self, asset_id: str):
        with self._lock:
            self._data["originals"].add(asset_id)
            self._save()

    def mark_thumb_done(self, asset_id: str):
        with self._lock:
            self._data["thumbs"].add(asset_id)
            self._save()

    def get_asset_id(self, local_path: str) -> str | None:
        with self._lock:
            return self._data["files"].get(local_path, {}).get("asset_id")

    def register_file(self, local_path: str, asset_id: str, checksum: str):
        with self._lock:
            self._data["files"][local_path] = {
                "asset_id": asset_id,
                "checksum": checksum,
            }
            self._save()
```

On re-run: if `.migrate_progress.json` exists, `mark_original_done` / `is_original_done`
skip S3 uploads for already-completed assets. The DB is always rebuilt from scratch on re-run
(to stay consistent), but checksums in `files` are reused to avoid re-hashing.

---

## 16. ML Phase Ordering

All ML processing runs **before** output so the DB is fully populated before being written/uploaded.

```
Phase 1: Scan Takeout → TakeoutPhoto list
Phase 2: Assign IDs, compute checksums, dedup
Phase 3: ML (faces → OCR → labels) — modifies DB in memory
Phase 4: Write/upload originals  (parallel pool or local copy)
Phase 5: Write/upload thumbnails (parallel pool or local copy)
Phase 6: Write/upload face crops (parallel pool or local copy, if --skip-faces not set)
Phase 7: Write/upload DB to .meta/s3immich.db (single operation)
```

In `--no-upload OUTPUT_DIR` mode phases 4–7 write to `OUTPUT_DIR/{key}` instead of S3.
In `--dry-run` mode phases 4–7 are skipped entirely (scan + ML only, DB saved locally).

---

## 17. Entry Point — `migrate.py`

```python
#!/usr/bin/env python3
"""
Google Takeout → S3/SQLite migration tool for server-free Immich fork.

Usage:
    python migrate.py [options]

Options:
    --env FILE          .env file path (default: .env)
    --skip-faces        Skip face detection (app detects on-device)
    --skip-ocr          Skip OCR text extraction
    --skip-labels       Skip image labeling
    --include-trashed   Include photos marked as trashed in Takeout
    --include-archived  Include archived photos (default: True)
    --include-videos    Include video files (default: True)
    --dry-run           Scan and compute checksums but do not write output
    --no-upload DIR     Write all output to DIR (mirrors S3 layout) instead of uploading
    --db-path FILE      Local SQLite output path (default: .migrate_temp.db)
    --progress FILE     Progress file path (default: .migrate_progress.json)
"""

import argparse, os, sys, time, uuid
from datetime import datetime, timezone

def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--env", default=".env")
    parser.add_argument("--skip-faces", action="store_true")
    parser.add_argument("--skip-ocr", action="store_true")
    parser.add_argument("--skip-labels", action="store_true")
    parser.add_argument("--include-trashed", action="store_true")
    parser.add_argument("--include-archived", action="store_true", default=True)
    parser.add_argument("--include-videos", action="store_true", default=True)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--no-upload", metavar="DIR",
                        help="Write output to local DIR instead of uploading to S3")
    parser.add_argument("--db-path", default=".migrate_temp.db")
    parser.add_argument("--progress", default=".migrate_progress.json")
    args = parser.parse_args()

    no_upload = args.no_upload  # str path or None
    cfg = TakeoutConfig.from_env(args.env, require_s3=(no_upload is None))
    progress = ProgressTracker(args.progress)

    # ── Phase 1: Scan ──────────────────────────────────────────────────────────
    print(f"Scanning {cfg.takeout_dir} …")
    photos = scan_takeout(cfg.takeout_dir)
    if not args.include_trashed:
        photos = [p for p in photos if not (p.sidecar and p.sidecar.trashed)]
    if not args.include_videos:
        photos = [p for p in photos if not p.is_video]
    print(f"Found {len(photos)} media files.")

    # ── Phase 2: Assign IDs + checksums ──────────────────────────────────────
    db = DbBuilder(args.db_path)
    db.insert_owner(cfg.owner_id, cfg.owner_name, cfg.owner_email)

    asset_list: list[tuple[str, TakeoutPhoto]] = []  # (asset_id, photo)
    seen_checksums: set[str] = set()
    album_map: dict[str, str] = {}  # folder_name → album_id

    print("Computing checksums …")
    for photo in photos:
        cached_id = progress.get_asset_id(photo.local_path)
        if cached_id:
            asset_list.append((cached_id, photo))
            continue
        checksum = sha1_base64(photo.local_path)
        if db.checksum_exists(cfg.owner_id, checksum) or checksum in seen_checksums:
            print(f"  SKIP (duplicate): {photo.filename}")
            # Still link to albums
            existing_id = _get_existing_id(db, cfg.owner_id, checksum)
            if existing_id:
                asset_list.append((existing_id, photo))
            continue
        taken_at = photo.sidecar.photo_taken_at if photo.sidecar else datetime.now(tz=timezone.utc)
        asset_id = s3_key_for(photo.filename, taken_at, cfg.prefix)
        seen_checksums.add(checksum)
        progress.register_file(photo.local_path, asset_id, checksum)
        db.insert_asset(asset_id, photo, checksum, cfg.owner_id,
                        int(time.time() * 1000))
        asset_list.append((asset_id, photo))

    # Albums
    for asset_id, photo in asset_list:
        for album_name in photo.album_names:
            if album_name not in album_map:
                aid = album_id_for(album_name)
                album_map[album_name] = aid
                db.insert_album(aid, album_name)
            db.link_asset_album(asset_id, album_map[album_name])
    db.commit()

    # ── Phase 3: ML ────────────────────────────────────────────────────────────
    if not (args.skip_faces and args.skip_ocr and args.skip_labels):
        face_det = None if args.skip_faces else load_face_detector(cfg.face_backend)
        ocr = None if args.skip_ocr else load_ocr(cfg.ocr_backend, cfg.ocr_languages)
        labeler = None if args.skip_labels else load_labeler(cfg.label_backend, cfg.label_threshold)

        face_crops: list[tuple[str, bytes]] = []  # (s3_key, jpeg_bytes)

        print(f"Running ML on {len(asset_list)} assets …")
        for i, (asset_id, photo) in enumerate(asset_list):
            if photo.is_video:
                continue
            img_path = photo.local_path

            if face_det is not None:
                bboxes = face_det.detect(img_path)
                for bbox in bboxes:
                    person_id = str(uuid.uuid4())
                    face_id   = str(uuid.uuid4())
                    face_key  = f"faces/{person_id}.jpg"
                    crop_bytes = crop_face(img_path, bbox.left, bbox.top,
                                           bbox.right, bbox.bottom)
                    if crop_bytes:
                        face_crops.append((f".thumbs/{face_key}", crop_bytes))
                    db.insert_person(person_id, cfg.owner_id,
                                     face_key if crop_bytes else None)
                    db.insert_face(face_id, asset_id, person_id, bbox)

            if ocr is not None:
                text = ocr.read(img_path)
                if text.strip():
                    insert_ocr_text(db._conn, asset_id, text)

            if labeler is not None:
                for label, conf in labeler.label(img_path):
                    db.insert_label(asset_id, label, conf)

            if (i + 1) % 50 == 0:
                db.commit()
                print(f"  ML: {i+1}/{len(asset_list)}")

        db.commit()

    if args.dry_run:
        print("Dry run — skipping output.")
        db.close()
        return

    # ── Build sink (S3 or local directory) ───────────────────────────────────
    if no_upload:
        from local_writer import LocalWriter
        sink = LocalWriter(no_upload)
        sink_label = f"local:{no_upload}"
    else:
        s3_client = build_s3_client(cfg)
        sink = (s3_client, cfg.bucket)
        sink_label = f"s3://{cfg.bucket}"

    # ── Phase 4: Write originals ──────────────────────────────────────────────
    print(f"\nWriting originals → {sink_label} (workers={cfg.upload_workers}) …")
    for asset_id, photo in asset_list:
        if progress.is_original_done(asset_id):
            continue
        ct = content_type_for(photo.extension)
        write_file(sink, asset_id, photo.local_path, ct)
        progress.mark_original_done(asset_id)
    print("Originals done.")

    # ── Phase 5: Write thumbnails ─────────────────────────────────────────────
    print("Generating and writing thumbnails …")
    thumb_items = []
    for asset_id, photo in asset_list:
        if progress.is_thumb_done(asset_id):
            continue
        thumb = (generate_video_thumbnail(photo.local_path)
                 if photo.is_video
                 else generate_thumbnail(photo.local_path))
        if thumb:
            thumb_key = f".thumbs/{asset_id}"
            thumb_items.append((thumb_key, thumb, "image/jpeg"))

    def _mark_thumb(key):
        progress.mark_thumb_done(key.removeprefix(".thumbs/"))
    write_all(sink, thumb_items, cfg.upload_workers, _mark_thumb)
    print(f"Thumbnails done ({len(thumb_items)} written).")

    # ── Phase 6: Write face crops ─────────────────────────────────────────────
    if face_crops:
        print(f"Writing {len(face_crops)} face crops …")
        write_all(sink, [(k, b, "image/jpeg") for k, b in face_crops],
                  cfg.upload_workers)
        print("Face crops done.")

    # ── Phase 7: Write DB ─────────────────────────────────────────────────────
    db.close()
    print("Writing database …")
    with open(args.db_path, "rb") as f:
        db_bytes = f.read()
    write_all(sink, [(".meta/s3immich.db", db_bytes, "application/octet-stream")])
    print(f"Done. Database → {sink_label}/.meta/s3immich.db")
    print(f"Total assets: {len(asset_list)}")

if __name__ == "__main__":
    main()
```

---

## 18. Album Handling

Each named folder in Takeout that does NOT match `^Photos from \d{4}$` becomes an album.

- One `remote_album_entity` row per unique folder name (deterministic UUID via SHA-1 of name).
- One `remote_album_asset_entity` row per `(asset_id, album_id)` pair.
- Photos in `Photos from YYYY` folders appear in the timeline but no album.
- Photos appearing in multiple album folders get one `remote_asset_entity` row but multiple
  `remote_album_asset_entity` rows — no S3 file duplication.
- The `thumbnail_asset_id` column in `remote_album_entity` is set to `NULL`; the app
  auto-selects a thumbnail on first open.

---

## 19. Deduplication

```
Before inserting a remote_asset_entity row:
  1. Compute SHA-1 base64 checksum
  2. Query: SELECT id FROM remote_asset_entity WHERE owner_id=? AND checksum=? LIMIT 1
  3. If found → skip S3 upload and DB insert; still link to album
  4. If not found → proceed
```

The UNIQUE index `UQ_remote_assets_owner_checksum` on `(owner_id, checksum) WHERE
library_id IS NULL` enforces this at the DB level. The Python check before insertion avoids
the exception.

---

## 20. Known Edge Cases

| Situation | Handling |
|-----------|----------|
| Truncated sidecar: `.supplemental-metada.json` | `match_normal` checks `HasPrefix("supplemental-metadata", ...)` — matches both spellings |
| Edited photos (`-edited` suffix) | `match_edited_name` handles any suffix starting with the base name |
| Same photo in multiple album folders | First occurrence inserted; subsequent merge album names via `file_tracker` |
| Duplicate files (same checksum, different filename) | `checksum_exists()` skips insert; still links to album |
| HEIC without `pillow-heif` | `generate_thumbnail` returns None — no thumbnail uploaded; app handles on-device |
| Motion photos (`.MP` extension) | Treated as `image/jpeg`; `asset_type = 1` |
| Videos in `Failed Videos` subfolder | Skip (matches immich-go behavior) |
| Zero-byte files | Skip (checksum would collide with all other zero-byte files) |
| `Trash/` folder | Skip unless `--include-trashed`; sidecar `trashed=true` also filtered |
| Files without sidecar JSON | Included if `--include-unmatched` (default: skip, matches immich-go `KeepJSONLess=false`) |
| Filename > 255 bytes on filesystem | Python `os.walk` handles it; skip and log if `open()` raises `OSError` |
| Burst photos / series | Not grouped — each is an independent asset (grouping happens in app) |

---

## 21. Error Handling

- **Per-file ML errors** (detection crash, decode failure): log and continue; mark with
  `face_processed = 0` so app retries on-device.
- **Per-file upload errors** (S3 put failure): log to `.migrate_errors.json`; `boto3`
  retries 3× automatically via `Config(retries={"max_attempts": 3})`.
- **DB errors** (constraint violation, disk full): fatal — stop before uploading the DB.
- **Missing `ffmpeg`** for video thumbnails: catch `FileNotFoundError`, skip thumbnail.

```python
import json as _json

def log_error(path: str, asset_id: str, error: str,
              errors_file: str = ".migrate_errors.json"):
    errors = []
    if os.path.exists(errors_file):
        with open(errors_file) as f:
            errors = _json.load(f)
    errors.append({"asset_id": asset_id, "path": path, "error": str(error)})
    with open(errors_file, "w") as f:
        _json.dump(errors, f, indent=2)
```

---

## 22. Verification (spot-check after upload)

```python
def verify_sample(s3, bucket: str, asset_ids: list[str], n: int = 10):
    for asset_id in asset_ids[:n]:
        try:
            s3.head_object(Bucket=bucket, Key=asset_id)
            orig_ok = True
        except Exception:
            orig_ok = False
        try:
            s3.head_object(Bucket=bucket, Key=f".thumbs/{asset_id}")
            thumb_ok = True
        except Exception:
            thumb_ok = False
        print(f"  {asset_id}: original={'OK' if orig_ok else 'MISSING'} "
              f"thumb={'OK' if thumb_ok else 'MISSING'}")
```

---

## 23. Implementation Checklist

- [ ] `python -m venv .venv && pip install -r requirements.txt`
- [ ] Copy full CREATE TABLE statements from `takeout_migrate_spec.md` §6 into `db_builder.py`
- [ ] Implement `sha1_base64()` in `checksum.py`
- [ ] Implement `scan_takeout()` with both sidecar suffixes and album detection
- [ ] Implement `_parse_sidecar()` with epoch-ms conversion and GPS fallback
- [ ] Implement `generate_thumbnail()` with EXIF orientation
- [ ] Implement `generate_video_thumbnail()` via ffmpeg subprocess
- [ ] Implement `crop_face()` matching `_cropFace` algorithm exactly
- [ ] Implement `MediaPipeFaceDetector` (and optionally `InsightFaceDetector`)
- [ ] Implement `EasyOCRBackend` / `TesseractBackend`
- [ ] Implement `CLIPLabeler`
- [ ] Implement `ProgressTracker` with thread-safe JSON persistence
- [ ] Implement `upload_all()` with `ThreadPoolExecutor`
- [ ] Implement `build_s3_client()` for AWS + MinIO/R2
- [ ] Set `PRAGMA user_version = 28` after schema creation
- [ ] Insert `user_entity` row for owner
- [ ] Run full pipeline: scan → checksum → ML → upload originals → thumbs → crops → DB
- [ ] Verify: open app → configure S3 → confirm photos appear in timeline and albums
