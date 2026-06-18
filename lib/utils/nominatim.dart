import 'dart:convert';

import 'package:http/http.dart' as http;

class NominatimPlace {
  const NominatimPlace({
    required this.displayName,
    required this.lat,
    required this.lon,
    this.boundingBox,
  });

  factory NominatimPlace.fromJson(Map<String, dynamic> json) {
    List<double>? bbox;
    final raw = json['boundingbox'];
    if (raw is List && raw.length == 4) {
      bbox = raw.map((e) => double.parse(e.toString())).toList();
    }
    return NominatimPlace(
      displayName: json['display_name'] as String,
      lat: double.parse(json['lat'] as String),
      lon: double.parse(json['lon'] as String),
      boundingBox: bbox,
    );
  }

  final String displayName;
  final double lat;
  final double lon;

  // [southLat, northLat, westLon, eastLon]
  final List<double>? boundingBox;
}

/// Searches Nominatim (OpenStreetMap) for places matching [query].
///
/// Pass a custom [client] for testing; otherwise a one-shot client is used.
Future<List<NominatimPlace>> searchNominatim(
  String query, {
  http.Client? client,
}) async {
  final ownClient = client == null;
  final c = client ?? http.Client();
  try {
    final uri = Uri.https(
      'nominatim.openstreetmap.org',
      '/search',
      {'q': query, 'format': 'json', 'limit': '5'},
    );
    final response = await c.get(
      uri,
      headers: {'User-Agent': 'immich-mobile/1.0 (https://github.com/immich-app/immich)'},
    );
    if (response.statusCode != 200) return [];
    final body = jsonDecode(response.body);
    if (body is! List) return [];
    return body
        .whereType<Map<String, dynamic>>()
        .map(NominatimPlace.fromJson)
        .toList();
  } finally {
    if (ownClient) c.close();
  }
}
