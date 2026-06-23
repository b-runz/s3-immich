import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';
import 'package:immich_mobile/services/api.service.dart';
import 'package:immich_mobile/infrastructure/local_server/local_api_service.dart';
import 'package:immich_mobile/services/s3/s3_service_provider.dart';

final apiServiceProvider = Provider<ApiService>(
  (ref) => LocalApiService(ref.watch(driftProvider), ref.watch(s3ServiceProvider)),
);
