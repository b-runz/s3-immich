/// Integration tests for NominatimPlace search — hits the real Nominatim API.
///
/// Run with: flutter test test/modules/utils/nominatim_test.dart
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/utils/nominatim.dart';

void main() {
  group('searchNominatim integration', () {
    test('greece returns results with lat/lon', () async {
      final results = await searchNominatim('greece');
      expect(results, isNotEmpty, reason: 'Expected at least one result for "greece"');
      final first = results.first;
      expect(first.lat, isNonZero, reason: 'lat should be non-zero');
      expect(first.lon, isNonZero, reason: 'lon should be non-zero');
      expect(first.displayName, isNotEmpty);
      // Greece is roughly lat 37–42, lon 20–28
      expect(first.lat, inInclusiveRange(34.0, 42.5));
      expect(first.lon, inInclusiveRange(18.0, 30.0));
    });

    test('aarhus returns results with lat/lon', () async {
      final results = await searchNominatim('aarhus');
      expect(results, isNotEmpty, reason: 'Expected at least one result for "aarhus"');
      final first = results.first;
      expect(first.lat, isNonZero);
      expect(first.lon, isNonZero);
      // Aarhus, Denmark: lat ~56.15, lon ~10.21
      expect(first.lat, inInclusiveRange(56.0, 56.3));
      expect(first.lon, inInclusiveRange(10.0, 10.5));
    });

    test('egtved returns results with lat/lon', () async {
      final results = await searchNominatim('egtved');
      expect(results, isNotEmpty, reason: 'Expected at least one result for "egtved"');
      final first = results.first;
      expect(first.lat, isNonZero);
      expect(first.lon, isNonZero);
      // Egtved, Denmark: lat ~55.62, lon ~9.30
      expect(first.lat, inInclusiveRange(55.0, 56.0));
      expect(first.lon, inInclusiveRange(9.0, 10.0));
    });

    test('boundingBox is populated when available', () async {
      final results = await searchNominatim('greece');
      expect(results, isNotEmpty);
      final withBbox = results.where((r) => r.boundingBox != null);
      expect(withBbox, isNotEmpty, reason: 'At least one result should have a bounding box');
      final bbox = withBbox.first.boundingBox!;
      expect(bbox.length, equals(4));
    });
  });
}
