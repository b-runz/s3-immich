import 'package:immich_mobile/infrastructure/repositories/db.repository.dart';

class OcrMlSchema {
  OcrMlSchema._();

  static Future<void> ensureSchema(Drift db) async {
    final cols = await db.customSelect('PRAGMA table_info(local_asset_entity)').get();
    final colNames = cols.map((r) => r.data['name'] as String).toSet();

    if (!colNames.contains('ocr_text')) {
      await db.customStatement(
        'ALTER TABLE local_asset_entity ADD COLUMN ocr_text TEXT',
      );
    }
    if (!colNames.contains('ocr_processed')) {
      await db.customStatement(
        'ALTER TABLE local_asset_entity ADD COLUMN ocr_processed INTEGER NOT NULL DEFAULT 0',
      );
    }

    await db.customStatement('''
      CREATE VIRTUAL TABLE IF NOT EXISTS asset_fts USING fts5(
        asset_id UNINDEXED,
        ocr_text,
        labels,
        tokenize = 'unicode61'
      )
    ''');
  }

  static Future<void> writeOcrText(Drift db, String assetId, String text) async {
    await db.customStatement(
      'UPDATE local_asset_entity SET ocr_text = ?, ocr_processed = 1 WHERE id = ?',
      [text, assetId],
    );
    await db.customStatement('DELETE FROM asset_fts WHERE asset_id = ?', [assetId]);
    await db.customStatement(
      'INSERT INTO asset_fts(asset_id, ocr_text, labels) VALUES (?, ?, ?)',
      [assetId, text, ''],
    );
  }
}
