import 'package:auto_route/auto_route.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/services/s3/s3_service_provider.dart';
import 'package:immich_mobile/routing/router.dart';

class S3ConfigGuard extends AutoRouteGuard {
  final Ref _ref;
  S3ConfigGuard(this._ref);

  @override
  void onNavigation(NavigationResolver resolver, StackRouter router) {
    final s3 = _ref.read(s3ServiceProvider);
    if (s3.isConfigured) {
      resolver.next(true);
    } else {
      resolver.next(false);
      router.push(const S3SetupRoute());
    }
  }
}
