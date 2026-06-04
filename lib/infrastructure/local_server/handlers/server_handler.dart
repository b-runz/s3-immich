import 'dart:convert';
import 'package:http/http.dart' as http;

class ServerHandler {
  http.Response handle(String route, String method) {
    if (route.startsWith('/server/about')) {
      return _about();
    }
    if (route.startsWith('/server/storage')) {
      return _storage();
    }
    if (route.startsWith('/server/info')) {
      return _storage();
    }
    if (route.startsWith('/server/version')) {
      return _version();
    }
    if (route.startsWith('/server/statistics')) {
      return _statistics();
    }
    if (route.startsWith('/server/config')) {
      return _config();
    }
    if (route.startsWith('/server/features')) {
      return _features();
    }
    return http.Response('{}', 200);
  }

  http.Response _about() => http.Response(
    jsonEncode({
      'licensed': true,
      'version': 'v1.134.0',
      'versionUrl':
          'https://github.com/immich-app/immich/releases/tag/v1.134.0',
    }),
    200,
    headers: {'content-type': 'application/json'},
  );

  http.Response _storage() => http.Response(
    jsonEncode({
      'diskAvailable': '999 GB',
      'diskAvailableRaw': 999000000000,
      'diskSize': '999 GB',
      'diskSizeRaw': 999000000000,
      'diskUsagePercentage': 0.0,
      'diskUse': '0 B',
      'diskUseRaw': 0,
    }),
    200,
    headers: {'content-type': 'application/json'},
  );

  http.Response _version() => http.Response(
    jsonEncode({'major': 1, 'minor': 134, 'patch': 0}),
    200,
    headers: {'content-type': 'application/json'},
  );

  http.Response _statistics() => http.Response(
    jsonEncode({
      'photos': 0,
      'videos': 0,
      'usage': 0,
      'usagePhotos': 0,
      'usageVideos': 0,
      'usageByUser': [],
    }),
    200,
    headers: {'content-type': 'application/json'},
  );

  http.Response _config() => http.Response(
    jsonEncode({
      'externalDomain': '',
      'isInitialized': true,
      'isOnboarded': true,
      'loginPageMessage': '',
      'maintenanceMode': false,
      'mapDarkStyleUrl': '',
      'mapLightStyleUrl': '',
      'oauthButtonText': '',
      'publicUsers': false,
      'trashDays': 30,
      'userDeleteDelay': 7,
    }),
    200,
    headers: {'content-type': 'application/json'},
  );

  http.Response _features() => http.Response(
    jsonEncode({
      'configFile': false,
      'duplicateDetection': false,
      'email': false,
      'facialRecognition': false,
      'importFaces': false,
      'map': false,
      'oauth': false,
      'oauthAutoLaunch': false,
      'ocr': true,
      'passwordLogin': true,
      'reverseGeocoding': false,
      'search': true,
      'sidecar': false,
      'smartSearch': true,
      'trash': true,
    }),
    200,
    headers: {'content-type': 'application/json'},
  );
}
