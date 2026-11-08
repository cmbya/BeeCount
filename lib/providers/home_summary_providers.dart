import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/repositories/budget_repository.dart';
import '../utils/month_range.dart';
import 'database_providers.dart';
import 'statistics_providers.dart';
import 'budget_providers.dart';

class HomeMonthlySummaryData {
  final double income;
  final double expense;
  final String currency;
  final BudgetUsage? budget;
  final double? dailyAvailable;

  const HomeMonthlySummaryData({
    required this.income,
    required this.expense,
    required this.currency,
    this.budget,
    this.dailyAvailable,
  });

  double get balance => income - expense;
}

/// Explicitly scoped to the ledger and selected label month. Never show the
/// current month's budget below a historical month's income/expense.
final homeMonthlySummaryProvider = FutureProvider.autoDispose.family<
    HomeMonthlySummaryData, ({int ledgerId, DateTime month})>((ref, key) async {
  ref.watch(statsRefreshProvider);
  ref.watch(budgetRefreshProvider);
  ref.watch(currentMonthStartDayProvider);
  final repo = ref.watch(repositoryProvider);
  final ledger = await repo.getLedgerById(key.ledgerId);
  if (ledger == null) throw StateError('ledger_not_found');
  final totals = await repo.monthlyTotals(ledgerId: key.ledgerId, month: key.month);
  final totalBudget = await repo.getTotalBudget(key.ledgerId);
  final range = periodForLabel(key.month.year, key.month.month, ledger.monthStartDay);
  final usage = totalBudget == null
      ? null
      : await repo.getBudgetUsage(totalBudget.id, range.start);
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = today.isBefore(range.start) ? range.start : today;
  // Calendar days, not elapsed 24-hour blocks (DST safe). Past periods have no
  // remaining daily allowance, not the allowance of today's current month.
  final days = DateTime.utc(range.end.year, range.end.month, range.end.day)
      .difference(DateTime.utc(day.year, day.month, day.day)).inDays;
  return HomeMonthlySummaryData(
    income: totals.$1,
    expense: totals.$2,
    currency: ledger.currency,
    budget: usage,
    dailyAvailable: usage == null || days <= 0 ? null
        : (usage.remaining > 0 ? usage.remaining / days : 0),
  );
});
