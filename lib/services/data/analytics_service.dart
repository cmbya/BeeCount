import '../../data/db.dart';
import '../../data/repositories/base_repository.dart';
import '../../data/repositories/local/local_repository.dart';
import '../../models/analytics_dashboard.dart';
import '../../utils/month_range.dart';

/// One snapshot is the source of truth for summary, series, groups and drilldown.
/// It never changes account balances, budget flags, exchange rates or bills.
class AnalyticsService {
  final BaseRepository repo;
  AnalyticsService(this.repo);
  Future<AnalyticsDashboard> load(AnalyticsQuery query) async {
    Future<AnalyticsDashboard> read() async {
      final ledger = await repo.getLedgerById(query.ledgerId);
      if (ledger == null) throw StateError('analytics_ledger_missing');
      final first = query.scope == AnalyticsScope.all ? await repo.getFirstTransactionByLedger(ledger.id) : null;
      final period = AnalyticsPeriod.resolve(query, earliest: first?.happenedAt);
      final rows = await repo.getTransactionsWithCategoryInRange(ledgerId: ledger.id,
        start: period.start, end: period.end);
      // A corrupt amount must not silently disappear while its bill stays listed.
      if (rows.any((row) => !AnalyticsDashboard.value(row.t).isFinite)) throw StateError('analytics_amount');
      final categories = <int, Category>{
        for (final category in await repo.getAllCategories()) category.id: category,
        ...await repo.getSharedSyntheticCategoriesForLedger(ledger.id),
      };
      return AnalyticsDashboard(ledger: ledger, query: query, period: period,
        categories: Map.unmodifiable(categories),
        rows: List.unmodifiable(rows), buckets: _buckets(period, query.startDay, rows),
        expenseCategories: _groups(rows, 'expense', categories),
        incomeCategories: _groups(rows, 'income', categories));
    }
    final local = repo;
    return local is LocalRepository ? local.db.transaction(read) : read();
  }

  static List<AnalyticsBucket> _buckets(AnalyticsPeriod period, int startDay, List<AnalyticsRow> rows) {
    final ranges = <DateRange>[];
    var start = period.start;
    while (start.isBefore(period.end)) {
      late DateTime next;
      switch (period.scope) {
        case AnalyticsScope.week:
        case AnalyticsScope.month: next = nextCalendarDay(start); break;
        case AnalyticsScope.year:
          next = DateTime(start.year, start.month + 1, start.day); break;
        case AnalyticsScope.all:
          next = yearRangeFor(labelForDate(start, startDay).year, startDay).end; break;
      }
      final end = next.isAfter(period.end) ? period.end : next;
      ranges.add((start: start, end: end)); start = end;
    }
    final expenses = List<double>.filled(ranges.length, 0);
    final incomes = List<double>.filled(ranges.length, 0);
    // Binary search prevents all-years daily scans on every transaction.
    for (final row in rows) {
      final tx = row.t;
      if (!AnalyticsDashboard.ordinary(tx, 'expense') && !AnalyticsDashboard.ordinary(tx, 'income')) continue;
      var low = 0, high = ranges.length - 1;
      while (low <= high) {
        final mid = (low + high) ~/ 2;
        final range = ranges[mid];
        if (tx.happenedAt.isBefore(range.start)) { high = mid - 1; }
        else if (!tx.happenedAt.isBefore(range.end)) { low = mid + 1; }
        else {
          if (tx.type == 'expense') expenses[mid] += AnalyticsDashboard.value(tx);
          else incomes[mid] += AnalyticsDashboard.value(tx);
          break;
        }
      }
    }
    return List.unmodifiable([for (var i = 0; i < ranges.length; i++) AnalyticsBucket(
      start: ranges[i].start, end: ranges[i].end, expense: expenses[i], income: incomes[i])]);
  }

  static List<AnalyticsCategoryGroup> _groups(List<AnalyticsRow> rows, String type, Map<int, Category> categories) {
    final grouped = <int?, List<AnalyticsRow>>{};
    for (final row in rows) {
      if (!AnalyticsDashboard.ordinary(row.t, type)) continue;
      var root = row.category;
      final seen = <int>{};
      while (root != null && root.parentId != null && seen.add(root.id)) {
        final parent = categories[root.parentId];
        if (parent == null || parent.kind != type || seen.contains(parent.id)) break;
        root = parent;
      }
      grouped.putIfAbsent(root?.id, () => []).add(row);
    }
    final result = <AnalyticsCategoryGroup>[];
    for (final entry in grouped.entries) {
      final leaves = <int?, List<AnalyticsRow>>{};
      for (final row in entry.value) { leaves.putIfAbsent(row.category?.id, () => []).add(row); }
      final children = <AnalyticsCategoryTotal>[
        for (final leaf in leaves.values) AnalyticsCategoryTotal(category: leaf.first.category,
          total: leaf.fold<double>(0, (sum, row) => sum + AnalyticsDashboard.value(row.t)), count: leaf.length)
      ]..sort((a, b) => b.total.compareTo(a.total));
      result.add(AnalyticsCategoryGroup(category: entry.key == null ? null : categories[entry.key] ?? entry.value.first.category,
        total: children.fold<double>(0, (sum, child) => sum + child.total), count: entry.value.length,
        children: List.unmodifiable(children), categoryIds: Set.unmodifiable(leaves.keys)));
    }
    result.sort((a, b) => b.total.compareTo(a.total));
    return List.unmodifiable(result);
  }
}
