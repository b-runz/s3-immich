import 'package:drift/drift.dart';
import 'package:flutter/widgets.dart';
import 'package:s3mmich/infrastructure/ml/face_ml_schema.dart';
import 'package:s3mmich/infrastructure/repositories/db.repository.dart';
import 'package:uuid/uuid.dart';

class AssetFaceMlRepository {
  static const int _coordScale = 10000;
  final Drift _db;

  AssetFaceMlRepository(this._db) {
    // ignore: discarded_futures
    FaceMlSchema.ensureColumns(_db);
  }

  Future<String> insertFace({
    required String assetId,
    required Rect normBoundingBox,
  }) async {
    final id = const Uuid().v4();
    await _db.customStatement(
      '''INSERT OR IGNORE INTO asset_face_entity
         (id, asset_id, person_id, image_width, image_height,
          bounding_box_x1, bounding_box_y1, bounding_box_x2, bounding_box_y2,
          source_type, is_visible)
         VALUES (?, ?, NULL, ?, ?, ?, ?, ?, ?, 'ml_kit', 1)''',
      [
        id, assetId, _coordScale, _coordScale,
        (normBoundingBox.left * _coordScale).round(),
        (normBoundingBox.top * _coordScale).round(),
        (normBoundingBox.right * _coordScale).round(),
        (normBoundingBox.bottom * _coordScale).round(),
      ],
    );
    return id;
  }

  Future<void> markFaceProcessed(String assetId) async {
    await _db.customStatement(
      'UPDATE local_asset_entity SET face_processed = 1 WHERE id = ?',
      [assetId],
    );
  }

  Future<bool> isFaceProcessed(String assetId) async {
    final rows = await _db.customSelect(
      'SELECT face_processed FROM local_asset_entity WHERE id = ?',
      variables: [Variable.withString(assetId)],
    ).get();
    return rows.isNotEmpty && (rows.first.data['face_processed'] as int? ?? 0) == 1;
  }

  Future<List<Map<String, dynamic>>> getFacesForAsset(String assetId) async {
    final rows = await _db.customSelect(
      '''SELECT f.id, f.bounding_box_x1, f.bounding_box_y1,
                f.bounding_box_x2, f.bounding_box_y2,
                f.image_width, f.image_height,
                p.id as person_id, p.name as person_name
         FROM asset_face_entity f
         LEFT JOIN person_entity p ON f.person_id = p.id
         WHERE f.asset_id = ? AND f.is_visible = 1 AND f.deleted_at IS NULL''',
      variables: [Variable.withString(assetId)],
    ).get();
    return rows.map((r) => r.data).toList();
  }
}
