import 'dart:async';
import 'dart:io';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/events.model.dart';
import 'package:immich_mobile/domain/utils/event_stream.dart';
import 'package:immich_mobile/extensions/network_capability_extensions.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/extensions/translate_extensions.dart';
import 'package:immich_mobile/infrastructure/repositories/backup.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/storage.repository.dart';
import 'package:immich_mobile/platform/connectivity_api.g.dart';
import 'package:immich_mobile/providers/infrastructure/platform.provider.dart';
import 'package:immich_mobile/providers/infrastructure/storage.provider.dart';
import 'package:immich_mobile/repositories/asset_media.repository.dart';
import 'package:immich_mobile/repositories/upload.repository.dart' show UploadResult;
import 'package:immich_mobile/services/s3/s3_service.dart';
import 'package:immich_mobile/services/s3/s3_service_provider.dart';
import 'package:immich_mobile/infrastructure/ml/ml_worker.service.dart';
import 'package:immich_mobile/providers/infrastructure/ml_worker.provider.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:photo_manager/photo_manager.dart' show PMProgressHandler;

/// Callbacks for upload progress and status updates
class UploadCallbacks {
  final void Function(String id, String filename, int bytes, int totalBytes)? onProgress;
  final void Function(String localId, String remoteId)? onSuccess;
  final void Function(String id, String errorMessage)? onError;
  final void Function(String id, double progress)? onICloudProgress;

  const UploadCallbacks({this.onProgress, this.onSuccess, this.onError, this.onICloudProgress});
}

final foregroundUploadServiceProvider = Provider((ref) {
  return ForegroundUploadService(
    ref.watch(storageRepositoryProvider),
    ref.watch(backupRepositoryProvider),
    ref.watch(connectivityApiProvider),
    ref.watch(assetMediaRepositoryProvider),
    ref.watch(s3ServiceProvider),
    ref.watch(mlWorkerServiceProvider),
  );
});

/// Service for handling foreground HTTP uploads
///
/// This service handles synchronous uploads using HTTP client with
/// concurrent worker pools. Used for manual backups, auto backups
/// (foreground mode), and share intent uploads.
class ForegroundUploadService {
  ForegroundUploadService(
    this._storageRepository,
    this._backupRepository,
    this._connectivityApi,
    this._assetMediaRepository,
    this._s3Service,
    this._mlWorker,
  );

  final StorageRepository _storageRepository;
  final DriftBackupRepository _backupRepository;
  final ConnectivityApi _connectivityApi;
  final AssetMediaRepository _assetMediaRepository;
  final S3Service _s3Service;
  final MlWorkerService _mlWorker;
  final Logger _logger = Logger('ForegroundUploadService');

  bool shouldAbortUpload = false;

  Future<({int total, int remainder, int processing})> getBackupCounts(String userId) {
    return _backupRepository.getAllCounts(userId);
  }

  Future<List<LocalAsset>> getBackupCandidates(String userId, {bool onlyHashed = true}) {
    return _backupRepository.getCandidates(userId, onlyHashed: onlyHashed);
  }

  /// Bulk upload of backup candidates from selected albums
  Future<void> uploadCandidates(
    String userId,
    Completer<void> cancelToken, {
    UploadCallbacks callbacks = const UploadCallbacks(),
    bool useSequentialUpload = false,
  }) async {
    final candidates = await _backupRepository.getCandidates(userId);
    if (candidates.isEmpty) {
      return;
    }

    final networkCapabilities = await _connectivityApi.getCapabilities();
    final hasWifi = networkCapabilities.isUnmetered;
    _logger.info('Network capabilities: $networkCapabilities, hasWifi/isUnmetered: $hasWifi');

    if (useSequentialUpload) {
      await _uploadSequentially(items: candidates, cancelToken: cancelToken, hasWifi: hasWifi, callbacks: callbacks, ownerId: userId);
    } else {
      await _executeWithWorkerPool<LocalAsset>(
        items: candidates,
        cancelToken: cancelToken,
        shouldSkip: (asset) {
          final requireWifi = _shouldRequireWiFi(asset);
          return requireWifi && !hasWifi;
        },
        processItem: (asset) => _uploadSingleAsset(asset, cancelToken, ownerId: userId, callbacks: callbacks),
      );
    }
  }

  /// Sequential upload - used for background isolate where concurrent HTTP clients may cause issues
  Future<void> _uploadSequentially({
    required List<LocalAsset> items,
    required Completer<void> cancelToken,
    required bool hasWifi,
    required UploadCallbacks callbacks,
    required String ownerId,
  }) async {
    await _storageRepository.clearCache();
    shouldAbortUpload = false;

    for (final asset in items) {
      if (shouldAbortUpload || cancelToken.isCompleted) {
        break;
      }

      final requireWifi = _shouldRequireWiFi(asset);
      if (requireWifi && !hasWifi) {
        _logger.warning('Skipping upload for ${asset.id} because it requires WiFi');
        continue;
      }

      await _uploadSingleAsset(asset, cancelToken, ownerId: ownerId, callbacks: callbacks);
    }
  }

  /// Manually upload picked local assets
  Future<void> uploadManual(
    List<LocalAsset> localAssets, {
    required String ownerId,
    Completer<void>? cancelToken,
    UploadCallbacks callbacks = const UploadCallbacks(),
  }) async {
    if (localAssets.isEmpty) {
      return;
    }

    await _executeWithWorkerPool<LocalAsset>(
      items: localAssets,
      cancelToken: cancelToken,
      processItem: (asset) => _uploadSingleAsset(asset, cancelToken, ownerId: ownerId, callbacks: callbacks),
    );
  }

  /// Upload files from shared intent
  Future<void> uploadShareIntent(
    List<File> files, {
    Completer<void>? cancelToken,
    void Function(String fileId, int bytes, int totalBytes)? onProgress,
    void Function(String fileId)? onSuccess,
    void Function(String fileId, String errorMessage)? onError,
  }) async {
    if (files.isEmpty) {
      return;
    }
    await _executeWithWorkerPool<File>(
      items: files,
      cancelToken: cancelToken,
      processItem: (file) async {
        final fileId = p.hash(file.path).toString();

        final result = await _uploadSingleFile(
          file,
          deviceAssetId: fileId,
          cancelToken: cancelToken,
          onProgress: (bytes, totalBytes) => onProgress?.call(fileId, bytes, totalBytes),
        );

        if (result.isSuccess) {
          onSuccess?.call(fileId);
        } else if (!result.isCancelled && result.errorMessage != null) {
          onError?.call(fileId, result.errorMessage!);
        }
      },
    );
  }

  void cancel() {
    shouldAbortUpload = true;
  }

  /// Generic worker pool for concurrent uploads
  ///
  /// [items] - List of items to process
  /// [cancelToken] - Token to cancel the operation
  /// [processItem] - Function to process each item with an HTTP client
  /// [shouldSkip] - Optional function to skip items (e.g., WiFi requirement check)
  /// [concurrentWorkers] - Number of concurrent workers (default: 3)
  Future<void> _executeWithWorkerPool<T>({
    required List<T> items,
    required Completer<void>? cancelToken,
    required Future<void> Function(T item) processItem,
    bool Function(T item)? shouldSkip,
    int concurrentWorkers = 3,
  }) async {
    await _storageRepository.clearCache();
    shouldAbortUpload = false;

    int currentIndex = 0;

    Future<void> worker() async {
      while (true) {
        if (shouldAbortUpload || (cancelToken != null && cancelToken.isCompleted)) {
          break;
        }

        final index = currentIndex;
        if (index >= items.length) {
          break;
        }
        currentIndex++;

        final item = items[index];

        if (shouldSkip?.call(item) ?? false) {
          continue;
        }

        await processItem(item);
      }
    }

    final workerFutures = <Future<void>>[];
    for (int i = 0; i < concurrentWorkers; i++) {
      workerFutures.add(worker());
    }

    await Future.wait(workerFutures);
  }

  Future<void> _uploadSingleAsset(
    LocalAsset asset,
    Completer<void>? cancelToken, {
    required String ownerId,
    required UploadCallbacks callbacks,
  }) async {
    File? file;
    File? livePhotoFile;

    try {
      final entity = await _storageRepository.getAssetEntityForAsset(asset);
      if (entity == null) {
        callbacks.onError?.call(
          asset.localId!,
          CurrentPlatform.isAndroid ? "asset_not_found_on_device_android".t() : "asset_not_found_on_device_ios".t(),
        );
        return;
      }

      final isAvailableLocally = await _storageRepository.isAssetAvailableLocally(asset.id);

      if (!isAvailableLocally && CurrentPlatform.isIOS) {
        _logger.info("Loading iCloud asset ${asset.id} - ${asset.name}");

        // Create progress handler for iCloud download
        PMProgressHandler? progressHandler;
        StreamSubscription? progressSubscription;

        progressHandler = PMProgressHandler();
        progressSubscription = progressHandler.stream.listen((event) {
          callbacks.onICloudProgress?.call(asset.localId!, event.progress);
        });

        try {
          file = await _storageRepository.loadFileFromCloud(asset.id, progressHandler: progressHandler);
          if (entity.isLivePhoto) {
            livePhotoFile = await _storageRepository.loadMotionFileFromCloud(
              asset.id,
              progressHandler: progressHandler,
            );
          }
        } finally {
          await progressSubscription.cancel();
        }
      } else {
        // Get files locally
        file = await _storageRepository.getFileForAsset(asset.id);
        if (file == null) {
          _logger.warning("Failed to get file ${asset.id} - ${asset.name}");
          callbacks.onError?.call(
            asset.localId!,
            CurrentPlatform.isAndroid ? "asset_not_found_on_device_android".t() : "asset_not_found_on_device_ios".t(),
          );
          return;
        }

        // For live photos, get the motion video file
        if (entity.isLivePhoto) {
          livePhotoFile = await _storageRepository.getMotionFileForAsset(asset);
          if (livePhotoFile == null) {
            _logger.warning("Failed to obtain motion part of the livePhoto - ${asset.name}");
            callbacks.onError?.call(
              asset.localId!,
              CurrentPlatform.isAndroid ? "asset_not_found_on_device_android".t() : "asset_not_found_on_device_ios".t(),
            );
          }
        }
      }

      if (file == null) {
        _logger.warning("Failed to obtain file from iCloud for asset ${asset.id} - ${asset.name}");
        callbacks.onError?.call(asset.localId!, "asset_not_found_on_icloud".t());
        return;
      }

      String fileName = await _assetMediaRepository.getOriginalFilename(asset.id) ?? asset.name;

      /// Handle special file name from DJI or Fusion app
      /// If the file name has no extension, likely due to special renaming template by specific apps
      /// we append the original extension from the asset name
      final hasExtension = p.extension(fileName).isNotEmpty;
      if (!hasExtension) {
        fileName = p.setExtension(fileName, p.extension(asset.name));
      }

      final originalFileName = entity.isLivePhoto ? p.setExtension(fileName, p.extension(file.path)) : fileName;

      if (cancelToken?.isCompleted == true) {
        shouldAbortUpload = true;
        return;
      }

      // Upload live photo video if available
      if (entity.isLivePhoto && livePhotoFile != null) {
        final livePhotoTitle = p.setExtension(originalFileName, p.extension(livePhotoFile.path));
        final videoS3Key = _s3Service.currentConfig!.s3KeyFor(livePhotoTitle, asset.createdAt);
        try {
          await _s3Service.putFile(videoS3Key, livePhotoFile.path);
        } catch (e) {
          _logger.warning('Live photo video upload failed for ${asset.localId}: $e');
        }
      }

      final s3Key = _s3Service.currentConfig!.s3KeyFor(originalFileName, asset.createdAt);
      await _s3Service.putFile(s3Key, file.path);

      // Prefer GPS from local_asset_entity; fall back to reading from AssetEntity
      // (needed when local sync ran before the native GPS fix was deployed).
      var uploadedAsset = asset;
      if (asset.latitude == null || asset.longitude == null) {
        final latlng = await entity.latlngAsync();
        if (latlng != null) {
          uploadedAsset = asset.copyWith(latitude: latlng.latitude, longitude: latlng.longitude);
        }
      }

      await _backupRepository.markAsBackedUp(uploadedAsset, s3Key, ownerId);
      if (uploadedAsset.latitude != null && uploadedAsset.longitude != null) {
        EventStream.shared.emit(const MapMarkerReloadEvent());
      }
      // Enqueue for on-device ML (labels, faces, OCR) while the file is still on disk.
      _mlWorker.enqueue(asset.localId!, file);
      unawaited(_mlWorker.start());
      callbacks.onSuccess?.call(asset.localId!, s3Key);
    } catch (error, stackTrace) {
      _logger.severe(() => "Error backup asset: ${error.toString()}", stackTrace);
      callbacks.onError?.call(asset.localId!, error.toString());
    } finally {
      if (Platform.isIOS) {
        try {
          await file?.delete();
          await livePhotoFile?.delete();
        } catch (error, stackTrace) {
          _logger.severe(() => "ERROR deleting file: ${error.toString()}", stackTrace);
        }
      }
    }
  }

  Future<UploadResult> _uploadSingleFile(
    File file, {
    required String deviceAssetId,
    required Completer<void>? cancelToken,
    void Function(int bytes, int totalBytes)? onProgress,
  }) async {
    try {
      final stats = await file.stat();
      final filename = p.basename(file.path);
      final s3Key = _s3Service.currentConfig!.s3KeyFor(filename, stats.changed);
      await _s3Service.putFile(s3Key, file.path);
      return UploadResult.success(remoteAssetId: s3Key);
    } catch (e) {
      return UploadResult.error(errorMessage: e.toString());
    }
  }

  bool _shouldRequireWiFi(LocalAsset asset) {
    final backup = SettingsRepository.instance.appConfig.backup;
    if (asset.isVideo && backup.useCellularForVideos) {
      return false;
    }
    if (!asset.isVideo && backup.useCellularForPhotos) {
      return false;
    }
    return true;
  }
}
