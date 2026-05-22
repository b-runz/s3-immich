import 'dart:convert';
import 'package:drift/drift.dart' hide Column;
import 'package:http/http.dart' as http;
import 'package:s3mmich/infrastructure/entities/remote_asset.entity.drift.dart';
import 'package:s3mmich/infrastructure/repositories/db.repository.dart';

class TrashHandler {
  final Drift _db;
  TrashHandler(this._db);

  Future<http.Response> handle(
    String route,
    String method,
    Object? body,
  ) async {
    if (route == '/trash' && method == 'GET') {
      return http.Response(
        jsonEncode({
          'items': [],
          'nextPage': null,
          'total': 0,
          'hasNextPage': false,
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    if (route == '/trash/restore' && method == 'POST') {
      if (body is Map) {
        final ids = (body['ids'] as List?)?.cast<String>() ?? <String>[];
        for (final id in ids) {
          await (_db.remoteAssetEntity.update()
                ..where((t) => t.id.equals(id)))
              .write(
                const RemoteAssetEntityCompanion(
                  deletedAt: Value<DateTime?>(null),
                ),
              );
        }
      }
      return http.Response('{}', 200);
    }
    if (route == '/trash/empty' && method == 'POST') {
      await (_db.remoteAssetEntity.delete()
            ..where((t) => t.deletedAt.isNotNull()))
          .go();
      return http.Response('{}', 200);
    }
    return http.Response('{}', 200);
  }
}
