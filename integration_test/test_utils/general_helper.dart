import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:s3mmich/entities/store.entity.dart';
import 'package:s3mmich/main.dart' as app;
import 'package:s3mmich/providers/infrastructure/db.provider.dart';
import 'package:s3mmich/utils/bootstrap.dart';
import 'package:integration_test/integration_test.dart';
// ignore: depend_on_referenced_packages
import 'package:meta/meta.dart';

class ImmichTestHelper {
  final WidgetTester tester;

  ImmichTestHelper(this.tester);

  static Future<IntegrationTestWidgetsFlutterBinding> initialize() async {
    final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
    binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

    await app.initApp();

    return binding;
  }

  static Future<void> loadApp(WidgetTester tester) async {
    await EasyLocalization.ensureInitialized();
    final (drift, _) = await Bootstrap.initDomain();
    await Store.clear();
    await tester.pumpWidget(
      ProviderScope(overrides: [driftProvider.overrideWith(driftOverride(drift))], child: const app.MainWidget()),
    );
    await EasyLocalization.ensureInitialized();
  }
}

@isTest
void immichWidgetTest(String description, Future<void> Function(WidgetTester, ImmichTestHelper) test) {
  testWidgets(description, (widgetTester) async {
    await ImmichTestHelper.loadApp(widgetTester);
    await test(widgetTester, ImmichTestHelper(widgetTester));
  }, semanticsEnabled: false);
}

Future<void> pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 120),
}) async {
  bool found = false;
  final timer = Timer(timeout, () => throw TimeoutException("Pump until has timed out"));
  while (found != true) {
    await tester.pump();
    found = tester.any(finder);
  }
  timer.cancel();
}
