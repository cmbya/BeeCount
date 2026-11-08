import 'package:beecount/data/db.dart';
import 'package:beecount/data/repositories/local/local_repository.dart';
import 'package:beecount/models/analytics_dashboard.dart';
import 'package:beecount/services/data/analytics_service.dart';
import 'package:beecount/services/data/refund_service.dart';
import 'package:drift/native.dart';
import 'package:drift/drift.dart' as d;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late BeeDatabase db;
  late LocalRepository repo;
  late int ledger, account, root, child, income;
  AnalyticsQuery query({AnalyticsScope scope = AnalyticsScope.week}) => (ledgerId: ledger,
    scope: scope, anchor: DateTime(2026, 11, 5), startDay: 1, today: DateTime(2026, 11, 5));
  Future<int> tx(String type, double amount, int day, {int? category, bool excluded = false, double? native}) =>
    repo.addTransaction(ledgerId: ledger, type: type, amount: amount, accountId: account,
      categoryId: category, happenedAt: DateTime(2026, 11, day, 12), excludeFromStats: excluded, nativeAmount: native);
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = BeeDatabase.forTesting(NativeDatabase.memory()); repo = LocalRepository(db);
    ledger = await repo.createLedger(name: 'Stats'); account = await repo.createAccount(ledgerId: ledger, name: 'Bank', initialBalance: 1000);
    root = await repo.createCategory(name: '固定支出', kind: 'expense');
    child = await repo.createCategory(name: '水电', kind: 'expense', level: 2, parentId: root);
    income = await repo.createCategory(name: '工资', kind: 'income');
  });
  tearDown(() async => db.close());
  test('cards, buckets and details share period, type and exclude flags', () async {
    await tx('expense', 100, 2, category: child); await tx('income', 200, 3, category: income);
    await tx('expense', 999, 4, excluded: true); await tx('expense', 777, 6); await tx('expense', 888, 1);
    await tx('transfer', 25, 4);
    final data = await AnalyticsService(repo).load(query());
    expect(data.total(AnalyticsMetric.expense), 100); expect(data.total(AnalyticsMetric.income), 200);
    expect(data.total(AnalyticsMetric.balance), 100); expect(data.total(AnalyticsMetric.dailyExpense), 25);
    expect(data.total(AnalyticsMetric.transfer), 25); expect(data.buckets.length, 4);
    expect(data.buckets.fold<double>(0, (s, b) => s + b.expense), 100);
    expect(data.detail(AnalyticsMetric.expense).length, 1); expect(data.detail(AnalyticsMetric.dailyExpense).length, 1);
    expect(data.detail(AnalyticsMetric.balance).length, 2);
    expect(data.expenseCategories.single.category!.id, root);
    expect(data.expenseCategories.single.children.single.category!.id, child);
  });
  test('refund metrics share one credit, separate from ordinary income', () async {
    final original = await tx('expense', 100, 2, category: child);
    final info = await RefundService(repo).load(original);
    final credit = await RefundService(repo).save(originalId: original, requestId: '00000000-0000-4000-8000-000000000001',
      customAmount: '30', expectedRemainingMinor: info.remainingMinor, expectedCurrency: info.currency, expected: info.original);
    final data = await AnalyticsService(repo).load(query());
    expect(data.total(AnalyticsMetric.refund), 30); expect(data.total(AnalyticsMetric.refundIncome), 30);
    expect(data.total(AnalyticsMetric.income), 0); expect(data.total(AnalyticsMetric.expense), 100);
    expect(data.detail(AnalyticsMetric.refund).single.t.id, credit.id);
    expect(data.detail(AnalyticsMetric.refundIncome).single.t.id, credit.id);
    expect(await repo.getAccountBalance(account), 930);
  });
  test('parent and child categories, uncategorized and native snapshot match detail sums', () async {
    await tx('expense', 20, 2, category: root); await tx('expense', 10, 3, category: child, native: 70); await tx('expense', 5, 4);
    final data = await AnalyticsService(repo).load(query());
    final group = data.expenseCategories.singleWhere((g) => g.category?.id == root);
    expect(group.total, 90); expect(group.categoryIds, {root, child}); expect(group.count, 2);
    expect(data.detail(AnalyticsMetric.expense, categoryIds: group.categoryIds).fold<double>(0, (s, r) => s + AnalyticsDashboard.value(r.t)), 90);
    expect(data.detail(AnalyticsMetric.expense, categoryIds: {null}).single.t.amount, 5);
    expect(data.total(AnalyticsMetric.expense), 95);
  });
  test('empty all-period is finite and another ledger never leaks into totals', () async {
    final other = await repo.createLedger(name: 'Other');
    await repo.addTransaction(ledgerId: other, type: 'income', amount: 999, happenedAt: DateTime(2026, 11, 2));
    final data = await AnalyticsService(repo).load(query(scope: AnalyticsScope.all));
    expect(data.rows, isEmpty); expect(data.total(AnalyticsMetric.dailyExpense), 0); expect(data.period.days, 1);
  });
  test('period detail keeps half-open bucket boundaries', () async {
    await tx('expense', 20, 2); await tx('expense', 30, 3);
    final data = await AnalyticsService(repo).load(query());
    final bucket = data.buckets.first;
    expect(data.detail(AnalyticsMetric.expense, start: bucket.start, end: bucket.end).single.t.amount, 20);
  });

  test('all-year series fills zero years and ends at the selected day', () async {
    await repo.addTransaction(ledgerId: ledger, type: 'expense', amount: 10,
      happenedAt: DateTime(2024, 6, 5), accountId: account);
    await tx('expense', 20, 2);
    final data = await AnalyticsService(repo).load(query(scope: AnalyticsScope.all));
    expect(data.buckets.length, 3); expect(data.buckets[1].expense, 0);
    expect(data.period.start, DateTime(2024, 6, 5)); expect(data.period.end, DateTime(2026, 11, 6));
    expect(data.total(AnalyticsMetric.expense), 30);
  });

  test('shared mirrored leaf rolls up to its mirrored first-level category', () async {
    final ledgerKey = (await repo.getLedgerById(ledger))!.syncId!;
    for (final row in [('shared-root', '共享固定', 1, null), ('shared-leaf', '共享水电', 2, 'shared-root')]) {
      await db.into(db.sharedLedgerCategories).insert(SharedLedgerCategoriesCompanion.insert(
        ledgerSyncId: ledgerKey, syncId: row.$1, name: row.$2, kind: 'expense',
        level: d.Value(row.$3), parentSyncId: d.Value(row.$4), updatedAt: DateTime(2026, 11, 1)));
    }
    final id = await tx('expense', 42, 2);
    await (db.update(db.transactions)..where((t) => t.id.equals(id))).write(
      const TransactionsCompanion(categorySyncIdOverride: d.Value('shared-leaf')));
    final data = await AnalyticsService(repo).load(query());
    expect(data.expenseCategories.single.category!.name, '共享固定');
    expect(data.expenseCategories.single.children.single.category!.name, '共享水电');
    final group = data.expenseCategories.single;
    expect(data.detail(AnalyticsMetric.expense, categoryIds: group.categoryIds).single.t.id, id);
  });
  test('parent identity survives edits into unused siblings and newly created children', () async {
    final sibling = await repo.createCategory(name: '房租', kind: 'expense', level: 2, parentId: root);
    final id = await tx('expense', 25, 2, category: child);
    final first = await AnalyticsService(repo).load(query());
    final filter = AnalyticsCategoryFilter.root(first.expenseCategories.single.category!.id);
    await repo.updateTransaction(id: id, type: 'expense', amount: 25, categoryId: sibling);
    var fresh = await AnalyticsService(repo).load(query());
    expect(fresh.detail(AnalyticsMetric.expense, categoryFilter: filter).single.t.id, id);
    expect(fresh.detail(AnalyticsMetric.expense, categoryFilter: AnalyticsCategoryFilter.leaf(child)), isEmpty);
    final added = await repo.createCategory(name: '网络', kind: 'expense', level: 2, parentId: root);
    await repo.updateTransaction(id: id, type: 'expense', amount: 25, categoryId: added);
    fresh = await AnalyticsService(repo).load(query());
    expect(fresh.detail(AnalyticsMetric.expense, categoryFilter: filter).single.t.id, id);
    final other = await repo.createCategory(name: '购物', kind: 'expense');
    await repo.updateTransaction(id: id, type: 'expense', amount: 25, categoryId: other);
    fresh = await AnalyticsService(repo).load(query());
    expect(fresh.detail(AnalyticsMetric.expense, categoryFilter: filter), isEmpty);
  });

  test('root identity includes direct legacy bills and keeps uncategorized separate', () async {
    final direct = await tx('expense', 20, 2, category: root);
    final nested = await tx('expense', 10, 3, category: child);
    final none = await tx('expense', 5, 4);
    final data = await AnalyticsService(repo).load(query());
    expect(data.detail(AnalyticsMetric.expense, categoryFilter: AnalyticsCategoryFilter.root(root))
      .map((r) => r.t.id).toSet(), {direct, nested});
    expect(data.detail(AnalyticsMetric.expense, categoryFilter: const AnalyticsCategoryFilter.root(null)).single.t.id, none);
    expect(data.detail(AnalyticsMetric.expense, categoryFilter: AnalyticsCategoryFilter.leaf(root)).single.t.id, direct);
  });

  test('shared negative root identity follows a newly mirrored sibling', () async {
    final ledgerKey = (await repo.getLedgerById(ledger))!.syncId!;
    Future<void> mirror(String key, String? parent) => db.into(db.sharedLedgerCategories).insert(
      SharedLedgerCategoriesCompanion.insert(ledgerSyncId: ledgerKey, syncId: key, name: key,
        kind: 'expense', level: d.Value(parent == null ? 1 : 2), parentSyncId: d.Value(parent),
        updatedAt: DateTime(2026, 11, 1))).then((_) {});
    await mirror('root-new', null); await mirror('leaf-old', 'root-new');
    final id = await tx('expense', 12, 2);
    await (db.update(db.transactions)..where((t) => t.id.equals(id))).write(
      const TransactionsCompanion(categorySyncIdOverride: d.Value('leaf-old')));
    final first = await AnalyticsService(repo).load(query());
    final filter = AnalyticsCategoryFilter.root(first.expenseCategories.single.category!.id);
    expect(filter.id, lessThan(0));
    await mirror('leaf-new', 'root-new');
    await (db.update(db.transactions)..where((t) => t.id.equals(id))).write(
      const TransactionsCompanion(categorySyncIdOverride: d.Value('leaf-new')));
    final fresh = await AnalyticsService(repo).load(query());
    expect(fresh.detail(AnalyticsMetric.expense, categoryFilter: filter).single.t.id, id);
  });

}
