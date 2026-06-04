import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:http/http.dart' as http;
import 'package:openapi/api.dart' show QueryParam;
import 'package:immich_mobile/infrastructure/repositories/db.repository.dart';

class MapHandler {
  final Drift _db;
  MapHandler(this._db);

  Future<http.Response> handle(
    String route,
    String method,
    List<QueryParam> queryParams,
  ) async {
    if (route == '/map/markers' && method == 'GET') {
      return _getMapMarkers(queryParams);
    }
    return http.Response('[]', 200, headers: {'content-type': 'application/json'});
  }

  Future<http.Response> _getMapMarkers(List<QueryParam> queryParams) async {
    final params = {for (final p in queryParams) p.name: p.value};

    final isFavorite = switch (params['isFavorite']) {
      'true' => true,
      'false' => false,
      _ => null,
    };
    final isArchived = params['isArchived'] == 'true';
    final fileCreatedAfter = _parseDate(params['fileCreatedAfter']);
    final fileCreatedBefore = _parseDate(params['fileCreatedBefore']);

    // timeline=0, archive=2; withArchived includes both
    final visibilityClause = isArchived ? 'IN (0, 2)' : '= 0';

    var sql = '''
      SELECT rae.id, ree.latitude, ree.longitude, ree.city, ree.country, ree.state
      FROM remote_exif_entity ree
      INNER JOIN remote_asset_entity rae ON rae.id = ree.asset_id
      WHERE rae.deleted_at IS NULL
        AND ree.latitude IS NOT NULL
        AND ree.longitude IS NOT NULL
        AND rae.visibility $visibilityClause
    ''';

    final vars = <Variable>[];

    if (isFavorite == true) {
      sql += ' AND rae.is_favorite = 1';
    }

    if (fileCreatedAfter != null) {
      sql += ' AND rae.created_at >= ?';
      vars.add(Variable.withString(fileCreatedAfter.toUtc().toIso8601String()));
    }

    if (fileCreatedBefore != null) {
      sql += ' AND rae.created_at <= ?';
      vars.add(Variable.withString(fileCreatedBefore.toUtc().toIso8601String()));
    }

    sql += ' LIMIT 10000';

    final rows = await _db.customSelect(sql, variables: vars).get();

    final markers = rows.map((row) {
      final d = row.data;
      return <String, dynamic>{
        'id': d['id'],
        'lat': d['latitude'],
        'lon': d['longitude'],
        if (d['city'] != null) 'city': d['city'],
        if (d['country'] != null) 'country': d['country'],
        if (d['state'] != null) 'state': d['state'],
      };
    }).toList();

    return http.Response(
      jsonEncode(markers),
      200,
      headers: {'content-type': 'application/json'},
    );
  }

  DateTime? _parseDate(String? value) {
    if (value == null) {
      return null;
    }
    try {
      return DateTime.parse(value);
    } catch (_) {
      return null;
    }
  }
}
