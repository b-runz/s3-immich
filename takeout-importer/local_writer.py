import shutil
from pathlib import Path


class LocalWriter:
    """Writes files to a local directory mirroring the S3 key structure."""

    def __init__(self, output_dir: str):
        self.root = Path(output_dir).resolve()
        self.root.mkdir(parents=True, exist_ok=True)

    def put(self, key: str, data: bytes, content_type: str = "") -> None:
        dest = self.root / key.lstrip("/\\")
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(data)

    def put_file(self, key: str, src_path: str, content_type: str = "") -> None:
        dest = self.root / key.lstrip("/\\")
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src_path, dest)

    def put_all(self, items: list[tuple[str, bytes, str]], workers: int = 1,
                progress_cb=None) -> list[str]:
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
