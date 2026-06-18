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
    prefix: str = ""
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
    def from_env(cls, env_file: str = ".env", require_s3: bool = True) -> "TakeoutConfig":
        load_dotenv(env_file)

        def req(k: str) -> str:
            v = os.getenv(k)
            if not v:
                raise SystemExit(f"Missing required env var: {k}")
            return v

        if require_s3:
            access_key = req("S3_ACCESS_KEY")
            secret_key = req("S3_SECRET_KEY")
            endpoint = req("S3_ENDPOINT")
            bucket = req("S3_BUCKET")
        else:
            access_key = os.getenv("S3_ACCESS_KEY", "")
            secret_key = os.getenv("S3_SECRET_KEY", "")
            endpoint = os.getenv("S3_ENDPOINT", "")
            bucket = os.getenv("S3_BUCKET", "")

        return cls(
            endpoint=endpoint,
            bucket=bucket,
            access_key=access_key,
            secret_key=secret_key,
            region=os.getenv("S3_REGION", "us-east-1"),
            use_ssl=os.getenv("S3_USE_SSL", "true").lower() != "false",
            prefix=os.getenv("S3_PREFIX", "").strip(),
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
