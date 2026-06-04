import 'dart:convert';
import 'package:http/http.dart' as http;

class MemoryHandler {
  http.Response handle(String route, String method, Object? body) {
    return http.Response(
      jsonEncode([]),
      200,
      headers: {'content-type': 'application/json'},
    );
  }
}
