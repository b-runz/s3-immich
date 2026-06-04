import 'dart:io';

import 'package:drift/drift.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/services/s3/s3_service.dart';

class DbSyncService {
  final S3Service _s3Service;
  final String _dbPath;
  final DatabaseConnectionUser? _db;
  DateTime? _lastSyncTime;

  static const _remoteKey = '.meta/s3immich.db';

  static DbSyncService? instance;

  DbSyncService({
    required S3Service s3Service,
    required String dbPath,
    DatabaseConnectionUser? db,
  })  : _s3Service = s3Service,
        _dbPath = dbPath,
        _db = db;

  void setLastSyncTime(DateTime t) => _lastSyncTime = t;

  Future<void> push() async {
    await _s3Service.putFile(_remoteKey, _dbPath);
    _lastSyncTime = DateTime.now().toUtc();
  }

  Future<void> pull() async {
    final meta = await _s3Service.headObject(_remoteKey);
    if (meta == null) return;
    if (_lastSyncTime != null && !meta.lastModified.isAfter(_lastSyncTime!)) return;

    final remoteBytes = await _s3Service.getObject(_remoteKey);
    if (_db != null) {
      final tempPath = '$_dbPath.remote_tmp';
      final tempFile = File(tempPath);
      await tempFile.writeAsBytes(remoteBytes);
      await _mergeRemoteDb(tempPath);
      await tempFile.delete();
    }
    _lastSyncTime = meta.lastModified;
  }

  Future<void> _mergeRemoteDb(String remotePath) async {
    final db = _db;
    if (db == null) return;
    await db.customStatement("ATTACH DATABASE '$remotePath' AS remote");
    try {
      await db.customStatement(
        'INSERT OR REPLACE INTO remote_asset_entity SELECT * FROM remote.remote_asset_entity',
      );
      await db.customStatement(
        'INSERT OR REPLACE INTO remote_exif_entity SELECT * FROM remote.remote_exif_entity',
      );
      await db.customStatement(
        'INSERT OR IGNORE INTO remote_album_entity SELECT * FROM remote.remote_album_entity',
      );
      // Restore s3 credentials if the local DB has none (e.g. after a Keystore wipe).
      await db.customStatement(
        'INSERT OR IGNORE INTO store_entity SELECT * FROM remote.store_entity WHERE id = ${StoreKey.s3ConfigJson.id}',
      );

      // Merge ML search index — ensure local tables exist first, then sync from remote.
      await db.customStatement('''
        CREATE VIRTUAL TABLE IF NOT EXISTS asset_fts USING fts5(
          asset_id UNINDEXED,
          ocr_text,
          labels,
          tokenize = 'unicode61'
        )
      ''');
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
      // FTS: delete+insert so updated OCR/labels replace stale entries.
      try {
        await db.customStatement(
          'DELETE FROM asset_fts WHERE asset_id IN (SELECT asset_id FROM remote.asset_fts)',
        );
        await db.customStatement(
          'INSERT INTO asset_fts(asset_id, ocr_text, labels) '
          'SELECT asset_id, ocr_text, labels FROM remote.asset_fts',
        );
      } catch (_) {}
      try {
        await db.customStatement(
          'INSERT OR IGNORE INTO asset_label_entity'
          '(asset_id, label, source, confidence, bbox_x, bbox_y, bbox_w, bbox_h) '
          'SELECT asset_id, label, source, confidence, bbox_x, bbox_y, bbox_w, bbox_h '
          'FROM remote.asset_label_entity',
        );
      } catch (_) {}
    } finally {
      await db.customStatement('DETACH DATABASE remote');
    }
  }
}
