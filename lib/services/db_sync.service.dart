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
    } finally {
      await db.customStatement('DETACH DATABASE remote');
    }
  }
}
