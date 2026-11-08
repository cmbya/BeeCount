import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Drift I/O runs in real time while widget tests use a fake frame clock.
/// Alternate both clocks until the requested lazy row/provider result exists.
Future<void> pumpUntilFound(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 50; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 50));
    if (finder.evaluate().isNotEmpty) return;
  }
  debugDumpApp();
  expect(finder, findsWidgets, reason: 'Expected UI after bounded asynchronous settling');
}

Future<void> revealRow(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(finder, 200,
    scrollable: find.byType(Scrollable).last, maxScrolls: 30);
  await tester.pumpAndSettle();
}
