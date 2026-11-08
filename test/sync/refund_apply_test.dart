import 'package:beecount/cloud/sync/change_tracker.dart';
import 'package:beecount/cloud/sync/sync_engine.dart';
import 'package:beecount/data/db.dart';
import 'package:beecount/data/repositories/local/local_repository.dart';
import 'package:beecount/services/data/refund_service.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../cloud/sync/_fakes/fake_beecount_cloud_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final fresh in [false, true]) {
  test('cloud replay (fresh=$fresh) preserves refund exclusion without duplicate credit', () async {
    SharedPreferences.setMockInitialValues({});
    final db = BeeDatabase.forTesting(NativeDatabase.memory());
    addTearDown(() async => db.close());
    final tracker = ChangeTracker(db);
    final repo = LocalRepository(db);
    final cloud = FakeBeeCountCloudProvider();
    final engine = SyncEngine(db: db, provider: cloud, changeTracker: tracker, repo: repo);
    final ledger = await repo.createLedger(name: 'Refund');
    final account = await repo.createAccount(ledgerId: ledger, name: 'Bank', initialBalance: 1000);
    final original = await repo.addTransaction(ledgerId: ledger, type: 'expense',
      amount: 100, accountId: account, happenedAt: DateTime(2026, 11, 5));
    final service = RefundService(repo);
    final info = await service.load(original);
    final refund = await service.save(originalId: original,
      requestId: '00000000-0000-4000-8000-000000000001', customAmount: '30',
      expectedRemainingMinor: info.remainingMinor, expectedCurrency: info.currency, expected: info.original);
    if (fresh) {
      await (db.delete(db.transactions)..where((t) => t.id.equals(refund.id))).go();
    }
    final accountKey = (await repo.getAccount(account))!.syncId;
    final ledgerKey = (await repo.getLedgerById(ledger))!.syncId!;
    void push() => cloud.pushFakeChange(entityType: 'transaction',
      entitySyncId: refund.syncId!, ledgerId: ledgerKey, payload: {
        'syncId': refund.syncId, 'type': 'income', 'amount': 30,
        'happenedAt': info.original.happenedAt.toUtc().toIso8601String(),
        'accountId': accountKey, 'accountName': 'Bank',
        'currencyCode': 'CNY', 'nativeAmount': 30,
        'excludeFromStats': false, 'excludeFromBudget': false,
      });
    push(); await engine.pull('');
    push(); await engine.pull('');
    final tx = (await repo.getTransactionBySyncId(refund.syncId!))!;
    expect(tx.type, 'income'); expect(tx.excludeFromStats, true);
    expect(tx.excludeFromBudget, true);
    expect((await repo.getTransactionsByLedger(ledger)).length, 2);
    expect(await repo.getAccountBalance(account), 930);
    expect((await service.load(original)).refundedMinor, 3000);
  });
  }
}
