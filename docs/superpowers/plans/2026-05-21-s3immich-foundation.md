# S3immich Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fork the Immich mobile codebase, replace the server API layer with S3-backed infrastructure, and deliver a working app that backs up device photos to S3, shows the timeline with cached thumbnails, and syncs the Drift DB to S3.

**Architecture:** rsync copies the full Immich mobile source; Riverpod provider overrides at `main.dart` swap in S3-backed repository implementations without touching UI code. An `AwsSigV4Signer` + `S3Service` own all S3 communication. Upload services keep their tested logic but swap `buildUploadTask` to emit a pre-signed S3 PUT instead of a multipart POST to the Immich server. Auth is stubbed to a synthetic local user; the login router guard is replaced with an S3-config-present check.

**Tech Stack:** Flutter/Dart, Riverpod 2.6.1 (hooks_riverpod), Drift 2.32.1 (SQLite), background_downloader 9.5.4, flutter_secure_storage, minio_new ^1.0.2 (new), auto_route 11.1.0.

**Spec:** `docs/superpowers/specs/2026-05-21-s3immich-design.md`

---

## File Map

### New files
| File | Responsibility |
|---|---|
| `lib/services/s3/s3_config.dart` | S3Config data class + secure storage persistence |
| `lib/services/s3/s3_object_meta.dart` | S3ObjectMeta + S3Exception value types |
| `lib/services/s3/s3_service.dart` | S3 operations via minio_new (put/get/head/presign/list) |
| `lib/services/db_sync.service.dart` | Pull/push Drift DB file to `.meta/s3immich.db` in S3 |
| `lib/routing/s3_config_guard.dart` | AutoRouteGuard: redirect to `/s3-setup` if unconfigured |
| `lib/presentation/pages/s3_setup/s3_setup.page.dart` | S3 credentials form screen |
| `lib/services/s3/s3_service_provider.dart` | Riverpod provider declaration for S3Service |
| `lib/utils/image_providers/s3_thumbnail_provider.dart` | ImageProvider that fetches `.thumbs/` from S3 |
| `test/services/s3/s3_config_test.dart` | Unit tests for S3Config |
| `test/services/s3/s3_service_test.dart` | Unit tests for S3Service |
| `test/services/db_sync_service_test.dart` | Unit tests for DbSyncService |

### Modified files
| File | Change |
|---|---|
| `pubspec.yaml` | Add `package:crypto` to dependencies |
| `lib/main.dart` | Add provider overrides: S3Service, auth stub, S3ConfigGuard |
| `lib/routing/router.dart` | Replace `_authGuard` with `_s3ConfigGuard` in TabShellRoute |
| `lib/services/background_upload.service.dart` | `buildUploadTask` → S3 pre-signed PUT; delete after `api.service.dart` import removed |
| `lib/services/foreground_upload.service.dart` | Same swap (after reading the file) |
| `lib/services/api.service.dart` | Delete after Task 10 removes all callers |
| `lib/infrastructure/repositories/db.repository.dart` | Add migration v27: `sourceDeviceId` column |
| `lib/infrastructure/repositories/storage.repository.dart` | Add S3 branch to `loadFileFromCloud()` |

---

## Task 1: Project Foundation

**Files:**
- Create: `.gitignore` additions
- Shell: `rsync` copy from Immich mobile

- [ ] **Step 1: Copy Immich mobile source**

```bash
cd /home/brj/local-source/s3mmich
rsync -a ../immich/mobile/ ./ \
  --exclude='.git' \
  --exclude='build/' \
  --exclude='.dart_tool/' \
  --exclude='.flutter-plugins' \
  --exclude='.flutter-plugins-dependencies'
```

- [ ] **Step 2: Verify the copy**

```bash
ls lib/ && echo "---" && wc -l pubspec.yaml
```

Expected: `lib/` directory with subdirs (`constants`, `domain`, `infrastructure`, etc.), pubspec.yaml with ~100+ lines.

- [ ] **Step 3: Rename app package references**

```bash
# Check current package name
grep "^name:" pubspec.yaml
grep "^name:" openapi/pubspec.yaml
```

```bash
# Rename in pubspec.yaml
sed -i 's/^name: immich_mobile/name: s3mmich/' pubspec.yaml
```

- [ ] **Step 4: Attempt initial build to baseline errors**

```bash
flutter pub get 2>&1 | tail -20
flutter analyze --no-fatal-infos 2>&1 | tail -30
```

Expected: compiles (possibly with warnings). Note any errors for later tasks.

- [ ] **Step 5: Delete files that are replaced by S3 equivalents**

```bash
# Login pages — replaced by S3SetupPage
rm -rf lib/pages/login lib/presentation/pages/login

# Partner and sharing pages — out of scope
rm -rf lib/pages/sharing lib/presentation/pages/sharing
rm -rf lib/pages/partner lib/presentation/pages/partner
find lib/widgets -name '*partner*' -o -name '*sharing*' | xargs rm -f

# WebSocket sync — replaced by DbSyncService
rm -f lib/domain/services/sync_stream.service.dart
rm -f lib/infrastructure/repositories/sync_stream.repository.dart
```

> After each `rm`, run `flutter analyze --no-fatal-infos 2>&1 | grep error | head -10` to surface any files that imported the deleted code. Fix those imports (either remove the import or delete the file if it's also out of scope) before continuing.

- [ ] **Step 6: Add `.gitignore` entries for generated files**

Append to `.gitignore`:
```
lib/generated/geodata_seed.g.dart
```

- [ ] **Step 8: Commit baseline**

```bash
git add -A
git commit -m "feat: rsync Immich mobile source as S3immich baseline"
```

---

## Task 2: Add Dependencies

**Files:**
- Modify: `pubspec.yaml`

- [ ] **Step 1: Add `minio_new` to dependencies and `mocktail` to dev_dependencies**

In `pubspec.yaml`, find the `dependencies:` section and add:
```yaml
  minio_new: ^1.0.2
```

Find the `dev_dependencies:` section and add:
```yaml
  mocktail: ^1.0.4
```

- [ ] **Step 2: Install and verify**

```bash
flutter pub get
flutter pub deps | grep minio_new
flutter pub deps | grep mocktail
```

Expected: `minio_new 1.0.x` and `mocktail 1.x.x` appear.

- [ ] **Step 3: Commit**

```bash
git add pubspec.yaml pubspec.lock
git commit -m "feat: add minio_new S3 client and mocktail test dependency"
```

---

## Task 3: S3 Value Types

**Files:**
- Create: `lib/services/s3/s3_object_meta.dart`
- Create: `lib/services/s3/s3_config.dart`
- Test: `test/services/s3/s3_config_test.dart`

- [ ] **Step 1: Write failing test for S3Config serialization**

Create `test/services/s3/s3_config_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:s3mmich/services/s3/s3_config.dart';

void main() {
  group('S3Config', () {
    test('round-trips through JSON preserving all fields', () {
      const config = S3Config(
        endpoint: 's3.nl-ams.scw.cloud',
        bucket: 'my-photos',
        region: 'nl-ams',
        accessKey: 'AKIAIOSFODNN7EXAMPLE',
        secretKey: 'wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY',
        prefix: 'photos',
        useSSL: true,
        pathStyle: false,
      );
      final restored = S3Config.fromJson(config.toJson());
      expect(restored.endpoint, config.endpoint);
      expect(restored.bucket, config.bucket);
      expect(restored.region, config.region);
      expect(restored.accessKey, config.accessKey);
      expect(restored.secretKey, config.secretKey);
      expect(restored.prefix, config.prefix);
      expect(restored.useSSL, config.useSSL);
      expect(restored.pathStyle, config.pathStyle);
    });

    test('handles null prefix and defaults', () {
      const config = S3Config(
        endpoint: 'minio.local',
        bucket: 'my-photos',
        region: 'us-east-1',
        accessKey: 'AKIA',
        secretKey: 'secret',
      );
      final restored = S3Config.fromJson(config.toJson());
      expect(restored.prefix, isNull);
      expect(restored.useSSL, isTrue);
      expect(restored.pathStyle, isFalse);
    });

    test('s3KeyFor generates date-based path with prefix', () {
      const config = S3Config(
        endpoint: 's3.nl-ams.scw.cloud',
        bucket: 'photos',
        region: 'nl-ams',
        accessKey: 'AKIA',
        secretKey: 'secret',
        prefix: 'mydevice',
      );
      final key = config.s3KeyFor('IMG_1234.JPG', DateTime(2024, 1, 5));
      expect(key, 'mydevice/2024/01/05/IMG_1234.JPG');
    });

    test('s3KeyFor without prefix', () {
      const config = S3Config(
        endpoint: 's3.nl-ams.scw.cloud',
        bucket: 'photos',
        region: 'nl-ams',
        accessKey: 'AKIA',
        secretKey: 'secret',
      );
      final key = config.s3KeyFor('IMG_1234.JPG', DateTime(2024, 1, 5));
      expect(key, '2024/01/05/IMG_1234.JPG');
    });
  });
}
```

- [ ] **Step 2: Run test to confirm it fails**

```bash
flutter test test/services/s3/s3_config_test.dart
```

Expected: FAIL — `s3_config.dart` not found.

- [ ] **Step 3: Create `s3_object_meta.dart`**

Create `lib/services/s3/s3_object_meta.dart`:

```dart
class S3ObjectMeta {
  final String key;
  final String etag;
  final DateTime lastModified;
  final int size;

  const S3ObjectMeta({
    required this.key,
    required this.etag,
    required this.lastModified,
    required this.size,
  });
}

class S3Exception implements Exception {
  final String message;
  const S3Exception(this.message);
  @override
  String toString() => 'S3Exception: $message';
}
```

- [ ] **Step 4: Create `s3_config.dart`**

Note: `endpoint` is a **hostname only** (no scheme) — e.g. `s3.nl-ams.scw.cloud` or `minio.local`. The `minio_new` `Minio` constructor takes this form directly.

Create `lib/services/s3/s3_config.dart`:

```dart
import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class S3Config {
  final String endpoint;   // hostname only: 's3.nl-ams.scw.cloud'
  final String bucket;
  final String region;
  final String accessKey;
  final String secretKey;
  final String? prefix;
  final bool useSSL;       // default true
  final bool pathStyle;    // true for self-hosted MinIO; false for hosted providers

  const S3Config({
    required this.endpoint,
    required this.bucket,
    required this.region,
    required this.accessKey,
    required this.secretKey,
    this.prefix,
    this.useSSL = true,
    this.pathStyle = false,
  });

  Map<String, dynamic> toJson() => {
    'endpoint': endpoint,
    'bucket': bucket,
    'region': region,
    'accessKey': accessKey,
    'secretKey': secretKey,
    if (prefix != null) 'prefix': prefix,
    'useSSL': useSSL,
    'pathStyle': pathStyle,
  };

  factory S3Config.fromJson(Map<String, dynamic> json) => S3Config(
    endpoint: json['endpoint'] as String,
    bucket: json['bucket'] as String,
    region: json['region'] as String,
    accessKey: json['accessKey'] as String,
    secretKey: json['secretKey'] as String,
    prefix: json['prefix'] as String?,
    useSSL: json['useSSL'] as bool? ?? true,
    pathStyle: json['pathStyle'] as bool? ?? false,
  );

  String s3KeyFor(String filename, DateTime createdAt) {
    final y = createdAt.year.toString().padLeft(4, '0');
    final m = createdAt.month.toString().padLeft(2, '0');
    final d = createdAt.day.toString().padLeft(2, '0');
    final path = '$y/$m/$d/$filename';
    return prefix != null ? '$prefix/$path' : path;
  }

  String thumbnailKeyFor(String filename, DateTime createdAt) =>
      '.thumbs/${s3KeyFor(filename, createdAt)}';

  static const _storageKey = 's3_config_v1';
  static const _storage = FlutterSecureStorage();

  static Future<S3Config?> load() async {
    final raw = await _storage.read(key: _storageKey);
    if (raw == null) return null;
    return S3Config.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  Future<void> save() =>
      _storage.write(key: _storageKey, value: jsonEncode(toJson()));

  static Future<void> clear() => _storage.delete(key: _storageKey);
}
```

- [ ] **Step 5: Run test — expect PASS**

```bash
flutter test test/services/s3/s3_config_test.dart
```

Expected: All 4 tests PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/services/s3/ test/services/s3/s3_config_test.dart
git commit -m "feat: add S3Config and S3ObjectMeta value types"
```

---

## Task 4: S3Service

**Files:**
- Create: `lib/services/s3/s3_service.dart`
- Test: `test/services/s3/s3_service_test.dart`

`S3Service` wraps `minio_new`'s `Minio` client. All signing is handled internally by `minio_new`.

Note: `presignPut` is **async** (`Future<String>`) because `minio_new`'s `presignedPutObject` is async.

- [ ] **Step 1: Write failing tests**

Create `test/services/s3/s3_service_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:minio_new/minio.dart';
import 'package:s3mmich/services/s3/s3_config.dart';
import 'package:s3mmich/services/s3/s3_service.dart';
import 'package:s3mmich/services/s3/s3_object_meta.dart';

class MockMinio extends Mock implements Minio {}

const _testConfig = S3Config(
  endpoint: 's3.nl-ams.scw.cloud',
  bucket: 'test-bucket',
  region: 'nl-ams',
  accessKey: 'AKIAIOSFODNN7EXAMPLE',
  secretKey: 'wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY',
);

void main() {
  late MockMinio mockMinio;

  setUp(() {
    mockMinio = MockMinio();
  });

  S3Service makeService() => S3Service.withClient(mockMinio, _testConfig);

  group('S3Service', () {
    test('isConfigured is false before configure()', () {
      final svc = S3Service();
      expect(svc.isConfigured, isFalse);
    });

    test('presignPut returns a non-empty URL', () async {
      when(() => mockMinio.presignedPutObject('test-bucket', any(), expires: any(named: 'expires')))
          .thenAnswer((_) async => 'https://s3.nl-ams.scw.cloud/test-bucket/photo.jpg?X-Amz-Signature=abc');
      final svc = makeService();
      final url = await svc.presignPut('2024/01/05/photo.jpg');
      expect(url, contains('X-Amz-Signature'));
    });

    test('putObject delegates to minio putObject', () async {
      when(() => mockMinio.putObject(
            'test-bucket', any(), any(),
            size: any(named: 'size'),
            contentType: any(named: 'contentType'),
          )).thenAnswer((_) async => '');
      final svc = makeService();
      await svc.putObject('2024/01/05/photo.jpg', [1, 2, 3]);
      verify(() => mockMinio.putObject('test-bucket', '2024/01/05/photo.jpg', any(), size: 3, contentType: any(named: 'contentType'))).called(1);
    });

    test('headObject returns null when MinioError NoSuchKey', () async {
      when(() => mockMinio.statObject('test-bucket', any()))
          .thenThrow(MinioError('NoSuchKey'));
      final svc = makeService();
      final meta = await svc.headObject('.meta/s3immich.db');
      expect(meta, isNull);
    });

    test('headObject returns S3ObjectMeta on success', () async {
      when(() => mockMinio.statObject('test-bucket', any()))
          .thenAnswer((_) async => StatObjectResult()
            ..eTag = '"abc123"'
            ..lastModified = DateTime(2024, 1, 5)
            ..size = 4096);
      final svc = makeService();
      final meta = await svc.headObject('.meta/s3immich.db');
      expect(meta, isNotNull);
      expect(meta!.etag, '"abc123"');
      expect(meta.size, 4096);
    });
  });
}
```

- [ ] **Step 2: Run test to confirm failure**

```bash
flutter test test/services/s3/s3_service_test.dart
```

Expected: FAIL — `s3_service.dart` not found.

- [ ] **Step 3: Create `s3_service.dart`**

Create `lib/services/s3/s3_service.dart`:

```dart
import 'dart:io';
import 'dart:typed_data';
import 'package:minio_new/minio.dart';
import 's3_config.dart';
import 's3_object_meta.dart';

class S3Service {
  Minio? _client;
  S3Config? _config;

  S3Service();

  S3Service.withClient(Minio client, S3Config config)
      : _client = client,
        _config = config;

  bool get isConfigured => _client != null;
  S3Config? get currentConfig => _config;

  Future<void> configure(S3Config config) async {
    await config.save();
    _apply(config);
  }

  Future<void> configureWithoutSave(S3Config config) async => _apply(config);

  void _apply(S3Config config) {
    _config = config;
    _client = Minio(
      endPoint: config.endpoint,
      accessKey: config.accessKey,
      secretKey: config.secretKey,
      region: config.region.isNotEmpty ? config.region : null,
      useSSL: config.useSSL,
      pathStyle: config.pathStyle,
    );
  }

  Future<void> loadFromStorage() async {
    final config = await S3Config.load();
    if (config != null) _apply(config);
  }

  Future<String> presignPut(String s3Key, {Duration ttl = const Duration(hours: 1)}) async {
    _requireConfigured();
    return _client!.presignedPutObject(_config!.bucket, s3Key, expires: ttl.inSeconds);
  }

  Future<void> putObject(String s3Key, List<int> data, {String contentType = 'application/octet-stream'}) async {
    _requireConfigured();
    final bytes = Uint8List.fromList(data);
    await _client!.putObject(
      _config!.bucket, s3Key,
      Stream.value(bytes),
      size: bytes.length,
      contentType: contentType,
    );
  }

  Future<List<int>> getObject(String s3Key) async {
    _requireConfigured();
    final stream = await _client!.getObject(_config!.bucket, s3Key);
    return await stream.fold<List<int>>([], (acc, chunk) => acc..addAll(chunk));
  }

  Future<S3ObjectMeta?> headObject(String s3Key) async {
    _requireConfigured();
    try {
      final stat = await _client!.statObject(_config!.bucket, s3Key);
      return S3ObjectMeta(
        key: s3Key,
        etag: stat.eTag ?? '',
        lastModified: stat.lastModified ?? DateTime.now(),
        size: stat.size ?? 0,
      );
    } on MinioError catch (e) {
      if (e.message?.contains('NoSuchKey') == true) return null;
      rethrow;
    } catch (_) {
      // statObject null-check crash (minio_new issue) — treat as not found
      return null;
    }
  }

  Future<void> putFile(String s3Key, String filePath) async {
    _requireConfigured();
    final data = await File(filePath).readAsBytes();
    await putObject(s3Key, data);
  }

  Future<List<S3ObjectMeta>> listPrefix(String prefix) async {
    _requireConfigured();
    final results = <S3ObjectMeta>[];
    await for (final chunk in _client!.listAllObjectsV2(_config!.bucket, prefix: prefix)) {
      for (final obj in chunk.objects) {
        results.add(S3ObjectMeta(
          key: obj.key ?? '',
          etag: obj.eTag ?? '',
          lastModified: obj.lastModified ?? DateTime.now(),
          size: obj.size ?? 0,
        ));
      }
    }
    return results;
  }

  void _requireConfigured() {
    if (_client == null) throw S3Exception('S3Service not configured');
  }
}
```

- [ ] **Step 4: Run tests — expect PASS**

```bash
flutter test test/services/s3/s3_service_test.dart
```

Expected: All 4 tests PASS. If `StatObjectResult` constructor differs from what minio_new provides, read the actual class from the package and adjust the mock setup accordingly.

- [ ] **Step 5: Commit**

```bash
git add lib/services/s3/s3_service.dart test/services/s3/s3_service_test.dart
git commit -m "feat: implement S3Service using minio_new client"
```

---

## Task 5: Auth Stub + main.dart Wiring

**Files:**
- Modify: `lib/main.dart`
- Read first: `lib/providers/auth.provider.dart`, `lib/providers/infrastructure/db.provider.dart`

- [ ] **Step 1: Read current main.dart provider setup**

```bash
grep -n 'ProviderScope\|overrides\|driftProvider\|driftOverride' lib/main.dart | head -30
```

Expected: Shows lines with `ProviderScope` and `driftOverride`.

- [ ] **Step 2: Read AuthState shape**

```bash
grep -n 'class AuthState\|isAuthenticated\|userId\|copyWith' lib/providers/auth.provider.dart | head -20
```

Note the fields of `AuthState` — you need them in Step 4.

- [ ] **Step 3: Create `lib/services/s3/s3_service_provider.dart`**

Create `lib/services/s3/s3_service_provider.dart`:

```dart
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 's3_service.dart';

final s3ServiceProvider = Provider<S3Service>((ref) {
  throw UnimplementedError('s3ServiceProvider must be overridden');
});
```

- [ ] **Step 4: Add S3Service initialization to main.dart**

Read `lib/main.dart` lines 40–75 to see the exact `ProviderScope` setup, then add S3Service initialization.

Find the `runApp` or early-init block (around line 49–64) and add S3 loading before `runApp`:

```dart
// After existing Store.init() / Hive setup, before runApp:
final s3Service = S3Service();
await s3Service.loadFromStorage();
```

Find the `ProviderScope(overrides: [` block and add:

```dart
s3ServiceProvider.overrideWithValue(s3Service),
```

- [ ] **Step 5: Verify the app still compiles**

```bash
flutter analyze --no-fatal-infos 2>&1 | grep -E 'error|Error' | head -20
```

Expected: No new errors introduced.

- [ ] **Step 6: Commit**

```bash
git add lib/main.dart lib/services/s3/s3_service_provider.dart
git commit -m "feat: wire S3Service into ProviderScope at app startup"
```

---

## Task 6: S3 Config Guard + S3 Setup Page

**Files:**
- Create: `lib/routing/s3_config_guard.dart`
- Create: `lib/presentation/pages/s3_setup/s3_setup.page.dart`
- Modify: `lib/routing/router.dart`

- [ ] **Step 1: Read current auth guard**

```bash
cat lib/routing/auth_guard.dart
```

Note the `onNavigation(NavigationResolver resolver, TabsRouter router)` signature — replicate it.

- [ ] **Step 2: Read router.dart guard registration**

```bash
grep -n 'authGuard\|AuthGuard\|_authGuard\|guards:' lib/routing/router.dart | head -20
```

Note the exact variable name and where it's passed into the route.

- [ ] **Step 3: Create S3ConfigGuard**

Create `lib/routing/s3_config_guard.dart`:

```dart
import 'package:auto_route/auto_route.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:s3mmich/services/s3/s3_service_provider.dart';
import 'router.gr.dart';

class S3ConfigGuard extends AutoRouteGuard {
  final Ref _ref;
  S3ConfigGuard(this._ref);

  @override
  void onNavigation(NavigationResolver resolver, StackRouter router) {
    final s3 = _ref.read(s3ServiceProvider);
    if (s3.isConfigured) {
      resolver.next(true);
    } else {
      router.push(const S3SetupRoute());
    }
  }
}
```

- [ ] **Step 4: Create S3SetupPage**

Create `lib/presentation/pages/s3_setup/s3_setup.page.dart`:

```dart
import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:s3mmich/services/s3/s3_config.dart';
import 'package:s3mmich/services/s3/s3_service_provider.dart';
import 'package:s3mmich/routing/router.gr.dart';

@RoutePage()
class S3SetupPage extends ConsumerStatefulWidget {
  const S3SetupPage({super.key});

  @override
  ConsumerState<S3SetupPage> createState() => _S3SetupPageState();
}

class _S3SetupPageState extends ConsumerState<S3SetupPage> {
  final _formKey = GlobalKey<FormState>();
  final _endpointCtrl = TextEditingController();
  final _bucketCtrl = TextEditingController();
  final _regionCtrl = TextEditingController(text: 'us-east-1');
  final _accessKeyCtrl = TextEditingController();
  final _secretKeyCtrl = TextEditingController();
  final _prefixCtrl = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    for (final c in [_endpointCtrl, _bucketCtrl, _regionCtrl, _accessKeyCtrl, _secretKeyCtrl, _prefixCtrl]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() { _saving = true; _error = null; });
    try {
      final endpoint = _endpointCtrl.text.trim();
      final config = S3Config(
        // strip scheme if user accidentally typed it
        endpoint: endpoint.replaceFirst(RegExp(r'^https?://'), ''),
        bucket: _bucketCtrl.text.trim(),
        region: _regionCtrl.text.trim(),
        accessKey: _accessKeyCtrl.text.trim(),
        secretKey: _secretKeyCtrl.text.trim(),
        prefix: _prefixCtrl.text.trim().isEmpty ? null : _prefixCtrl.text.trim(),
        useSSL: true,
        pathStyle: false,
      );
      await ref.read(s3ServiceProvider).configure(config);
      if (mounted) context.router.replaceAll([const TabsRoute()]);
    } catch (e) {
      setState(() { _error = e.toString(); });
    } finally {
      if (mounted) setState(() { _saving = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Connect to S3')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _field('Endpoint', _endpointCtrl, hint: 's3.nl-ams.scw.cloud', required: true),
            _field('Bucket', _bucketCtrl, required: true),
            _field('Region', _regionCtrl, required: true),
            _field('Access Key', _accessKeyCtrl, required: true),
            _field('Secret Key', _secretKeyCtrl, required: true, obscure: true),
            _field('Prefix (optional)', _prefixCtrl),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _saving ? null : _save,
              child: _saving ? const CircularProgressIndicator() : const Text('Connect'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _field(
    String label,
    TextEditingController ctrl, {
    String? hint,
    bool required = false,
    bool obscure = false,
  }) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextFormField(
          controller: ctrl,
          decoration: InputDecoration(labelText: label, hintText: hint),
          obscureText: obscure,
          validator: required ? (v) => (v == null || v.trim().isEmpty) ? '$label is required' : null : null,
        ),
      );
}
```

- [ ] **Step 5: Register S3SetupRoute in router.dart**

Open `lib/routing/router.dart`. Find the `@AutoRouter(routes: [...])` annotation.

Add the S3Setup route and replace the auth guard registration:

```dart
// Add to routes list:
AutoRoute(page: S3SetupRoute.page),

// Replace _authGuard with _s3ConfigGuard:
// was: final _authGuard = AuthGuard(_ref);
// now:
final _s3ConfigGuard = S3ConfigGuard(_ref);

// In the TabShellRoute guards list:
// was: guards: [_authGuard, _duplicateGuard]
// now: guards: [_s3ConfigGuard, _duplicateGuard]
```

- [ ] **Step 6: Run auto_route code generation**

```bash
dart run build_runner build --delete-conflicting-outputs
```

Expected: `router.gr.dart` regenerates with `S3SetupRoute` included.

- [ ] **Step 7: Verify compilation**

```bash
flutter analyze --no-fatal-infos 2>&1 | grep -E '^  error' | head -20
```

Expected: No errors.

- [ ] **Step 8: Commit**

```bash
git add lib/routing/s3_config_guard.dart lib/presentation/pages/s3_setup/ lib/routing/router.dart lib/routing/router.gr.dart
git commit -m "feat: replace auth guard with S3 config guard, add S3 setup screen"
```

---

## Task 7: Auth Stub

**Files:**
- Modify: `lib/providers/auth.provider.dart` (read first)
- Modify: `lib/main.dart`

- [ ] **Step 1: Read AuthState and authProvider**

```bash
grep -n 'class AuthState\|AuthState(\|isAuthenticated\|userId\|name\|isAdmin\|deviceId' lib/providers/auth.provider.dart | head -30
```

Note all `AuthState` fields.

- [ ] **Step 2: Read how authProvider is consumed**

```bash
grep -rn 'authProvider\|isAuthenticated' lib/providers/ lib/presentation/ --include='*.dart' | grep -v '.dart:.*authProvider.*=' | head -20
```

This shows which widgets/providers read auth state.

- [ ] **Step 3: Override authProvider in main.dart with stubbed state**

In `lib/main.dart`, in the `ProviderScope(overrides: [...])` block, add an auth override that always returns authenticated state. The exact shape depends on Step 1 output, but will be similar to:

```dart
authProvider.overrideWith(
  (ref) => AuthNotifier.stub(
    AuthState(
      isAuthenticated: true,
      userId: 'local-device-user',
      userEmail: 'local@s3immich',
      name: 'My Device',
      isAdmin: false,
      deviceId: 'this-device',
    ),
  ),
),
```

If `AuthNotifier` has no `.stub()` factory, create one in `auth.provider.dart`:

```dart
// In AuthNotifier class:
factory AuthNotifier.stub(AuthState state) => AuthNotifier._stub(state);
AuthNotifier._stub(AuthState state) : super(state);
```

- [ ] **Step 4: Verify the app still analyzes clean**

```bash
flutter analyze --no-fatal-infos 2>&1 | grep -E '^  error' | head -20
```

- [ ] **Step 5: Commit**

```bash
git add lib/providers/auth.provider.dart lib/main.dart
git commit -m "feat: stub AuthNotifier to bypass login flow, always return authenticated local user"
```

---

## Task 8: Drift Migration v27 — sourceDeviceId

**Files:**
- Modify: `lib/infrastructure/repositories/db.repository.dart`
- Read: `lib/infrastructure/entities/remote_asset_entity.dart` (find exact path first)

- [ ] **Step 1: Find the remote asset entity**

```bash
find lib -name '*remote_asset*' -o -name '*asset_entity*' | grep -v '.g.dart' | head -10
```

- [ ] **Step 2: Read the entity file**

```bash
cat <file from step 1>
```

Note the existing columns and class name.

- [ ] **Step 3: Add sourceDeviceId column to entity**

In the entity file, add the new column. The pattern matches existing columns in the file. For a Drift `TextColumn`:

```dart
TextColumn get sourceDeviceId => text().nullable()();
```

Add it after the last existing column in the entity class.

- [ ] **Step 4: Add migration to db.repository.dart**

Open `lib/infrastructure/repositories/db.repository.dart`.

Change `int get schemaVersion => 26;` to `int get schemaVersion => 27;`.

In the `onUpgrade` switch/if-chain (look at the `from25To26` step as a template), add:

```dart
if (from < 27) {
  await m.addColumn(remoteAssetEntity, remoteAssetEntity.sourceDeviceId);
}
```

Add it immediately after the `from25To26` block, following the exact same indentation and pattern.

- [ ] **Step 5: Regenerate Drift code**

```bash
dart run build_runner build --delete-conflicting-outputs 2>&1 | tail -10
```

Expected: Drift generates updated `*.g.dart` files without errors.

- [ ] **Step 6: Verify compilation**

```bash
flutter analyze --no-fatal-infos 2>&1 | grep -E '^  error' | head -20
```

- [ ] **Step 7: Commit**

```bash
git add lib/infrastructure/entities/ lib/infrastructure/repositories/db.repository.dart
git commit -m "feat: Drift migration v27 — add sourceDeviceId to RemoteAssetEntity"
```

---

## Task 9: Upload Service Adaptation

**Files:**
- Modify: `lib/services/background_upload.service.dart`
- Modify: `lib/services/foreground_upload.service.dart`

- [ ] **Step 1: Read foreground upload service**

```bash
cat lib/services/foreground_upload.service.dart
```

Note whether it has its own `buildUploadTask` or delegates to background. It likely injects the same service.

- [ ] **Step 2: Add S3Service dependency to BackgroundUploadService**

Open `lib/services/background_upload.service.dart`.

Find the constructor and its injected dependencies. Add `S3Service` injection:

```dart
// Find the class definition and constructor, add:
final S3Service _s3Service;

// In constructor initializer list add:
// _s3Service = s3Service,
// The exact constructor shape is already in the file — add S3Service alongside existing deps.
```

- [ ] **Step 3: Replace `buildUploadTask` server URL logic**

Find the `buildUploadTask` method (lines ~372–437). Replace the URL + headers section:

```dart
// REMOVE these lines:
// final serverEndpoint = Store.get(StoreKey.serverEndpoint);
// final url = Uri.parse('$serverEndpoint/assets').toString();
// final headers = ApiService.getRequestHeaders();

// ADD:
final s3Key = _s3Service.currentConfig!.s3KeyFor(
  originalFileName ?? filename,
  createdAt,
);
final url = await _s3Service.presignPut(s3Key);  // async — minio_new presignedPutObject is async
final headers = <String, String>{};
```

Also update the `UploadTask` construction:

```dart
// Change:
// httpRequestMethod: 'POST',
// fileField: 'assetData',
// fields: fieldsMap,

// To:
httpRequestMethod: 'PUT',
// Remove fileField and fields entirely (binary upload, not multipart)
```

The resulting `UploadTask` should have no `fileField`, no `fields`, method `'PUT'`, and the pre-signed URL.

- [ ] **Step 4: Update BackgroundUploadService provider**

Find where `BackgroundUploadService` is provided (grep for its class name in providers):

```bash
grep -rn 'BackgroundUploadService\b' lib/providers/ --include='*.dart' | head -10
```

Update the provider to inject `S3Service`:

```dart
// Add to provider:
final s3 = ref.watch(s3ServiceProvider);
// Pass to constructor
```

- [ ] **Step 5: Adapt ForegroundUploadService if it has its own buildUploadTask**

Based on Step 1 output, apply the same changes to `foreground_upload.service.dart` if it has its own task-building code. If it delegates to background service, skip.

- [ ] **Step 6: Verify compilation**

```bash
flutter analyze --no-fatal-infos 2>&1 | grep -E '^  error' | head -20
```

- [ ] **Step 7: Commit**

```bash
git add lib/services/background_upload.service.dart lib/services/foreground_upload.service.dart lib/providers/
git commit -m "feat: swap upload task destination from Immich server to S3 pre-signed PUT"
```

---

## Task 10: Thumbnail S3 Upload

**Files:**
- Modify: `lib/services/background_upload.service.dart` (add thumbnail upload after main upload)

- [ ] **Step 1: Find where upload completion is handled**

```bash
grep -n 'TaskStatus.complete\|onTaskFinished\|_onUploadSuccess\|kBackupGroup' lib/services/background_upload.service.dart | head -20
```

Note the callback/handler that fires when a file finishes uploading.

- [ ] **Step 2: Add thumbnail upload in completion handler**

In the upload completion handler, after confirming the main asset uploaded successfully, add:

```dart
// Generate and upload thumbnail after successful asset upload
Future<void> _uploadThumbnail(LocalAsset asset) async {
  try {
    final entity = await _storageRepository.getAssetEntityForAsset(asset);
    if (entity == null) return;
    const thumbnailSize = 256;
    final thumb = await entity.thumbnailDataWithSize(
      const ThumbnailSize(thumbnailSize, thumbnailSize),
    );
    if (thumb == null) return;
    final thumbKey = _s3Service.currentConfig!.thumbnailKeyFor(
      asset.name,
      asset.createdAt,
    );
    await _s3Service.putObject(thumbKey, thumb, contentType: 'image/jpeg');
  } catch (e) {
    _logger.warning('Thumbnail upload failed for ${asset.id}: $e');
  }
}
```

Call `_uploadThumbnail(asset)` (unawaited) from the completion handler.

- [ ] **Step 3: Verify compilation**

```bash
flutter analyze --no-fatal-infos 2>&1 | grep -E '^  error' | head -20
```

- [ ] **Step 4: Commit**

```bash
git add lib/services/background_upload.service.dart
git commit -m "feat: upload thumbnail to S3 after successful asset backup"
```

---

## Task 11: S3 Thumbnail Image Provider

**Files:**
- Create: `lib/utils/image_providers/s3_thumbnail_provider.dart`
- Read first: find the thumbnail widget and current image provider

- [ ] **Step 1: Find the thumbnail image provider**

```bash
find lib packages -name '*.dart' | xargs grep -l 'ImageProvider\|thumbnailProvider\|CachedNetworkImage' 2>/dev/null | grep -i thumb | head -10
grep -rn 'class.*ImageProvider\|ImmichThumbnail\|AssetThumbnail' lib/ packages/ --include='*.dart' | head -15
```

Note the class name and what URL/data it currently uses.

- [ ] **Step 2: Create S3ThumbnailProvider**

Create `lib/utils/image_providers/s3_thumbnail_provider.dart`:

```dart
import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:s3mmich/services/s3/s3_service.dart';

class S3ThumbnailProvider extends ImageProvider<S3ThumbnailProvider> {
  final String s3Key;
  final S3Service s3Service;
  final double scale;

  const S3ThumbnailProvider({
    required this.s3Key,
    required this.s3Service,
    this.scale = 1.0,
  });

  @override
  Future<S3ThumbnailProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(S3ThumbnailProvider key, ImageDecoderCallback decode) {
    return MultiFrameImageStreamCompleter(
      codec: _loadAsync(key, decode),
      scale: key.scale,
      informationCollector: () => [DiagnosticsProperty('S3 key', key.s3Key)],
    );
  }

  Future<ui.Codec> _loadAsync(S3ThumbnailProvider key, ImageDecoderCallback decode) async {
    final bytes = await key.s3Service.getObject(key.s3Key);
    final buffer = await ui.ImmutableBuffer.fromUint8List(Uint8List.fromList(bytes));
    return decode(buffer);
  }

  @override
  bool operator ==(Object other) =>
      other is S3ThumbnailProvider && other.s3Key == s3Key && other.scale == scale;

  @override
  int get hashCode => Object.hash(s3Key, scale);
}
```

- [ ] **Step 3: Wire the provider into the thumbnail widget**

Based on the findings from Step 1, locate where the existing image provider is constructed (likely in the thumbnail widget or a custom image widget). 

If the widget uses a URL-based provider like `CachedNetworkImageProvider`, replace with `S3ThumbnailProvider` for remote assets. The distinction: local device assets use the platform `ThumbnailApi`; S3-only assets (no local `AssetEntity`) use `S3ThumbnailProvider`.

The check looks like:
```dart
// In the image provider selection:
if (asset.localId != null) {
  // existing device thumbnail path — unchanged
} else {
  // S3-only asset
  final thumbKey = s3Config.thumbnailKeyFor(asset.fileName, asset.fileCreatedAt);
  return S3ThumbnailProvider(s3Key: thumbKey, s3Service: s3Service);
}
```

The exact integration point depends on Step 1. Read the found file carefully and make the minimal change.

- [ ] **Step 4: Verify compilation**

```bash
flutter analyze --no-fatal-infos 2>&1 | grep -E '^  error' | head -20
```

- [ ] **Step 5: Commit**

```bash
git add lib/utils/image_providers/s3_thumbnail_provider.dart
git commit -m "feat: add S3ThumbnailProvider for fetching remote asset thumbnails from S3"
```

---

## Task 12: DbSyncService

**Files:**
- Create: `lib/services/db_sync.service.dart`
- Test: `test/services/db_sync_service_test.dart`

- [ ] **Step 1: Find Drift DB file path**

```bash
grep -rn 'lazyDatabase\|openDatabase\|databaseFactory\|getDatabasesPath\|getApplicationDocumentsDirectory' lib/ --include='*.dart' | head -10
```

Note how the DB file path is constructed — you'll need it in the sync service.

- [ ] **Step 2: Write failing tests**

Create `test/services/db_sync_service_test.dart`:

```dart
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:s3mmich/services/db_sync.service.dart';
import 'package:s3mmich/services/s3/s3_service.dart';
import 'package:s3mmich/services/s3/s3_object_meta.dart';

class MockS3Service extends Mock implements S3Service {}

void main() {
  late MockS3Service s3;
  late DbSyncService svc;

  setUp(() {
    s3 = MockS3Service();
    svc = DbSyncService(s3Service: s3, dbPath: '/tmp/test.db');
  });

  group('DbSyncService', () {
    test('push uploads db file to .meta/s3immich.db', () async {
      when(() => s3.putFile(any(), any())).thenAnswer((_) async {});
      await svc.push();
      verify(() => s3.putFile('.meta/s3immich.db', '/tmp/test.db')).called(1);
    });

    test('pull does nothing when S3 version matches local', () async {
      final sameTime = DateTime(2024, 1, 5, 12);
      when(() => s3.headObject('.meta/s3immich.db')).thenAnswer(
        (_) async => S3ObjectMeta(key: '.meta/s3immich.db', etag: 'abc', lastModified: sameTime, size: 1024),
      );
      svc.setLastSyncTime(sameTime); // same time → no pull needed
      await svc.pull();
      verifyNever(() => s3.getObject(any()));
    });

    test('pull downloads when S3 is newer', () async {
      final newerTime = DateTime(2024, 1, 5, 13);
      when(() => s3.headObject('.meta/s3immich.db')).thenAnswer(
        (_) async => S3ObjectMeta(key: '.meta/s3immich.db', etag: 'abc', lastModified: newerTime, size: 1024),
      );
      when(() => s3.getObject('.meta/s3immich.db')).thenAnswer((_) async => [1, 2, 3]);
      svc.setLastSyncTime(DateTime(2024, 1, 5, 10)); // older
      await svc.pull();
      verify(() => s3.getObject('.meta/s3immich.db')).called(1);
    });

    test('pull does nothing when remote db does not exist yet', () async {
      when(() => s3.headObject('.meta/s3immich.db')).thenAnswer((_) async => null);
      await svc.pull();
      verifyNever(() => s3.getObject(any()));
    });
  });
}
```

- [ ] **Step 3: Run test to confirm failure**

```bash
flutter test test/services/db_sync_service_test.dart
```

Expected: FAIL — `db_sync.service.dart` not found.

- [ ] **Step 4: Add mocktail to dev_dependencies**

```bash
grep 'mocktail' pubspec.yaml
```

If not present, add to `pubspec.yaml` dev_dependencies:
```yaml
  mocktail: ^1.0.4
```

Then `flutter pub get`.

- [ ] **Step 5: Create `db_sync.service.dart`**

Create `lib/services/db_sync.service.dart`:

```dart
import 'dart:io';
import 'package:drift/drift.dart';
import 'package:s3mmich/services/s3/s3_service.dart';

class DbSyncService {
  final S3Service _s3Service;
  final String _dbPath;
  DateTime? _lastSyncTime;

  static const _remoteKey = '.meta/s3immich.db';

  DbSyncService({required S3Service s3Service, required String dbPath})
      : _s3Service = s3Service,
        _dbPath = dbPath;

  void setLastSyncTime(DateTime t) => _lastSyncTime = t;

  Future<void> push() async {
    await _s3Service.putFile(_remoteKey, _dbPath);
    _lastSyncTime = DateTime.now().toUtc();
  }

  Future<void> pull() async {
    final meta = await _s3Service.headObject(_remoteKey);
    if (meta == null) return;
    if (_lastSyncTime != null && !meta.lastModified.isAfter(_lastSyncTime!)) return;

    final remoteBytes = await _s3Service.getObject(_remoteKey);
    final tempPath = '$_dbPath.remote_tmp';
    final tempFile = File(tempPath);
    await tempFile.writeAsBytes(remoteBytes);
    await _mergeRemoteDb(tempPath);
    await tempFile.delete();
    _lastSyncTime = meta.lastModified;
  }

  Future<void> _mergeRemoteDb(String remotePath) async {
    // Use SQLite ATTACH to merge additively — new rows only, no overwrites
    final db = _openRawDb(_dbPath);
    await db.customStatement("ATTACH DATABASE '$remotePath' AS remote");
    try {
      // Insert assets from remote that don't exist locally (keyed by s3Key/cloudId)
      await db.customStatement('''
        INSERT OR IGNORE INTO remote_asset_entity
        SELECT * FROM remote.remote_asset_entity
      ''');
      await db.customStatement('''
        INSERT OR IGNORE INTO remote_exif_entity
        SELECT * FROM remote.remote_exif_entity
      ''');
      await db.customStatement('''
        INSERT OR IGNORE INTO remote_album_entity
        SELECT * FROM remote.remote_album_entity
        WHERE updated_at > (
          SELECT COALESCE(MAX(updated_at), 0) FROM remote_album_entity WHERE id = remote.remote_album_entity.id
        )
      ''');
    } finally {
      await db.customStatement('DETACH DATABASE remote');
    }
  }

  // Returns the Drift database for raw SQL access
  // The real implementation receives the Drift instance via DI
  DatabaseConnectionUser _openRawDb(String path) {
    throw UnimplementedError('Inject Drift db via constructor');
  }
}
```

> **Note on `_openRawDb`:** The real `DbSyncService` receives the `Drift` instance (the app's database) via the constructor alongside `s3Service`. Replace the `_openRawDb` stub with `final Drift _db;` in the constructor and use `_db.customStatement(...)` directly. The tests mock the merge — the test above only tests the pull/push orchestration, not the SQL merge.

- [ ] **Step 6: Update constructor to inject Drift**

Replace the class constructor:

```dart
class DbSyncService {
  final S3Service _s3Service;
  final String _dbPath;
  final DatabaseConnectionUser _db;
  DateTime? _lastSyncTime;

  DbSyncService({
    required S3Service s3Service,
    required String dbPath,
    required DatabaseConnectionUser db,
  })  : _s3Service = s3Service,
        _dbPath = dbPath,
        _db = db;

  // Replace _openRawDb usage with _db:
  Future<void> _mergeRemoteDb(String remotePath) async {
    await _db.customStatement("ATTACH DATABASE '$remotePath' AS remote");
    try {
      await _db.customStatement('INSERT OR IGNORE INTO remote_asset_entity SELECT * FROM remote.remote_asset_entity');
      await _db.customStatement('INSERT OR IGNORE INTO remote_exif_entity SELECT * FROM remote.remote_exif_entity');
      await _db.customStatement('INSERT OR IGNORE INTO remote_album_entity SELECT * FROM remote.remote_album_entity');
    } finally {
      await _db.customStatement('DETACH DATABASE remote');
    }
  }
}
```

- [ ] **Step 7: Run tests — expect PASS**

```bash
flutter test test/services/db_sync_service_test.dart
```

Expected: All 4 tests PASS.

- [ ] **Step 8: Wire DbSyncService into main.dart**

Add to the `ProviderScope(overrides: [...])` initialization block:

```dart
final dbSyncService = DbSyncService(
  s3Service: s3Service,
  dbPath: drift.dbPath, // get dbPath from the Drift instance
  db: drift,
);
// Call pull on startup (non-blocking):
unawaited(dbSyncService.pull());
```

Find the Drift instance initialization in main.dart and extract its path.

- [ ] **Step 9: Commit**

```bash
git add lib/services/db_sync.service.dart test/services/db_sync_service_test.dart lib/main.dart
git commit -m "feat: add DbSyncService — pull/push Drift DB to S3 on launch and after backup"
```

---

## Task 13: StorageRepository S3 Branch (Full-res Fetch)

**Files:**
- Modify: `lib/infrastructure/repositories/storage.repository.dart`

- [ ] **Step 1: Add S3Service to StorageRepository**

Open `lib/infrastructure/repositories/storage.repository.dart`.

The current constructor takes no arguments. Add `S3Service`:

```dart
class StorageRepository {
  final S3Service _s3Service;
  StorageRepository({required S3Service s3Service}) : _s3Service = s3Service;
  // ...existing methods unchanged...
}
```

Update `lib/providers/infrastructure/storage.provider.dart` to inject:

```dart
final storageRepositoryProvider = Provider<StorageRepository>((ref) {
  final s3 = ref.watch(s3ServiceProvider);
  return StorageRepository(s3Service: s3);
});
```

- [ ] **Step 2: Extend `loadFileFromCloud()` with S3 branch**

The current `loadFileFromCloud()` (lines 102–115) uses `AssetEntity.fromId(assetId)` — this only works for assets on the local device. Replace with:

```dart
Future<File?> loadFileFromCloud(
  String assetId, {
  PMProgressHandler? progressHandler,
  String? s3Key, // null for local assets, set for S3-only assets
}) async {
  // S3-only assets have no local AssetEntity
  if (s3Key != null) {
    return _loadFromS3(s3Key, assetId);
  }

  // Existing iCloud / local path — unchanged
  try {
    final entity = await AssetEntity.fromId(assetId);
    if (entity == null) {
      log.warning("Cannot get AssetEntity for asset $assetId");
      return null;
    }
    return await entity.loadFile(progressHandler: progressHandler);
  } catch (error, stackTrace) {
    log.warning("Error loading file from cloud for asset $assetId", error, stackTrace);
    return null;
  }
}

Future<File?> _loadFromS3(String s3Key, String assetId) async {
  try {
    final cacheDir = await getTemporaryDirectory();
    final cachedFile = File('${cacheDir.path}/s3_full/$assetId${p.extension(s3Key)}');
    if (await cachedFile.exists()) return cachedFile;
    await cachedFile.parent.create(recursive: true);
    final bytes = await _s3Service.getObject(s3Key);
    await cachedFile.writeAsBytes(bytes);
    return cachedFile;
  } catch (e) {
    log.warning("Error loading from S3 key $s3Key: $e");
    return null;
  }
}
```

Add imports at top of file: `import 'package:path/path.dart' as p; import 'package:path_provider/path_provider.dart';`

- [ ] **Step 3: Verify compilation**

```bash
flutter analyze --no-fatal-infos 2>&1 | grep -E '^  error' | head -20
```

- [ ] **Step 4: Find the asset viewer's full-res loading call site**

```bash
grep -rn 'loadFileFromCloud\|isAssetAvailableLocally' lib/ --include='*.dart' | head -15
```

Identify where the full-res viewer calls `loadFileFromCloud`. If it doesn't pass `s3Key`, find the asset's S3 key from the DB and pass it. This may require a small change in the caller.

- [ ] **Step 5: Commit**

```bash
git add lib/infrastructure/repositories/storage.repository.dart lib/providers/infrastructure/storage.provider.dart
git commit -m "feat: add S3 full-res fetch branch to StorageRepository.loadFileFromCloud()"
```

---

## Final Verification

- [ ] **Verify full project analysis is clean**

```bash
flutter analyze --no-fatal-infos 2>&1 | grep -c 'error'
```

Expected: 0

- [ ] **Run all tests**

```bash
flutter test
```

Expected: All tests PASS.

- [ ] **Final commit**

```bash
git add -A
git commit -m "feat: S3immich Phase 1-2 foundation complete — backup, browse, sync"
```

---

## What's Next

**Plan 2 covers Phases 3–5:**
- `tool/build_geodata.dart` — build script to generate `lib/generated/geodata_seed.g.dart`
- Drift migration v28 — `GeodataPlacesEntity` table
- `GeoDataRepository` — forward + reverse geocoding queries
- `SearchRepository` (Drift SQL) — metadata tier 1 search
- `MapRepository` (Drift EXIF query) — local GPS data
- Albums via local DB metadata
