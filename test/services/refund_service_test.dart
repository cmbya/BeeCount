import 'package:beecount/cloud/sync/change_tracker.dart';
import 'package:beecount/data/db.dart';
import 'package:beecount/data/repositories/local/local_repository.dart';
import 'package:beecount/data/repositories/transaction_repository.dart';
import 'package:beecount/models/refund_identity.dart';
import 'package:beecount/services/data/refund_service.dart';
import 'package:beecount/services/data/transaction_detail_service.dart';
import 'package:drift/drift.dart' as d;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FailingTracker extends ChangeTracker {
  _FailingTracker(super.db);
  @override
  Future<void> recordLedgerChange({required String entityType,
    required int entityId, required String entitySyncId, required int ledgerId,
    required String action, String? payloadJson}) async {
    throw StateError('simulated_outbox_failure');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late BeeDatabase db;
  late LocalRepository repo;
  late RefundService service;
  late int ledger, account, originalId;
  var request = 0;
  String requestId() => '00000000-0000-4000-8000-${(++request).toString().padLeft(12, '0')}';
  final date = DateTime(2026, 11, 5, 12, 32);
  Matcher failure(String code) => isA<RefundFailure>().having((e) => e.code, 'code', code);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = BeeDatabase.forTesting(NativeDatabase.memory());
    repo = LocalRepository(db);
    service = RefundService(repo);
    ledger = await repo.createLedger(name: 'Refund ledger');
    account = await repo.createAccount(ledgerId: ledger, name: 'Payment account',
      type: 'bank_card', initialBalance: 1000);
    originalId = await repo.addTransaction(ledgerId: ledger, type: 'expense',
      amount: 100, accountId: account, happenedAt: date, note: 'Original note');
  });
  tearDown(() async => db.close());

  Future<Transaction> refund({String? amount, String? requestKey, RefundInfo? snapshot}) async {
    final info = snapshot ?? await service.load(originalId);
    return service.save(originalId: originalId, requestId: requestKey ?? requestId(),
      customAmount: amount, expectedRemainingMinor: info.remainingMinor, expectedCurrency: info.currency,
      expected: info.original);
  }

  test('default full refund preserves expense and credits the account once', () async {
    final budget = await repo.createBudget(ledgerId: ledger, type: 'total', amount: 500);
    final before = await service.load(originalId);
    final key = requestId();
    final result = await refund(requestKey: key, snapshot: before);
    final retry = await refund(requestKey: key, snapshot: before);
    expect(retry.id, result.id);
    expect(result.type, 'income'); expect(result.amount, 100);
    expect(result.accountId, account); expect(result.happenedAt, date);
    expect(result.note, 'Original note'); expect(result.excludeFromStats, true);
    expect(result.excludeFromBudget, true);
    expect(RefundIdentity.parse(result.syncId)!.originalSyncId, before.original.syncId);
    expect((await repo.getTransactionById(originalId))!.amount, 100);
    expect((await repo.getAccount(account))!.initialBalance, 1000);
    expect(await repo.getAccountBalance(account), 1000);
    expect(await repo.monthlyTotals(ledgerId: ledger, month: DateTime(2026, 11)), (0.0, 100.0));
    expect((await repo.getBudgetUsage(budget, DateTime(2026, 11))).used, 100);
    expect((await service.load(originalId)).remainingMinor, 0);
    expect((await repo.getTransactionsByLedger(ledger)).length, 2);
  });

  test('30 + 20 + default remaining 50; no cumulative over-refund', () async {
    await refund(amount: '30');
    expect(await repo.getAccountBalance(account), 930);
    await refund(amount: '20.00');
    final info = await service.load(originalId);
    expect(info.refundedMinor, 5000); expect(info.remainingMinor, 5000);
    final last = await refund();
    expect(last.amount, 50); expect(await repo.getAccountBalance(account), 1000);
    await expectLater(refund(amount: '0.01'), throwsA(failure('exceeds')));
    expect((await service.load(originalId)).refunds.length, 3);
  });

  test('invalid precision, signs, zero, NaN and over-limit do not write', () async {
    for (final value in ['0', '-1', 'NaN', '1e2', '1.001', '9999999999999']) {
      await expectLater(refund(amount: value), throwsA(isA<RefundFailure>()));
    }
    await expectLater(refund(amount: '100.01'), throwsA(failure('exceeds')));
    expect((await repo.getTransactionsByLedger(ledger)).length, 1);
    expect(await repo.getAccountBalance(account), 900);
  });

  test('same request with different amount conflicts without another credit', () async {
    final info = await service.load(originalId);
    final key = requestId();
    await refund(amount: '30', requestKey: key, snapshot: info);
    await expectLater(refund(amount: '20', requestKey: key, snapshot: info), throwsA(failure('conflict')));
    expect(await repo.getAccountBalance(account), 930);
  });

  test('stale full-refund page never silently refunds a different remaining amount', () async {
    final old = await service.load(originalId);
    await refund(amount: '30');
    await expectLater(refund(snapshot: old), throwsA(failure('stale')));
    expect(await repo.getAccountBalance(account), 930);
  });

  test('simultaneous local requests cannot exceed the source expense', () async {
    final info = await service.load(originalId);
    Future<bool> attempt() async {
      try { await refund(amount: '60', snapshot: info); return true; }
      on RefundFailure { return false; }
    }
    final outcomes = await Future.wait([attempt(), attempt()]);
    expect(outcomes.where((success) => success).length, 1);
    expect((await service.load(originalId)).refundedMinor, 6000);
    expect(await repo.getAccountBalance(account), 960);
  });

  test('changing source after opening the page is rejected', () async {
    final info = await service.load(originalId);
    await TransactionDetailService.update(repo, originalId, {'amount': 80.0});
    await expectLater(refund(snapshot: info), throwsA(failure('stale')));
    expect((await repo.getTransactionsByLedger(ledger)).length, 1);
  });

  test('viewer cannot refund; an expense without an account is not redirected', () async {
    await (db.update(db.ledgers)..where((t) => t.id.equals(ledger))).write(
      const LedgersCompanion(isShared: d.Value(true), myRole: d.Value('viewer')));
    await expectLater(service.load(originalId), throwsA(failure('read_only')));
    await (db.update(db.ledgers)..where((t) => t.id.equals(ledger))).write(
      const LedgersCompanion(isShared: d.Value(false), myRole: d.Value('owner')));
    await TransactionDetailService.update(repo, originalId, {'account': null});
    await expectLater(refund(), throwsA(failure('account')));
    expect((await repo.getTransactionsByLedger(ledger)).length, 1);
  });

  test('hidden original account is retained, missing or wrong currency is rejected', () async {
    await (db.update(db.accounts)..where((t) => t.id.equals(account))).write(
      const AccountsCompanion(hidden: d.Value(true)));
    expect((await refund(amount: '30')).accountId, account);
    await (db.update(db.accounts)..where((t) => t.id.equals(account))).write(
      const AccountsCompanion(currency: d.Value('USD')));
    await expectLater(service.load(originalId), throwsA(failure('account')));
    await (db.delete(db.accounts)..where((t) => t.id.equals(account))).go();
    await expectLater(service.load(originalId), throwsA(failure('account')));
  });

  test('refund and source protections; removing credit reverses its balance effect', () async {
    final result = await refund(amount: '30');
    await expectLater(TransactionDetailService.update(repo, result.id, {'amount': 1.0}), throwsStateError);
    await expectLater(TransactionDetailService.update(repo, originalId, {'amount': 70.0}), throwsStateError);
    await expectLater(TransactionDetailService.update(repo, originalId, {'date': date.add(const Duration(days: 1))}), throwsStateError);
    final target = await repo.createLedger(name: 'Other');
    await expectLater(repo.updateTransactionLedger(id: originalId, ledgerId: target), throwsStateError);
    await expectLater(repo.deleteTransaction(originalId), throwsStateError);
    await expectLater(repo.deleteTransactionBySyncId((await repo.getTransactionById(originalId))!.syncId!), throwsStateError);
    await TransactionDetailService.update(repo, originalId, {'note': 'Allowed metadata edit'});
    expect((await repo.getTransactionById(originalId))!.note, 'Allowed metadata edit');
    await service.remove(result.id);
    expect(await repo.getAccountBalance(account), 900);
    expect((await service.load(originalId)).remainingMinor, 10000);
    await repo.deleteTransaction(originalId);
    expect(await repo.getAccountBalance(account), 1000);
  });

  test('bulk delete cannot leave a refund without its source', () async {
    final result = await refund(amount: '30');
    final source = (await repo.getTransactionById(originalId))!;
    await expectLater(repo.deleteTransactionsBatchBySyncIds([source.syncId!]), throwsStateError);
    await expectLater(repo.updateTransactionsBatchBySyncId([
      TransactionUpdateBySyncIdData(syncId: source.syncId!, type: source.type,
        amount: 70, accountId: source.accountId, happenedAt: source.happenedAt)
    ]), throwsStateError);
    expect(await repo.deleteTransactionsBatchBySyncIds([source.syncId!, result.syncId!]), 2);
    expect(await repo.getAccountBalance(account), 1000);
  });

  test('outbox failure rolls back both new credit and legacy source sync key', () async {
    await (db.update(db.transactions)..where((t) => t.id.equals(originalId))).write(
      const TransactionsCompanion(syncId: d.Value(null)));
    final info = await service.load(originalId);
    repo.changeTracker = _FailingTracker(db);
    await expectLater(refund(snapshot: info), throwsStateError);
    expect((await repo.getTransactionById(originalId))!.syncId, isNull);
    expect((await repo.getTransactionsByLedger(ledger)).length, 1);
    expect(await db.select(db.localChanges).get(), isEmpty);
    repo.changeTracker = ChangeTracker(db);
    final result = await refund();
    expect(RefundIdentity.isRefund(result.syncId), true);
    expect((await db.select(db.localChanges).get()).length, 2);
  });

  test('new refund and outbox insertion are atomic for an existing sync key', () async {
    repo.changeTracker = _FailingTracker(db);
    await expectLater(refund(amount: '30'), throwsStateError);
    expect((await repo.getTransactionsByLedger(ledger)).length, 1);
    expect(await repo.getAccountBalance(account), 900);
  });

  test('non-expense and invalid source amounts are rejected', () async {
    await (db.update(db.transactions)..where((t) => t.id.equals(originalId))).write(
      const TransactionsCompanion(type: d.Value('income')));
    await expectLater(service.load(originalId), throwsA(failure('expense_only')));
    await (db.update(db.transactions)..where((t) => t.id.equals(originalId))).write(
      const TransactionsCompanion(type: d.Value('expense'), amount: d.Value(1.001)));
    await expectLater(service.load(originalId), throwsA(failure('amount')));
  });

  test('refund totals are scoped to the source ledger even for copied sync IDs', () async {
    await refund(amount: '30');
    final source = (await repo.getTransactionById(originalId))!;
    final other = await repo.createLedger(name: 'Copy');
    final copiedId = await repo.addTransaction(ledgerId: other, type: 'expense',
      amount: 100, accountId: account, happenedAt: date, syncId: source.syncId);
    expect((await service.load(copiedId)).refundedMinor, 0);
    expect((await service.load(originalId)).refundedMinor, 3000);
  });

  for (final pair in [('JPY', 0), ('KWD', 3)]) {
    test('${pair.$1} minor units and inherited foreign exchange snapshot', () async {
      await (db.update(db.accounts)..where((t) => t.id.equals(account))).write(
        AccountsCompanion(currency: d.Value(pair.$1)));
      await (db.update(db.transactions)..where((t) => t.id.equals(originalId))).write(
        TransactionsCompanion(currencyCode: d.Value(pair.$1), nativeAmount: const d.Value(700)));
      final result = await refund(amount: pair.$2 == 0 ? '30' : '30.125');
      expect(result.amount, pair.$2 == 0 ? 30 : 30.125);
      expect(result.nativeAmount, closeTo(result.amount * 7, 0.0000001));
      expect(result.currencyCode, pair.$1);
      await expectLater(refund(amount: pair.$2 == 0 ? '1.1' : '1.0001'), throwsA(failure('amount')));
    });
  }

  test('legacy null snapshot is not replaced using a new rate', () async {
    await (db.update(db.accounts)..where((t) => t.id.equals(account))).write(
      const AccountsCompanion(currency: d.Value('USD')));
    await (db.update(db.transactions)..where((t) => t.id.equals(originalId))).write(
      const TransactionsCompanion(currencyCode: d.Value(null), nativeAmount: d.Value(null)));
    await repo.setOverride(base: 'CNY', quote: 'USD', rate: '7');
    expect((await refund(amount: '30')).nativeAmount, isNull);
  });

  test('credit card refund reduces debt without changing the credit limit or initial balance', () async {
    await (db.update(db.accounts)..where((t) => t.id.equals(account))).write(
      const AccountsCompanion(type: d.Value('credit_card'), initialBalance: d.Value(0), creditLimit: d.Value(1000)));
    expect(await repo.getAccountBalance(account), -100);
    await refund(amount: '30');
    expect(await repo.getAccountBalance(account), -70);
    expect((await repo.getAccount(account))!.creditLimit, 1000);
    expect((await repo.getAccount(account))!.initialBalance, 0);
  });

  test('legacy inherited currency cannot change while refund page is open', () async {
    await (db.update(db.transactions)..where((t) => t.id.equals(originalId))).write(
      const TransactionsCompanion(currencyCode: d.Value(null)));
    final old = await service.load(originalId);
    await (db.update(db.accounts)..where((t) => t.id.equals(account))).write(
      const AccountsCompanion(currency: d.Value('JPY')));
    await expectLater(refund(snapshot: old), throwsA(failure('stale')));
    expect((await repo.getTransactionsByLedger(ledger)).length, 1);
  });

  test('shared editor refund keeps the original scoped account override', () async {
    final ledgerKey = (await repo.getLedgerById(ledger))!.syncId!;
    final other = await repo.createLedger(name: 'Another shared ledger');
    final otherKey = (await repo.getLedgerById(other))!.syncId!;
    await (db.update(db.ledgers)..where((t) => t.id.equals(ledger))).write(
      const LedgersCompanion(isShared: d.Value(true), myRole: d.Value('editor')));
    for (final entry in [(otherKey, 'Unrelated mirror'), (ledgerKey, 'Original mirror')]) {
      await db.into(db.sharedLedgerAccounts).insert(SharedLedgerAccountsCompanion.insert(
        ledgerSyncId: entry.$1, syncId: 'owner-bank', name: entry.$2, updatedAt: date));
    }
    await (db.update(db.transactions)..where((t) => t.id.equals(originalId))).write(
      const TransactionsCompanion(accountId: d.Value(null), accountSyncIdOverride: d.Value('owner-bank')));
    expect((await service.load(originalId)).accountName, 'Original mirror');
    final result = await refund(amount: '30');
    expect(result.accountId, isNull); expect(result.accountSyncIdOverride, 'owner-bank');
    expect(result.ledgerId, ledger); expect(result.happenedAt, date);
  });

  test('legacy no-sync source metadata edits remain available after refund', () async {
    await (db.update(db.transactions)..where((t) => t.id.equals(originalId))).write(
      const TransactionsCompanion(syncId: d.Value(null), currencyCode: d.Value(null), nativeAmount: d.Value(null)));
    await refund(amount: '30');
    await TransactionDetailService.update(repo, originalId, {'note': 'Legacy metadata'});
    expect((await repo.getTransactionById(originalId))!.note, 'Legacy metadata');
    expect((await service.load(originalId)).refundedMinor, 3000);
  });

  test('protected original account cannot be cleared through generic fields', () async {
    await refund(amount: '30');
    await expectLater(repo.updateTransactionFields(id: originalId,
      accountId: const d.Value<int?>(null)), throwsStateError);
    expect((await repo.getTransactionById(originalId))!.accountId, account);
  });
}
