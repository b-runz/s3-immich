import 'package:drift/drift.dart';
import 'package:s3mmich/infrastructure/repositories/db.repository.dart';

class LabelMlSchema {
  LabelMlSchema._();

  static Future<void> ensureSchema(Drift db) async {
    await db.customStatement('''
      CREATE TABLE IF NOT EXISTS asset_label_entity (
        id         INTEGER PRIMARY KEY AUTOINCREMENT,
        asset_id   TEXT NOT NULL,
        label      TEXT NOT NULL,
        source     TEXT NOT NULL,
        confidence REAL NOT NULL,
        bbox_x     REAL,
        bbox_y     REAL,
        bbox_w     REAL,
        bbox_h     REAL
      )
    ''');
    await db.customStatement(
      'CREATE INDEX IF NOT EXISTS idx_asset_label_asset ON asset_label_entity(asset_id)',
    );
    await db.customStatement(
      'CREATE INDEX IF NOT EXISTS idx_asset_label_label ON asset_label_entity(label)',
    );

    final cols = await db.customSelect('PRAGMA table_info(local_asset_entity)').get();
    final colNames = cols.map((r) => r.data['name'] as String).toSet();
    if (!colNames.contains('labels_processed')) {
      await db.customStatement(
        'ALTER TABLE local_asset_entity ADD COLUMN labels_processed INTEGER NOT NULL DEFAULT 0',
      );
    }
  }

  static Future<void> writeLabels(Drift db, String assetId, String labelText) async {
    final tables = await db.customSelect(
      "SELECT name FROM sqlite_master WHERE type='table' AND name='asset_fts'",
    ).get();
    if (tables.isEmpty) {
      return;
    }

    await db.customStatement('UPDATE asset_fts SET labels = ? WHERE asset_id = ?', [labelText, assetId]);
    final existing = await db.customSelect(
      'SELECT rowid FROM asset_fts WHERE asset_id = ?',
      variables: [Variable.withString(assetId)],
    ).get();
    if (existing.isEmpty) {
      await db.customStatement(
        'INSERT INTO asset_fts(asset_id, ocr_text, labels) VALUES (?, ?, ?)',
        [assetId, '', labelText],
      );
    }
  }
}
