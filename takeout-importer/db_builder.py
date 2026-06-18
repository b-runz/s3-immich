import hashlib
import os
import sqlite3
from datetime import datetime, timezone


# ── Schema DDL (version 28) ────────────────────────────────────────────────

_CREATE_USER_ENTITY = """
CREATE TABLE IF NOT EXISTS user_entity (
  id TEXT NOT NULL,
  name TEXT NOT NULL,
  email TEXT NOT NULL,
  has_profile_image INTEGER NOT NULL DEFAULT 0 CHECK (has_profile_image IN (0, 1)),
  profile_changed_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now') * 1000),
  avatar_color INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (id)
) WITHOUT ROWID, STRICT;
"""

_CREATE_AUTH_USER_ENTITY = """
CREATE TABLE IF NOT EXISTS auth_user_entity (
  id TEXT NOT NULL,
  name TEXT NOT NULL,
  email TEXT NOT NULL,
  is_admin INTEGER NOT NULL DEFAULT 0 CHECK (is_admin IN (0, 1)),
  has_profile_image INTEGER NOT NULL DEFAULT 0 CHECK (has_profile_image IN (0, 1)),
  profile_changed_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now') * 1000),
  avatar_color INTEGER NOT NULL DEFAULT 0,
  quota_size_in_bytes INTEGER NOT NULL DEFAULT 0,
  quota_usage_in_bytes INTEGER NOT NULL DEFAULT 0,
  pin_code TEXT,
  PRIMARY KEY (id)
) WITHOUT ROWID, STRICT;
"""

_CREATE_PARTNER_ENTITY = """
CREATE TABLE IF NOT EXISTS partner_entity (
  shared_by_id TEXT NOT NULL REFERENCES user_entity (id) ON DELETE CASCADE,
  shared_with_id TEXT NOT NULL REFERENCES user_entity (id) ON DELETE CASCADE,
  in_timeline INTEGER NOT NULL DEFAULT 0 CHECK (in_timeline IN (0, 1)),
  PRIMARY KEY (shared_by_id, shared_with_id)
) WITHOUT ROWID, STRICT;
"""

_CREATE_STACK_ENTITY = """
CREATE TABLE IF NOT EXISTS stack_entity (
  id TEXT NOT NULL,
  created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now') * 1000),
  updated_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now') * 1000),
  owner_id TEXT NOT NULL REFERENCES user_entity (id) ON DELETE CASCADE,
  primary_asset_id TEXT NOT NULL,
  PRIMARY KEY (id)
) WITHOUT ROWID, STRICT;
"""

_CREATE_REMOTE_ASSET_ENTITY = """
CREATE TABLE IF NOT EXISTS remote_asset_entity (
  id TEXT NOT NULL,
  name TEXT NOT NULL,
  type INTEGER NOT NULL,
  created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now') * 1000),
  updated_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now') * 1000),
  width INTEGER,
  height INTEGER,
  duration_ms INTEGER,
  checksum TEXT NOT NULL,
  is_favorite INTEGER NOT NULL DEFAULT 0 CHECK (is_favorite IN (0, 1)),
  owner_id TEXT NOT NULL REFERENCES user_entity (id) ON DELETE CASCADE,
  local_date_time INTEGER,
  thumb_hash TEXT,
  deleted_at INTEGER,
  uploaded_at INTEGER,
  live_photo_video_id TEXT,
  visibility INTEGER NOT NULL DEFAULT 0,
  stack_id TEXT,
  library_id TEXT,
  is_edited INTEGER NOT NULL DEFAULT 0 CHECK (is_edited IN (0, 1)),
  source_device_id TEXT,
  PRIMARY KEY (id)
) WITHOUT ROWID, STRICT;
"""

_CREATE_REMOTE_EXIF_ENTITY = """
CREATE TABLE IF NOT EXISTS remote_exif_entity (
  asset_id TEXT NOT NULL REFERENCES remote_asset_entity (id) ON DELETE CASCADE,
  city TEXT,
  state TEXT,
  country TEXT,
  date_time_original INTEGER,
  description TEXT,
  height INTEGER,
  width INTEGER,
  exposure_time TEXT,
  f_number REAL,
  file_size INTEGER,
  focal_length REAL,
  latitude REAL,
  longitude REAL,
  iso INTEGER,
  make TEXT,
  model TEXT,
  lens TEXT,
  orientation TEXT,
  time_zone TEXT,
  rating INTEGER,
  projection_type TEXT,
  PRIMARY KEY (asset_id)
) WITHOUT ROWID, STRICT;
"""

_CREATE_REMOTE_ALBUM_ENTITY = """
CREATE TABLE IF NOT EXISTS remote_album_entity (
  id TEXT NOT NULL,
  name TEXT NOT NULL,
  description TEXT NOT NULL DEFAULT '',
  created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now') * 1000),
  updated_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now') * 1000),
  thumbnail_asset_id TEXT REFERENCES remote_asset_entity (id) ON DELETE SET NULL,
  is_activity_enabled INTEGER NOT NULL DEFAULT 1 CHECK (is_activity_enabled IN (0, 1)),
  "order" INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (id)
) WITHOUT ROWID, STRICT;
"""

_CREATE_REMOTE_ALBUM_ASSET_ENTITY = """
CREATE TABLE IF NOT EXISTS remote_album_asset_entity (
  asset_id TEXT NOT NULL REFERENCES remote_asset_entity (id) ON DELETE CASCADE,
  album_id TEXT NOT NULL REFERENCES remote_album_entity (id) ON DELETE CASCADE,
  PRIMARY KEY (asset_id, album_id)
) WITHOUT ROWID, STRICT;
"""

_CREATE_REMOTE_ALBUM_USER_ENTITY = """
CREATE TABLE IF NOT EXISTS remote_album_user_entity (
  album_id TEXT NOT NULL REFERENCES remote_album_entity (id) ON DELETE CASCADE,
  user_id TEXT NOT NULL REFERENCES user_entity (id) ON DELETE CASCADE,
  role INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (album_id, user_id)
) WITHOUT ROWID, STRICT;
"""

_CREATE_REMOTE_ASSET_CLOUD_ID_ENTITY = """
CREATE TABLE IF NOT EXISTS remote_asset_cloud_id_entity (
  asset_id TEXT NOT NULL REFERENCES remote_asset_entity (id) ON DELETE CASCADE,
  cloud_id TEXT,
  created_at INTEGER,
  adjustment_time INTEGER,
  latitude REAL,
  longitude REAL,
  PRIMARY KEY (asset_id)
) WITHOUT ROWID, STRICT;
"""

_CREATE_PERSON_ENTITY = """
CREATE TABLE IF NOT EXISTS person_entity (
  id TEXT NOT NULL,
  created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now') * 1000),
  updated_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now') * 1000),
  owner_id TEXT NOT NULL REFERENCES user_entity (id) ON DELETE CASCADE,
  name TEXT NOT NULL DEFAULT '',
  face_asset_id TEXT,
  is_favorite INTEGER NOT NULL DEFAULT 0 CHECK (is_favorite IN (0, 1)),
  is_hidden INTEGER NOT NULL DEFAULT 0 CHECK (is_hidden IN (0, 1)),
  color TEXT,
  birth_date INTEGER,
  PRIMARY KEY (id)
) WITHOUT ROWID, STRICT;
"""

_CREATE_ASSET_FACE_ENTITY = """
CREATE TABLE IF NOT EXISTS asset_face_entity (
  id TEXT NOT NULL,
  asset_id TEXT NOT NULL REFERENCES remote_asset_entity (id) ON DELETE CASCADE,
  person_id TEXT REFERENCES person_entity (id) ON DELETE SET NULL,
  image_width INTEGER NOT NULL,
  image_height INTEGER NOT NULL,
  bounding_box_x1 INTEGER NOT NULL,
  bounding_box_y1 INTEGER NOT NULL,
  bounding_box_x2 INTEGER NOT NULL,
  bounding_box_y2 INTEGER NOT NULL,
  source_type TEXT NOT NULL DEFAULT 'ml_kit',
  is_visible INTEGER NOT NULL DEFAULT 1 CHECK (is_visible IN (0, 1)),
  deleted_at INTEGER,
  PRIMARY KEY (id)
) WITHOUT ROWID, STRICT;
"""

_CREATE_MEMORY_ENTITY = """
CREATE TABLE IF NOT EXISTS memory_entity (
  id TEXT NOT NULL,
  created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now') * 1000),
  updated_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now') * 1000),
  deleted_at INTEGER,
  owner_id TEXT NOT NULL REFERENCES user_entity (id) ON DELETE CASCADE,
  type INTEGER NOT NULL,
  data TEXT NOT NULL,
  is_saved INTEGER NOT NULL DEFAULT 0 CHECK (is_saved IN (0, 1)),
  memory_at INTEGER NOT NULL,
  seen_at INTEGER,
  show_at INTEGER,
  hide_at INTEGER,
  PRIMARY KEY (id)
) WITHOUT ROWID, STRICT;
"""

_CREATE_MEMORY_ASSET_ENTITY = """
CREATE TABLE IF NOT EXISTS memory_asset_entity (
  asset_id TEXT NOT NULL REFERENCES remote_asset_entity (id) ON DELETE CASCADE,
  memory_id TEXT NOT NULL REFERENCES memory_entity (id) ON DELETE CASCADE,
  PRIMARY KEY (asset_id, memory_id)
) WITHOUT ROWID, STRICT;
"""

_CREATE_STORE_ENTITY = """
CREATE TABLE IF NOT EXISTS store_entity (
  id INTEGER NOT NULL,
  value TEXT NOT NULL,
  PRIMARY KEY (id)
) WITHOUT ROWID, STRICT;
"""

_CREATE_LOCAL_ASSET_ENTITY = """
CREATE TABLE IF NOT EXISTS local_asset_entity (
  id TEXT NOT NULL,
  name TEXT NOT NULL,
  type INTEGER NOT NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  width INTEGER,
  height INTEGER,
  duration_ms INTEGER,
  checksum TEXT NOT NULL,
  is_favorite INTEGER NOT NULL DEFAULT 0 CHECK (is_favorite IN (0, 1)),
  local_date_time INTEGER,
  thumb_hash TEXT,
  adjustment_time INTEGER,
  latitude REAL,
  longitude REAL,
  i_cloud_id TEXT,
  playback_style INTEGER NOT NULL DEFAULT 0,
  face_processed INTEGER NOT NULL DEFAULT 0 CHECK (face_processed IN (0, 1)),
  PRIMARY KEY (id)
) WITHOUT ROWID, STRICT;
"""

_CREATE_LOCAL_ALBUM_ENTITY = """
CREATE TABLE IF NOT EXISTS local_album_entity (
  id TEXT NOT NULL,
  name TEXT NOT NULL,
  updated_at INTEGER NOT NULL,
  backup_selection_type INTEGER NOT NULL DEFAULT 0,
  linked_remote_album_id TEXT,
  PRIMARY KEY (id)
) WITHOUT ROWID, STRICT;
"""

_CREATE_LOCAL_ALBUM_ASSET_ENTITY = """
CREATE TABLE IF NOT EXISTS local_album_asset_entity (
  asset_id TEXT NOT NULL REFERENCES local_asset_entity (id) ON DELETE CASCADE,
  album_id TEXT NOT NULL REFERENCES local_album_entity (id) ON DELETE CASCADE,
  marker_ INTEGER,
  PRIMARY KEY (asset_id, album_id)
) WITHOUT ROWID, STRICT;
"""

_CREATE_TRASHED_LOCAL_ASSET_ENTITY = """
CREATE TABLE IF NOT EXISTS trashed_local_asset_entity (
  id TEXT NOT NULL,
  name TEXT NOT NULL,
  type INTEGER NOT NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  width INTEGER,
  height INTEGER,
  duration_ms INTEGER,
  checksum TEXT NOT NULL,
  is_favorite INTEGER NOT NULL DEFAULT 0 CHECK (is_favorite IN (0, 1)),
  local_date_time INTEGER,
  thumb_hash TEXT,
  source INTEGER NOT NULL DEFAULT 0,
  playback_style INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (id)
) WITHOUT ROWID, STRICT;
"""

_CREATE_ASSET_EDIT_ENTITY = """
CREATE TABLE IF NOT EXISTS asset_edit_entity (
  id TEXT NOT NULL,
  asset_id TEXT NOT NULL REFERENCES remote_asset_entity (id) ON DELETE CASCADE,
  created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now') * 1000),
  updated_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now') * 1000),
  PRIMARY KEY (id)
) WITHOUT ROWID, STRICT;
"""

_CREATE_SETTINGS_ENTITY = """
CREATE TABLE IF NOT EXISTS settings (
  key TEXT NOT NULL,
  value TEXT NOT NULL,
  updated_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now') * 1000),
  PRIMARY KEY (key)
) WITHOUT ROWID, STRICT;
"""

_CREATE_USER_METADATA_ENTITY = """
CREATE TABLE IF NOT EXISTS user_metadata (
  user_id TEXT NOT NULL REFERENCES user_entity (id) ON DELETE CASCADE,
  key TEXT NOT NULL,
  value TEXT NOT NULL,
  PRIMARY KEY (user_id, key)
) WITHOUT ROWID, STRICT;
"""

# ML tables (non-STRICT, not STRICT-mode compatible with FTS5)
_CREATE_ASSET_LABEL_ENTITY = """
CREATE TABLE IF NOT EXISTS asset_label_entity (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  asset_id TEXT NOT NULL,
  label TEXT NOT NULL,
  source TEXT NOT NULL DEFAULT 'imageLabeler',
  confidence REAL NOT NULL,
  bbox_x REAL,
  bbox_y REAL,
  bbox_w REAL,
  bbox_h REAL
);
"""

_CREATE_ASSET_FTS = """
CREATE VIRTUAL TABLE IF NOT EXISTS asset_fts USING fts5(
  asset_id UNINDEXED,
  ocr_text,
  labels,
  tokenize = 'unicode61'
);
"""

# ── Indexes ────────────────────────────────────────────────────────────────

_INDEXES = [
    "CREATE UNIQUE INDEX IF NOT EXISTS UQ_remote_assets_owner_checksum ON remote_asset_entity (owner_id, checksum) WHERE (library_id IS NULL);",
    "CREATE UNIQUE INDEX IF NOT EXISTS UQ_remote_assets_owner_library_checksum ON remote_asset_entity (owner_id, library_id, checksum) WHERE (library_id IS NOT NULL);",
    "CREATE INDEX IF NOT EXISTS idx_remote_asset_checksum ON remote_asset_entity (checksum);",
    "CREATE INDEX IF NOT EXISTS idx_remote_asset_stack_id ON remote_asset_entity (stack_id);",
    "CREATE INDEX IF NOT EXISTS idx_remote_asset_owner_visibility_deleted_created ON remote_asset_entity (owner_id, visibility, deleted_at, created_at DESC);",
    "CREATE INDEX IF NOT EXISTS idx_lat_lng ON remote_exif_entity (latitude, longitude);",
    "CREATE INDEX IF NOT EXISTS idx_remote_exif_city ON remote_exif_entity (city) WHERE city IS NOT NULL;",
    "CREATE INDEX IF NOT EXISTS idx_remote_album_asset_album_asset ON remote_album_asset_entity (album_id, asset_id);",
    "CREATE INDEX IF NOT EXISTS idx_person_owner_id ON person_entity (owner_id);",
    "CREATE INDEX IF NOT EXISTS idx_asset_face_person_id ON asset_face_entity (person_id);",
    "CREATE INDEX IF NOT EXISTS idx_asset_face_asset_id ON asset_face_entity (asset_id);",
    "CREATE INDEX IF NOT EXISTS idx_asset_face_visible_person ON asset_face_entity (person_id, asset_id) WHERE is_visible = 1 AND deleted_at IS NULL;",
    "CREATE INDEX IF NOT EXISTS idx_partner_shared_with_id ON partner_entity (shared_with_id);",
    "CREATE INDEX IF NOT EXISTS idx_stack_primary_asset_id ON stack_entity (primary_asset_id);",
    "CREATE INDEX IF NOT EXISTS idx_remote_asset_cloud_id ON remote_asset_cloud_id_entity (cloud_id);",
    "CREATE INDEX IF NOT EXISTS idx_local_asset_cloud_id ON local_asset_entity (i_cloud_id);",
    "CREATE INDEX IF NOT EXISTS idx_local_album_asset_album_asset ON local_album_asset_entity (album_id, asset_id);",
    "CREATE INDEX IF NOT EXISTS idx_trashed_local_asset_checksum ON trashed_local_asset_entity (checksum);",
    "CREATE INDEX IF NOT EXISTS idx_trashed_local_asset_album ON trashed_local_asset_entity (id);",
    "CREATE INDEX IF NOT EXISTS idx_asset_edit_asset_id ON asset_edit_entity (asset_id);",
    "CREATE INDEX IF NOT EXISTS idx_asset_label_asset ON asset_label_entity (asset_id);",
    "CREATE INDEX IF NOT EXISTS idx_asset_label_label ON asset_label_entity (label);",
]

_ALL_TABLES = [
    _CREATE_USER_ENTITY,
    _CREATE_AUTH_USER_ENTITY,
    _CREATE_USER_METADATA_ENTITY,
    _CREATE_PARTNER_ENTITY,
    _CREATE_STACK_ENTITY,
    _CREATE_REMOTE_ASSET_ENTITY,
    _CREATE_REMOTE_EXIF_ENTITY,
    _CREATE_REMOTE_ALBUM_ENTITY,
    _CREATE_REMOTE_ALBUM_ASSET_ENTITY,
    _CREATE_REMOTE_ALBUM_USER_ENTITY,
    _CREATE_REMOTE_ASSET_CLOUD_ID_ENTITY,
    _CREATE_PERSON_ENTITY,
    _CREATE_ASSET_FACE_ENTITY,
    _CREATE_MEMORY_ENTITY,
    _CREATE_MEMORY_ASSET_ENTITY,
    _CREATE_STORE_ENTITY,
    _CREATE_LOCAL_ASSET_ENTITY,
    _CREATE_LOCAL_ALBUM_ENTITY,
    _CREATE_LOCAL_ALBUM_ASSET_ENTITY,
    _CREATE_TRASHED_LOCAL_ASSET_ENTITY,
    _CREATE_ASSET_EDIT_ENTITY,
    _CREATE_SETTINGS_ENTITY,
    _CREATE_ASSET_LABEL_ENTITY,
    _CREATE_ASSET_FTS,
]


def apply_pragmas(conn: sqlite3.Connection) -> None:
    conn.execute("PRAGMA foreign_keys = ON")
    conn.execute("PRAGMA journal_mode = WAL")
    conn.execute("PRAGMA synchronous = NORMAL")
    conn.execute("PRAGMA cache_size = -32000")
    conn.execute("PRAGMA temp_store = MEMORY")


def set_schema_version(conn: sqlite3.Connection, version: int = 28) -> None:
    conn.execute(f"PRAGMA user_version = {version}")


def album_id_for(folder_name: str) -> str:
    """Stable UUID from folder name so re-runs don't create duplicate albums."""
    digest = hashlib.sha1(folder_name.encode()).digest()
    hex_ = digest[:16].hex()
    return f"{hex_[:8]}-{hex_[8:12]}-{hex_[12:16]}-{hex_[16:20]}-{hex_[20:32]}"


def insert_ocr_text(conn: sqlite3.Connection, asset_id: str,
                    ocr_text: str, labels: str = "") -> None:
    conn.execute(
        "INSERT OR REPLACE INTO asset_fts(asset_id, ocr_text, labels) VALUES (?, ?, ?)",
        (asset_id, ocr_text, labels),
    )


class DbBuilder:
    def __init__(self, path: str, create: bool = True):
        self._conn = sqlite3.connect(path)
        self._conn.row_factory = sqlite3.Row
        apply_pragmas(self._conn)
        if create:
            self._create_schema()
            set_schema_version(self._conn, 28)

    def _create_schema(self):
        for stmt in _ALL_TABLES:
            self._conn.execute(stmt)
        for stmt in _INDEXES:
            self._conn.execute(stmt)
        self._conn.commit()

    def checksum_exists(self, owner_id: str, checksum: str) -> bool:
        row = self._conn.execute(
            "SELECT id FROM remote_asset_entity "
            "WHERE owner_id = ? AND checksum = ? LIMIT 1",
            (owner_id, checksum),
        ).fetchone()
        return row is not None

    def get_id_by_checksum(self, owner_id: str, checksum: str) -> str | None:
        row = self._conn.execute(
            "SELECT id FROM remote_asset_entity "
            "WHERE owner_id = ? AND checksum = ? LIMIT 1",
            (owner_id, checksum),
        ).fetchone()
        return row["id"] if row else None

    def insert_asset(self, asset_id: str, photo, checksum: str,
                     owner_id: str, now_ms: int) -> None:
        from scanner import TakeoutPhoto
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
                    bbox) -> None:
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

    def conn(self) -> sqlite3.Connection:
        return self._conn

    def commit(self):
        self._conn.commit()

    def close(self):
        self._conn.commit()
        self._conn.close()
