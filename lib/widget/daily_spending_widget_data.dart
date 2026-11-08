import '../data/repositories/base_repository.dart';
import '../utils/month_range.dart';

/// A small, versioned snapshot for the native iOS widget. No transaction notes,
/// account names or attachments cross the App Group boundary.
class DailySpendingWidgetData {
  final int ledgerId;
  final String currency;
  final DateTime generatedAt;
  final DateTime dayStart;
  final DateTime dayEnd;
  final DateTime periodStart;
  final DateTime periodEnd;
  final double todayExpense;
  final double monthExpense;
  final double? budgetRemaining;
  final List<({DateTime date, double total})> days;

  const DailySpendingWidgetData({
    required this.ledgerId,
    required this.currency,
    required this.generatedAt,
    required this.dayStart,
    required this.dayEnd,
    required this.periodStart,
    required this.periodEnd,
    required this.todayExpense,
    required this.monthExpense,
    required this.budgetRemaining,
    required this.days,
  });

  Map<String, Object?> toJson({
    required String locale,
    required String currencySymbol,
  }) => {
        'schemaVersion': 1,
        'ledgerId': ledgerId,
        'currency': currency,
        'currencySymbol': currencySymbol,
        'locale': locale,
        'generatedAtMs': generatedAt.millisecondsSinceEpoch,
        'dayStartMs': dayStart.millisecondsSinceEpoch,
        'dayEndMs': dayEnd.millisecondsSinceEpoch,
        'periodStartMs': periodStart.millisecondsSinceEpoch,
        'periodEndMs': periodEnd.millisecondsSinceEpoch,
        'todayExpense': todayExpense,
        'monthExpense': monthExpense,
        // null means no enabled total budget, not a remaining amount of zero.
        'budgetRemaining': budgetRemaining,
        'days': [
          for (final day in days)
            {
              'date': '${day.date.year.toString().padLeft(4, '0')}-'
                  '${day.date.month.toString().padLeft(2, '0')}-'
                  '${day.date.day.toString().padLeft(2, '0')}',
              'weekday': day.date.weekday,
              'total': day.total,
            },
        ],
      };
}

class DailySpendingWidgetDataService {
  const DailySpendingWidgetDataService._();

  static Future<DailySpendingWidgetData?> gather({
    required BaseRepository repository,
    required int ledgerId,
    DateTime? now,
  }) async {
    final anchor = (now ?? DateTime.now()).toLocal();
    final ledger = await repository.getLedgerById(ledgerId);
    // Do not continue displaying a deleted ledger's previous snapshot.
    if (ledger == null) return null;

    final today = DateTime(anchor.year, anchor.month, anchor.day);
    // Calendar constructors, not elapsed 24-hour durations: safe across DST.
    final tomorrow = DateTime(today.year, today.month, today.day + 1);
    final firstDay = DateTime(today.year, today.month, today.day - 6);
    final range = periodContaining(anchor, ledger.monthStartDay);
    final todayTotals = await repository.totalsInRange(
        ledgerId: ledgerId, start: today, end: tomorrow);
    final monthTotals = await repository.totalsInRange(
        ledgerId: ledgerId, start: range.start, end: range.end);

    // Budget usage deliberately honors excludeFromBudget, independently from
    // excludeFromStats. Never infer it by subtracting the displayed month total.
    final budget = await repository.getTotalBudget(ledgerId);
    final usage = budget == null
        ? null
        : await repository.getBudgetUsage(budget.id, anchor);

    final transactions = await repository.getTransactionsByLedgerInRange(
        ledgerId: ledgerId, start: firstDay, end: tomorrow);
    final totals = List<double>.filled(7, 0);
    final firstUtc = DateTime.utc(firstDay.year, firstDay.month, firstDay.day);
    for (final transaction in transactions) {
      if (transaction.type != 'expense' || transaction.excludeFromStats) continue;
      final date = transaction.happenedAt.toLocal();
      final index = DateTime.utc(date.year, date.month, date.day)
          .difference(firstUtc)
          .inDays;
      if (index >= 0 && index < totals.length) {
        // Match the homepage's ledger-currency statistics, not the original
        // transaction currency. Income/refunds/transfers are not new spending.
        totals[index] += transaction.nativeAmount ?? transaction.amount;
      }
    }

    return DailySpendingWidgetData(
      ledgerId: ledgerId,
      currency: ledger.currency,
      generatedAt: anchor,
      dayStart: today,
      dayEnd: tomorrow,
      periodStart: range.start,
      periodEnd: range.end,
      todayExpense: todayTotals.$2,
      monthExpense: monthTotals.$2,
      budgetRemaining: usage?.remaining,
      days: List.generate(
        7,
        (index) => (
          date: DateTime(firstDay.year, firstDay.month, firstDay.day + index),
          total: totals[index],
        ),
        growable: false,
      ),
    );
  }
}
