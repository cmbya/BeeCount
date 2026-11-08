import 'package:beecount/cloud/sync/change_tracker.dart';
import 'package:beecount/data/db.dart';
import 'package:beecount/data/repositories/local/local_repository.dart';
import 'package:beecount/l10n/app_localizations.dart';
import 'package:beecount/providers.dart';
import 'package:beecount/services/data/refund_service.dart';
import 'package:beecount/widgets/biz/transaction_list.dart';
import 'package:beecount/widgets/biz/day_section_header.dart';
import 'package:drift/drift.dart' as d;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../support/widget_waits.dart';

void main() {
  late BeeDatabase db;
  late LocalRepository repo;
  late ProviderContainer container;
  late int ledger, id;
  Future<void> setRole(String role) => (db.update(db.ledgers)..where((l) => l.id.equals(ledger)))
    .write(LedgersCompanion(isShared: const d.Value(true), myRole: d.Value(role))).then((_) {});
  Future<void> show(WidgetTester tester) async {
    final rows = await repo.getTransactionsWithCategoryInRange(ledgerId: ledger,
      start: DateTime(2026, 11, 1), end: DateTime(2026, 12, 1));
    container = ProviderContainer(overrides: [repositoryProvider.overrideWithValue(repo),
      databaseProvider.overrideWithValue(db), currentLedgerIdProvider.overrideWith((ref) => ledger)]);
    await tester.pumpWidget(UncontrolledProviderScope(container: container, child: MaterialApp(
      locale: const Locale('zh'), supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      home: Scaffold(body: TransactionList(hideAmounts: false, transactions: rows)))));
    await tester.runAsync(() async => Future<void>.delayed(const Duration(milliseconds: 150)));
    await tester.pumpAndSettle();
    await pumpUntilFound(tester, find.byType(Dismissible).first);
  }
  Future<void> dispose(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 3));
    container.dispose(); await db.close();
  }
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = BeeDatabase.forTesting(NativeDatabase.memory());
    repo = LocalRepository(db, changeTracker: ChangeTracker(db));
    ledger = await repo.createLedger(name: 'List checks');
    id = await repo.addTransaction(ledgerId: ledger, type: 'expense', amount: 10,
      happenedAt: DateTime(2026, 11, 5));
    await db.delete(db.localChanges).go();
  });
  testWidgets('viewer swipe neither confirms nor deletes the row', (tester) async {
    await setRole('viewer'); await show(tester);
    final row = find.byKey(ValueKey('tx-$id'));
    await tester.drag(row, const Offset(-600, 0));
    await tester.runAsync(() async => Future<void>.delayed(const Duration(milliseconds: 150)));
    await tester.pumpAndSettle();
    expect(find.text('确定'), findsNothing); expect(row, findsOneWidget);
    expect(await repo.getTransactionById(id), isNotNull);
    expect(await db.select(db.localChanges).get(), isEmpty);
    await dispose(tester);
  });
  testWidgets('role downgrade while confirmation is open keeps the row', (tester) async {
    await setRole('editor'); await show(tester);
    final row = find.byKey(ValueKey('tx-$id'));
    await tester.drag(row, const Offset(-600, 0));
    await tester.runAsync(() async => Future<void>.delayed(const Duration(milliseconds: 150)));
    await tester.pumpAndSettle();
    expect(find.text('确定'), findsOneWidget);
    await tester.runAsync(() => setRole('viewer'));
    await tester.tap(find.text('确定'));
    await tester.runAsync(() async => Future<void>.delayed(const Duration(milliseconds: 150)));
    await tester.pumpAndSettle();
    expect(row, findsOneWidget); expect(await repo.getTransactionById(id), isNotNull);
    expect(await db.select(db.localChanges).get(), isEmpty);
    await dispose(tester);
  });
  testWidgets('repository failure after confirmation leaves row and outbox untouched', (tester) async {
    await setRole('editor'); await show(tester);
    await tester.runAsync(() => db.customStatement(
      "CREATE TRIGGER fail_delete BEFORE DELETE ON transactions BEGIN SELECT RAISE(ABORT, 'failed'); END"));
    final row = find.byKey(ValueKey('tx-$id'));
    await tester.drag(row, const Offset(-600, 0));
    await tester.runAsync(() async => Future<void>.delayed(const Duration(milliseconds: 150)));
    await tester.pumpAndSettle(); await tester.tap(find.text('确定'));
    await tester.runAsync(() async => Future<void>.delayed(const Duration(milliseconds: 150)));
    await tester.pumpAndSettle();
    expect(row, findsOneWidget); expect(await repo.getTransactionById(id), isNotNull);
    expect(await db.select(db.localChanges).get(), isEmpty);
    expect(tester.takeException(), isNull);
    await dispose(tester);
  });
  testWidgets('successful deletion removes stale parent rows without a Dismissible error', (tester) async {
    await setRole('editor'); await show(tester);
    final row = find.byKey(ValueKey('tx-$id'));
    await tester.drag(row, const Offset(-600, 0));
    await tester.runAsync(() async => Future<void>.delayed(const Duration(milliseconds: 150)));
    await tester.pumpAndSettle(); await tester.tap(find.text('确定'));
    await tester.runAsync(() async => Future<void>.delayed(const Duration(milliseconds: 150)));
    await tester.pumpAndSettle();
    expect(row, findsNothing); expect(await repo.getTransactionById(id), isNull);
    expect(tester.takeException(), isNull);
    await dispose(tester);
  });
  testWidgets('day headers equal month totals while excluded bills stay visible', (tester) async {
    final account = await repo.createAccount(ledgerId: ledger, name: 'Bank', initialBalance: 1000);
    final source = await repo.addTransaction(ledgerId: ledger, type: 'expense', amount: 100,
      accountId: account, happenedAt: DateTime(2026, 11, 5));
    await repo.addTransaction(ledgerId: ledger, type: 'income', amount: 30, happenedAt: DateTime(2026, 11, 5));
    await repo.addTransaction(ledgerId: ledger, type: 'income', amount: 999,
      excludeFromStats: true, happenedAt: DateTime(2026, 11, 5));
    await repo.addTransaction(ledgerId: ledger, type: 'expense', amount: 888,
      excludeFromStats: true, happenedAt: DateTime(2026, 11, 5));
    await repo.addTransaction(ledgerId: ledger, type: 'transfer', amount: 777, happenedAt: DateTime(2026, 11, 5));
    final service = RefundService(repo);
    final info = await service.load(source);
    await service.save(originalId: source, requestId: '00000000-0000-4000-8000-000000000001',
      customAmount: '25', expectedRemainingMinor: info.remainingMinor, expectedCurrency: info.currency, expected: info.original);
    await show(tester);
    final header = tester.widget<DaySectionHeader>(find.byType(DaySectionHeader));
    final month = await repo.monthlyTotals(ledgerId: ledger, month: DateTime(2026, 11));
    expect(header.income, 30); expect(header.expense, 110);
    expect((header.income, header.expense), month);
    // No data filtering: all seven records remain the list's source.
    expect(tester.widget<TransactionList>(find.byType(TransactionList)).transactions!.length, 7);
    await dispose(tester);
  });
}
