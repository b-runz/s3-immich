import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:s3mmich/infrastructure/repositories/db.repository.dart';

class SearchHandler {
  // ignore: unused_field
  final Drift _db;
  SearchHandler(this._db);

  Future<http.Response> handle(
    String route,
    String method,
    Object? body,
  ) async {
    if (route.startsWith('/search/suggestions')) {
      return http.Response(
        jsonEncode([]),
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    if (route.startsWith('/search/explore')) {
      return http.Response(
        jsonEncode([]),
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    // Smart search and metadata search — return empty for now
    return http.Response(
      jsonEncode({
        'assets': {
          'items': [],
          'nextPage': null,
          'total': 0,
          'count': 0,
          'facets': [],
        },
        'albums': {
          'items': [],
          'total': 0,
          'count': 0,
          'facets': [],
        },
      }),
      200,
      headers: {'content-type': 'application/json'},
    );
  }
}
