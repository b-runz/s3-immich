import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/infrastructure/ml/local_photo_watcher.service.dart';
import 'package:immich_mobile/providers/infrastructure/ml_worker.provider.dart';

final localPhotoWatcherServiceProvider = Provider<LocalPhotoWatcherService>((ref) {
  final mlWorker = ref.watch(mlWorkerServiceProvider);
  final service = LocalPhotoWatcherService(mlWorker);
  ref.onDispose(service.stop);
  service.start();
  return service;
});
