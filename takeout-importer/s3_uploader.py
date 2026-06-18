import re
from concurrent.futures import ThreadPoolExecutor, as_completed

import boto3
from botocore.config import Config

from config import TakeoutConfig


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


def build_s3_client(cfg: TakeoutConfig):
    kwargs = dict(
        aws_access_key_id=cfg.access_key,
        aws_secret_access_key=cfg.secret_key,
        region_name=cfg.region,
        config=Config(
            retries={"max_attempts": 3, "mode": "adaptive"},
            max_pool_connections=cfg.upload_workers + 2,
        ),
    )
    if not re.search(r'amazonaws\.com', cfg.endpoint):
        scheme = "https" if cfg.use_ssl else "http"
        ep = cfg.endpoint
        if not ep.startswith("http"):
            ep = f"{scheme}://{ep}"
        kwargs["endpoint_url"] = ep

    return boto3.client("s3", **kwargs)


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


def write_all(sink, items: list[tuple[str, bytes, str]], workers: int = 8,
              progress_cb=None) -> list[str]:
    from local_writer import LocalWriter
    if isinstance(sink, LocalWriter):
        return sink.put_all(items, workers=1, progress_cb=progress_cb)
    s3_client, bucket = sink
    return upload_all(s3_client, bucket, items, workers, progress_cb)


def write_file(sink, key: str, src_path: str, content_type: str = "") -> None:
    from local_writer import LocalWriter
    if isinstance(sink, LocalWriter):
        sink.put_file(key, src_path, content_type)
    else:
        s3_client, bucket = sink
        with open(src_path, "rb") as f:
            s3_client.put_object(Bucket=bucket, Key=key, Body=f,
                                 ContentType=content_type)
