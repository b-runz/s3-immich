import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:s3mmich/services/s3/s3_service.dart';

final s3ServiceProvider = Provider<S3Service>((ref) {
  throw UnimplementedError('s3ServiceProvider must be overridden in main.dart');
});
