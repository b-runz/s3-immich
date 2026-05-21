import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/infrastructure/repositories/storage.repository.dart';
import 'package:immich_mobile/services/s3/s3_service_provider.dart';

final storageRepositoryProvider = Provider<StorageRepository>((ref) {
  final s3 = ref.watch(s3ServiceProvider);
  return StorageRepository(s3Service: s3);
});
