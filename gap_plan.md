# Gap Plan: S3 Backend API Stub Layer

## Context

Phase 1 (s3-credentials, s3-transport) is complete. The app has S3 credentials, transport,
upload, and DB file sync. Phase 2 agents (manifest-sync, thumbnail-cache, s3-upload) are
planned but not yet run.

**The gap:** The existing codebase still calls the Immich server for sync, search, asset
mutations, albums, user info, and server metadata. These calls either crash (no serverEndpoint
in Store) or silently fail (network error). The Phase 2 agents assume a working app underneath
them. This plan closes that gap before Phase 2 begins.

**Architecture principle (from project description):** A server client implements every
interface the Immich app already uses. No null guards. No conditional checks. Every API call
gets a real response — either from S3, Drift DB, or a permanent local mock. The UI code is
untouched.

---

## What Already Exists (do not re-implement)

- `S3Service` — put, get, head, list, presign, putFile (`lib/services/s3/s3_service.dart`)
- `S3Config` — credential storage in FlutterSecureStorage (`lib/services/s3/s3_config.dart`)
- `S3SetupPage` + `S3ConfigGuard` — entry-point routing
- `AuthNotifier.stub` + `CurrentUserProvider.stub` — auth state overrides in main.dart
- Upload services already use S3Service directly
- `DbSyncService` — DB file sync to/from S3

---

## The Gap: Three Work Items

### Gap 1 — Store Bootstrap (30 min, no agent needed)

**Problem:** `Store.get(StoreKey.serverEndpoint)` and `Store.get(StoreKey.accessToken)` are
called by `ApiService`, `image_url_builder`, `upload.repository`, and several widgets. These
throw `StoreKeyNotFoundException` because no Immich server was ever connected.

**Fix:** Write sentinel values into Store at app startup, before `runApp`. These values are
never used for real network calls (the `LocalApiClient` in Gap 2 intercepts all calls) but
satisfy every `Store.get()` assertion in the existing codebase.

**Location:** `lib/main.dart`, inside `main()` after `Bootstrap.initDomain()`:

```dart
// Bootstrap Store keys expected by legacy Immich code paths.
// LocalApiClient intercepts all API calls so these values are never sent over the network.
await Store.put(StoreKey.serverEndpoint, 'http://localhost/api');
await Store.put(StoreKey.accessToken, 's3-local');
await Store.put(StoreKey.serverUrl, 'http://localhost');
```

Also remove the session-patching null guards added during earlier debugging:
- Revert `Store.tryGet(...) ?? ''` back to `Store.get(...)` in image_url_builder.dart,
  user_avatar.dart, user_circle_avatar.dart, partner_user_avatar.widget.dart,
  video_viewer.widget.dart (these now work because Store is pre-populated)
- Remove the `hasImmichServer` guard in app_life_cycle.provider.dart and splash_screen.page.dart
  (the stub handles those code paths cleanly)

---

### Gap 2 — `api-stub` Agent (main gap)

A new agent task that creates a `LocalApiClient` — a subclass of `ApiClient` from the
`openapi` package. `LocalApiClient.invokeAPI()` intercepts every outbound API call and
dispatches by URL path to local handlers. `ApiService` is subclassed to inject
`LocalApiClient`. `apiServiceProvider` is overridden in main.dart.

Zero changes to providers, services, repositories, or UI. The existing call chain
`Widget → Provider → Service → Repository → ApiService.xyzApi.method()` runs unchanged;
the interception is entirely inside `invokeAPI`.

**New files (all under `lib/infrastructure/local_server/`):**

```
lib/infrastructure/local_server/
  local_api_client.dart          ← ApiClient subclass; dispatch table
  local_api_service.dart         ← ApiService subclass; injects LocalApiClient
  handlers/
    auth_handler.dart            ← /api/auth/*, /api/users/me, /api/users/me/preferences
    server_handler.dart          ← /api/server/about, /api/server/info, /api/server/version,
                                    /api/server/statistics, /api/server/config
    asset_handler.dart           ← /api/assets/:id (GET, PUT, DELETE), /api/assets (bulk ops)
    album_handler.dart           ← /api/albums (GET, POST), /api/albums/:id (GET, PUT, DELETE)
    sync_handler.dart            ← /api/sync/stream  (placeholder → replaced by manifest-sync agent)
    search_handler.dart          ← /api/search/smart, /api/search/metadata
                                    (placeholder → replaced by ocr-search agent)
    partner_handler.dart         ← /api/partners (GET), partner asset queries
    person_handler.dart          ← /api/people/:id, /api/people/:id/assets
    memory_handler.dart          ← /api/memories (GET, PUT)
    activity_handler.dart        ← /api/activities (no-op stubs)
    tag_handler.dart             ← /api/tags (no-op stubs)
    trash_handler.dart           ← /api/trash (GET), /api/trash/restore (POST)
    shared_link_handler.dart     ← /api/shared-links (empty list stubs)
```

#### `local_api_client.dart`

```dart
class LocalApiClient extends ApiClient {
  final Drift _db;

  LocalApiClient(this._db) : super(basePath: 'http://localhost');

  @override
  Future<Response> invokeAPI(
    String path, String method,
    List<QueryParam> queryParams, Object? body,
    Map<String, String> headerParams, Map<String, String> formParams,
    String? contentType,
  ) async {
    // Strip leading /api if present (ApiClient adds basePath + path)
    final route = path.replaceFirst('/api', '');

    if (route.startsWith('/auth') || route.startsWith('/users/me'))
      return AuthHandler(_db).handle(route, method, body);
    if (route.startsWith('/server'))
      return ServerHandler().handle(route, method);
    if (route.startsWith('/sync'))
      return SyncHandler(_db).handle(route, method, body);
    if (route.startsWith('/search'))
      return SearchHandler(_db).handle(route, method, body);
    if (route.startsWith('/assets'))
      return AssetHandler(_db).handle(route, method, body);
    if (route.startsWith('/albums'))
      return AlbumHandler(_db).handle(route, method, body);
    if (route.startsWith('/partners'))
      return PartnerHandler(_db).handle(route, method, body);
    if (route.startsWith('/people'))
      return PersonHandler(_db).handle(route, method, body);
    if (route.startsWith('/memories'))
      return MemoryHandler(_db).handle(route, method, body);
    if (route.startsWith('/trash'))
      return TrashHandler(_db).handle(route, method, body);

    // All unhandled paths return empty success (activities, tags, shared-links, etc.)
    return Response(200, '{}');
  }
}
```

`Response` here is `package:http/http.dart`'s `Response`. The `ApiClient.invokeAPI` return
type and how downstream deserialization works must be verified against the openapi package
before finalising — check `openapi/lib/api_client.dart` lines 1–110 for the exact signature.

#### `local_api_service.dart`

```dart
class LocalApiService extends ApiService {
  LocalApiService(Drift db) {
    // Replace the ApiClient with the local interceptor.
    // ApiService exposes setEndpoint() which re-creates all API objects from a new ApiClient.
    // We override it here to inject our client instead.
    _injectLocalClient(db);
  }

  void _injectLocalClient(Drift db) {
    final client = LocalApiClient(db);
    // ApiService fields (usersApi, assetsApi, etc.) are non-final — assign directly.
    authenticationApi = AuthenticationApi(client);
    usersApi = UsersApi(client);
    assetsApi = AssetsApi(client);
    syncApi = SyncApi(client);
    searchApi = SearchApi(client);
    albumsApi = AlbumsApi(client);
    partnersApi = PartnersApi(client);
    peopleApi = PeopleApi(client);
    memoriesApi = MemoriesApi(client);
    trashApi = TrashApi(client);
    serverInfoApi = ServerApi(client);
    // Leave remaining API fields (sharedLinksApi, activitiesApi, tagsApi, etc.)
    // pointing to the same LocalApiClient — they will hit the default no-op return.
  }
}
```

#### `lib/providers/api.provider.dart` change

```dart
// Before:
final apiServiceProvider = Provider((_) => ApiService());

// After:
final apiServiceProvider = Provider((ref) => LocalApiService(ref.watch(driftProvider)));
```

This is the only change outside `lib/infrastructure/local_server/`.

---

#### Handler specifications

##### `auth_handler.dart`

All responses are permanent mocks — there is no Immich server, so these never change.

| Route | Method | Response DTO | Notes |
|---|---|---|---|
| `/auth/login` | POST | `LoginResponseDto` | `accessToken: 's3-local'`, `userId: 'local-user'` |
| `/auth/validateToken` | GET | `ValidateAccessTokenResponseDto` | `authStatus: true` |
| `/auth/logout` | POST | `{}` | no-op |
| `/users/me` | GET | `UserAdminResponseDto` | id=`local-user`, email=`local@s3immich`, name=`My Device` |
| `/users/me/preferences` | GET/PUT | `UserPreferencesResponseDto` | all defaults |
| `/users/me/profile-image` | GET | 404 | no profile image |

The `UserAdminResponseDto` and `LoginResponseDto` JSON shapes must be taken verbatim from
`openapi/lib/model/` — serialise them as plain `jsonEncode(map)`.

##### `server_handler.dart`

Permanent stubs. The app uses these to display version strings and enable/disable features.

| Route | Response fields |
|---|---|
| `/server/about` | `version: 'v1.134.0'`, `versionUrl: ''`, `licensed: true` |
| `/server/info` | `diskAvailable: '∞'`, `diskUse: '0 B'`, `diskUsagePercentage: 0` |
| `/server/version` | `major: 1`, `minor: 134`, `patch: 0` |
| `/server/statistics` | `photos: 0`, `videos: 0`, `usage: 0` |
| `/server/config` | `loginPageMessage: ''`, `oauthButtonText: ''`, `isInitialized: true` |
| `/server/features` | all features disabled except `search: true`, `trash: true` |

##### `asset_handler.dart`

Routes asset mutations to Drift DB. All writes operate on `RemoteAssetEntity`.

| Route | Method | Action |
|---|---|---|
| `/assets/:id` | GET | Query `remoteAssetEntity` by id; serialise to `AssetResponseDto` JSON |
| `/assets/:id` | PUT | Apply `UpdateAssetDto` fields (isFavorite, isArchived) to DB row |
| `/assets/:id` | DELETE | Set `deletedAt` on DB row (soft delete); do not touch S3 |
| `/assets` (bulk) | DELETE | Batch soft-delete |
| `/assets/:id/thumbnail` | GET | Return 302 redirect to S3 presigned URL (handled by `S3Service`) |
| `/assets/:id/original` | GET | Return 302 redirect to S3 presigned URL |

The `AssetResponseDto` JSON shape is the largest mapping task. Required fields: `id`,
`deviceAssetId`, `ownerId`, `deviceId`, `originalPath`, `originalFileName`, `fileCreatedAt`,
`fileModifiedAt`, `updatedAt`, `isFavorite`, `isArchived`, `isOffline`, `isTrashed`,
`duration`, `type`, `thumbhash`, `checksum`, `localAssetData` (null for remote). Map
directly from `RemoteAssetEntity` fields.

##### `album_handler.dart`

| Route | Method | Action |
|---|---|---|
| `/albums` | GET | Query `remoteAlbumEntity`; return `AlbumResponseDto[]` |
| `/albums/:id` | GET | Single album with asset list |
| `/albums/:id` | PUT | Update album name/description in DB |
| `/albums` | POST | Insert new album row |
| `/albums/:id` | DELETE | Delete album row; do not delete assets |
| `/albums/:id/assets` | PUT | Add assets to album (insert join rows) |
| `/albums/:id/assets` | DELETE | Remove assets from album |

##### `sync_handler.dart` — placeholder until `manifest-sync` agent

The sync stream is the most complex endpoint. For now, return a valid but empty JSONL
response so `SyncApiRepository.streamChanges()` completes without error.

```
POST /api/sync/stream
Response body (JSONL):
  (empty — no events)
Status: 200
Content-Type: text/event-stream
```

`SyncApiRepository` will call `ack()` after processing events. `DELETE /api/sync/ack` should
return 204.

When the `manifest-sync` agent is implemented, it will override `syncApiRepositoryProvider`
with `S3SyncRepository` directly, bypassing this handler entirely. The placeholder just
prevents crashes in the interim.

##### `search_handler.dart` — placeholder until `ocr-search` agent

For now, query Drift DB with a basic `LIKE '%query%'` on `originalFileName` and
`exifEntity.city`/`country` fields. This gives usable search immediately. The `ocr-search`
agent replaces this handler with FTS5 text search when it runs.

```
POST /api/search/smart      → { assets: { items: [...], nextPage: null }, albums: { items: [] } }
POST /api/search/metadata   → same shape, filter from Drift DB by date/type/city/country
GET  /api/search/suggestions → { fieldName: [], ... }
GET  /api/search/explore    → []
```

Response shape: `SearchResponseDto` — verify field names in `openapi/lib/model/search_response_dto.dart`.

##### `partner_handler.dart`

Return empty lists. Partners are an Immich-server feature not applicable to S3-only.

```
GET /api/partners           → []
GET /api/partners/:id/assets → { items: [], nextPage: null }
```

##### `person_handler.dart`

Serve from `personEntity` and `assetFaceEntity` in Drift DB if populated by the
`face-recognition` agent; otherwise return empty.

```
GET /api/people             → { people: [], total: 0, hidden: 0 }
GET /api/people/:id         → 404 if not in DB
GET /api/people/:id/assets  → { items: [], nextPage: null }
PUT /api/people/:id         → update name in DB
```

##### `trash_handler.dart`

```
GET  /api/trash             → { items: [/* trashed RemoteAssets */], nextPage: null }
POST /api/trash/restore     → restore (clear deletedAt) on listed asset IDs
POST /api/trash/empty       → hard-delete all trashed rows
```

##### Remaining handlers (permanent no-ops)

`memory_handler.dart` — `GET /api/memories` → `[]`  
`activity_handler.dart` — all routes → `[]` or `{}`  
`tag_handler.dart` — `GET /api/tags` → `[]`  
`shared_link_handler.dart` — `GET /api/shared-links` → `[]`

---

### Gap 3 — Cleanup of session patches

Once Gap 1 and Gap 2 are in place, revert these session-specific patches that were added as
emergency null-guards and are no longer needed:

| File | What to revert |
|---|---|
| `app_life_cycle.provider.dart` | Remove `hasImmichServer` guard; restore original `if (isAuthenticated)` block |
| `splash_screen.page.dart` | Restore original `initState` (call `setOpenApiServiceEndpoint()` directly); restore original `resumeSession()` else branch — these now work because Store is pre-populated and `LocalApiClient` handles all calls |
| `routing/router.dart` | Already fixed (all `_authGuard` → `_s3ConfigGuard`) — keep this change |
| `main.dart` | Remove `currentUserProvider.overrideWith(...)` and `authProvider.overrideWith(...)` — `LocalApiClient` now returns a proper user from `/users/me`, so `currentUserProvider` reads it from DB naturally after the first sync |
| `user.provider.dart` | Revert `CurrentUserProvider.stub` constructor if no longer needed |

**Note:** Only revert these after confirming the full `LocalApiClient` path is working
end-to-end. Do them as a single cleanup commit.

---

## Integration with Phase 2 Agents

The stub handlers are designed as **drop-in replacement points** — each Phase 2 agent replaces
one handler or overrides one provider, with no further changes needed to `LocalApiClient`:

| Phase 2 Agent | What it replaces |
|---|---|
| `manifest-sync` | Overrides `syncApiRepositoryProvider` with `S3SyncRepository`; `sync_handler.dart` becomes dead code |
| `thumbnail-cache` | Overrides `image_url_builder` to serve from local cache first; `asset_handler /thumbnail` redirect becomes fallback |
| `s3-upload` | Overrides `upload.repository.dart`; no handler changes needed |
| `ocr-search` | Overrides `searchApiRepositoryProvider` with `LocalSearchRepository` (FTS5); `search_handler.dart` becomes dead code |
| `face-recognition` | Populates `personEntity` in Drift DB; `person_handler.dart` begins returning real data |
| `settings-db-backup` | Adds DB/settings backup to S3; no handler changes |

---

## Dependency Order for This Gap Work

```
Gap 1 (Store bootstrap)       ← do first, standalone, 30 min
       │
       ▼
Gap 2 (api-stub agent)        ← main work; depends on Gap 1 for clean Store state
       │
       ▼
Gap 3 (cleanup patches)       ← do last, after api-stub is verified end-to-end
```

---

## Agent Task File

Save the following as `.claude/agents/api-stub.md` when implementing Gap 2:

```markdown
---
name: api-stub
description: Implement LocalApiClient — an ApiClient subclass that intercepts all Immich
server API calls and routes them to Drift DB, S3, or permanent mocks. This is the bridge
between the existing Immich UI codebase and the S3-only backend.
---

# Task: Local API Client (Server Stub)

## Context

The Immich mobile app calls ApiService.xyzApi.someMethod() throughout its codebase.
Those calls reach ApiClient.invokeAPI() which makes HTTP requests to the Immich server.
This task replaces that HTTP call with local dispatch — Drift DB reads/writes, S3 presigned
URLs, or permanent mock responses.

No changes to providers, services, repositories, or UI. The injection point is
apiServiceProvider in lib/providers/api.provider.dart.

## Worktree Setup

git worktree add ../immich-api-stub -b feat/api-stub

## What to Implement

See gap_plan.md §Gap 2 for full handler specifications.

## Acceptance Criteria

- flutter analyze: zero errors
- flutter test: all existing tests pass
- Manual: app launches, gallery loads, backup page opens, search returns results from DB,
  recently-taken page loads without error, asset viewer opens
- No Store.get() exceptions in logcat
- No 'User must be logged in' exceptions in logcat
- No network calls to any real server in logcat
```

---

## Files Changed Summary

| File | Change type |
|---|---|
| `lib/main.dart` | Add Store bootstrap lines; add `apiServiceProvider` override; remove auth/user overrides (Gap 3) |
| `lib/providers/api.provider.dart` | Return `LocalApiService` instead of `ApiService` |
| `lib/infrastructure/local_server/local_api_client.dart` | New |
| `lib/infrastructure/local_server/local_api_service.dart` | New |
| `lib/infrastructure/local_server/handlers/auth_handler.dart` | New |
| `lib/infrastructure/local_server/handlers/server_handler.dart` | New |
| `lib/infrastructure/local_server/handlers/asset_handler.dart` | New |
| `lib/infrastructure/local_server/handlers/album_handler.dart` | New |
| `lib/infrastructure/local_server/handlers/sync_handler.dart` | New (placeholder) |
| `lib/infrastructure/local_server/handlers/search_handler.dart` | New (placeholder) |
| `lib/infrastructure/local_server/handlers/partner_handler.dart` | New |
| `lib/infrastructure/local_server/handlers/person_handler.dart` | New |
| `lib/infrastructure/local_server/handlers/trash_handler.dart` | New |
| `lib/infrastructure/local_server/handlers/memory_handler.dart` | New (no-op) |
| `lib/infrastructure/local_server/handlers/shared_link_handler.dart` | New (no-op) |
| `lib/infrastructure/local_server/handlers/activity_handler.dart` | New (no-op) |
| `lib/infrastructure/local_server/handlers/tag_handler.dart` | New (no-op) |
| `lib/utils/image_url_builder.dart` | Revert to `Store.get()` (Gap 3) |
| `lib/widgets/common/user_avatar.dart` | Revert to `Store.get()` (Gap 3) |
| `lib/widgets/common/user_circle_avatar.dart` | Revert to `Store.get()` (Gap 3) |
| `lib/presentation/widgets/people/partner_user_avatar.widget.dart` | Revert to `Store.get()` (Gap 3) |
| `lib/presentation/widgets/asset_viewer/video_viewer.widget.dart` | Revert to `Store.get()` (Gap 3) |
| `lib/providers/app_life_cycle.provider.dart` | Revert hasImmichServer guard (Gap 3) |
| `lib/pages/common/splash_screen.page.dart` | Revert session patches (Gap 3) |
