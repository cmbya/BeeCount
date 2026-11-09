import 'package:beecount/data/repositories/budget_repository.dart';
import 'package:beecount/l10n/app_localizations.dart';
import 'package:beecount/providers.dart';
import 'package:beecount/providers/budget_providers.dart';
import 'package:beecount/providers/home_summary_providers.dart';
import 'package:beecount/widgets/biz/home_monthly_summary.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('left swipe changes expense to income to budget without moving list', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final key = (ledgerId: 1, month: DateTime(2026, 11));
    final c = ProviderContainer(overrides: [
      currentLedgerIdProvider.overrideWith((ref) => 1),
      selectedMonthProvider.overrideWith((ref) => key.month),
      homeMonthlySummaryProvider(key).overrideWith((ref) async => HomeMonthlySummaryData(
        income: 100, expense: 40, currency: 'CNY',
        budget: BudgetUsage(used: 30, budget: 200), dailyAvailable: 10)),
    ]);
    addTearDown(c.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(container: c,
      child: MaterialApp(locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(body: Column(children: [HomeMonthlySummary(),
          Expanded(child: Center(child: Text('transaction-list-marker')))]))),
    ));
    await tester.pumpAndSettle();
    final pager = find.byKey(const Key('home-summary-pager'));
    expect(tester.widget<PageView>(pager).reverse, isFalse);
    final listPosition = tester.getTopLeft(find.text('transaction-list-marker'));
    expect(find.byKey(const ValueKey('home-summary-amount-0')).hitTestable(), findsOneWidget);
    await tester.drag(pager, const Offset(-400, 0));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('home-summary-amount-1')).hitTestable(), findsOneWidget);
    await tester.drag(pager, const Offset(-400, 0));
    await tester.pumpAndSettle();
    expect(find.text('剩余月预算').hitTestable(), findsOneWidget);
    expect(find.byKey(const ValueKey('home-summary-amount-2')).hitTestable(), findsOneWidget);
    expect(tester.getTopLeft(find.text('transaction-list-marker')), listPosition);
    // Swiping right goes back without changing the logical card order.
    await tester.drag(pager, const Offset(400, 0));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('home-summary-amount-1')).hitTestable(), findsOneWidget);
    await tester.drag(pager, const Offset(-400, 0));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('home-summary-amount-2')).hitTestable(), findsOneWidget);
    c.read(hideAmountsProvider.notifier).state = true;
    await tester.pumpAndSettle();
    expect(find.text('****').hitTestable(), findsWidgets);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('no budget shows setup instead of invented zero; setting hides budget page', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final key = (ledgerId: 1, month: DateTime(2026, 11));
    final c = ProviderContainer(overrides: [
      currentLedgerIdProvider.overrideWith((ref) => 1),
      selectedMonthProvider.overrideWith((ref) => key.month),
      homeMonthlySummaryProvider(key).overrideWith((ref) async =>
        const HomeMonthlySummaryData(income: 0, expense: 0, currency: 'CNY')),
    ]);
    addTearDown(c.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(container: c,
      child: MaterialApp(locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(body: HomeMonthlySummary()))));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('home-summary-dot-2')));
    await tester.pumpAndSettle();
    expect(find.text('还没有设置预算').hitTestable(), findsOneWidget);
    await c.read(homeBudgetCardEnabledProvider.notifier).toggle(false);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('home-summary-dot-2')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
