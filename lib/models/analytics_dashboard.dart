import '../data/db.dart';
import 'refund_identity.dart';
import '../utils/month_range.dart';

enum AnalyticsScope { week, month, year, all }
enum AnalyticsMetric { expense, income, balance, dailyExpense, refund, refundIncome, transfer }
typedef AnalyticsRow = ({Transaction t, Category? category, Account? account, Account? toAccount});
typedef AnalyticsQuery = ({int ledgerId, AnalyticsScope scope, DateTime anchor, int startDay, DateTime today});

DateTime calendarDay(DateTime value) => DateTime(value.year, value.month, value.day);
DateTime nextCalendarDay(DateTime value) => DateTime(value.year, value.month, value.day + 1);
int calendarDays(DateTime start, DateTime end) => DateTime.utc(end.year, end.month, end.day)
    .difference(DateTime.utc(start.year, start.month, start.day)).inDays;

/// All comparisons use [start, end). fullEnd is the displayed period boundary;
/// end clips an ongoing period to tomorrow, so future days do not dilute averages.
class AnalyticsPeriod {
  final AnalyticsScope scope;
  final DateTime start, end, fullEnd;
  const AnalyticsPeriod({required this.scope, required this.start, required this.end, required this.fullEnd});
  int get days => calendarDays(start, end);
  bool contains(DateTime time) => !time.isBefore(start) && time.isBefore(end);

  factory AnalyticsPeriod.resolve(AnalyticsQuery query, {DateTime? earliest}) {
    final today = calendarDay(query.today);
    final tomorrow = nextCalendarDay(today);
    late DateTime start, fullEnd;
    switch (query.scope) {
      case AnalyticsScope.week:
        final date = calendarDay(query.anchor);
        start = DateTime(date.year, date.month, date.day - date.weekday + 1);
        fullEnd = DateTime(start.year, start.month, start.day + 7);
        break;
      case AnalyticsScope.month:
        final label = labelForDate(query.anchor, query.startDay);
        final range = periodForLabel(label.year, label.month, query.startDay);
        start = range.start; fullEnd = range.end;
        break;
      case AnalyticsScope.year:
        final year = labelForDate(query.anchor, query.startDay).year;
        final range = yearRangeFor(year, query.startDay);
        start = range.start; fullEnd = range.end;
        break;
      case AnalyticsScope.all:
        start = earliest == null || earliest.isAfter(today) ? today : calendarDay(earliest);
        fullEnd = tomorrow;
        break;
    }
    var end = fullEnd.isAfter(tomorrow) ? tomorrow : fullEnd;
    if (end.isBefore(start)) end = start;
    return AnalyticsPeriod(scope: query.scope, start: start, end: end, fullEnd: fullEnd);
  }
}

class AnalyticsBucket {
  final DateTime start, end;
  final double expense, income;
  const AnalyticsBucket({required this.start, required this.end, this.expense = 0, this.income = 0});
  double get balance => income - expense;
}

class AnalyticsCategoryTotal {
  final Category? category;
  final double total;
  final int count;
  const AnalyticsCategoryTotal({required this.category, required this.total, required this.count});
  int? get id => category?.id;
}

class AnalyticsCategoryGroup {
  final Category? category;
  final double total;
  final int count;
  final List<AnalyticsCategoryTotal> children;
  /// Includes direct transactions on a legacy parent and every child actually used.
  final Set<int?> categoryIds;
  const AnalyticsCategoryGroup({required this.category, required this.total,
    required this.count, required this.children, required this.categoryIds});
}

/// A parent route keeps its identity, never a snapshot of used descendants.
class AnalyticsCategoryFilter {
  final int? id;
  final bool includeDescendants;
  const AnalyticsCategoryFilter.root(this.id) : includeDescendants = true;
  const AnalyticsCategoryFilter.leaf(this.id) : includeDescendants = false;
}

class AnalyticsDashboard {
  final Ledger ledger;
  final AnalyticsQuery query;
  final AnalyticsPeriod period;
  final List<AnalyticsRow> rows;
  final Map<int, Category> categories;
  final List<AnalyticsBucket> buckets;
  final List<AnalyticsCategoryGroup> expenseCategories, incomeCategories;
  const AnalyticsDashboard({required this.ledger, required this.query, required this.period,
    required this.rows, required this.buckets, required this.expenseCategories, required this.incomeCategories,
    this.categories = const {}});

  static double value(Transaction tx) => tx.nativeAmount ?? tx.amount;
  static bool ordinary(Transaction tx, String type) => tx.type == type &&
      !tx.excludeFromStats && !RefundIdentity.isRefund(tx.syncId);
  static bool matches(Transaction tx, AnalyticsMetric metric) {
    switch (metric) {
      case AnalyticsMetric.expense:
      case AnalyticsMetric.dailyExpense: return ordinary(tx, 'expense');
      case AnalyticsMetric.income: return ordinary(tx, 'income');
      case AnalyticsMetric.balance: return ordinary(tx, 'income') || ordinary(tx, 'expense');
      case AnalyticsMetric.refund:
      case AnalyticsMetric.refundIncome: return tx.type == 'income' && RefundIdentity.isRefund(tx.syncId);
      case AnalyticsMetric.transfer: return tx.type == 'transfer';
    }
  }
  bool _categoryMatches(Category? category, AnalyticsCategoryFilter filter) {
    if (filter.id == null) return category == null;
    if (category == null) return false;
    if (!filter.includeDescendants) return category.id == filter.id;
    Category? current = categories[category.id] ?? category;
    final seen = <int>{};
    while (current != null && seen.add(current.id)) {
      if (current.id == filter.id) return true;
      final parent = categories[current.parentId];
      if (parent == null || parent.kind != category.kind) break;
      current = parent;
    }
    return false;
  }

  List<AnalyticsRow> detail(AnalyticsMetric metric, {DateTime? start, DateTime? end,
      Set<int?>? categoryIds, AnalyticsCategoryFilter? categoryFilter}) =>
      rows.where((row) => matches(row.t, metric) &&
          (start == null || !row.t.happenedAt.isBefore(start)) &&
          (end == null || row.t.happenedAt.isBefore(end)) &&
          (categoryIds == null || categoryIds.contains(row.category?.id)) &&
          (categoryFilter == null || _categoryMatches(row.category, categoryFilter))).toList();
  double total(AnalyticsMetric metric) {
    if (metric == AnalyticsMetric.balance) return total(AnalyticsMetric.income) - total(AnalyticsMetric.expense);
    if (metric == AnalyticsMetric.dailyExpense) return period.days > 0 ? total(AnalyticsMetric.expense) / period.days : 0;
    return detail(metric).fold<double>(0, (sum, row) => sum + value(row.t));
  }
}
