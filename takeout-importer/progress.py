import json
import os
from threading import Lock


class ProgressTracker:
    """Thread-safe JSON-backed progress store."""

    def __init__(self, path: str = ".migrate_progress.json"):
        self._path = path
        self._lock = Lock()
        self._data = self._deserialize(self._load())

    def _load(self) -> dict:
        if not os.path.exists(self._path):
            return {"version": 1, "originals": [], "thumbs": [], "files": {}}
        try:
            with open(self._path) as f:
                return json.load(f)
        except json.JSONDecodeError:
            return self._recover(self._path)

    def _recover(self, path: str) -> dict:
        """Best-effort recovery: scan the file line by line and collect valid file entries."""
        import re
        backup = path + ".corrupt"
        import shutil
        shutil.copy2(path, backup)
        print(f"  WARNING: Progress file corrupt; attempting recovery (backup: {backup})")

        result: dict = {"version": 1, "originals": [], "thumbs": [], "files": {}}
        # Each file entry looks like: "  \"/path\": {\"asset_id\": \"...\", \"checksum\": \"...\"},"
        file_re = re.compile(r'"(/[^"]+)"\s*:\s*(\{[^}]+\})')
        try:
            with open(path) as f:
                content = f.read()
        except Exception:
            return result

        for m in file_re.finditer(content):
            try:
                entry = json.loads(m.group(2))
                if "asset_id" in entry:
                    result["files"][m.group(1)] = entry
            except Exception:
                pass

        print(f"  Recovered {len(result['files'])} file entries from corrupt progress file.")
        # Rewrite with recovered data so future runs are clean
        out = {**result, "originals": sorted(result["originals"]),
               "thumbs": sorted(result["thumbs"])}
        with open(path, "w") as f:
            json.dump(out, f, indent=2)
        return result

    def _deserialize(self, raw: dict) -> dict:
        raw["originals"] = set(raw.get("originals", []))
        raw["thumbs"] = set(raw.get("thumbs", []))
        return raw

    def _save(self):
        out = {
            "version": 1,
            "originals": sorted(self._data["originals"]),
            "thumbs": sorted(self._data["thumbs"]),
            "files": self._data["files"],
        }
        with open(self._path, "w") as f:
            json.dump(out, f, indent=2)

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
