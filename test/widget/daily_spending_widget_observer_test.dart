import 'dart:convert';

import 'package:beecount/data/db.dart';
import 'package:beecount/data/repositories/local/local_repository.dart';
import 'package:beecount/providers.dart';
import 'package:beecount/widget/daily_spending_widget_observer.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  testWidgets('explicit attach publishes an already-ready app without a provider update', (tester) async {
    final db = BeeDatabase.forTesting(NativeDatabase.memory());
    final repo = LocalRepository(db);
    await db.customStatement("INSERT INTO ledgers (id, name, currency) VALUES (501, 'L', 'CNY')");
    final published = <Map<String, dynamic>>[];
    final observer = DailySpendingWidgetObserver(supported: true, publish: (text) async {
      published.add(jsonDecode(text) as Map<String, dynamic>);
    });
    final container = ProviderContainer(observers: [observer], overrides: [
      repositoryProvider.overrideWithValue(repo),
      currentLedgerIdProvider.overrideWith((ref) => 501),
      appInitStateProvider.overrideWith((ref) => AppInitState.ready),
    ]);
    addTearDown(() async { observer.dispose(); container.dispose(); await db.close(); });
    // Seed before attaching. didUpdateProvider is not guaranteed on this path.
    expect(container.read(appInitStateProvider), AppInitState.ready);
    observer.attach(container);
    await tester.runAsync(DailySpendingWidgetObserver.refreshNow);
    expect(published, isNotEmpty);
    expect(published.last['ledgerId'], 501);
    expect(published.last['locale'], 'zh_CN');
    expect(published.last['days'], hasLength(7));
    expect(container.read(dailySpendingWidgetStatusProvider), contains('回读校验'));
  });

  testWidgets('publishes on ready and retries after a denied shared write', (tester) async {
    final db = BeeDatabase.forTesting(NativeDatabase.memory());
    final repo = LocalRepository(db);
    await db.customStatement("INSERT INTO ledgers (id, name, currency) VALUES (502, 'L', 'CNY')");
    var deny = true;
    var count = 0;
    final observer = DailySpendingWidgetObserver(supported: true, publish: (_) async {
      if (deny) throw StateError('permission denied');
      count++;
    });
    final container = ProviderContainer(observers: [observer], overrides: [
      repositoryProvider.overrideWithValue(repo),
      currentLedgerIdProvider.overrideWith((ref) => 502),
    ]);
    addTearDown(() async { observer.dispose(); container.dispose(); await db.close(); });
    observer.attach(container);
    await tester.runAsync(() async {
      await expectLater(DailySpendingWidgetObserver.refreshNow(), throwsStateError);
    });
    expect(count, 0);
    container.read(appInitStateProvider.notifier).state = AppInitState.ready;
    await tester.runAsync(() async {
      await expectLater(DailySpendingWidgetObserver.refreshNow(), throwsStateError);
    });
    expect(container.read(dailySpendingWidgetStatusProvider), contains('刷新失败'));
    deny = false;
    await tester.runAsync(DailySpendingWidgetObserver.refreshNow);
    expect(count, greaterThan(0));
  });

  testWidgets('deleted ledger invalidates snapshot instead of keeping old amounts', (tester) async {
    final db = BeeDatabase.forTesting(NativeDatabase.memory());
    final repo = LocalRepository(db);
    final payloads = <Map<String, dynamic>>[];
    final observer = DailySpendingWidgetObserver(supported: true, publish: (text) async {
      payloads.add(jsonDecode(text) as Map<String, dynamic>);
    });
    final container = ProviderContainer(observers: [observer], overrides: [
      repositoryProvider.overrideWithValue(repo),
      currentLedgerIdProvider.overrideWith((ref) => 999),
      appInitStateProvider.overrideWith((ref) => AppInitState.ready),
    ]);
    addTearDown(() async { observer.dispose(); container.dispose(); await db.close(); });
    observer.attach(container);
    await tester.runAsync(DailySpendingWidgetObserver.refreshNow);
    expect(payloads.last, {'status': 'noLedger'});
    expect(container.read(dailySpendingWidgetStatusProvider), contains('账本不可用'));
  });
}
