import 'dart:convert';
import 'package:drift/drift.dart' hide Column;
import 'package:http/http.dart' as http;
import 'package:immich_mobile/domain/models/album/album.model.dart';
import 'package:immich_mobile/infrastructure/entities/remote_album.entity.drift.dart';
import 'package:immich_mobile/infrastructure/repositories/db.repository.dart';

class AlbumHandler {
  final Drift _db;
  AlbumHandler(this._db);

  Future<http.Response> handle(
    String route,
    String method,
    Object? body,
  ) async {
    final segments =
        route.split('/').where((s) => s.isNotEmpty).toList();
    // segments[0] == 'albums'

    if (segments.length == 1) {
      if (method == 'GET') {
        return await _listAlbums();
      }
      if (method == 'POST') {
        return await _createAlbum(body);
      }
      return http.Response('[]', 200);
    }

    final id = segments[1];

    switch (method) {
      case 'GET':
        return await _getAlbum(id);
      case 'PATCH':
        return await _updateAlbum(id, body);
      case 'DELETE':
        return await _deleteAlbum(id);
      default:
        return http.Response('{}', 200);
    }
  }

  Future<http.Response> _listAlbums() async {
    final albums = await (_db.remoteAlbumEntity.select()).get();
    final json = albums.map(_rowToJson).toList();
    return http.Response(
      jsonEncode(json),
      200,
      headers: {'content-type': 'application/json'},
    );
  }

  Future<http.Response> _getAlbum(String id) async {
    final row = await (_db.remoteAlbumEntity.select()
          ..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    if (row == null) {
      return http.Response('{}', 404);
    }

    // Count assets for this album
    final assetRows = await (_db.remoteAlbumAssetEntity.select()
          ..where((t) => t.albumId.equals(id)))
        .get();

    final albumJson = _rowToJson(row);
    albumJson['assetCount'] = assetRows.length;
    return http.Response(
      jsonEncode(albumJson),
      200,
      headers: {'content-type': 'application/json'},
    );
  }

  Future<http.Response> _createAlbum(Object? body) async {
    // No-op: return empty album stub
    final now = DateTime.now().toUtc().toIso8601String();
    return http.Response(
      jsonEncode({
        'albumName': 'New Album',
        'albumThumbnailAssetId': null,
        'albumUsers': [],
        'assetCount': 0,
        'contributorCounts': [],
        'createdAt': now,
        'description': '',
        'hasSharedLink': false,
        'id': 'new-album-stub',
        'isActivityEnabled': true,
        'shared': false,
        'updatedAt': now,
      }),
      200,
      headers: {'content-type': 'application/json'},
    );
  }

  Future<http.Response> _updateAlbum(String id, Object? body) async {
    return await _getAlbum(id);
  }

  Future<http.Response> _deleteAlbum(String id) async {
    await (_db.remoteAlbumEntity.delete()
          ..where((t) => t.id.equals(id)))
        .go();
    return http.Response('{}', 200);
  }

  Map<String, dynamic> _rowToJson(RemoteAlbumEntityData row) {
    return {
      'albumName': row.name,
      'albumThumbnailAssetId': row.thumbnailAssetId,
      'albumUsers': [],
      'assetCount': 0,
      'contributorCounts': [],
      'createdAt': row.createdAt.toUtc().toIso8601String(),
      'description': row.description,
      'hasSharedLink': false,
      'id': row.id,
      'isActivityEnabled': row.isActivityEnabled,
      'order': _orderString(row.order),
      'shared': false,
      'updatedAt': row.updatedAt.toUtc().toIso8601String(),
    };
  }

  String _orderString(AlbumAssetOrder order) {
    return order == AlbumAssetOrder.desc ? 'desc' : 'asc';
  }
}
