import 'dart:io';
import 'package:beecount/cloud/sync/change_tracker.dart';
import 'package:beecount/cloud/sync/sync_engine.dart';
import 'package:beecount/data/db.dart';
import 'package:beecount/data/repositories/local/local_repository.dart';
import 'package:beecount/models/refund_identity.dart';
import 'package:beecount/services/data/refund_service.dart';
import 'package:drift/native.dart';
import 'package:drift/drift.dart' as d;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../cloud/sync/_fakes/fake_beecount_cloud_provider.dart';

class _Paths extends PathProviderPlatform {
  final String path;
  _Paths(this.path);
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
  @override
  Future<String?> getTemporaryPath() async => path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late BeeDatabase db;
  late LocalRepository repo;
  late FakeBeeCountCloudProvider cloud;
  late SyncEngine engine;
  late int ledger, account, original;
  late Transaction source, credit;
  late String ledgerKey, accountKey;
  const secondRequest = '00000000-0000-4000-8000-000000000002';
  Map<String, dynamic> payload(Transaction tx) => {
    'type': tx.type, 'amount': tx.amount,
    'happenedAt': tx.happenedAt.toUtc().toIso8601String(),
    'accountId': accountKey, 'accountName': 'Bank',
    'currencyCode': tx.currencyCode, 'nativeAmount': tx.nativeAmount,
    'excludeFromStats': tx.excludeFromStats, 'excludeFromBudget': tx.excludeFromBudget,
  };
  void update(Transaction tx, Map<String, dynamic> fields) => cloud.pushFakeChange(
    entitySyncId: tx.syncId!, ledgerId: ledgerKey, payload: {...payload(tx), ...fields});
  void remove(String key) => cloud.pushFakeChange(entitySyncId: key, ledgerId: ledgerKey, action: 'delete');
  void padding(int count) {
    for (var i = 0; i < count; i++) {
      cloud.pushFakeChange(entityType: 'ignored', entitySyncId: 'padding-$i');
    }
  }
  Future<void> unchanged() async {
    expect(await engine.pull(''), 0);
    expect(await engine.appCursor.read(), 0);
    expect(await repo.getAccountBalance(account), 930);
    expect((await repo.getTransactionById(original))!.amount, 100);
    expect((await RefundService(repo).load(original)).refundedMinor, 3000);
    expect((await db.select(db.syncPullErrors).get()).single.resolvedAt, isNull);
  }
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = BeeDatabase.forTesting(NativeDatabase.memory()); repo = LocalRepository(db);
    cloud = FakeBeeCountCloudProvider();
    engine = SyncEngine(db: db, provider: cloud, changeTracker: ChangeTracker(db), repo: repo);
    ledger = await repo.createLedger(name: 'Refund');
    account = await repo.createAccount(ledgerId: ledger, name: 'Bank', initialBalance: 1000);
    original = await repo.addTransaction(ledgerId: ledger, type: 'expense', amount: 100,
      accountId: account, happenedAt: DateTime(2026, 11, 5));
    final service = RefundService(repo);
    final info = await service.load(original);
    credit = await service.save(originalId: original, requestId: '00000000-0000-4000-8000-000000000001',
      customAmount: '30', expectedRemainingMinor: info.remainingMinor, expectedCurrency: info.currency, expected: info.original);
    source = (await repo.getTransactionById(original))!;
    ledgerKey = (await repo.getLedgerById(ledger))!.syncId!;
    accountKey = (await repo.getAccount(account))!.syncId!;
  });
  tearDown(() async => db.close());

  for (final field in ['amount', 'type', 'happenedAt', 'accountId', 'currencyCode', 'nativeAmount']) {
    test('pull rolls back protected source $field changes and leaves cursor', () async {
      final other = await repo.createAccount(ledgerId: ledger, name: 'Other');
      final value = switch (field) {
        'amount' => 20,
        'type' => 'income',
        'happenedAt' => DateTime(2026, 11, 6).toUtc().toIso8601String(),
        'accountId' => (await repo.getAccount(other))!.syncId!,
        'currencyCode' => 'USD',
        _ => 700,
      };
      update(source, {field: value});
      await unchanged();
    });
  }

  test('changing a referenced account currency cannot invalidate its refunds', () async {
    cloud.pushFakeChange(entityType: 'account', entitySyncId: accountKey, ledgerId: ledgerKey,
      payload: {'name': 'Bank', 'type': 'cash', 'currency': 'USD', 'initialBalance': 1000});
    await unchanged();
    expect((await repo.getAccount(account))!.currency, 'CNY');
  });
  test('orphan source deletion rolls back even when the account balance would change', () async {
    remove(source.syncId!); await unchanged();
  });
  test('sum of concurrent partial refunds cannot exceed the original', () async {
    cloud.pushFakeChange(entitySyncId: RefundIdentity(source.syncId!, secondRequest).encode(),
      ledgerId: ledgerKey, payload: {...payload(credit), 'amount': 80, 'nativeAmount': 80});
    await unchanged();
  });
  test('existing credit cannot be silently rewritten', () async {
    update(credit, {'amount': 20, 'nativeAmount': 20}); await unchanged();
  });
  test('a mismatched new credit is rejected before commit', () async {
    cloud.pushFakeChange(entitySyncId: RefundIdentity(source.syncId!, secondRequest).encode(),
      ledgerId: ledgerKey, payload: {...payload(credit),
        'happenedAt': DateTime(2026, 11, 6).toUtc().toIso8601String()});
    await unchanged();
  });
  test('a later valid server state resolves a blocked group without losing its cursor', () async {
    update(source, {'amount': 20, 'nativeAmount': 20}); await unchanged();
    update(source, {});
    expect(await engine.pull(''), 2);
    expect(await engine.appCursor.read(), 2);
    expect(await repo.getAccountBalance(account), 930);
    expect((await db.select(db.syncPullErrors).get()).single.resolvedAt, isNotNull);
  });
  test('direct apply cannot bypass source/refund validation', () async {
    final change = cloud.pushFakeChange(entitySyncId: source.syncId!, ledgerId: ledgerKey,
      payload: {...payload(source), 'amount': 20});
    await expectLater(engine.applyRemoteChange(change), throwsStateError);
    expect((await repo.getTransactionById(original))!.amount, 100);
    expect(await repo.getAccountBalance(account), 930);
    expect(await engine.appCursor.read(), 0);
  });
  test('orphan credits cannot be committed on a fresh device', () async {
    await db.delete(db.transactions).go(); update(credit, {});
    expect(await engine.pull(''), 0);
    expect(await repo.getTransactionsByLedger(ledger), isEmpty);
    expect(await engine.appCursor.read(), 0);
  });
  for (final money in [('JPY', 1.0), ('KWD', 0.001)]) {
    test('refund sync uses currency minor units for ${money.$1}', () async {
      await db.delete(db.transactions).go();
      await (db.update(db.accounts)..where((a) => a.id.equals(account)))
        .write(AccountsCompanion(currency: d.Value(money.$1)));
      final time = source.happenedAt.toUtc().toIso8601String();
      final key = 'original-${money.$1}';
      cloud.pushFakeChange(entitySyncId: key, ledgerId: ledgerKey, payload: {
        'type': 'expense', 'amount': 10, 'accountId': accountKey,
        'happenedAt': time, 'currencyCode': money.$1, 'nativeAmount': 10,
      });
      cloud.pushFakeChange(entitySyncId: RefundIdentity(key, secondRequest).encode(),
        ledgerId: ledgerKey, payload: {'type': 'income', 'amount': money.$2,
          'accountId': accountKey, 'happenedAt': time, 'currencyCode': money.$1,
          'nativeAmount': money.$2});
      expect(await engine.pull(''), 2);
      expect(await engine.appCursor.read(), 2);
      expect(await db.select(db.syncPullErrors).get(), isEmpty);
    });
  }
  test('normal partial credit keeps the account and inherited FX rate', () async {
    cloud.pushFakeChange(entitySyncId: RefundIdentity(source.syncId!, secondRequest).encode(),
      ledgerId: ledgerKey, payload: {...payload(credit), 'amount': 20, 'nativeAmount': 20});
    expect(await engine.pull(''), 1);
    expect((await RefundService(repo).load(original)).refundedMinor, 5000);
    expect(await repo.getAccountBalance(account), 950);
  });
  test('metadata-only updates and exact replay remain idempotent', () async {
    update(source, {'note': 'metadata only'}); update(credit, {});
    expect(await engine.pull(''), 2); expect(await repo.getAccountBalance(account), 930);
    expect(await engine.appCursor.read(), 2);
    expect(await db.select(db.syncPullErrors).get(), isEmpty);
  });
  test('removing a credit reverses it once without deleting its source', () async {
    remove(credit.syncId!);
    expect(await engine.pull(''), 1); expect(await repo.getAccountBalance(account), 900);
    expect(await repo.getTransactionById(original), isNotNull);
  });

  for (final sourceFirst in [true, false]) {
    test('whole-group deletes work in either order ($sourceFirst)', () async {
      for (final tx in sourceFirst ? [source, credit] : [credit, source]) { remove(tx.syncId!); }
      expect(await engine.pull(''), 2); expect(await repo.getTransactionsByLedger(ledger), isEmpty);
      expect(await repo.getAccountBalance(account), 1000);
      expect(await engine.appCursor.read(), 2);
    });
  }
  test('whole-group delete crossing a page boundary is atomic', () async {
    remove(source.syncId!); padding(499); remove(credit.syncId!);
    expect(await engine.pull(''), 2); expect(await engine.appCursor.read(), 501);
    expect(await repo.getTransactionsByLedger(ledger), isEmpty);
    expect(await repo.getAccountBalance(account), 1000);
    expect(await db.select(db.syncPullErrors).get(), isEmpty);
    expect(cloud.pullCalls.map((c) => c.since).toList(), [0, 500]);
  });
  test('fresh credit-before-source replay across pages does not leave an orphan', () async {
    await db.delete(db.transactions).go();
    update(credit, {}); padding(499); update(source, {});
    expect(await engine.pull(''), 2); expect(await engine.appCursor.read(), 501);
    expect(await repo.getAccountBalance(account), 930);
    expect(await db.select(db.syncPullErrors).get(), isEmpty);
  });
  test('failed cross-page group keeps the old cursor and all local rows', () async {
    remove(source.syncId!); padding(500); await unchanged();
    expect(cloud.pullCalls.length, 2);
  });

  test('shared files remain until the last reference is successfully deleted', () async {
    final dir = await Directory.systemTemp.createTemp('refund-sync-shared-');
    final previousPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(dir.path);
    addTearDown(() async { PathProviderPlatform.instance = previousPaths; await dir.delete(recursive: true); });
    final file = File('${dir.path}/attachments/shared.png');
    final thumb = File('${dir.path}/attachment_thumbs/shared_thumb.jpg');
    await file.parent.create(recursive: true); await thumb.parent.create(recursive: true);
    await file.writeAsBytes([1]); await thumb.writeAsBytes([2]);
    for (final tx in [source, credit]) {
      await db.into(db.transactionAttachments).insert(TransactionAttachmentsCompanion.insert(
        transactionId: tx.id, fileName: 'shared.png'));
    }
    remove(credit.syncId!); expect(await engine.pull(''), 1);
    expect(await file.exists(), true); expect(await thumb.exists(), true);
    remove(source.syncId!); expect(await engine.pull(''), 1);
    expect(await file.exists(), false); expect(await thumb.exists(), false);
  });

  for (final deleteRow in [true, false]) {
    test('refund rollback retains attachment row, original file and thumbnail ($deleteRow)', () async {
      final dir = await Directory.systemTemp.createTemp('refund-sync-test-');
      final previousPaths = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _Paths(dir.path);
      addTearDown(() async {
        PathProviderPlatform.instance = previousPaths;
        await dir.delete(recursive: true);
      });
      final file = File('${dir.path}/attachments/proof.png');
      final thumb = File('${dir.path}/attachment_thumbs/proof_thumb.jpg');
      await file.parent.create(recursive: true); await thumb.parent.create(recursive: true);
      await file.writeAsBytes([1, 2]); await thumb.writeAsBytes([3]);
      await db.into(db.transactionAttachments).insert(TransactionAttachmentsCompanion.insert(
        transactionId: original, fileName: 'proof.png'));
      if (deleteRow) { remove(source.syncId!); }
      else { update(source, {'amount': 20, 'nativeAmount': 20, 'attachments': []}); }
      await unchanged();
      expect(await file.exists(), true); expect(await thumb.exists(), true);
      expect((await db.select(db.transactionAttachments).get()).single.transactionId, original);
    });
  }
}
