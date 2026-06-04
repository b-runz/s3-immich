# S3 Sync & Thumbnail Disk Cache Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix DB merge to accept server updates, add a persistent on-device thumbnail disk cache, and wire both into the existing image loading pipeline.

**Architecture:** `ThumbnailCacheService` owns a `{documentsDir}/thumbcache/` directory and exposes `getOrFetch(s3Key)` — disk hit returns bytes immediately, miss presigns + downloads via HTTP and writes to disk. `RemoteImageRequest.load()` routes `.thumbs/` keys through this service and routes originals through `S3Service.global.presignGet()` → native `remoteImageApi`.

**Tech Stack:** Dart/Flutter, `http ^1.6.0` (already in pubspec), `dart:io`, `mocktail ^1.0.5` (tests), Python `boto3` + stdlib `sqlite3` (verification script).

---

## File Map

| File | Change |
|------|--------|
| `lib/services/db_sync.service.dart` | `INSERT OR IGNORE` → `INSERT OR REPLACE` for asset + exif |
| `lib/services/thumbnail_cache.service.dart` | **New** — disk cache service |
| `lib/main.dart` | Initialize `ThumbnailCacheService.instance` |
| `lib/infrastructure/loaders/image_request.dart` | Add `ThumbnailCacheService` import |
| `lib/infrastructure/loaders/remote_image_request.dart` | Route thumbnails through cache; presign originals |
| `test/services/thumbnail_cache_service_test.dart` | **New** — unit tests for the cache service |
| `C:/Users/bru/spare-source/s3-test/test_s3.py` | Add DB validity check |

---

## Task 1: Fix DB merge strategy

**Files:**
- Modify: `lib/services/db_sync.service.dart:51-55`
- Test: `test/services/db_sync_service_test.dart` (existing tests must still pass)

- [ ] **Step 1: Change the two SQL statements**

In `lib/services/db_sync.service.dart`, replace the `_mergeRemoteDb` method body:

```dart
Future<void> _mergeRemoteDb(String remotePath) async {
  final db = _db;
  if (db == null) return;
  await db.customStatement("ATTACH DATABASE '$remotePath' AS remote");
  try {
    await db.customStatement(
      'INSERT OR REPLACE INTO remote_asset_entity SELECT * FROM remote.remote_asset_entity',
    );
    await db.customStatement(
      'INSERT OR REPLACE INTO remote_exif_entity SELECT * FROM remote.remote_exif_entity',
    );
    await db.customStatement(
      'INSERT OR IGNORE INTO remote_album_entity SELECT * FROM remote.remote_album_entity',
    );
    // Restore s3 credentials if the local DB has none (e.g. after a Keystore wipe).
    await db.customStatement(
      'INSERT OR IGNORE INTO store_entity SELECT * FROM remote.store_entity WHERE id = ${StoreKey.s3ConfigJson.id}',
    );
  } finally {
    await db.customStatement('DETACH DATABASE remote');
  }
}
```

- [ ] **Step 2: Run existing tests to confirm no regression**

```bash
flutter test test/services/db_sync_service_test.dart
```

Expected output: all 4 tests pass. (The existing tests mock `_db` as null so the SQL path is bypassed — they test the pull/push orchestration, not the SQL itself.)

- [ ] **Step 3: Commit**

```bash
git add lib/services/db_sync.service.dart
git commit -m "fix: use INSERT OR REPLACE for asset and exif rows in DB merge"
```

---

## Task 2: Create ThumbnailCacheService

**Files:**
- Create: `lib/services/thumbnail_cache.service.dart`
- Create: `test/services/thumbnail_cache_service_test.dart`

- [ ] **Step 1: Write the failing tests first**

Create `test/services/thumbnail_cache_service_test.dart`:

```dart
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mocktail/mocktail.dart';
import 'package:immich_mobile/services/thumbnail_cache.service.dart';
import 'package:immich_mobile/services/s3/s3_service.dart';

class MockS3Service extends Mock implements S3Service {}

void main() {
  late Directory tempDir;
  late MockS3Service s3;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('thumb_cache_test_');
    s3 = MockS3Service();
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  group('ThumbnailCacheService', () {
    test('returns bytes from disk when file is already cached', () async {
      const s3Key = '.thumbs/2020/03/06/IMG_001.jpg';
      final cacheFile = File('${tempDir.path}/$s3Key');
      await cacheFile.parent.create(recursive: true);
      final expected = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0]); // fake JPEG header
      await cacheFile.writeAsBytes(expected);

      final svc = ThumbnailCacheService(
        cacheDir: tempDir,
        s3: s3,
        httpClient: MockClient((_) async => throw Exception('should not hit network')),
      );

      final result = await svc.getOrFetch(s3Key);
      expect(result, equals(expected));
      verifyNever(() => s3.presignGet(any()));
    });

    test('downloads from S3 and writes to disk on cache miss', () async {
      const s3Key = '.thumbs/2020/03/06/IMG_002.jpg';
      const fakePresignedUrl = 'https://s3.example.com/bucket/.thumbs/2020/03/06/IMG_002.jpg?X-Amz-Signature=abc';
      final fakeBytes = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE1]);

      when(() => s3.presignGet(s3Key)).thenAnswer((_) async => fakePresignedUrl);

      final svc = ThumbnailCacheService(
        cacheDir: tempDir,
        s3: s3,
        httpClient: MockClient((request) async {
          expect(request.url.toString(), fakePresignedUrl);
          return http.Response.bytes(fakeBytes, 200);
        }),
      );

      final result = await svc.getOrFetch(s3Key);
      expect(result, equals(fakeBytes));

      // File should now exist on disk
      final cacheFile = File('${tempDir.path}/$s3Key');
      expect(await cacheFile.exists(), isTrue);
      expect(await cacheFile.readAsBytes(), equals(fakeBytes));
    });

    test('second call to same key reads from disk without hitting network', () async {
      const s3Key = '.thumbs/2020/03/06/IMG_003.jpg';
      const fakePresignedUrl = 'https://s3.example.com/presigned';
      final fakeBytes = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0]);
      int networkHits = 0;

      when(() => s3.presignGet(s3Key)).thenAnswer((_) async => fakePresignedUrl);

      final svc = ThumbnailCacheService(
        cacheDir: tempDir,
        s3: s3,
        httpClient: MockClient((_) async {
          networkHits++;
          return http.Response.bytes(fakeBytes, 200);
        }),
      );

      await svc.getOrFetch(s3Key); // miss — downloads
      await svc.getOrFetch(s3Key); // hit — reads from disk

      expect(networkHits, 1);
    });
  });
}
```

- [ ] **Step 2: Run tests to confirm they fail**

```bash
flutter test test/services/thumbnail_cache_service_test.dart
```

Expected: compile error — `ThumbnailCacheService` does not exist yet.

- [ ] **Step 3: Implement ThumbnailCacheService**

Create `lib/services/thumbnail_cache.service.dart`:

```dart
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:immich_mobile/services/s3/s3_service.dart';

class ThumbnailCacheService {
  static ThumbnailCacheService? instance;

  final Directory _cacheDir;
  final S3Service _s3;
  final http.Client _httpClient;

  ThumbnailCacheService({
    required Directory cacheDir,
    required S3Service s3,
    http.Client? httpClient,
  })  : _cacheDir = cacheDir,
        _s3 = s3,
        _httpClient = httpClient ?? http.Client();

  Future<Uint8List> getOrFetch(String s3Key) async {
    final file = File('${_cacheDir.path}/$s3Key');
    if (await file.exists()) {
      return file.readAsBytes();
    }
    final url = await _s3.presignGet(s3Key);
    final response = await _httpClient.get(Uri.parse(url));
    final bytes = response.bodyBytes;
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes);
    return bytes;
  }
}
```

- [ ] **Step 4: Run tests to confirm they pass**

```bash
flutter test test/services/thumbnail_cache_service_test.dart
```

Expected: all 3 tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/services/thumbnail_cache.service.dart test/services/thumbnail_cache_service_test.dart
git commit -m "feat: add ThumbnailCacheService — persistent on-device thumbnail disk cache"
```

---

## Task 3: Wire ThumbnailCacheService into main.dart

**Files:**
- Modify: `lib/main.dart:93-101`

- [ ] **Step 1: Add import and initialization**

In `lib/main.dart`, add the import near the other `s3` imports:

```dart
import 'package:immich_mobile/services/thumbnail_cache.service.dart';
```

Then after `S3Service.global = s3Service;` (line 94), add:

```dart
ThumbnailCacheService.instance = ThumbnailCacheService(
  cacheDir: Directory(p.join(documentsDir.path, 'thumbcache')),
  s3: s3Service,
);
```

The full block in `main()` becomes:

```dart
final s3Service = S3Service();
await s3Service.loadFromStorage();
S3Service.global = s3Service;

final documentsDir = await getApplicationDocumentsDirectory();
ThumbnailCacheService.instance = ThumbnailCacheService(
  cacheDir: Directory(p.join(documentsDir.path, 'thumbcache')),
  s3: s3Service,
);

final dbPath = p.join(documentsDir.path, 'immich.sqlite');
final dbSyncService = DbSyncService(s3Service: s3Service, dbPath: dbPath, db: drift);
if (s3Service.isConfigured) {
  unawaited(dbSyncService.pull());
}
```

- [ ] **Step 2: Build to confirm no compile errors**

```bash
flutter build apk --debug 2>&1 | tail -5
```

Expected: `✓ Built build/app/outputs/flutter-apk/app-debug.apk`

- [ ] **Step 3: Commit**

```bash
git add lib/main.dart
git commit -m "feat: initialize ThumbnailCacheService on app launch"
```

---

## Task 4: Route image loading through cache and presigned URLs

**Files:**
- Modify: `lib/infrastructure/loaders/image_request.dart:1-14`
- Modify: `lib/infrastructure/loaders/remote_image_request.dart`

- [ ] **Step 1: Add imports to image_request.dart**

In `lib/infrastructure/loaders/image_request.dart`, the imports currently end at:

```dart
import 'package:immich_mobile/providers/infrastructure/platform.provider.dart';
import 'package:immich_mobile/services/s3/s3_service.dart';
```

Replace with:

```dart
import 'dart:typed_data';

import 'package:immich_mobile/providers/infrastructure/platform.provider.dart';
import 'package:immich_mobile/services/s3/s3_service.dart';
import 'package:immich_mobile/services/thumbnail_cache.service.dart';
```

- [ ] **Step 2: Replace RemoteImageRequest**

Replace the entire contents of `lib/infrastructure/loaders/remote_image_request.dart` with:

```dart
part of 'image_request.dart';

class RemoteImageRequest extends ImageRequest {
  final String uri;

  RemoteImageRequest({required this.uri});

  @override
  Future<ImageInfo?> load(ImageDecoderCallback decode, {double scale = 1.0}) async {
    if (_isCancelled) return null;

    if (uri.startsWith('.thumbs/')) {
      return _loadFromCache(scale);
    }
    return _loadFromNative(scale);
  }

  @override
  Future<ui.Codec?> loadCodec() async {
    if (_isCancelled) return null;

    if (uri.startsWith('.thumbs/')) {
      return _codecFromCache();
    }
    return _codecFromNative();
  }

  @override
  Future<void> _onCancelled() {
    return remoteImageApi.cancelRequest(requestId);
  }

  // --- thumbnail path (disk cache → Dart decoder) ---

  Future<ImageInfo?> _loadFromCache(double scale) async {
    final cache = ThumbnailCacheService.instance;
    if (cache == null) return null;

    final bytes = await cache.getOrFetch(uri);
    if (_isCancelled) return null;

    final frame = await _fromEncodedPlatformBytes(bytes);
    return frame == null ? null : ImageInfo(image: frame.image, scale: scale);
  }

  Future<ui.Codec?> _codecFromCache() async {
    final cache = ThumbnailCacheService.instance;
    if (cache == null) return null;

    final bytes = await cache.getOrFetch(uri);
    if (_isCancelled) return null;

    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    if (_isCancelled) {
      buffer.dispose();
      return null;
    }
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    buffer.dispose();
    if (_isCancelled) {
      descriptor.dispose();
      return null;
    }
    final codec = await descriptor.instantiateCodec();
    if (_isCancelled) {
      descriptor.dispose();
      codec.dispose();
      return null;
    }
    return codec;
  }

  // --- original path (presign → native remoteImageApi) ---

  Future<ImageInfo?> _loadFromNative(double scale) async {
    final s3 = S3Service.global;
    if (s3 == null || !s3.isConfigured) return null;
    final presignedUrl = await s3.presignGet(uri);
    if (_isCancelled) return null;

    final info = await remoteImageApi.requestImage(presignedUrl, requestId: requestId, preferEncoded: false);
    final frame = switch (info) {
      {'pointer': int pointer, 'length': int length} => await _fromEncodedPlatformImage(pointer, length),
      {'pointer': int pointer, 'width': int width, 'height': int height, 'rowBytes': int rowBytes} =>
        await _fromDecodedPlatformImage(pointer, width, height, rowBytes),
      _ => null,
    };
    return frame == null ? null : ImageInfo(image: frame.image, scale: scale);
  }

  Future<ui.Codec?> _codecFromNative() async {
    final s3 = S3Service.global;
    if (s3 == null || !s3.isConfigured) return null;
    final presignedUrl = await s3.presignGet(uri);
    if (_isCancelled) return null;

    final info = await remoteImageApi.requestImage(presignedUrl, requestId: requestId, preferEncoded: true);
    if (info == null) return null;

    final (codec, _) = await _codecFromEncodedPlatformImage(info['pointer']!, info['length']!) ?? (null, null);
    return codec;
  }

  // --- helper: decode raw Dart bytes to a frame ---

  Future<ui.FrameInfo?> _fromEncodedPlatformBytes(Uint8List bytes) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    if (_isCancelled) {
      buffer.dispose();
      return null;
    }
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    buffer.dispose();
    if (_isCancelled) {
      descriptor.dispose();
      return null;
    }
    final codec = await descriptor.instantiateCodec();
    if (_isCancelled) {
      descriptor.dispose();
      codec.dispose();
      return null;
    }
    final frame = await codec.getNextFrame();
    descriptor.dispose();
    codec.dispose();
    if (_isCancelled) {
      frame.image.dispose();
      return null;
    }
    return frame;
  }
}
```

- [ ] **Step 3: Build to confirm no compile errors**

```bash
flutter build apk --debug 2>&1 | tail -5
```

Expected: `✓ Built build/app/outputs/flutter-apk/app-debug.apk`

- [ ] **Step 4: Commit**

```bash
git add lib/infrastructure/loaders/image_request.dart \
        lib/infrastructure/loaders/remote_image_request.dart
git commit -m "feat: route thumbnail loads through ThumbnailCacheService, presign originals"
```

---

## Task 5: Extend test_s3.py with DB validity check

**Files:**
- Modify: `C:/Users/bru/spare-source/s3-test/test_s3.py`

- [ ] **Step 1: Replace test_s3.py with updated version**

Replace the full contents of `C:/Users/bru/spare-source/s3-test/test_s3.py`:

```python
import os
import sqlite3
import tempfile
import boto3
from botocore.exceptions import ClientError, NoCredentialsError
from dotenv import load_dotenv

load_dotenv()

endpoint = os.environ["S3_ENDPOINT"]
bucket   = os.environ["S3_BUCKET"]
region   = os.environ.get("S3_REGION", "us-east-1")
use_ssl  = os.environ.get("S3_USE_SSL", "true").lower() not in ("false", "0", "no")
access_key = os.environ["S3_ACCESS_KEY"]
secret_key = os.environ["S3_SECRET_KEY"]

print(f"Endpoint : {endpoint}")
print(f"Bucket   : {bucket}")
print(f"Region   : {region}")
print(f"Use SSL  : {use_ssl}")
print(f"Key ID   : {access_key[:6]}…")
print()

s3 = boto3.client(
    "s3",
    endpoint_url=endpoint,
    aws_access_key_id=access_key,
    aws_secret_access_key=secret_key,
    region_name=region,
    use_ssl=use_ssl,
)

# --- Bucket connectivity ---
try:
    s3.head_bucket(Bucket=bucket)
    print(f"[OK] Connected — bucket '{bucket}' is accessible.")
except ClientError as e:
    code = e.response["Error"]["Code"]
    if code == "404":
        print(f"[FAIL] Bucket '{bucket}' does not exist.")
    elif code in ("403", "AccessDenied"):
        print(f"[OK] Connected — bucket '{bucket}' exists (credentials may be read-only).")
    else:
        print(f"[FAIL] ClientError {code}: {e}")
except NoCredentialsError:
    print("[FAIL] SCW_ACCESS_KEY / SCW_SECRET_KEY not set.")
except Exception as e:
    print(f"[FAIL] {type(e).__name__}: {e}")

# --- List objects ---
try:
    result = s3.list_objects_v2(Bucket=bucket, MaxKeys=5)
    count = result.get("KeyCount", 0)
    print(f"[OK] list_objects_v2 returned {count} object(s) (showing up to 5).")
    for obj in result.get("Contents", []):
        print(f"     {obj['Key']}  ({obj['Size']} bytes)")
except ClientError as e:
    print(f"[SKIP] list_objects_v2: {e.response['Error']['Code']}")
except Exception as e:
    print(f"[SKIP] list_objects_v2 error: {e}")

# --- Marker file round-trip (.meta/ prefix) ---
TEST_KEY = ".meta/sync-test.txt"
TEST_CONTENT = b"Hello from Claude Code upload/download test!"

try:
    s3.put_object(Bucket=bucket, Key=TEST_KEY, Body=TEST_CONTENT)
    print(f"\n[OK] Uploaded  '{TEST_KEY}' ({len(TEST_CONTENT)} bytes)")
except ClientError as e:
    print(f"\n[FAIL] Upload: {e.response['Error']['Code']}: {e}")
    TEST_KEY = None

if TEST_KEY:
    try:
        response = s3.get_object(Bucket=bucket, Key=TEST_KEY)
        downloaded = response["Body"].read()
        if downloaded == TEST_CONTENT:
            print(f"[OK] Downloaded '{TEST_KEY}' — content matches.")
        else:
            print(f"[FAIL] Downloaded content mismatch: {downloaded!r}")
    except ClientError as e:
        print(f"[FAIL] Download: {e.response['Error']['Code']}: {e}")

    try:
        s3.delete_object(Bucket=bucket, Key=TEST_KEY)
        print(f"[OK] Deleted   '{TEST_KEY}'")
    except ClientError as e:
        print(f"[WARN] Delete failed: {e.response['Error']['Code']}: {e}")

# --- DB validity check ---
print()
DB_KEY = ".meta/s3immich.db"
try:
    head = s3.head_object(Bucket=bucket, Key=DB_KEY)
    size = head["ContentLength"]
    if size == 0:
        print(f"[FAIL] {DB_KEY} exists but is empty.")
    else:
        print(f"[OK] {DB_KEY} exists ({size} bytes, last modified {head['LastModified']})")

    response = s3.get_object(Bucket=bucket, Key=DB_KEY)
    db_bytes = response["Body"].read()

    with tempfile.NamedTemporaryFile(suffix=".db", delete=False) as f:
        f.write(db_bytes)
        tmp_path = f.name

    try:
        con = sqlite3.connect(tmp_path)
        tables = {r[0] for r in con.execute(
            "SELECT name FROM sqlite_master WHERE type='table'"
        ).fetchall()}

        required = {"remote_asset_entity", "remote_exif_entity"}
        missing = required - tables
        if missing:
            print(f"[FAIL] Missing tables: {missing}")
        else:
            count = con.execute("SELECT COUNT(*) FROM remote_asset_entity").fetchone()[0]
            exif_count = con.execute("SELECT COUNT(*) FROM remote_exif_entity").fetchone()[0]
            print(f"[OK] DB schema valid — {count} asset(s), {exif_count} exif row(s)")
        con.close()
    finally:
        os.unlink(tmp_path)

except ClientError as e:
    code = e.response["Error"]["Code"]
    if code in ("404", "NoSuchKey"):
        print(f"[SKIP] {DB_KEY} not found in bucket — upload it from the app first.")
    else:
        print(f"[FAIL] DB check: {code}: {e}")
except Exception as e:
    print(f"[FAIL] DB check: {type(e).__name__}: {e}")
```

- [ ] **Step 2: Run the script to confirm it works**

```bash
cd /c/Users/bru/spare-source/s3-test
.venv/Scripts/python test_s3.py
```

Expected: all existing checks pass. The DB check prints either `[OK] DB schema valid` (if the DB is already on S3) or `[SKIP] .meta/s3immich.db not found` (if not yet uploaded — that's fine at this stage).

- [ ] **Step 3: Commit**

```bash
cd /c/Users/bru/spare-source/s3-test
git add test_s3.py
git commit -m "test: add DB validity check and retarget marker file to .meta/ prefix"
```

---

## End-to-End Verification

After all tasks are complete:

1. Build and install the debug APK:
   ```bash
   flutter run
   ```
2. Open the app — it should launch and sync the DB from S3 on first open.
3. Scroll through the timeline — thumbnails should appear progressively. After scrolling, check the cache directory:
   ```bash
   adb shell ls /data/data/app.alextran.immich.debug/files/thumbcache/.thumbs/ | head -10
   ```
   You should see date-structured subdirectories with `.jpg` files.
4. Kill and reopen the app — scroll the same photos. Thumbnails should load instantly (no network delay) because they're served from disk.
5. Run the Python verification:
   ```bash
   cd /c/Users/bru/spare-source/s3-test && .venv/Scripts/python test_s3.py
   ```
   Expected: `[OK] DB schema valid — N asset(s), M exif row(s)`
