import 'package:http/http.dart' as http;
import 'package:openapi/api.dart';
import 'package:s3mmich/infrastructure/repositories/db.repository.dart';
import 'package:s3mmich/infrastructure/local_server/handlers/auth_handler.dart';
import 'package:s3mmich/infrastructure/local_server/handlers/server_handler.dart';
import 'package:s3mmich/infrastructure/local_server/handlers/asset_handler.dart';
import 'package:s3mmich/infrastructure/local_server/handlers/album_handler.dart';
import 'package:s3mmich/infrastructure/local_server/handlers/sync_handler.dart';
import 'package:s3mmich/infrastructure/local_server/handlers/search_handler.dart';
import 'package:s3mmich/infrastructure/local_server/handlers/partner_handler.dart';
import 'package:s3mmich/infrastructure/local_server/handlers/person_handler.dart';
import 'package:s3mmich/infrastructure/local_server/handlers/memory_handler.dart';
import 'package:s3mmich/infrastructure/local_server/handlers/trash_handler.dart';
import 'package:s3mmich/infrastructure/local_server/handlers/activity_handler.dart';
import 'package:s3mmich/infrastructure/local_server/handlers/tag_handler.dart';
import 'package:s3mmich/infrastructure/local_server/handlers/shared_link_handler.dart';

class LocalApiClient extends ApiClient {
  final Drift _db;

  LocalApiClient(this._db) : super(basePath: 'http://localhost');

  @override
  Future<http.Response> invokeAPI(
    String path,
    String method,
    List<QueryParam> queryParams,
    Object? body,
    Map<String, String> headerParams,
    Map<String, String> formParams,
    String? contentType,
  ) async {
    final route = path.startsWith('/api') ? path.substring(4) : path;

    if (route.startsWith('/auth') || route.startsWith('/users/me')) {
      return AuthHandler().handle(route, method, body);
    }
    if (route.startsWith('/server')) {
      return ServerHandler().handle(route, method);
    }
    if (route.startsWith('/sync')) {
      return SyncHandler().handle(route, method, body);
    }
    if (route.startsWith('/search')) {
      return await SearchHandler(_db).handle(route, method, body);
    }
    if (route.startsWith('/assets')) {
      return await AssetHandler(_db).handle(route, method, body);
    }
    if (route.startsWith('/albums')) {
      return await AlbumHandler(_db).handle(route, method, body);
    }
    if (route.startsWith('/partners')) {
      return PartnerHandler().handle(route, method, body);
    }
    if (route.startsWith('/people')) {
      return await PersonHandler(_db).handle(route, method, body);
    }
    if (route.startsWith('/memories')) {
      return MemoryHandler().handle(route, method, body);
    }
    if (route.startsWith('/trash')) {
      return await TrashHandler(_db).handle(route, method, body);
    }
    if (route.startsWith('/activities')) {
      return ActivityHandler().handle(route, method, body);
    }
    if (route.startsWith('/tags')) {
      return TagHandler().handle(route, method, body);
    }
    if (route.startsWith('/shared-links')) {
      return SharedLinkHandler().handle(route, method, body);
    }

    return http.Response('{}', 200);
  }
}
