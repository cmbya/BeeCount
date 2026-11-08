import 'package:beecount/cloud/sync/change_tracker.dart';
import 'package:beecount/data/db.dart';
import 'package:beecount/data/repositories/local/local_repository.dart';
import 'package:drift/drift.dart' as d;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late BeeDatabase db;
  late LocalRepository repo;
  late int ledger, account, id;
  Future<void> role(String role, {bool shared = true}) =>
    (db.update(db.ledgers)..where((l) => l.id.equals(ledger)))
      .write(LedgersCompanion(isShared: d.Value(shared), myRole: d.Value(role))).then((_) {});
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = BeeDatabase.forTesting(NativeDatabase.memory());
    repo = LocalRepository(db, changeTracker: ChangeTracker(db));
    ledger = await repo.createLedger(name: 'Delete permissions');
    account = await repo.createAccount(ledgerId: ledger, name: 'Bank', initialBalance: 100);
    id = await repo.addTransaction(ledgerId: ledger, type: 'expense', amount: 10,
      happenedAt: DateTime(2026, 11, 5), accountId: account);
    await db.delete(db.localChanges).go();
  });
  tearDown(() async => db.close());

  for (final method in ['single', 'syncId', 'batch', 'batchWithoutTracker']) {
    test('viewer cannot delete through $method or create an outbox change', () async {
      final key = (await repo.getTransactionById(id))!.syncId!;
      await role('viewer');
      if (method == 'batchWithoutTracker') repo.changeTracker = null;
      final Future<Object?> Function() remove = switch (method) {
        'single' => () async { await repo.deleteTransaction(id); return null; },
        'syncId' => () async { await repo.deleteTransactionBySyncId(key); return null; },
        _ => () => repo.deleteTransactionsBatchBySyncIds([key], recordChanges: method != 'batchWithoutTracker'),
      };
      await expectLater(remove(), throwsA(isA<StateError>().having((e) => e.message, 'message', 'read_only')));
      expect(await repo.getTransactionById(id), isNotNull);
      // Joined shared ledgers never alter the member's personal net worth.
      expect(await repo.getAccountBalance(account), 100);
      expect(await repo.getAccountBalanceInLedger(account, ledger), -10);
      expect(await db.select(db.localChanges).get(), isEmpty);
    });
  }

  for (final allowedRole in ['owner', 'editor']) {
    test('$allowedRole can delete a shared bill normally', () async {
      await role(allowedRole);
      await repo.deleteTransaction(id);
      expect(await repo.getTransactionById(id), isNull);
      expect(await repo.getAccountBalance(account), 100);
      final changes = await db.select(db.localChanges).get();
      expect(changes.single.action, 'delete');
    });
  }

  test('batch is atomic when one target belongs to a read-only ledger', () async {
    final otherLedger = await repo.createLedger(name: 'Writable');
    final otherId = await repo.addTransaction(ledgerId: otherLedger, type: 'expense', amount: 2,
      happenedAt: DateTime(2026, 11, 5));
    final keys = [(await repo.getTransactionById(id))!.syncId!, (await repo.getTransactionById(otherId))!.syncId!];
    await db.delete(db.localChanges).go();
    await role('viewer');
    await expectLater(repo.deleteTransactionsBatchBySyncIds(keys), throwsStateError);
    expect(await repo.getTransactionById(id), isNotNull);
    expect(await repo.getTransactionById(otherId), isNotNull);
    expect(await db.select(db.localChanges).get(), isEmpty);
  });

  test('a nonshared ledger keeps its existing write semantics', () async {
    await role('viewer', shared: false);
    await repo.deleteTransaction(id);
    expect(await repo.getTransactionById(id), isNull);
  });
}
