# Unified Asset Schema & Data-Flow Redesign (schema v28 → v29)

## 0. Context that shaped these decisions

- `RemoteAsset.id` **is the S3 key** (`prefix/yyyy/mm/dd/filename.jpg`); the thumbnail key is always `.thumbs/{id}`. This is load-bearing across upload, download (`background_downloader` taskId), and image loading.
- `local_asset_entity.id` is a **photo_manager platform ID** (`1000008757`), and `asset_fts.asset_id` / `asset_label_entity.asset_id` reference *that* local ID, not the S3 key. Search resolves local→remote via `checksum` join.
- There are **two writers** that must agree on the schema: the Dart app (`backup.repository.dart::markAsBackedUp`) and the Python `takeout-importer/db_builder.py`. Any schema change is a two-file change.
- DB sync merges remote rows from S3 via `INSERT OR REPLACE` (`db_sync.service.dart`). The merge SQL is column-name-based, so renaming/adding columns touches that file too.
- `local_asset_entity` already carries `latitude`/`longitude` (added in v13→v14) and uses them at upload time. The remote table does **not** carry GPS inline today — it lives in `remote_exif_entity`.

The cleanest model given all of the above: **keep one row per real-world photo, keyed by checksum-independent identity, with two nullable ID "addresses" (local platform ID and S3 key) and inlined hot EXIF.**

---

## 1. Proposed unified schema: `asset_entity`

A photo is one row. "Local-only", "remote-only", and "both" become a function of which address columns are populated. The PK is **not** reused from either existing table — both old IDs are preserved as nullable address columns.

```dart
class AssetEntity extends Table with DriftDefaultsMixin {
  // ---- Identity ----
  TextColumn get id => text()();                 // stable key: use checksum when available (see §6 gotcha #1)
  TextColumn get checksum => text().nullable()(); // SHA-1; null only briefly before hashing
  TextColumn get localId => text().nullable()();  // photo_manager platform ID, null if remote-only
  TextColumn get remoteId => text().nullable()(); // S3 key (== old remote_asset_entity.id), null if not uploaded

  // ---- Core media ----
  TextColumn get name => text()();
  IntColumn  get type => intEnum<AssetType>()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
  IntColumn  get width => integer().nullable()();
  IntColumn  get height => integer().nullable()();
  IntColumn  get durationMs => integer().nullable()();
  DateTimeColumn get localDateTime => dateTime().nullable()(); // wall-clock capture time for timeline bucketing

  // ---- Flags / lifecycle ----
  BoolColumn get isFavorite => boolean().withDefault(const Constant(false))();
  IntColumn  get orientation => integer().withDefault(const Constant(0))();
  IntColumn  get playbackStyle => intEnum<AssetPlaybackStyle>().withDefault(const Constant(0))();
  IntColumn  get visibility => intEnum<AssetVisibility>().withDefault(Constant(AssetVisibility.timeline.index))();
  DateTimeColumn get deletedAt => dateTime().nullable()();
  DateTimeColumn get uploadedAt => dateTime().nullable()(); // null == not yet on S3
  BoolColumn get isEdited => boolean().withDefault(const Constant(false))();
  TextColumn get thumbHash => text().nullable()();

  // ---- Ownership / grouping ----
  TextColumn get ownerId => text().nullable()(); // null while local-only; set at upload
  TextColumn get livePhotoVideoId => text().nullable()();
  TextColumn get stackId => text().nullable()();
  TextColumn get libraryId => text().nullable()();
  TextColumn get sourceDeviceId => text().nullable()();
  TextColumn get iCloudId => text().nullable()();
  DateTimeColumn get adjustmentTime => dateTime().nullable()();

  // ---- Inlined hot EXIF (search + map + list-tile display) ----
  RealColumn get latitude  => real().nullable()();
  RealColumn get longitude => real().nullable()();
  TextColumn get city      => text().nullable()();
  TextColumn get state     => text().nullable()();
  TextColumn get country   => text().nullable()();
  TextColumn get make      => text().nullable()(); // camera brand
  TextColumn get model     => text().nullable()(); // camera model
  DateTimeColumn get dateTimeOriginal => dateTime().nullable()();
  IntColumn  get rating    => integer().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}
```

### Indexes

```sql
CREATE INDEX idx_asset_checksum   ON asset_entity (checksum);
CREATE INDEX idx_asset_local_id   ON asset_entity (local_id)   WHERE local_id  IS NOT NULL;
CREATE INDEX idx_asset_remote_id  ON asset_entity (remote_id)  WHERE remote_id IS NOT NULL;
CREATE INDEX idx_asset_cloud_id   ON asset_entity (i_cloud_id) WHERE i_cloud_id IS NOT NULL;
CREATE INDEX idx_asset_stack_id   ON asset_entity (stack_id);
CREATE INDEX idx_asset_lat_lng    ON asset_entity (latitude, longitude);
CREATE INDEX idx_asset_city       ON asset_entity (city) WHERE city IS NOT NULL;
CREATE INDEX idx_asset_owner_vis_deleted_created
  ON asset_entity (owner_id, visibility, deleted_at, created_at DESC);
```

The old `UNIQUE(owner_id, checksum)` constraint is dropped — with a synthetic PK there is a transient window where local-only and freshly-synced remote-only rows share a checksum before reconciliation. Enforce uniqueness in the reconciliation step instead.

---

## 2. Inline vs sidecar EXIF

**Inline (in `asset_entity`):** `latitude, longitude, city, state, country, make, model, dateTimeOriginal, rating`

These are the fields the timeline grid, search handler, and map read on every scroll.

**Sidecar — rename `remote_exif_entity` → `asset_exif_entity`**, FK `asset_id → asset_entity.id`. Keep cold fields:

```
description, exposureTime, fNumber, fileSize, focalLength,
iso, lens, orientation, timeZone, projectionType
```

Drop the duplicated `width`/`height` from the sidecar (they live in `asset_entity`). The sidecar is only read when the user opens the single-asset detail panel — a join there is cheap and rare.

---

## 3. Upload-time EXIF extraction

**Package:** `exif: ^3.x`

Add to `pubspec.yaml`. Prefer this over the `image` package's EXIF reader — `image` decodes the whole frame and is weaker on GPS rationals/HEIC. `exif.readExifFromBytes` reads only the EXIF block and handles GPS rationals + ref signs correctly.

Extraction happens in `_uploadSingleAsset` **before** `markAsBackedUp`, on the same `File` already loaded for upload (no extra read):

```dart
final tags = await readExifFromBytes(await file.readAsBytes());
final exif = ExtractedExif.from(tags); // helper: parse fields below
```

| EXIF tag | Target column | Notes |
|---|---|---|
| `GPS GPSLatitude` + `GPSLatitudeRef` | `latitude` | Apply S sign; fall back to `entity.latlngAsync()` |
| `GPS GPSLongitude` + `GPSLongitudeRef` | `longitude` | Apply W sign |
| `Image Make` | `make` | |
| `Image Model` | `model` | |
| `EXIF DateTimeOriginal` | `dateTimeOriginal`, `localDateTime` | Parse as local wall-clock |
| `Image Orientation` | `orientation` | Int |
| `EXIF LensModel` | sidecar `lens` | |
| `EXIF FNumber` | sidecar `fNumber` | |
| `EXIF ISOSpeedRatings` | sidecar `iso` | |
| `EXIF ExposureTime` | sidecar `exposureTime` | Raw string e.g. "1/250" |
| `EXIF FocalLength` | sidecar `focalLength` | |
| `file.stat().size` | sidecar `fileSize` | |

`city/state/country` are **not** derivable on-device (no reverse-geocoder shipped). Leave null at upload; filled by the Python importer / DB sync. The GPS coordinates themselves are populated at upload, so place-based search works immediately.

---

## 4. Thumbnail caching design

The existing `ThumbnailCacheService` is the right shape — formalize the policy:

- **Cache key = S3 thumbnail key = `.thumbs/{remoteId}`**. Do not key by synthetic `id` — keying by S3 key mirrors the S3 layout, is self-describing, and survives a DB rebuild.
- **Storage:** `{documentsDir}/thumbcache/.thumbs/{key}`, parent dirs created on write.
- **Local-only assets** (not yet uploaded): no `.thumbs/` S3 object exists. Route via `LocalThumbProvider` using `originalPath = "pm:{localId}"`. Decision rule: `uploadedAt != null` → S3 cached thumbnail; else → photo_manager.
- **Eviction (LRU by mtime):**
  - Default budget: **512 MB** (~10–25k thumbnails at 20–50 KB each).
  - On each successful fetch, touch the file's mtime.
  - Sweeper runs on app launch and after large scroll sessions: if total size > budget, delete oldest-mtime files until under 80% of budget.
  - No DB table needed — filesystem mtime *is* the LRU metadata. Crash-safe: a dropped DB doesn't desync the cache.
- **Concurrency:** keep the existing `_inflight` map dedup (prevents N decoders fetching the same key during fast scroll).
- **Invalidation on edit:** when `isEdited` flips, the S3 thumb is overwritten under the same key. Delete `{_cacheDir}/.thumbs/{remoteId}` in the edit-commit path so the next load re-fetches.

---

## 5. Migration v28 → v29

v28 was hand-applied with raw `ALTER TABLE`. v29 likewise uses **hand-written raw SQL inside `onUpgrade`**, guarded by `if (from < 29 && to >= 29)`, run with `PRAGMA foreign_keys = OFF`.

### Steps

**Step 1 — Create `asset_entity`**

Emit `CREATE TABLE asset_entity (...)` with all columns + indexes. Use `WITHOUT ROWID, STRICT` to match the Python importer's convention for byte-compatible `ATTACH`-based merge.

**Step 2 — Insert remote rows first** (richest data; S3 key preserved as `remoteId`):

```sql
INSERT INTO asset_entity (
  id, checksum, local_id, remote_id, name, type, created_at, updated_at,
  width, height, duration_ms, local_date_time, is_favorite, orientation,
  playback_style, visibility, deleted_at, uploaded_at, is_edited, thumb_hash,
  owner_id, live_photo_video_id, stack_id, library_id, source_device_id,
  latitude, longitude, city, state, country, make, model, date_time_original, rating)
SELECT
  r.checksum,  -- id = checksum (see §6 gotcha #1)
  r.checksum,
  (SELECT l.id FROM local_asset_entity l WHERE l.checksum = r.checksum LIMIT 1),
  r.id, r.name, r.type, r.created_at, r.updated_at,
  COALESCE(r.width, e.width), COALESCE(r.height, e.height), r.duration_ms,
  r.local_date_time, r.is_favorite, 0, 0, r.visibility, r.deleted_at,
  COALESCE(r.uploaded_at, r.updated_at),  -- backfill: synced rows are by definition uploaded
  r.is_edited, r.thumb_hash, r.owner_id, r.live_photo_video_id, r.stack_id,
  r.library_id, r.source_device_id,
  e.latitude, e.longitude, e.city, e.state, e.country, e.make, e.model,
  e.date_time_original, e.rating
FROM remote_asset_entity r
LEFT JOIN remote_exif_entity e ON e.asset_id = r.id;
```

**Step 3 — Insert local-only rows** (no matching remote checksum):

```sql
INSERT INTO asset_entity (
  id, checksum, local_id, remote_id, name, type, created_at, updated_at,
  width, height, duration_ms, is_favorite, orientation, playback_style,
  visibility, i_cloud_id, adjustment_time, latitude, longitude)
SELECT
  COALESCE(l.checksum, lower(hex(randomblob(16)))),  -- deterministic if checksum exists
  l.checksum, l.id, NULL, l.name, l.type,
  l.created_at, l.updated_at, l.width, l.height, l.duration_ms, l.is_favorite,
  l.orientation, l.playback_style, 0, l.i_cloud_id, l.adjustment_time,
  l.latitude, l.longitude
FROM local_asset_entity l
WHERE l.checksum IS NULL
   OR NOT EXISTS (SELECT 1 FROM remote_asset_entity r WHERE r.checksum = l.checksum);
```

**Step 4 — Create `asset_exif_entity`** and copy cold fields:

```sql
INSERT INTO asset_exif_entity (
  asset_id, description, exposure_time, f_number, file_size,
  focal_length, iso, lens, orientation, time_zone, projection_type)
SELECT
  a.id, e.description, e.exposure_time, e.f_number, e.file_size,
  e.focal_length, e.iso, e.lens, e.orientation, e.time_zone, e.projection_type
FROM remote_exif_entity e
JOIN asset_entity a ON a.remote_id = e.asset_id;
```

**Step 5 — Repoint FK tables.** Tables that referenced `remote_asset_entity.id` (S3 key):

```sql
UPDATE asset_face_entity    SET asset_id = (SELECT id FROM asset_entity WHERE remote_id = asset_id);
UPDATE asset_edit_entity    SET asset_id = (SELECT id FROM asset_entity WHERE remote_id = asset_id);
UPDATE memory_asset_entity  SET asset_id = (SELECT id FROM asset_entity WHERE remote_id = asset_id);
UPDATE remote_album_asset_entity SET asset_id = (SELECT id FROM asset_entity WHERE remote_id = asset_id);
-- etc. for any other FK referencing old remote id
```

`asset_fts.asset_id` and `asset_label_entity.asset_id` hold **photo_manager local IDs** — translate via `local_id`:

```sql
UPDATE asset_label_entity SET asset_id = (SELECT id FROM asset_entity WHERE local_id = asset_id)
WHERE EXISTS (SELECT 1 FROM asset_entity WHERE local_id = asset_label_entity.asset_id);
```

**Step 6 — Drop old tables:**

```sql
DROP TABLE remote_exif_entity;
DROP TABLE remote_asset_entity;
DROP TABLE local_asset_entity;
DROP TABLE IF EXISTS remote_asset_cloud_id_entity;  -- iCloud data folded into asset_entity.i_cloud_id
```

**Step 7 — Rewrite `merged_asset.drift`.**

The entire `UNION ALL + NOT EXISTS checksum` dedup collapses to:

```sql
SELECT * FROM asset_entity
WHERE deleted_at IS NULL
  AND visibility = 0
  AND (uploaded_at IS NOT NULL OR local_id IN (
    SELECT laae.asset_id FROM local_album_asset_entity laae
    JOIN local_album_entity la ON la.id = laae.album_id
    WHERE la.backup_selection = 0
  ));
```

### What gets dropped (data loss assessment)

- **No photo is lost.** Every local and remote row maps to exactly one `asset_entity` row.
- `remote_asset_cloud_id_entity` → folded or dropped (iCloud linkage only matters on iOS re-sync).
- Hard `UNIQUE(owner_id, checksum)` constraint dropped (replaced by reconciliation logic).
- Sidecar `width`/`height` columns dropped (redundant with `asset_entity`).

---

## 6. Gotchas & open questions

### 1. Synthetic ID — use checksum, not randomblob ⚠️

**This is the most important design decision.** If `id = randomblob(16)`, the Python importer and the Dart app mint different IDs for the same photo on different runs, breaking `INSERT OR REPLACE` sync semantics across devices.

**Decision: `id = checksum` when checksum is available** (SHA-1 is already unique per content). Both writers independently compute the same `id`, and `INSERT OR REPLACE` on `id` works correctly for cross-device sync. Only unhashed local-only rows (checksum IS NULL) fall back to `randomblob`.

### 2. DB sync must preserve device-local fields

Today sync `INSERT OR REPLACE`s `remote_asset_entity` rows by S3 key. With `id = checksum`, sync replaces `asset_entity` by the same ID. But `local_id` and `i_cloud_id` are device-specific — when device B pulls device A's rows, A's `local_id` is meaningless on B.

**Rule:** sync must never overwrite a non-null `local_id` with a remote value. Use a `COALESCE` upsert or split sync into "remote fields" vs "device-local fields":

```sql
INSERT INTO asset_entity (...all remote columns...) VALUES (...)
ON CONFLICT(id) DO UPDATE SET
  remote_id = excluded.remote_id,
  name = excluded.name,
  -- ... all remote columns ...
  local_id = COALESCE(asset_entity.local_id, excluded.local_id);  -- preserve device local_id
```

### 3. `asset_fts` / `asset_label_entity` still key on photo_manager local ID

This redesign does not change the FTS schema (out of scope). However, with `local_id` as a first-class indexed column on `asset_entity`, the search handler's resolution collapses from a cross-table checksum join to:

```sql
WHERE asset_entity.local_id = ?
```

Worth doing in the same PR since `search_handler.dart` is being rewritten anyway.

See §8 for the full ML metadata design.

### 4. HEIC EXIF on Android

The `exif` package reads HEIC EXIF inconsistently across devices. Keep `entity.latlngAsync()` as the GPS fallback (it already exists and works). For non-GPS HEIC fields, accept that some may be null at upload and get backfilled by the importer.

### 5. `localDateTime` source priority

photo_manager's `createDateTime` is often file mtime, not capture time. Prefer EXIF `DateTimeOriginal`; fall back to photo_manager. Timeline bucketing currently coalesces — preserve that fallback in the migration backfill (`COALESCE(e.date_time_original, r.local_date_time)`).

### 6. `visibility` default for migrated local-only rows

Set to `timeline (0)`. They only appear if in a selected backup album anyway. Confirm this matches `mergedBucket` expectations after the rewrite.

### 7. STRICT / WITHOUT ROWID parity

The Python importer uses `WITHOUT ROWID, STRICT`. Drift's generated `CREATE TABLE` does **not** emit these. Since v29 is hand-written raw SQL, emit them explicitly so a phone-created DB and an importer-created DB are byte-compatible for `ATTACH`-based merge. Drift's runtime will not choke on a STRICT table it didn't generate — it only issues column-name SQL.

---

## 7. Files to touch in lockstep

| File | Change |
|---|---|
| `lib/infrastructure/entities/asset.entity.dart` | New unified entity |
| `lib/infrastructure/entities/asset_exif.entity.dart` | Renamed from `remote_exif_entity`, cold fields only |
| `lib/infrastructure/repositories/db.repository.dart` | Bump to v29, raw migration block |
| `lib/infrastructure/entities/merged_asset.drift` | Rewrite to single-table SELECT |
| `lib/infrastructure/repositories/backup.repository.dart` | `markAsBackedUp` writes inline EXIF |
| `lib/services/foreground_upload.service.dart` | EXIF extraction before `markAsBackedUp` |
| `lib/services/thumbnail_cache.service.dart` | LRU sweeper + edit invalidation |
| `lib/infrastructure/local_server/handlers/search_handler.dart` | Single-table `local_id` resolution |
| `lib/services/db_sync.service.dart` | Merge column lists; preserve device-local fields |
| `takeout-importer/db_builder.py` | Matching `CREATE TABLE asset_entity` + insert path |
| `pubspec.yaml` | Add `exif: ^3.x` |
| `lib/infrastructure/ml/ocr_ml_schema.dart` | Rekey `asset_fts` to `asset_entity.id` |
| `lib/infrastructure/repositories/asset_face_ml.repository.dart` | Rekey faces to `asset_entity.id` |

---

## 8. ML metadata: OCR, object labels, face detection

### Current state — two ID spaces

The three ML tables currently use **different** asset ID spaces, which is the root inconsistency:

| Table | Key type | Populated by |
|---|---|---|
| `asset_fts` (FTS5 virtual) | photo_manager local ID | ML pipeline on-device |
| `asset_label_entity` | photo_manager local ID | ML pipeline on-device |
| `asset_face_entity` | S3 key (`remote_asset_entity.id`) | Synced from remote DB |

After the unified schema, all three should reference `asset_entity.id` (= checksum).

### Proposed: keep all three as separate tables, rekey to `asset_entity.id`

None of these belong inline — they are variable-multiplicity (multiple faces/labels per photo) or large (OCR text). They stay as sidecars.

#### `asset_fts` — OCR text + labels

FTS5 virtual tables cannot have foreign keys, but the `asset_id` column should nonetheless hold the unified `asset_entity.id`:

```sql
CREATE VIRTUAL TABLE asset_fts USING fts5(
  asset_id UNINDEXED,   -- asset_entity.id (checksum), not local_id
  ocr_text,
  labels,
  tokenize = 'unicode61'
);
```

**Migration step for `asset_fts`:** Drop and recreate (FTS tables cannot be altered). Repopulate by joining on `local_id`:

```sql
DROP TABLE asset_fts;
CREATE VIRTUAL TABLE asset_fts USING fts5(asset_id UNINDEXED, ocr_text, labels, tokenize = 'unicode61');

INSERT INTO asset_fts (asset_id, ocr_text, labels)
SELECT a.id, old.ocr_text, old.labels
FROM asset_fts_old old              -- saved via: ALTER TABLE asset_fts RENAME TO asset_fts_old
JOIN asset_entity a ON a.local_id = old.asset_id;
-- Rows whose local_id has no asset_entity match (orphaned ML data) are dropped.
```

The ML worker (`OcrMlSchema.writeOcrText`, `LabelMlSchema.writeLabels`) must be updated to write `asset_entity.id` instead of the photo_manager local ID. Since the ML worker receives a local asset, look up `id` via `SELECT id FROM asset_entity WHERE local_id = ?` before writing.

#### `asset_label_entity` — object detection labels

Same situation as `asset_fts`. Rekey via `local_id` join in migration (same SQL pattern as above). Update the ML writer to resolve `local_id → asset_entity.id` before inserting.

The `asset_label_entity` schema itself is unchanged except the `asset_id` column now references `asset_entity.id`.

#### `asset_face_entity` — face bounding boxes + person assignment

Currently references `remote_asset_entity.id` (S3 key). Migrates via `remote_id`:

```sql
UPDATE asset_face_entity
SET asset_id = (SELECT id FROM asset_entity WHERE remote_id = asset_face_entity.asset_id);
```

After migration, the FK declaration becomes:
```dart
TextColumn get assetId => text().references(AssetEntity, #id, onDelete: KeyAction.cascade)();
```

Face detection currently only runs on remote (backed-up) assets. With the unified schema, it can run on local-only assets too — the writer would resolve `local_id → asset_entity.id` the same way as the label writer.

### Search handler simplification after rekey

Once all three ML tables use `asset_entity.id`, the search handler's multi-step resolution collapses significantly:

**Before (current):**
```sql
-- Step 1: labels use local_id → resolve to remote via checksum join
-- Step 2: local name search uses local_id  
-- Step 3: remote name search uses remote_id
-- Steps 3-5: batch fetch + dedup by checksum
```

**After (unified):**
```sql
-- Labels, FTS, faces all produce asset_entity.id directly
-- Single batch fetch: SELECT * FROM asset_entity WHERE id IN (?)
-- No checksum join needed
-- Place bbox search also produces asset_entity rows directly
```

### ML pipeline write path (post-migration)

Every ML writer needs one extra lookup before inserting:

```dart
// Before writing any ML result for a local photo:
final assetId = await db.customSelect(
  'SELECT id FROM asset_entity WHERE local_id = ?',
  variables: [Variable.withString(localPhotoManagerId)],
).map((r) => r.read<String>('id')).getSingleOrNull();
if (assetId == null) return; // asset not yet in DB, skip
```

This is a cheap indexed lookup (`idx_asset_local_id`). Cache the result per ML session to avoid redundant queries for multi-label batches on the same asset.

### Face detection for local-only assets

`asset_face_entity` currently only has data for remote assets (synced from the remote DB). With the unified `asset_entity.id`, on-device face detection results can be stored for local-only photos too — the `asset_id` just resolves to the checksum-based `asset_entity.id` regardless of upload status. No schema change needed; only the writer's ID resolution changes.
