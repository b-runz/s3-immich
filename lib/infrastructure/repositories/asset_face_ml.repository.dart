import 'package:drift/drift.dart';
import 'package:flutter/widgets.dart';
import 'package:immich_mobile/infrastructure/ml/face_ml_schema.dart';
import 'package:immich_mobile/infrastructure/repositories/db.repository.dart';
import 'package:uuid/uuid.dart';

class AssetFaceMlRepository {
  static const int _coordScale = 10000;
  final Drift _db;

  AssetFaceMlRepository(this._db) {
    // ignore: discarded_futures
    FaceMlSchema.ensureColumns(_db);
  }

  /// Resolves a local photo_manager ID to the S3 key in remote_asset_entity.
  /// Returns null if the photo hasn't been uploaded yet.
  Future<String?> getRemoteIdForLocal(String localId) async {
    final rows = await _db.customSelect(
      '''SELECT r.id FROM remote_asset_entity r
         JOIN local_asset_entity l ON l.checksum = r.checksum
         WHERE l.id = ?''',
      variables: [Variable.withString(localId)],
    ).get();
    return rows.isEmpty ? null : rows.first.data['id'] as String;
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

  /// Creates a person linked to the given face and returns the new person ID.
  /// [faceThumbnailKey] is the S3 sub-key for the pre-cropped face image
  /// (e.g. 'faces/{personId}.jpg'). Falls back to [remoteAssetId] if null,
  /// which causes the full photo thumbnail to be used as the person thumbnail.
  Future<String> createPersonForFace({
    required String faceId,
    required String remoteAssetId,
    String? faceThumbnailKey,
    String? personId,
  }) async {
    final id = personId ?? const Uuid().v4();
    final thumbKey = faceThumbnailKey ?? remoteAssetId;
    await _db.customStatement(
      '''INSERT INTO person_entity
         (id, owner_id, name, face_asset_id, is_favorite, is_hidden)
         VALUES (?, 'local-user', '', ?, 0, 0)''',
      [id, thumbKey],
    );
    await _db.customStatement(
      'UPDATE asset_face_entity SET person_id = ? WHERE id = ?',
      [id, faceId],
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
