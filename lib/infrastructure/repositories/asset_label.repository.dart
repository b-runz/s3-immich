import 'package:drift/drift.dart';
import 'package:flutter/painting.dart' show Rect;
import 'package:immich_mobile/infrastructure/ml/image_labeler.dart';
import 'package:immich_mobile/infrastructure/ml/label_ml_schema.dart';
import 'package:immich_mobile/infrastructure/repositories/db.repository.dart';

class LabelSummary {
  final String label;
  final int assetCount;
  final String? coverAssetId;
  const LabelSummary({required this.label, required this.assetCount, this.coverAssetId});
}

class AssetLabelRepository {
  final Drift _db;

  AssetLabelRepository(this._db) {
    // ignore: discarded_futures
    LabelMlSchema.ensureSchema(_db);
  }

  Future<List<AssetLabel>> getForAsset(String assetId) async {
    final rows = await _db.customSelect(
      'SELECT label, source, confidence, bbox_x, bbox_y, bbox_w, bbox_h FROM asset_label_entity WHERE asset_id = ? ORDER BY confidence DESC',
      variables: [Variable.withString(assetId)],
    ).get();
    return rows.map(_rowToLabel).toList();
  }

  Future<List<LabelSummary>> getAllLabels({double minConfidence = 0.7}) async {
    final rows = await _db.customSelect(
      '''SELECT label, COUNT(DISTINCT asset_id) AS cnt,
           (SELECT asset_id FROM asset_label_entity l2 WHERE l2.label = l.label ORDER BY rowid DESC LIMIT 1) AS cover_id
         FROM asset_label_entity l WHERE confidence >= ? GROUP BY label ORDER BY cnt DESC''',
      variables: [Variable.withReal(minConfidence)],
    ).get();
    return rows.map((r) => LabelSummary(
      label: r.data['label'] as String,
      assetCount: r.data['cnt'] as int,
      coverAssetId: r.data['cover_id'] as String?,
    )).toList();
  }

  Future<void> replaceLabels(String assetId, List<AssetLabel> labels) async {
    await _db.customStatement('DELETE FROM asset_label_entity WHERE asset_id = ?', [assetId]);
    for (final l in labels) {
      await _db.customStatement(
        'INSERT INTO asset_label_entity (asset_id, label, source, confidence, bbox_x, bbox_y, bbox_w, bbox_h) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
        [assetId, l.label, l.source.name, l.confidence, l.boundingBox?.left, l.boundingBox?.top, l.boundingBox?.width, l.boundingBox?.height],
      );
    }
    await _db.customStatement('UPDATE local_asset_entity SET labels_processed = 1 WHERE id = ?', [assetId]);
    final labelText = labels.map((l) => l.label).join(' ');
    await LabelMlSchema.writeLabels(_db, assetId, labelText);
  }

  Future<bool> isLabelsProcessed(String assetId) async {
    final rows = await _db.customSelect(
      'SELECT labels_processed FROM local_asset_entity WHERE id = ?',
      variables: [Variable.withString(assetId)],
    ).get();
    if (rows.isEmpty) {
      return false;
    }
    return (rows.first.data['labels_processed'] as int? ?? 0) == 1;
  }

  AssetLabel _rowToLabel(QueryRow r) {
    final bx = r.data['bbox_x'] as double?;
    final by = r.data['bbox_y'] as double?;
    final bw = r.data['bbox_w'] as double?;
    final bh = r.data['bbox_h'] as double?;
    return AssetLabel(
      label: r.data['label'] as String,
      confidence: r.data['confidence'] as double,
      source: LabelSource.values.firstWhere(
        (s) => s.name == r.data['source'] as String,
        orElse: () => LabelSource.imageLabeler,
      ),
      boundingBox: (bx != null && by != null && bw != null && bh != null)
          ? Rect.fromLTWH(bx, by, bw, bh) : null,
    );
  }
}
