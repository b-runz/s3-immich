import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/services/s3/s3_service.dart';

class DbSyncService {
  final S3Service _s3Service;
  final String _dbPath;
  final DatabaseConnectionUser? _db;
  DateTime? _lastSyncTime;

  static const _remoteKey = '.meta/s3immich.db';
  static const _statusKey = '.meta/db-status.json';

  static DbSyncService? instance;

  bool _isPulling = false;

  DbSyncService({
    required S3Service s3Service,
    required String dbPath,
    DatabaseConnectionUser? db,
  })  : _s3Service = s3Service,
        _dbPath = dbPath,
        _db = db;

  void setLastSyncTime(DateTime t) => _lastSyncTime = t;

  Future<void> push() async {
    // Always merge remote rows first so we never overwrite S3 with a subset.
    try {
      await pull();
    } catch (_) {}
    await _s3Service.putFile(_remoteKey, _dbPath);
    final now = DateTime.now().toUtc();
    _lastSyncTime = now;
    // Write locale-independent status file so pull() on any locale can compare
    // timestamps without relying on the minio Last-Modified DateFormat parser.
    try {
      final ms = now.millisecondsSinceEpoch;
      final statusJson = utf8.encode('{"lastModified":$ms}');
      await _s3Service.putObject(
        _statusKey,
        Uint8List.fromList(statusJson),
        contentType: 'application/json',
      );
    } catch (_) {}
  }

  Future<void> pull() async {
    if (_isPulling) return;
    _isPulling = true;
    try {
      // Read the locale-independent status file to compare timestamps.
      // Falls through gracefully on first run or if the file doesn't exist yet.
      DateTime? remoteModified;
      try {
        final statusBytes = await _s3Service.getObject(_statusKey);
        final statusJson = utf8.decode(statusBytes is Uint8List
            ? statusBytes
            : Uint8List.fromList(statusBytes));
        final decoded = jsonDecode(statusJson) as Map<String, dynamic>;
        final ms = decoded['lastModified'];
        if (ms is int) {
          remoteModified = DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
        }
      } catch (_) {}

      if (remoteModified != null &&
          _lastSyncTime != null &&
          !remoteModified.isAfter(_lastSyncTime!)) {
        return;
      }

      final remoteBytes = await _s3Service.getObject(_remoteKey);
      if (_db != null) {
        final tempPath = '$_dbPath.remote_tmp';
        final tempFile = File(tempPath);
        await tempFile.writeAsBytes(remoteBytes);
        await _mergeRemoteDb(tempPath);
        await tempFile.delete();
      }
      _lastSyncTime = remoteModified ?? DateTime.now().toUtc();
    } catch (e, st) {
      rethrow;
    } finally {
      _isPulling = false;
    }
  }

  Future<void> _mergeRemoteDb(String remotePath) async {
    final db = _db;
    if (db == null) return;
    await db.customStatement("ATTACH DATABASE '$remotePath' AS remote");
    try {
      // Explicit column list + typeof()-based conversion handles two remote DB
      // formats: migration tool (INTEGER epoch-ms) and phone-pushed (TEXT ISO-8601).
      await db.customStatement('''
        INSERT OR REPLACE INTO remote_asset_entity
          (id, name, type, created_at, updated_at, width, height, duration_ms,
           checksum, is_favorite, owner_id, local_date_time, thumb_hash,
           deleted_at, uploaded_at, live_photo_video_id, visibility,
           stack_id, library_id, is_edited, source_device_id)
        SELECT
          id, name, type,
          CASE WHEN typeof(created_at) = 'integer'
               THEN strftime('%Y-%m-%dT%H:%M:%S.000Z', created_at/1000, 'unixepoch')
               ELSE created_at END,
          CASE WHEN typeof(updated_at) = 'integer'
               THEN strftime('%Y-%m-%dT%H:%M:%S.000Z', updated_at/1000, 'unixepoch')
               ELSE updated_at END,
          width, height, duration_ms, checksum, is_favorite, owner_id,
          CASE WHEN local_date_time IS NULL THEN NULL
               WHEN typeof(local_date_time) = 'integer'
               THEN strftime('%Y-%m-%dT%H:%M:%S.000Z', local_date_time/1000, 'unixepoch')
               ELSE local_date_time END,
          thumb_hash,
          CASE WHEN deleted_at IS NULL THEN NULL
               WHEN typeof(deleted_at) = 'integer'
               THEN strftime('%Y-%m-%dT%H:%M:%S.000Z', deleted_at/1000, 'unixepoch')
               ELSE deleted_at END,
          CASE WHEN uploaded_at IS NULL THEN NULL
               WHEN typeof(uploaded_at) = 'integer'
               THEN strftime('%Y-%m-%dT%H:%M:%S.000Z', uploaded_at/1000, 'unixepoch')
               ELSE uploaded_at END,
          live_photo_video_id, visibility, stack_id, library_id, is_edited, source_device_id
        FROM remote.remote_asset_entity
      ''');
      await db.customStatement('''
        INSERT OR REPLACE INTO remote_exif_entity
          (asset_id, city, state, country, date_time_original, description,
           height, width, exposure_time, f_number, file_size, focal_length,
           latitude, longitude, iso, make, model, lens, orientation,
           time_zone, rating, projection_type)
        SELECT
          asset_id, city, state, country,
          CASE WHEN date_time_original IS NULL THEN NULL
               WHEN typeof(date_time_original) = 'integer'
               THEN strftime('%Y-%m-%dT%H:%M:%S.000Z', date_time_original/1000, 'unixepoch')
               ELSE date_time_original END,
          description, height, width, exposure_time, f_number, file_size,
          focal_length, latitude, longitude, iso, make, model, lens,
          orientation, time_zone, rating, projection_type
        FROM remote.remote_exif_entity
      ''');
      try {
        await db.customStatement('''
          INSERT OR REPLACE INTO remote_album_entity
            (id, name, description, created_at, updated_at,
             thumbnail_asset_id, is_activity_enabled, "order")
          SELECT
            id, name, description,
            CASE WHEN typeof(created_at) = 'integer'
                 THEN strftime('%Y-%m-%dT%H:%M:%S.000Z', created_at/1000, 'unixepoch')
                 ELSE created_at END,
            CASE WHEN typeof(updated_at) = 'integer'
                 THEN strftime('%Y-%m-%dT%H:%M:%S.000Z', updated_at/1000, 'unixepoch')
                 ELSE updated_at END,
            thumbnail_asset_id, is_activity_enabled, "order"
          FROM remote.remote_album_entity
        ''');
        await db.customStatement(
          'INSERT OR IGNORE INTO remote_album_asset_entity SELECT * FROM remote.remote_album_asset_entity',
        );
        await db.customStatement(
          'INSERT OR REPLACE INTO remote_album_user_entity SELECT * FROM remote.remote_album_user_entity',
        );
      } catch (_) {}
      // Restore s3 credentials if the local DB has none (e.g. after a Keystore wipe).
      try {
        await db.customStatement(
          'INSERT OR IGNORE INTO store_entity SELECT * FROM remote.store_entity WHERE id = ${StoreKey.s3ConfigJson.id}',
        );
      } catch (_) {}

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
