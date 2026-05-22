import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/services/api.service.dart';
import 'package:immich_mobile/infrastructure/local_server/local_api_service.dart';

final apiServiceProvider = Provider<ApiService>((ref) => LocalApiService(ref.watch(driftProvider)));
