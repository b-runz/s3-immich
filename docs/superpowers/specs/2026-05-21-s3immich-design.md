# S3immich — Design Spec

**Date:** 2026-05-21  
**Status:** Approved  

---

## Overview

S3immich is a Flutter mobile app that replicates the Immich mobile experience with one fundamental change: the backend is a user-supplied S3-compatible bucket instead of a self-hosted Immich server. No server is required. All photo backup, browsing, search, and album management happens between the device and S3.

The app is built by forking the Immich mobile codebase (`../immich/mobile/`), preserving the entire UI layer and as much logic as possible, and swapping the server-facing infrastructure layer for S3-backed equivalents using Riverpod provider overrides.

---

## Goals

- Identical look, feel, and animations to Immich mobile
- Back up photos to any S3-compatible endpoint (AWS, MinIO, Backblaze B2, Cloudflare R2, Wasabi, etc.)
- S3 is the authority — all devices sharing a bucket see the same timeline
- On-device thumbnails; full-res pulled from S3 on demand
- Local-DB search (metadata tier 1; ML tier 2 additive later)
- Map/places feature using local EXIF data
- Albums via metadata, no file copies
- No login, no server auth, no sharing/partner features

---

## Project Setup

**Source copy (filesystem, not LLM):**

```
rsync -a ../immich/mobile/ ./ --exclude='.git'
```

This copies all 470+ Dart files, assets, Android/iOS native code, fonts, and build config. The LLM only touches new files and the small set of modified files listed below.

**Deletion pass after copy:**

| Path | Reason |
|---|---|
| `openapi/` | Generated OpenAPI client — no server |
| `lib/services/api.service.dart` | Server URL + auth header management |
| `lib/domain/services/sync_stream.service.dart` | WebSocket server sync |
| `lib/infrastructure/repositories/sync_stream.repository.dart` | WebSocket transport |
| `lib/pages/login/` | Replaced by S3 setup screen |
| `lib/presentation/pages/login/` | Same |
| Partner and sharing pages/widgets | Out of scope |
| Auth guard logic in router | Replaced with S3 config check |

---

## Architecture

### Layer model

```
UI (widgets, pages)           — unchanged from Immich
    ↓ ref.watch()
Riverpod providers            — unchanged; repository providers overridden at ProviderScope
    ↓
Repository interfaces         — unchanged
    ↓
Repository implementations    — new S3/Drift implementations registered via overrides
    ↓
S3Service / Drift DB          — new infrastructure
```

Riverpod's `ProviderScope(overrides: [...])` at `main.dart` is the single registration point for all new implementations. No UI file is touched.

### Key principle: filesystem copy, minimal modification

Every file copied from Immich is kept byte-for-byte unless it is in the explicit modification list below. New code is written only in new files. Modified files have the smallest possible diff.

---

## S3Service

**File:** `lib/services/s3.service.dart`  
**Purpose:** Single infrastructure class that owns all S3 communication.

```dart
class S3Service {
  Future<void> configure(S3Config config);
  S3Config? get currentConfig;
  bool get isConfigured;

  Future<String> presignPut(String s3Key, {Duration ttl});
  Future<void> putObject(String s3Key, Uint8List data);
  Future<Uint8List> getObject(String s3Key);
  Future<S3ObjectMeta?> headObject(String s3Key);
  Future<void> putFile(String s3Key, File file);
  Future<List<S3ObjectMeta>> listPrefix(String prefix);
}
```

**S3Config** (stored in `flutter_secure_storage`):

```dart
class S3Config {
  final String endpoint;    // hostname only: 's3.nl-ams.scw.cloud' (no scheme)
  final String bucket;
  final String region;
  final String accessKey;
  final String secretKey;
  final String? prefix;     // optional sub-folder within bucket
  final bool useSSL;        // default true
  final bool pathStyle;     // true for self-hosted MinIO; false for hosted providers
}
```

**HTTP implementation:** `package:minio_new ^1.0.2` — a Dart S3-compatible client. Handles AWS SigV4 signing internally. Works with any S3-compatible endpoint (AWS, MinIO, Backblaze B2, Cloudflare R2, Wasabi, Scaleway) via `endPoint` + optional `pathStyle`. No manual signing code required.

**S3 bucket layout:**

```
bucket/
  YYYY/MM/DD/filename.jpg        ← full-res originals
  .thumbs/YYYY/MM/DD/filename.jpg ← thumbnails
  .meta/s3immich.db               ← Drift DB file (sync target)
```

---

## Auth Replacement

### Router guard

The Immich router redirects to `/login` if no auth session exists. This is replaced with:

```dart
// was: redirect to /login if no token
// now: redirect to /s3-setup if !s3Service.isConfigured
```

### AuthProvider stub

`AuthProvider` is stubbed to always return a synthetic local user. Any widget reading `ref.watch(currentUserProvider)` continues to work without modification.

### S3 Setup Screen

**Route:** `/s3-setup`  
**File:** `lib/presentation/pages/s3_setup/s3_setup.page.dart`

Fields: endpoint, bucket, region, access key, secret key, optional prefix. On save: calls `S3Service.configure()`, writes to `flutter_secure_storage`, navigates to `/` (timeline). On subsequent launches the guard finds `isConfigured == true` and goes straight to the timeline. This is the only genuinely new UI page in the project.

---

## Upload Services (Keep with minimal modification)

`background_upload.service.dart` and `foreground_upload.service.dart` are kept intact. They own all the tested logic: battery awareness, WiFi-only mode, live photo pairing, retry, progress callbacks, iOS URLSession background tasks, Android foreground service lifecycle.

**Only change:** the function that builds the upload task URL. Currently it asks `ApiService` for the server endpoint and auth token. Instead it calls `S3Service.presignPut(s3Key)` to get a pre-signed S3 PUT URL. The `background_downloader` runtime, retry logic, and progress tracking are unchanged.

Thumbnail upload (small file, after full-res enqueued): direct `S3Service.putObject()` call — no background_downloader needed.

---

## DB Sync Service

**File:** `lib/services/db_sync.service.dart`  
**Replaces:** `sync_stream.service.dart` (WebSocket server sync)

| Operation | Trigger | Action |
|---|---|---|
| Pull | App foreground / launch | `headObject(.meta/s3immich.db)` → compare `LastModified` → download + merge if newer |
| Push | After backup completes | Upload local DB file to `.meta/s3immich.db` |
| Push | After album/metadata edit | Same upload |

**Merge strategy on pull:** Asset rows are keyed by S3 path (`YYYY/MM/DD/filename`). Pull is additive — rows not present locally are inserted; existing rows are left alone. Albums and metadata fields use `updatedAt` timestamps for last-write-wins on conflicts. Each asset carries a `sourceDeviceId` so assets from multiple devices coexist without collision.

**DB schema additions** use Drift's existing migration system (currently at v26). New columns and tables are added as numbered migration steps in the existing migration file — same pattern as the 26 steps already there:

- v27: add `sourceDeviceId` (TEXT, nullable) to `RemoteAssetEntity`; add `GeodataPlacesEntity` table (name, adminName, countryCode, latitude, longitude, alternateNames). Existing asset rows default to NULL sourceDeviceId, treated as "this device".
- v28: add `AssetEmbeddingEntity` table (Phase 6, ML search).

No new migration infrastructure. Drift handles execution, rollback safety, and version tracking as it always has.

---

## Thumbnails

### New photos (on-device)

Unchanged: `photo_manager` scan discovers new photos → `ThumbnailApi` platform channel generates scaled JPEG → cached in app cache dir.

After local cache: `S3Service.putObject(".thumbs/YYYY/MM/DD/filename.jpg", thumbnailBytes)` uploads the thumbnail to S3.

### S3-only assets (from other devices)

`ThumbnailWidget` itself is unchanged. The `ImageProvider` it uses (currently pointing at the Immich server URL) is replaced with an S3-backed provider: it calls `S3Service.getObject(".thumbs/YYYY/MM/DD/filename.jpg")` and returns the bytes. `CustomImageCache` caches to disk on first fetch. Subsequent loads are local. Only the image provider implementation changes, not the widget.

---

## Full-res Fetch

Immich's asset viewer already has a local-first strategy via `StorageRepository.isAssetAvailableLocally()`. The chain is extended:

```
tap full-res
  → isAvailableLocally?
      yes → load from device photo library (unchanged)
      no  → S3Service.getObject("YYYY/MM/DD/filename.jpg")
            → cache to app temp dir
            → display
```

**Modified file:** `lib/infrastructure/repositories/storage.repository.dart` — the `loadFileFromCloud()` method gains an S3 branch alongside the existing iCloud branch. Interface unchanged.

---

## GeoData

**Source:** GeoNames city files at `../immich/server/build/geodata/` — same data Immich uses.

**Build step:** `tool/build_geodata.dart` reads `cities*.txt` + `admin1CodesASCII.txt` and generates `lib/generated/geodata_seed.g.dart` (gitignored, same convention as other `.g.dart` files). Run before `flutter build`. Can be wired into a `Makefile` or `build.yaml`.

The generated file is a compiled Dart constant — no file I/O at runtime:

```dart
// GENERATED — run: dart run tool/build_geodata.dart
const kGeodataCities = [
  (name: 'Paris', admin1: 'Île-de-France', countryCode: 'FR', lat: 48.8534, lng: 2.3488),
  ...
];
```

**Storage:** A `GeodataPlacesEntity` table in the existing Drift DB, added in migration v27. On first launch the migration batch-inserts from `kGeodataCities`. `StoreEntity` tracks whether the seed has run; subsequent launches skip it entirely.

**`GeoDataRepository`** is a standard Drift repository:
- `searchPlaces(name)` — LIKE / FTS5 on `name` / `alternateNames`, returns ranked `GeoPlace` list with coordinates
- `nearestCity(lat, lng)` — closest place within 25km for reverse geocoding at index time; JOINs directly with `RemoteExifEntity` since both live in the same Drift DB

---

## Search

### Tier 1 — Metadata (ships with MVP)

`SearchApiRepository` is replaced with a Drift-backed implementation. All queries run against the local DB — no network required.

| Search type | Source |
|---|---|
| Text (filename, description) | `RemoteAssetEntity.fileName` + SQLite FTS5 |
| Location by name ("Paris") | `GeoDataRepository.searchPlaces()` → lat/lng → bounding box on `RemoteExifEntity` |
| Location stored (city/state/country) | `RemoteExifEntity.city / state / country` — populated by reverse geocoding at index time using `GeoDataRepository` (no network call) |
| Date range | `RemoteAssetEntity.fileCreatedAt` |
| Camera | `RemoteExifEntity.make / model` |

**Reverse geocoding at index time:** when a new photo is indexed, its GPS coordinates are looked up against the bundled `geodata.db` (nearest city within 25km, same logic as Immich) and `city / state / country` are stored in `RemoteExifEntity`. No network call. Enables both text-based city search and coordinate bounding box search to work.

The search UI, filter models, and Riverpod providers are unchanged.

### Tier 2 — ML search (Phase 5, additive)

Faces: ML Kit face detection → TFLite MobileFaceNet embeddings → DBSCAN clustering → stored in existing `AssetFaceEntity` + `PersonEntity` Drift tables.

Semantic / objects: TFLite CLIP generates per-photo embedding → stored as BLOB column in a new `AssetEmbeddingEntity` table → `sqlite-vec` extension for ANN similarity queries.

Embeddings are part of the synced DB file, so other devices inherit computed embeddings without re-processing.

---

## Map / Places

`MapRepository` is replaced with a Drift implementation. Single query:

```sql
SELECT lat, lng, assetId
FROM RemoteExifEntity
WHERE latitude IS NOT NULL AND longitude IS NOT NULL
JOIN RemoteAssetEntity ON ...
```

`maplibre_gl` rendering and all map UI code unchanged.

---

## Albums

Albums are stored as metadata in the local Drift DB (`RemoteAlbumEntity`, `RemoteAlbumAssetEntity`). Creating or editing an album writes to the local DB and triggers a DB push to S3. No files are copied or moved. Album UI code unchanged.

---

## Repository Override Summary

| Repository | Action | Implementation |
|---|---|---|
| `AssetRepository` | Override | Drift — populated by sync service |
| `AlbumRepository` | Override | Drift — local metadata |
| `SearchApiRepository` | Override | Drift SQL (tier 1) |
| `MapRepository` | Override | Drift EXIF query |
| `StorageRepository` | Modify | Add S3 branch to `loadFileFromCloud()` |
| `BackupRepository` | Keep | Already Drift-backed |
| `UploadRepository` | Keep | `background_downloader` unchanged |
| `NetworkRepository` | Keep | Platform HTTP client unchanged |
| `AuthRepository` | Stub | Always returns synthetic local user |

---

## Phasing

| Phase | Scope |
|---|---|
| 1 | `rsync` setup, deletion pass, S3Service, AwsSigV4Signer, S3SetupPage, auth stub, router guard swap, backup to S3 (upload services minimally modified), timeline showing device photos |
| 2 | DbSyncService, thumbnail upload to S3, thumbnail fetch for S3-only assets, full-res fetch from S3 |
| 3 | Search tier 1 (Drift SQL metadata search) |
| 4 | Map/places (Drift EXIF query) |
| 5 | Albums (local DB metadata) |
| 6 | ML search tier 2 (faces, CLIP semantic, objects) — additive |

---

## Out of Scope

- Sharing features
- Partner features
- Server/API compatibility
- iOS-specific testing (Android primary; Flutter code remains cross-platform)
- Multi-user access control within a bucket
