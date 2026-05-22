import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:s3mmich/infrastructure/repositories/db.repository.dart';

class PersonHandler {
  // ignore: unused_field
  final Drift _db;
  PersonHandler(this._db);

  Future<http.Response> handle(
    String route,
    String method,
    Object? body,
  ) async {
    if (route.startsWith('/people') && method == 'GET') {
      return http.Response(
        jsonEncode({'people': [], 'total': 0, 'hidden': 0}),
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    return http.Response('{}', 404);
  }
}
