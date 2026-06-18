import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:immich_mobile/infrastructure/repositories/db.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/people.repository.dart';

class PersonHandler {
  final Drift _db;
  PersonHandler(this._db);

  Future<http.Response> handle(
    String route,
    String method,
    Object? body,
  ) async {
    final repo = DriftPeopleRepository(_db);

    if (route == '/people' && method == 'GET') {
      final people = await repo.getAllPeople();
      final list = people.map((p) => _personJson(p)).toList();
      return http.Response(
        jsonEncode({'people': list, 'total': list.length, 'hidden': 0}),
        200,
        headers: {'content-type': 'application/json'},
      );
    }

    if (route.startsWith('/people/') && method == 'PUT') {
      final personId = route.substring('/people/'.length);
      if (body is Map) {
        final name = body['name'];
        if (name is String) {
          await repo.updateName(personId, name);
        }
        final birthday = body['birthDate'];
        if (birthday is String) {
          await repo.updateBirthday(personId, DateTime.parse(birthday));
        }
      }
      final person = await repo.get(personId);
      if (person == null) {
        return http.Response('{}', 404);
      }
      return http.Response(
        jsonEncode(_personJson(person)),
        200,
        headers: {'content-type': 'application/json'},
      );
    }

    return http.Response('{}', 404);
  }

  Map<String, dynamic> _personJson(dynamic p) => {
    'id': p.id,
    'name': p.name,
    'isHidden': p.isHidden,
    'isFavorite': p.isFavorite,
    'thumbnailPath': p.faceAssetId != null ? '.thumbs/${p.faceAssetId}' : '',
    if (p.birthDate != null) 'birthDate': (p.birthDate as DateTime).toUtc().toIso8601String(),
    'updatedAt': (p.updatedAt as DateTime).toUtc().toIso8601String(),
  };
}
