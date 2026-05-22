import 'dart:convert';
import 'package:http/http.dart' as http;

class AuthHandler {

  http.Response handle(String route, String method, Object? body) {
    if (route == '/auth/login') {
      return _login();
    }
    if (route == '/auth/validateToken' || route == '/auth/validate-token') {
      return _validateToken();
    }
    if (route == '/auth/logout') {
      return http.Response('{}', 200);
    }
    if (route.startsWith('/users/me/preferences')) {
      return _userPreferences(method);
    }
    if (route == '/users/me') {
      return _me();
    }
    return http.Response('{}', 200);
  }

  http.Response _login() => http.Response(
    jsonEncode({
      'accessToken': 's3-local',
      'isAdmin': false,
      'isOnboarded': true,
      'name': 'My Device',
      'profileImagePath': '',
      'shouldChangePassword': false,
      'userEmail': 'local@s3immich',
      'userId': 'local-user',
    }),
    200,
    headers: {'content-type': 'application/json'},
  );

  http.Response _validateToken() => http.Response(
    jsonEncode({'authStatus': true}),
    200,
    headers: {'content-type': 'application/json'},
  );

  http.Response _me() => http.Response(
    jsonEncode(_localUser()),
    200,
    headers: {'content-type': 'application/json'},
  );

  http.Response _userPreferences(String method) => http.Response(
    jsonEncode({
      'avatar': {'color': 'primary'},
      'memories': {'enabled': true},
      'emailNotifications': {
        'enabled': false,
        'albumInvite': false,
        'albumUpdate': false,
      },
      'purchase': {'showSupportBadge': false, 'hideBuyButtonUntil': null},
      'ratings': {'enabled': false},
      'tags': {'enabled': false},
    }),
    200,
    headers: {'content-type': 'application/json'},
  );

  Map<String, dynamic> _localUser() => {
    'avatarColor': 'primary',
    'createdAt': '2020-01-01T00:00:00.000Z',
    'deletedAt': null,
    'email': 'local@s3immich',
    'id': 'local-user',
    'isAdmin': false,
    'license': null,
    'name': 'My Device',
    'oauthId': '',
    'profileChangedAt': '2020-01-01T00:00:00.000Z',
    'profileImagePath': '',
    'quotaSizeInBytes': null,
    'quotaUsageInBytes': null,
    'shouldChangePassword': false,
    'status': 'active',
    'storageLabel': null,
    'updatedAt': '2020-01-01T00:00:00.000Z',
  };
}
