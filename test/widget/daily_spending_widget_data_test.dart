import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:beecount/data/db.dart';
import 'package:beecount/data/repositories/local/local_repository.dart';
import 'package:beecount/widget/daily_spending_widget_data.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});
  late BeeDatabase db;
  late LocalRepository repo;
  final now = DateTime(2026, 11, 9, 15);

  setUp(() async {
    db = BeeDatabase.forTesting(NativeDatabase.memory());
    repo = LocalRepository(db);
    await db.customStatement(
        "INSERT INTO ledgers (id, name, currency, month_start_day) "
        "VALUES (401, 'Widget', 'CNY', 10), (402, 'Other', 'USD', 1)");
  });
  tearDown(() async => db.close());

  Future<DailySpendingWidgetData> gather() async =>
      (await DailySpendingWidgetDataService.gather(
          repository: repo, ledgerId: 401, now: now))!;

  test('uses current ledger, custom monthly period and seven calendar days', () async {
    await repo.createBudget(ledgerId: 401, type: 'total', amount: 1000);
    for (final entry in [
      (date: DateTime(2026, 10, 9, 12), amount: 999.0),
      (date: DateTime(2026, 10, 10, 12), amount: 50.0),
      (date: DateTime(2026, 11, 3, 12), amount: 20.0),
      (date: now, amount: 30.0),
      (date: DateTime(2026, 11, 10), amount: 777.0),
    ]) {
      await repo.addTransaction(ledgerId: 401, type: 'expense',
          amount: entry.amount, happenedAt: entry.date);
    }
    await repo.addTransaction(ledgerId: 402, type: 'expense', amount: 9999, happenedAt: now);
    final data = await gather();
    expect(data.todayExpense, 30);
    expect(data.monthExpense, 100);
    expect(data.budgetRemaining, 900);
    expect(data.periodStart, DateTime(2026, 10, 10));
    expect(data.periodEnd, DateTime(2026, 11, 10));
    expect(data.days, hasLength(7));
    expect(data.days.first.date, DateTime(2026, 11, 3));
    expect(data.days.last.date, DateTime(2026, 11, 9));
    expect(data.days.map((d) => d.total), [20, 0, 0, 0, 0, 0, 30]);
  });

  test('statistics and budget exclusions stay independent; native currency wins', () async {
    await repo.createBudget(ledgerId: 401, type: 'total', amount: 1000);
    await repo.addTransaction(ledgerId: 401, type: 'expense', amount: 20,
        happenedAt: now, excludeFromStats: true);
    await repo.addTransaction(ledgerId: 401, type: 'expense', amount: 30,
        happenedAt: now, excludeFromBudget: true);
    final foreign = await repo.addTransaction(ledgerId: 401, type: 'expense',
        amount: 50, happenedAt: now);
    await db.customStatement('UPDATE transactions SET native_amount = ? WHERE id = ?', [350.0, foreign]);
    // Income (including a refund) and transfers are not expense totals.
    await repo.addTransaction(ledgerId: 401, type: 'income', amount: 10, happenedAt: now);
    await repo.addTransaction(ledgerId: 401, type: 'transfer', amount: 80, happenedAt: now);
    final data = await gather();
    expect(data.todayExpense, 380);
    expect(data.monthExpense, 380);
    expect(data.days.last.total, 380);
    expect(data.budgetRemaining, 630); // 1000 - (20 + 350)
  });

  test('absent or disabled total budget is null; overspending remains negative', () async {
    expect((await gather()).budgetRemaining, isNull);
    final budget = await repo.createBudget(ledgerId: 401, type: 'total', amount: 10);
    await repo.addTransaction(ledgerId: 401, type: 'expense', amount: 25, happenedAt: now);
    expect((await gather()).budgetRemaining, -15);
    await repo.updateBudget(budget, enabled: false);
    expect((await gather()).budgetRemaining, isNull);
  });

  test('snapshot is JSON-safe, has local boundaries, and missing ledger clears data', () async {
    final data = await gather();
    final json = jsonDecode(jsonEncode(data.toJson(locale: 'zh', currencySymbol: '¥')));
    expect(json['schemaVersion'], 1);
    expect(json['budgetRemaining'], isNull);
    expect(json['currency'], 'CNY');
    expect(json['dayStartMs'], DateTime(2026, 11, 9).millisecondsSinceEpoch);
    expect(json['dayEndMs'], DateTime(2026, 11, 10).millisecondsSinceEpoch);
    expect(json['days'].last['date'], '2026-11-09');
    expect(json['days'].last['weekday'], DateTime.monday);
    expect(await DailySpendingWidgetDataService.gather(
        repository: repo, ledgerId: 999, now: now), isNull);
  });
}
