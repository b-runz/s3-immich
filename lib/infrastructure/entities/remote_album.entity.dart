import 'package:drift/drift.dart';
import 'package:immich_mobile/domain/models/album/album.model.dart';
import 'package:immich_mobile/infrastructure/entities/remote_asset.entity.dart';
import 'package:immich_mobile/infrastructure/utils/drift_default.mixin.dart';

/// Handles epoch-ms strings (from S3 importer) and ISO8601 strings (Drift default).
class EpochOrIsoConverter extends TypeConverter<DateTime, String> {
  const EpochOrIsoConverter();

  @override
  DateTime fromSql(String fromDb) {
    final epochMs = int.tryParse(fromDb);
    if (epochMs != null) {
      return DateTime.fromMillisecondsSinceEpoch(epochMs, isUtc: true);
    }
    return DateTime.parse(fromDb);
  }

  @override
  String toSql(DateTime value) => value.toUtc().toIso8601String();
}

class RemoteAlbumEntity extends Table with DriftDefaultsMixin {
  const RemoteAlbumEntity();

  TextColumn get id => text()();

  TextColumn get name => text()();

  TextColumn get description => text().withDefault(const Constant(''))();

  TextColumn get createdAt => text().map(const EpochOrIsoConverter())();

  TextColumn get updatedAt => text().map(const EpochOrIsoConverter())();

  TextColumn get thumbnailAssetId =>
      text().references(RemoteAssetEntity, #id, onDelete: KeyAction.setNull).nullable()();

  BoolColumn get isActivityEnabled => boolean().withDefault(const Constant(true))();

  IntColumn get order => intEnum<AlbumAssetOrder>()();

  @override
  Set<Column> get primaryKey => {id};
}
