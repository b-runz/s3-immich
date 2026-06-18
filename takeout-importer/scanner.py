import os
import re
import json
from dataclasses import dataclass, field
from datetime import datetime

from sidecar import TakeoutSidecar, is_asset_json, parse_sidecar


IMAGE_EXTS = {"jpg", "jpeg", "png", "heic", "heif", "gif", "mp"}
VIDEO_EXTS = {"mp4", "mov", "3gp", "avi", "mkv"}
MEDIA_EXTS = IMAGE_EXTS | VIDEO_EXTS

_YEAR_FOLDER_RE = re.compile(r'^Photos from \d{4}$')
_BANNED = {"metadata.json", "shared_album_comments.json"}


@dataclass
class TakeoutPhoto:
    local_path: str                 # absolute path on disk
    filename: str                   # basename
    extension: str                  # lowercase, no dot
    is_video: bool
    sidecar: TakeoutSidecar | None
    album_names: list[str] = field(default_factory=list)


def is_album_folder(folder_name: str) -> bool:
    return not _YEAR_FOLDER_RE.match(folder_name)


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
    parts = json_name.rsplit(".", 2)
    if len(parts) == 3 and parts[1].startswith("supplemental-metada"):
        json_name = parts[0] + "." + parts[2]
    json_name = _strip_ext(json_name)
    if json_name == file_name:
        return True
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
    p = base.rfind(".")
    if p > 1 and base[p + 1:].startswith("supplemental-metada"):
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


def scan_takeout(root: str) -> list[TakeoutPhoto]:
    catalogs: dict[str, dict] = {}
    file_tracker: dict[tuple, list[str]] = {}

    for dirpath, dirnames, filenames in os.walk(root):
        # Skip Failed Videos subfolder (matches immich-go behaviour)
        dirnames[:] = [d for d in dirnames if d != "Failed Videos"]

        jsons: dict[str, dict] = {}
        files: dict[str, str] = {}
        for fname in filenames:
            if fname in _BANNED:
                continue
            ext = fname.rsplit(".", 1)[-1].lower() if "." in fname else ""
            fpath = os.path.join(dirpath, fname)
            if ext == "json":
                try:
                    with open(fpath, encoding="utf-8") as fh:
                        data = json.load(fh)
                    if is_asset_json(data):
                        jsons[fname] = data
                except Exception:
                    pass
            elif ext in MEDIA_EXTS:
                size = os.path.getsize(fpath)
                if size == 0:
                    continue
                key = (fname, size)
                file_tracker.setdefault(key, []).append(dirpath)
                if fname not in files:
                    files[fname] = fpath
        if jsons or files:
            catalogs[dirpath] = {"jsons": jsons, "files": files}

    resolved: dict[str, TakeoutPhoto] = {}

    for dirpath, cat in catalogs.items():
        unmatched = dict(cat["files"])
        matched: dict[str, TakeoutSidecar | None] = {}

        for json_name, json_data in cat["jsons"].items():
            sidecar = parse_sidecar(json_data, json_name)
            for fname in list(unmatched):
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

        for fname in unmatched:
            matched[fname] = None

        folder_name = os.path.basename(dirpath)
        album = folder_name if is_album_folder(folder_name) else None

        for fname, sidecar in matched.items():
            fpath = cat["files"].get(fname) or os.path.join(dirpath, fname)
            if fpath in resolved:
                if album and album not in resolved[fpath].album_names:
                    resolved[fpath].album_names.append(album)
                continue
            ext = fname.rsplit(".", 1)[-1].lower() if "." in fname else ""
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
