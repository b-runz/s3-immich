import 'package:drift/drift.dart';
import 'package:immich_mobile/infrastructure/ml/label_ml_schema.dart';
import 'package:immich_mobile/infrastructure/ml/ocr_ml_schema.dart';
import 'package:immich_mobile/infrastructure/repositories/db.repository.dart';

class SearchQuery {
  final String? text;
  final String? location;
  final DateTime? from;
  final DateTime? to;

  const SearchQuery({this.text, this.location, this.from, this.to});
}

class LocalSearchRepository {
  final Drift _db;

  LocalSearchRepository(this._db) {
    // ignore: discarded_futures
    OcrMlSchema.ensureSchema(_db);
    // ignore: discarded_futures
    LabelMlSchema.ensureSchema(_db);
  }

  Future<List<String>> searchByText(String query) async {
    final rows = await _db.customSelect(
      'SELECT asset_id FROM asset_fts WHERE asset_fts MATCH ?',
      variables: [Variable.withString(query)],
    ).get();
    return rows.map((r) => r.data['asset_id'] as String).toList();
  }

  Future<List<String>> searchByLocation(String locationQuery) async {
    final pattern = '%${locationQuery.toLowerCase()}%';
    final rows = await _db.customSelect(
      'SELECT asset_id FROM remote_exif_entity WHERE LOWER(city) LIKE ? OR LOWER(country) LIKE ?',
      variables: [Variable.withString(pattern), Variable.withString(pattern)],
    ).get();
    return rows.map((r) => r.data['asset_id'] as String).toList();
  }

  Future<List<String>> searchByDateRange(DateTime from, DateTime to) async {
    final rows = await _db.customSelect(
      'SELECT id FROM local_asset_entity WHERE created_at >= ? AND created_at <= ?',
      variables: [Variable.withString(from.toIso8601String()), Variable.withString(to.toIso8601String())],
    ).get();
    return rows.map((r) => r.data['id'] as String).toList();
  }

  Future<List<String>> search(SearchQuery query) async {
    final results = <String>{};
    if (query.text != null && query.text!.isNotEmpty) {
      results.addAll(await searchByText(query.text!));
    }
    if (query.location != null && query.location!.isNotEmpty) {
      results.addAll(await searchByLocation(query.location!));
    }
    if (query.from != null && query.to != null) {
      results.addAll(await searchByDateRange(query.from!, query.to!));
    }
    return results.toList();
  }
}
