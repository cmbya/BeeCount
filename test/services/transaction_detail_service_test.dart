import 'package:beecount/data/db.dart';
import 'package:beecount/data/repositories/local/local_repository.dart';
import 'package:beecount/services/data/transaction_detail_service.dart';
import 'package:drift/drift.dart' as d;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late BeeDatabase db;
  late LocalRepository repo;
  late int ledger;
  late int category;
  late int account;
  late int id;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = BeeDatabase.forTesting(NativeDatabase.memory());
    repo = LocalRepository(db);
    ledger = await repo.createLedger(name: '详情账本');
    category = await repo.createCategory(name: '水电', kind: 'expense');
    account = await repo.createAccount(ledgerId: ledger, name: '信用卡', type: 'credit_card');
    id = await repo.addTransaction(ledgerId: ledger, type: 'expense', amount: 127.89,
      categoryId: category, accountId: account, happenedAt: DateTime(2026, 11, 5, 12, 32),
      note: '原备注', excludeFromBudget: true, currencyCode: 'CNY', nativeAmount: 127.89);
  });
  tearDown(() async => db.close());

  test('note edit and clear preserve account category flags and monetary snapshot', () async {
    await TransactionDetailService.update(repo, id, {'note': '直接修改'});
    var tx = (await repo.getTransactionById(id))!;
    expect(tx.note, '直接修改'); expect(tx.categoryId, category); expect(tx.accountId, account);
    expect(tx.excludeFromBudget, true); expect(tx.nativeAmount, 127.89);
    await TransactionDetailService.update(repo, id, {'note': ''});
    tx = (await repo.getTransactionById(id))!;
    expect(tx.note, ''); expect(tx.currencyCode, 'CNY'); expect(tx.happenedAt, DateTime(2026, 11, 5, 12, 32));
  });

  test('single-field update retains overrides on shared editor rows', () async {
    await (db.update(db.ledgers)..where((r) => r.id.equals(ledger))).write(
      const LedgersCompanion(isShared: d.Value(true), myRole: d.Value('editor')));
    await (db.update(db.transactions)..where((r) => r.id.equals(id))).write(
      const TransactionsCompanion(categorySyncIdOverride: d.Value('owner-category'), accountSyncIdOverride: d.Value('owner-account'), toAccountSyncIdOverride: d.Value('owner-to')));
    await TransactionDetailService.update(repo, id, {'note': '不清引用'});
    final tx = (await repo.getTransactionById(id))!;
    expect(tx.categorySyncIdOverride, 'owner-category'); expect(tx.accountSyncIdOverride, 'owner-account');
    expect(tx.toAccountSyncIdOverride, 'owner-to');
  });

  test('budget and stats flags update independently and keep tags', () async {
    final tag = await repo.createTag(name: '家庭');
    await repo.updateTransactionTags(transactionId: id, tagIds: [tag]);
    await TransactionDetailService.update(repo, id, {'excludeFromStats': true});
    var tx = (await repo.getTransactionById(id))!;
    expect(tx.excludeFromStats, true); expect(tx.excludeFromBudget, true);
    await TransactionDetailService.update(repo, id, {'excludeFromBudget': false});
    tx = (await repo.getTransactionById(id))!;
    expect(tx.excludeFromStats, true); expect(tx.excludeFromBudget, false);
    expect((await repo.getTagsForTransaction(id)).single.id, tag);
  });

  test('bad amount and read-only ledger reject without writing', () async {
    for (final amount in [0.0, -1.0, double.infinity, 1.001]) {
      await expectLater(TransactionDetailService.update(repo, id, {'amount': amount}), throwsStateError);
    }
    await (db.update(db.ledgers)..where((r) => r.id.equals(ledger))).write(
      const LedgersCompanion(isShared: d.Value(true), myRole: d.Value('viewer')));
    await expectLater(TransactionDetailService.update(repo, id, {'note': '禁止'}), throwsStateError);
    expect((await repo.getTransactionById(id))!.note, '原备注');
    expect((await repo.getTransactionById(id))!.amount, 127.89);
  });

  test('amount preserves implicit exchange rate and transfer endpoints', () async {
    final other = await repo.createAccount(ledgerId: ledger, name: '储蓄卡', type: 'bank_card');
    await (db.update(db.transactions)..where((r) => r.id.equals(id))).write(
      TransactionsCompanion(type: const d.Value('transfer'), toAccountId: d.Value(other),
        nativeAmount: const d.Value(255.78)));
    await TransactionDetailService.update(repo, id, {'amount': 100.0});
    final tx = (await repo.getTransactionById(id))!;
    expect(tx.nativeAmount, closeTo(200, 0.00001)); expect(tx.accountId, account); expect(tx.toAccountId, other);
  });

  test('clear account is explicit, currency change requires a real rate', () async {
    await expectLater(TransactionDetailService.update(repo, id, {'currency': 'USD'}), throwsStateError);
    expect((await repo.getTransactionById(id))!.accountId, account);
    await TransactionDetailService.update(repo, id, {'account': null});
    expect((await repo.getTransactionById(id))!.accountId, isNull);
    expect((await repo.getTransactionById(id))!.categoryId, category);
  });

  test('tags can clear and private ledger move preserves transaction identity', () async {
    final tag = await repo.createTag(name: '个人');
    final value = (await repo.getAllTags()).single;
    await TransactionDetailService.update(repo, id, {'tags': [value]});
    expect((await repo.getTagsForTransaction(id)).single.id, tag);
    await TransactionDetailService.update(repo, id, {'tags': <Tag>[]});
    expect(await repo.getTagsForTransaction(id), isEmpty);
    final next = await repo.createLedger(name: '目标');
    final syncId = (await repo.getTransactionById(id))!.syncId;
    await TransactionDetailService.update(repo, id, {'ledgerId': next});
    final tx = (await repo.getTransactionById(id))!;
    expect(tx.ledgerId, next); expect(tx.syncId, syncId); expect(tx.accountId, account);
  });
  test('transfer destination changes only the selected endpoint', () async {
    final to = await repo.createAccount(ledgerId: ledger, name: '原收款', type: 'bank_card');
    final next = await repo.createAccount(ledgerId: ledger, name: '新收款', type: 'bank_card');
    await (db.update(db.transactions)..where((r) => r.id.equals(id))).write(
      TransactionsCompanion(type: const d.Value('transfer'), toAccountId: d.Value(to)));
    await TransactionDetailService.update(repo, id, {'toAccount': await repo.getAccount(next)});
    final tx = (await repo.getTransactionById(id))!;
    expect(tx.accountId, account); expect(tx.toAccountId, next); expect(tx.note, '原备注');
    await expectLater(TransactionDetailService.update(repo, id, {'toAccount': await repo.getAccount(account)}), throwsStateError);
    expect((await repo.getTransactionById(id))!.toAccountId, next);
  });

}
