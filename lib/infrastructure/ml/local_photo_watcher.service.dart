import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:logging/logging.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:s3mmich/infrastructure/ml/ml_worker.service.dart';

class LocalPhotoWatcherService {
  final MlWorkerService _mlWorker;
  final Logger _log = Logger('LocalPhotoWatcherService');

  final DateTime? _initialCutoff;
  DateTime? _lastChecked;
  bool _watching = false;

  LocalPhotoWatcherService(this._mlWorker, {DateTime? initialCutoff})
      : _initialCutoff = initialCutoff;

  void start() {
    if (_watching) {
      return;
    }
    _watching = true;
    _lastChecked = _initialCutoff ?? DateTime.now();
    PhotoManager.addChangeCallback(_onGalleryChange);
    PhotoManager.startChangeNotify();
  }

  void stop() {
    if (!_watching) {
      return;
    }
    _watching = false;
    PhotoManager.removeChangeCallback(_onGalleryChange);
    PhotoManager.stopChangeNotify();
  }

  Future<void> _onGalleryChange(MethodCall call) async {
    await _processNewPhotos();
  }

  Future<void> _processNewPhotos() async {
    final since = _lastChecked ?? DateTime.now().subtract(const Duration(minutes: 5));
    _lastChecked = DateTime.now();

    List<AssetPathEntity> albums;
    try {
      albums = await PhotoManager.getAssetPathList(type: RequestType.image);
    } catch (e, st) {
      _log.warning('Failed to list photo albums', e, st);
      return;
    }

    for (final album in albums) {
      final count = await album.assetCountAsync;
      if (count == 0) {
        continue;
      }
      final assets = await album.getAssetListRange(start: 0, end: count);
      for (final entity in assets) {
        if (!entity.createDateTime.isAfter(since)) {
          continue;
        }
        await _handleNewAsset(entity);
      }
    }
  }

  Future<void> _handleNewAsset(AssetEntity entity) async {
    final File? file;
    try {
      file = await entity.originFile;
    } catch (e, st) {
      _log.warning('Failed to get origin file for ${entity.id}', e, st);
      return;
    }
    if (file == null) {
      return;
    }

    _mlWorker.enqueue(entity.id, file);
    unawaited(_mlWorker.start());
  }
}
