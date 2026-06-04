import 'dart:convert';
import 'package:drift/drift.dart' hide Column;
import 'package:http/http.dart' as http;
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/infrastructure/entities/remote_asset.entity.drift.dart';
import 'package:immich_mobile/infrastructure/repositories/db.repository.dart';

class AssetHandler {
  final Drift _db;
  AssetHandler(this._db);

  Future<http.Response> handle(
    String route,
    String method,
    Object? body,
  ) async {
    final segments =
        route.split('/').where((s) => s.isNotEmpty).toList();
    // segments[0] == 'assets'

    if (segments.length == 1) {
      if (method == 'DELETE') {
        return _bulkDelete(body);
      }
      return http.Response('[]', 200);
    }

    final id = segments[1];
    final subpath = segments.length > 2 ? segments[2] : null;

    if (subpath == 'thumbnail' || subpath == 'original') {
      return http.Response('', 200);
    }

    switch (method) {
      case 'GET':
        return await _getAsset(id);
      case 'PUT':
        return await _updateAsset(id, body);
      case 'DELETE':
        return await _deleteAsset(id);
      default:
        return http.Response('{}', 200);
    }
  }

  Future<http.Response> _getAsset(String id) async {
    final row = await (_db.remoteAssetEntity.select()
          ..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    if (row == null) {
      return http.Response('{}', 404);
    }
    return http.Response(
      jsonEncode(_rowToJson(row)),
      200,
      headers: {'content-type': 'application/json'},
    );
  }

  Future<http.Response> _updateAsset(String id, Object? body) async {
    // For now just return the current asset after a no-op
    return await _getAsset(id);
  }

  Future<http.Response> _deleteAsset(String id) async {
    await (_db.remoteAssetEntity.delete()
          ..where((t) => t.id.equals(id)))
        .go();
    return http.Response('{}', 200);
  }

  Future<http.Response> _bulkDelete(Object? body) async {
    if (body is Map) {
      final ids = (body['ids'] as List?)?.cast<String>() ?? <String>[];
      for (final id in ids) {
        await (_db.remoteAssetEntity.delete()
              ..where((t) => t.id.equals(id)))
            .go();
      }
    }
    return http.Response('{}', 200);
  }

  Map<String, dynamic> _rowToJson(RemoteAssetEntityData row) {
    final visibilityStr = _visibilityString(row.visibility);
    final typeStr = _typeString(row.type);
    final createdAt = row.createdAt.toUtc().toIso8601String();
    final updatedAt = row.updatedAt.toUtc().toIso8601String();
    final localDateTime =
        (row.localDateTime ?? row.createdAt).toUtc().toIso8601String();

    return {
      'checksum': row.checksum,
      'createdAt': createdAt,
      'duration': row.durationMs,
      'fileCreatedAt': createdAt,
      'fileModifiedAt': updatedAt,
      'hasMetadata': false,
      'height': row.height,
      'id': row.id,
      'isArchived': row.visibility == AssetVisibility.archive,
      'isEdited': row.isEdited,
      'isFavorite': row.isFavorite,
      'isOffline': false,
      'isTrashed': row.deletedAt != null,
      'libraryId': row.libraryId,
      'livePhotoVideoId': row.livePhotoVideoId,
      'localDateTime': localDateTime,
      'originalFileName': row.name,
      'originalPath': row.name,
      'ownerId': row.ownerId,
      'people': [],
      'tags': [],
      'thumbhash': row.thumbHash,
      'type': typeStr,
      'updatedAt': updatedAt,
      'visibility': visibilityStr,
      'width': row.width,
    };
  }

  /// domain AssetVisibility enum: timeline, hidden, archive, locked
  String _visibilityString(AssetVisibility v) {
    switch (v) {
      case AssetVisibility.timeline:
        return 'timeline';
      case AssetVisibility.hidden:
        return 'hidden';
      case AssetVisibility.archive:
        return 'archive';
      case AssetVisibility.locked:
        return 'locked';
    }
  }

  /// domain AssetType enum: other, image, video, audio
  String _typeString(AssetType t) {
    switch (t) {
      case AssetType.image:
        return 'IMAGE';
      case AssetType.video:
        return 'VIDEO';
      case AssetType.audio:
        return 'AUDIO';
      case AssetType.other:
        return 'OTHER';
    }
  }
}
