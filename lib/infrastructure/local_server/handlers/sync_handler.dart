import 'package:http/http.dart' as http;

class SyncHandler {

  http.Response handle(String route, String method, Object? body) {
    if (route.startsWith('/sync/ack') && method == 'DELETE') {
      return http.Response('', 204);
    }
    // Empty event stream — manifest-sync agent will replace this
    return http.Response(
      '',
      200,
      headers: {'content-type': 'text/event-stream'},
    );
  }
}
