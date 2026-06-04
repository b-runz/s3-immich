import 'package:immich_mobile/infrastructure/repositories/db.repository.dart';

class FaceMlSchema {
  FaceMlSchema._();

  /// Idempotent: adds face_embedding to asset_face_entity and
  /// face_processed to local_asset_entity if they don't exist yet.
  static Future<void> ensureColumns(Drift db) async {
    final faceCols = await db.customSelect('PRAGMA table_info(asset_face_entity)').get();
    final faceColNames = faceCols.map((r) => r.data['name'] as String).toSet();
    if (!faceColNames.contains('face_embedding')) {
      await db.customStatement(
        'ALTER TABLE asset_face_entity ADD COLUMN face_embedding BLOB',
      );
    }

    final assetCols = await db.customSelect('PRAGMA table_info(local_asset_entity)').get();
    final assetColNames = assetCols.map((r) => r.data['name'] as String).toSet();
    if (!assetColNames.contains('face_processed')) {
      await db.customStatement(
        'ALTER TABLE local_asset_entity ADD COLUMN face_processed INTEGER NOT NULL DEFAULT 0',
      );
    }
  }
}
