import io
import os
from dataclasses import dataclass
from PIL import Image

from thumbnail import _apply_exif_orientation


@dataclass
class NormBBox:
    left: float
    top: float
    right: float
    bottom: float


def load_face_detector(backend: str):
    if backend == "mediapipe":
        return MediaPipeFaceDetector()
    if backend == "insightface":
        return InsightFaceDetector()
    return None


def crop_face(img_path: str, norm_left: float, norm_top: float,
              norm_right: float, norm_bottom: float) -> bytes | None:
    """
    Square crop centred on face with 1.4× padding, resized to 256×256 JPEG.
    Mirrors ml_worker.service.dart _cropFace algorithm.
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


_MODEL_URL = (
    "https://storage.googleapis.com/mediapipe-models/face_detector/"
    "blaze_face_short_range/float16/latest/blaze_face_short_range.tflite"
)
_MODEL_PATH = os.path.join(os.path.dirname(__file__), "blaze_face_short_range.tflite")


def _ensure_model():
    if not os.path.exists(_MODEL_PATH):
        import urllib.request
        print(f"Downloading MediaPipe face model → {_MODEL_PATH}")
        urllib.request.urlretrieve(_MODEL_URL, _MODEL_PATH)


class MediaPipeFaceDetector:
    def __init__(self, min_confidence: float = 0.5):
        _ensure_model()
        from mediapipe.tasks.python import vision
        from mediapipe.tasks import python as mp_tasks
        options = vision.FaceDetectorOptions(
            base_options=mp_tasks.BaseOptions(model_asset_path=_MODEL_PATH),
            min_detection_confidence=min_confidence,
        )
        self._detector = vision.FaceDetector.create_from_options(options)

    def detect(self, img_path: str) -> list[NormBBox]:
        import mediapipe as mp
        image = mp.Image.create_from_file(img_path)
        result = self._detector.detect(image)
        if not result.detections:
            return []
        iw, ih = image.width, image.height
        boxes = []
        for det in result.detections:
            bb = det.bounding_box
            boxes.append(NormBBox(
                left=max(0.0, bb.origin_x / iw),
                top=max(0.0, bb.origin_y / ih),
                right=min(1.0, (bb.origin_x + bb.width) / iw),
                bottom=min(1.0, (bb.origin_y + bb.height) / ih),
            ))
        return boxes

    def close(self):
        self._detector.close()


class InsightFaceDetector:
    def __init__(self):
        import insightface
        self._app = insightface.app.FaceAnalysis(
            name="buffalo_s", providers=["CPUExecutionProvider"]
        )
        self._app.prepare(ctx_id=0)

    def detect(self, img_path: str) -> list[NormBBox]:
        import cv2
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
