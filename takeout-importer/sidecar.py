import json
from datetime import datetime, timezone
from dataclasses import dataclass


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


def is_asset_json(data: dict) -> bool:
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


def parse_sidecar(data: dict, json_filename: str) -> TakeoutSidecar:
    """Parse a GoogleMetaData JSON dict into a TakeoutSidecar."""
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
