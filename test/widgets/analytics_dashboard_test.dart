import 'package:beecount/data/db.dart';
import 'package:beecount/data/repositories/local/local_repository.dart';
import 'package:beecount/l10n/app_localizations.dart';
import 'package:beecount/models/analytics_dashboard.dart';
import 'package:beecount/pages/transaction/analytics_detail_page.dart';
import 'package:beecount/providers.dart';
import 'package:beecount/services/data/analytics_service.dart';
import 'package:beecount/widgets/analytics/analytics_dashboard_content.dart';
import 'package:beecount/widgets/biz/amount_text.dart';
import 'package:drift/native.dart';
import 'package:drift/drift.dart' as d;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('summary expense and daily average both navigate to scoped expense details', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final db = BeeDatabase.forTesting(NativeDatabase.memory()); final repo = LocalRepository(db);
    final ledger = await repo.createLedger(name: '统计');
    final id = await repo.addTransaction(ledgerId: ledger, type: 'expense', amount: 100,
      happenedAt: DateTime(2026, 11, 2));
    final query = (ledgerId: ledger, scope: AnalyticsScope.week, anchor: DateTime(2026, 11, 5),
      startDay: 1, today: DateTime(2026, 11, 5));
    final data = await AnalyticsService(repo).load(query);
    final container = ProviderContainer(overrides: [repositoryProvider.overrideWithValue(repo),
      databaseProvider.overrideWithValue(db), currentLedgerIdProvider.overrideWith((ref) => ledger)]);
    addTearDown(() async { container.dispose(); await db.close(); });
    await tester.pumpWidget(UncontrolledProviderScope(container: container, child: MaterialApp(
      locale: const Locale('zh'), supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      home: Scaffold(body: SingleChildScrollView(child: AnalyticsDashboardContent(data: data))))));
    await tester.pump();
    for (final metric in [AnalyticsMetric.expense, AnalyticsMetric.dailyExpense]) {
      await tester.ensureVisible(find.byKey(Key('analytics-metric-${metric.name}')));
      await tester.tap(find.byKey(Key('analytics-metric-${metric.name}')));
      await tester.runAsync(() async => Future<void>.delayed(const Duration(milliseconds: 150)));
      await tester.pumpAndSettle();
      final page = tester.widget<AnalyticsDetailPage>(find.byType(AnalyticsDetailPage));
      expect(page.metric, metric); expect(page.query, query);
      expect(find.byKey(const Key('analytics-detail-range')), findsOneWidget);
      expect(data.detail(metric).single.t.id, id);
      await tester.pageBack(); await tester.pumpAndSettle();
    }
    container.read(hideAmountsProvider.notifier).state = true;
    await tester.pump();
    expect(find.byType(AmountText), findsWidgets);
    expect(find.text('****'), findsWidgets);
    await tester.pumpWidget(const SizedBox.shrink()); await tester.pump(const Duration(seconds: 3));
  });
  testWidgets('parent detail route follows unused/new children after refresh', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final db = BeeDatabase.forTesting(NativeDatabase.memory()); final repo = LocalRepository(db);
    final ledger = await repo.createLedger(name: '分类详情');
    final root = await repo.createCategory(name: '固定支出', kind: 'expense');
    final child = await repo.createCategory(name: '水电', kind: 'expense', level: 2, parentId: root);
    final id = await repo.addTransaction(ledgerId: ledger, type: 'expense', amount: 100,
      categoryId: child, happenedAt: DateTime(2026, 11, 2));
    final query = (ledgerId: ledger, scope: AnalyticsScope.week, anchor: DateTime(2026, 11, 5),
      startDay: 1, today: DateTime(2026, 11, 5));
    final data = await AnalyticsService(repo).load(query);
    final container = ProviderContainer(overrides: [repositoryProvider.overrideWithValue(repo),
      databaseProvider.overrideWithValue(db), currentLedgerIdProvider.overrideWith((ref) => ledger)]);
    addTearDown(() async { container.dispose(); await db.close(); });
    await tester.pumpWidget(UncontrolledProviderScope(container: container, child: MaterialApp(
      locale: const Locale('zh'), supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      home: Scaffold(body: SingleChildScrollView(child: AnalyticsCategorySection(data: data, type: 'expense'))))));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('analytics-group-expense-$root'))); await tester.pumpAndSettle();
    final label = AppLocalizations.of(tester.element(find.byType(AnalyticsCategorySection))).insightsViewDetails;
    await tester.tap(find.text(label));
    await tester.runAsync(() async => Future<void>.delayed(const Duration(milliseconds: 150)));
    await tester.pumpAndSettle();
    final page = tester.widget<AnalyticsDetailPage>(find.byType(AnalyticsDetailPage));
    expect(page.categoryIds, isNull);
    expect(page.categoryFilter!.id, root); expect(page.categoryFilter!.includeDescendants, true);
    expect(find.byKey(ValueKey('tx-$id')), findsOneWidget);
    await tester.runAsync(() async {
      final added = await repo.createCategory(name: '网络', kind: 'expense', level: 2, parentId: root);
      await (db.update(db.transactions)..where((t) => t.id.equals(id))).write(
        TransactionsCompanion(categoryId: d.Value(added)));
    });
    container.read(statsRefreshProvider.notifier).state++;
    await tester.runAsync(() async => Future<void>.delayed(const Duration(milliseconds: 150)));
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('tx-$id')), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink()); await tester.pump(const Duration(seconds: 3));
  });

}
