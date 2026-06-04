# S3 Sync & Thumbnail Disk Cache — Design

**Date:** 2026-06-04
**Status:** Approved

## Context

This app is an S3-only Immich fork. There is no server — S3 is the source of truth. The intended workflow is:

1. A PC ingestion tool (separate project) parses Google Takeout, builds a SQLite DB with asset + EXIF metadata, generates thumbnails, and uploads everything to S3.
2. The phone downloads the DB on launch and browses the library locally.
3. When the user switches phones, the new phone re-syncs from S3 and gets the full library.

S3 layout:
- `{yyyy}/{mm}/{dd}/{filename}` — original photo/video
- `.thumbs/{yyyy}/{mm}/{dd}/{filename}` — thumbnail JPEG
- `.meta/s3immich.db` — SQLite DB (authoritative copy)

## Section 1: DB Sync on Launch

**Existing:** `DbSyncService.pull()` already runs at launch. It calls `headObject('.meta/s3immich.db')`, compares `lastModified` to a stored `_lastSyncTime`, and if newer downloads the remote DB and merges it via SQLite `ATTACH`.

**Change — merge strategy:** Replace `INSERT OR IGNORE` with `INSERT OR REPLACE` for `remote_asset_entity` and `remote_exif_entity`. The PC is the authoritative source; updated records (e.g. EXIF added after initial import) must overwrite local copies.

`store_entity` (S3 credentials fallback) keeps `INSERT OR IGNORE` — credentials should never be overwritten by a remote copy.

**No version file needed** — `headObject` on the DB itself gives `lastModified`, which is sufficient for a freshness check.

Files changed:
- `lib/services/db_sync.service.dart` — two SQL statement changes

## Section 2: Thumbnail Disk Cache

**New service:** `lib/services/thumbnail_cache.service.dart`

```
class ThumbnailCacheService {
  static ThumbnailCacheService? instance;   // set in main.dart

  ThumbnailCacheService({required Directory cacheDir, required S3Service s3});

  Future<Uint8List> getOrFetch(String s3Key) async {
    // 1. Check {cacheDir}/{s3Key} on disk
    // 2. Hit  → read and return bytes
    // 3. Miss → presignGet(s3Key) → http.get → mkdirs → write → return bytes
  }
}
```

Cache directory: `{documentsDir}/thumbcache/` — mirrors the S3 key structure on disk, e.g.
`.thumbs/2020/03/06/IMG_20200306_120932.jpg` → `{cacheDir}/.thumbs/2020/03/06/IMG_20200306_120932.jpg`

No eviction policy at this stage. Thumbnails are ~20–50 KB each; a 32 GB library produces roughly 500 MB–1 GB of cached thumbnails — acceptable on modern phones.

**Initialization in `main.dart`** (after `s3Service.loadFromStorage()`):
```dart
ThumbnailCacheService.instance = ThumbnailCacheService(
  cacheDir: Directory(p.join(documentsDir.path, 'thumbcache')),
  s3: s3Service,
);
```

**Dependency:** Add `http` package (already a transitive dependency; check `pubspec.yaml` before adding explicitly).

Files changed:
- `lib/services/thumbnail_cache.service.dart` — new file
- `lib/main.dart` — initialize instance

## Section 3: Image Loading Integration

**Change to `RemoteImageRequest.load()`** in `lib/infrastructure/loaders/remote_image_request.dart`:

```
uri starts with '.thumbs/'
  → ThumbnailCacheService.instance.getOrFetch(uri)
  → decode bytes via ui.ImmutableBuffer.fromUint8List
  → return ImageInfo

uri is an S3 original key (no '.thumbs/' prefix)
  → S3Service.global.presignGet(uri) → remoteImageApi.requestImage(presignedUrl)
  → existing path, unchanged
```

This applies to both `load()` and `loadCodec()`. Thumbnail loading bypasses the native `remoteImageApi` entirely; the decoded bytes come from the Dart layer.

Files changed:
- `lib/infrastructure/loaders/remote_image_request.dart`
- `lib/infrastructure/loaders/image_request.dart` — add `ThumbnailCacheService` import (shared by parts)

## Section 4: Search

No new work. The existing search infrastructure queries `remote_asset_entity` and `remote_exif_entity` in SQLite. Once the DB sync uses `INSERT OR REPLACE` (Section 1), metadata from the PC ingestion tool is fully available and searchable — by filename, date, GPS, camera model, etc.

## Section 5: Verification (Python script)

Location: `C:\Users\bru\spare-source\s3-test\test_s3.py` (boto3, `.env` credentials, existing venv).

Extend the script with two additional checks after the existing upload/download test:

**Check 1 — DB presence and validity:**
```python
import sqlite3, tempfile

resp = s3.get_object(Bucket=bucket, Key='.meta/s3immich.db')
db_bytes = resp['Body'].read()
assert len(db_bytes) > 0, "DB is empty"

with tempfile.NamedTemporaryFile(suffix='.db', delete=False) as f:
    f.write(db_bytes)
    tmp = f.name

con = sqlite3.connect(tmp)
tables = {r[0] for r in con.execute("SELECT name FROM sqlite_master WHERE type='table'")}
assert 'remote_asset_entity' in tables
assert 'remote_exif_entity' in tables
count = con.execute("SELECT COUNT(*) FROM remote_asset_entity").fetchone()[0]
assert count > 0, "No assets in DB"
con.close()
print(f"[OK] .meta/s3immich.db — valid SQLite, {count} asset(s)")
```

**Check 2 — Marker file round-trip (`.meta/` prefix):**
Retarget the existing upload/download test key from `claude-test/upload-download-test.txt` to `.meta/sync-test.txt` to confirm writes land in the correct S3 prefix.

Run: `.venv\Scripts\python test_s3.py` from `C:\Users\bru\spare-source\s3-test\`

## Out of Scope

- PC ingestion tool (Google Takeout parser, thumbnail generator, DB builder) — separate project
- Thumbnail cache eviction — revisit if device storage becomes a concern
- Video playback URL presigning — separate issue
- Face/people thumbnail caching — separate issue
