import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    // These are in-app widget tests, not tests of the native home-widget host.
    // A missing platform response would trigger fallback offscreen rendering
    // that temporarily owns FlutterError/ErrorWidget during test teardown.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel('home_widget'), (call) async {
        if (call.method == 'getInstalledWidgets') return <dynamic>[];
        return null;
      });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel('home_widget'), null);
  });
  await testMain();
}
