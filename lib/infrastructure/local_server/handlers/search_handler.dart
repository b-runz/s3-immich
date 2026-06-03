import 'dart:convert';
import 'package:drift/drift.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:openapi/api.dart';
import 'package:s3mmich/infrastructure/repositories/db.repository.dart';

/// Handles /search/* routes entirely from local SQLite — no Immich server needed.
///
/// Strategy: three flat LIKE queries (labels, local filenames, remote filenames),
/// collect all matching IDs, then batch-fetch full rows and map to AssetResponseDto
/// JSON. No multi-table JOINs — avoids sync-timing gaps between the ML pipeline
/// (which writes asset_label_entity with photo_manager IDs) and the Immich
/// background-sync (which writes local_asset_entity).
class SearchHandler {
  final Drift _db;
  final Logger _log = Logger('SearchHandler');
  SearchHandler(this._db);

  static const _pageSize = 100;
  static const _ownerId = 'local-user';

  Future<http.Response> handle(String route, String method, Object? body) async {
    if (route.startsWith('/search/suggestions') || route.startsWith('/search/explore')) {
      return _json([]);
    }
    if (route.startsWith('/search/smart') || route.startsWith('/search/metadata')) {
      return await _search(body);
    }
    return _emptyResult();
  }

  Future<http.Response> _search(Object? rawBody) async {
    final query = _extractQuery(rawBody)?.trim() ?? '';
    if (query.isEmpty) return _emptyResult();

    final q = '%${query.toLowerCase()}%';

    // ── Step 1: collect matching IDs from every relevant table (no JOINs) ──

    final labelIds = <String>{};   // photo_manager IDs from ML pipeline
    final localIds = <String>{};   // local_asset_entity.id
    final remoteIds = <String>{};  // remote_asset_entity.id (UUIDs)

    try {
      final rows = await _db.customSelect(
        '''SELECT DISTINCT ale.asset_id
           FROM asset_label_entity ale
           JOIN local_album_asset_entity laae ON laae.asset_id = ale.asset_id
           JOIN local_album_entity la ON la.id = laae.album_id
           WHERE LOWER(ale.label) LIKE ?
             AND la.backup_selection = 0''',
        variables: [Variable.withString(q)],
      ).get();
      labelIds.addAll(rows.map((r) => r.data['asset_id'] as String));
    } catch (e, st) {
      _log.warning('Label search failed', e, st);
    }

    try {
      final rows = await _db.customSelect(
        '''SELECT DISTINCT lae.id
           FROM local_asset_entity lae
           JOIN local_album_asset_entity laae ON laae.asset_id = lae.id
           JOIN local_album_entity la ON la.id = laae.album_id
           WHERE LOWER(lae.name) LIKE ?
             AND la.backup_selection = 0''',
        variables: [Variable.withString(q)],
      ).get();
      localIds.addAll(rows.map((r) => r.data['id'] as String));
    } catch (e, st) {
      _log.warning('Local name search failed', e, st);
    }

    try {
      final rows = await _db.customSelect(
        'SELECT id FROM remote_asset_entity WHERE LOWER(name) LIKE ? AND deleted_at IS NULL',
        variables: [Variable.withString(q)],
      ).get();
      remoteIds.addAll(rows.map((r) => r.data['id'] as String));
    } catch (e, st) {
      _log.warning('Remote name search failed', e, st);
    }

    if (labelIds.isEmpty && localIds.isEmpty && remoteIds.isEmpty) {
      return _emptyResult();
    }

    // ── Step 2: for label IDs, prefer remote UUID over raw platform ID ──
    //
    // asset_label_entity.asset_id == local_asset_entity.id (photo_manager ID).
    // If that local asset has been backed up, remote_asset_entity has the UUID
    // and the app can display it via the normal remote path. Fall back to the
    // local row if not yet backed up, or a stub if Immich hasn't scanned it yet.

    final allLocalIds = {...labelIds, ...localIds};

    final items = <Map<String, dynamic>>[];
    final seenIds = <String>{};

    // ── Step 3: batch-fetch remote assets (prefer these — app renders them fully) ──
    final allRemoteIds = {...remoteIds};

    // Resolve label/local IDs → remote via checksum.
    // Also build a reverse map (remote_id → local_id) so the thumbnail provider
    // can use LocalThumbProvider instead of trying S3 (no thumbnails there yet).
    final resolvedLocalIds = <String>{};
    final remoteToLocalId = <String, String>{};

    if (allLocalIds.isNotEmpty) {
      try {
        final ph = allLocalIds.map((_) => '?').join(',');
        final rows = await _db.customSelect(
          '''SELECT l.id AS local_id, r.id AS remote_id
             FROM remote_asset_entity r
             JOIN local_asset_entity l ON l.checksum = r.checksum
             WHERE l.id IN ($ph)
               AND r.deleted_at IS NULL
               AND l.checksum IS NOT NULL''',
          variables: allLocalIds.map(Variable.withString).toList(),
        ).get();
        for (final row in rows) {
          final localId = row.data['local_id'] as String;
          final remoteId = row.data['remote_id'] as String;
          allRemoteIds.add(remoteId);
          remoteToLocalId[remoteId] = localId;
          resolvedLocalIds.add(localId);
        }
      } catch (_) {
        // checksum not available yet — will fall through to local/stub path
      }
    }

    if (allRemoteIds.isNotEmpty) {
      try {
        final ph = allRemoteIds.map((_) => '?').join(',');
        final rows = await _db.customSelect(
          'SELECT * FROM remote_asset_entity WHERE id IN ($ph) AND deleted_at IS NULL',
          variables: allRemoteIds.map(Variable.withString).toList(),
        ).get();
        for (final r in rows) {
          final id = r.data['id'] as String;
          if (seenIds.add(id)) items.add(_remoteRowToJson(r, localId: remoteToLocalId[id]));
        }
      } catch (e, st) {
        _log.warning('Remote batch fetch failed', e, st);
      }
    }

    // ── Step 4: batch-fetch local_asset_entity for IDs not resolved to remote ──
    // Exclude resolvedLocalIds — those already appear as their remote counterpart above.
    final unresolvedLocalIds = allLocalIds.difference(seenIds).difference(resolvedLocalIds);
    if (unresolvedLocalIds.isNotEmpty) {
      try {
        final ph = unresolvedLocalIds.map((_) => '?').join(',');
        final rows = await _db.customSelect(
          'SELECT * FROM local_asset_entity WHERE id IN ($ph)',
          variables: unresolvedLocalIds.map(Variable.withString).toList(),
        ).get();
        final foundIds = <String>{};
        for (final r in rows) {
          final id = r.data['id'] as String;
          foundIds.add(id);
          if (seenIds.add(id)) items.add(_localRowToJson(r));
        }

        // ── Step 5: stubs for label IDs not in local_asset_entity yet ──
        for (final id in unresolvedLocalIds.difference(foundIds)) {
          if (seenIds.add(id)) items.add(_stubJson(id));
        }
      } catch (e, st) {
        _log.warning('Local batch fetch failed', e, st);
        for (final id in unresolvedLocalIds) {
          if (seenIds.add(id)) items.add(_stubJson(id));
        }
      }
    }

    return _assetResult(items.take(_pageSize).toList(), null);
  }

  // ── Body parsing ─────────────────────────────────────────────────────────

  String? _extractQuery(Object? body) {
    if (body is SmartSearchDto) return body.query;
    if (body is MetadataSearchDto) return body.originalFileName;
    if (body is Map<String, dynamic>) {
      return (body['query'] ?? body['originalFileName'])?.toString();
    }
    return null;
  }

  // ── Row → JSON mappers ────────────────────────────────────────────────────

  Map<String, dynamic> _remoteRowToJson(QueryRow r, {String? localId}) {
    final d = r.data;
    final typeInt = d['type'] as int? ?? 0;
    final visibilityInt = d['visibility'] as int? ?? 0;
    return {
      'checksum': d['checksum'],
      'createdAt': _ts(d['created_at']),
      'duration': d['duration_ms'],
      'fileCreatedAt': _ts(d['created_at']),
      'fileModifiedAt': _ts(d['updated_at']),
      'hasMetadata': false,
      'height': d['height'],
      'id': d['id'],
      'isArchived': visibilityInt == 2,
      'isEdited': (d['is_edited'] as int? ?? 0) == 1,
      'isFavorite': (d['is_favorite'] as int? ?? 0) == 1,
      'isOffline': false,
      'isTrashed': d['deleted_at'] != null,
      'libraryId': d['library_id'],
      'livePhotoVideoId': d['live_photo_video_id'],
      'localDateTime': _ts(d['local_date_time'] ?? d['created_at']),
      'originalFileName': d['name'],
      // Prefix 'pm:' signals toDto() to use this as localId → LocalThumbProvider.
      'originalPath': localId != null ? 'pm:$localId' : (d['name'] ?? ''),
      'ownerId': d['owner_id'] ?? _ownerId,
      'people': [],
      'tags': [],
      'thumbhash': d['thumb_hash'],
      'type': _typeStr(typeInt),
      'updatedAt': _ts(d['updated_at']),
      'visibility': _visibilityStr(visibilityInt),
      'width': d['width'],
    };
  }

  Map<String, dynamic> _localRowToJson(QueryRow r) {
    final d = r.data;
    final typeInt = d['type'] as int? ?? 0;
    final now = DateTime.now().toUtc().toIso8601String();
    return {
      'checksum': d['checksum'],
      'createdAt': _ts(d['created_at']) ?? now,
      'duration': d['duration_ms'],
      'fileCreatedAt': _ts(d['created_at']) ?? now,
      'fileModifiedAt': _ts(d['updated_at']) ?? now,
      'hasMetadata': false,
      'height': d['height'],
      'id': d['id'],
      'isArchived': false,
      'isEdited': false,
      'isFavorite': (d['is_favorite'] as int? ?? 0) == 1,
      'isOffline': true,
      'isTrashed': false,
      'libraryId': null,
      'livePhotoVideoId': null,
      'localDateTime': _ts(d['created_at']) ?? now,
      'originalFileName': d['name'] ?? d['id'],
      'originalPath': d['name'] ?? d['id'],
      'ownerId': _ownerId,
      'people': [],
      'tags': [],
      'thumbhash': d['thumb_hash'],
      'type': _typeStr(typeInt),
      'updatedAt': _ts(d['updated_at']) ?? now,
      'visibility': 'timeline',
      'width': d['width'],
    };
  }

  // Minimal stub for assets only in asset_label_entity (ML ran before Immich scan).
  Map<String, dynamic> _stubJson(String id) {
    final now = DateTime.now().toUtc().toIso8601String();
    return {
      'checksum': null,
      'createdAt': now,
      'duration': null,
      'fileCreatedAt': now,
      'fileModifiedAt': now,
      'hasMetadata': false,
      'height': null,
      'id': id,
      'isArchived': false,
      'isEdited': false,
      'isFavorite': false,
      'isOffline': true,
      'isTrashed': false,
      'libraryId': null,
      'livePhotoVideoId': null,
      'localDateTime': now,
      'originalFileName': id,
      'originalPath': id,
      'ownerId': _ownerId,
      'people': [],
      'tags': [],
      'thumbhash': null,
      'type': 'IMAGE',
      'updatedAt': now,
      'visibility': 'timeline',
      'width': null,
    };
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  String? _ts(dynamic v) => v?.toString();

  String _typeStr(int t) => switch (t) {
    1 => 'IMAGE',
    2 => 'VIDEO',
    3 => 'AUDIO',
    _ => 'OTHER',
  };

  String _visibilityStr(int v) => switch (v) {
    1 => 'hidden',
    2 => 'archive',
    3 => 'locked',
    _ => 'timeline',
  };

  http.Response _assetResult(List<Map<String, dynamic>> items, int? nextPage) => _json({
    'assets': {
      'items': items,
      'nextPage': nextPage?.toString(),
      'total': items.length,
      'count': items.length,
      'facets': [],
    },
    'albums': {'items': [], 'total': 0, 'count': 0, 'facets': []},
  });

  http.Response _emptyResult() => _assetResult([], null);

  http.Response _json(Object data) => http.Response(
    jsonEncode(data),
    200,
    headers: {'content-type': 'application/json'},
  );
}
