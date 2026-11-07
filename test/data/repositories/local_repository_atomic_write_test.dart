import 'package:beecount/cloud/sync/change_tracker.dart';
import 'package:beecount/data/db.dart';
import 'package:beecount/data/repositories/local/local_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late BeeDatabase db;
  late LocalRepository repo;
  late int ledger;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = BeeDatabase.forTesting(NativeDatabase.memory());
    repo = LocalRepository(db, changeTracker: ChangeTracker(db));
    ledger = await repo.createLedger(name: 'local');
  });
  tearDown(() async => db.close());

  Future<int> add() => repo.addTransaction(
        ledgerId: ledger, type: 'expense', amount: 10,
        happenedAt: DateTime(2026, 11, 8), note: 'original',
      );
  Future<void> rejectOutbox(String action) => db.customStatement("""
    CREATE TRIGGER reject_outbox BEFORE INSERT ON local_changes
    WHEN NEW.entity_type = 'transaction' AND NEW.action = '$action'
    BEGIN SELECT RAISE(ABORT, 'injected outbox failure'); END
  """);

  test('create rolls back the transaction when the outbox insert fails', () async {
    await rejectOutbox('create');
    await expectLater(add(), throwsA(isA<Exception>()));
    expect(await db.select(db.transactions).get(), isEmpty);
    expect(await db.select(db.localChanges).get(), isEmpty);
    await db.customStatement('DROP TRIGGER reject_outbox');
    await add();
    expect(await db.select(db.transactions).get(), hasLength(1));
    final changes = await db.select(db.localChanges).get();
    expect(changes, hasLength(1));
    expect(changes.single.action, 'create');
  });

  test('update rolls back the changed fields when outbox insert fails', () async {
    final id = await add();
    await db.delete(db.localChanges).go();
    await rejectOutbox('update');
    await expectLater(repo.updateTransaction(
      id: id, type: 'expense', amount: 25, note: 'changed',
    ), throwsA(isA<Exception>()));
    final tx = await repo.getTransactionById(id);
    expect(tx!.amount, 10);
    expect(tx.nativeAmount, 10);
    expect(tx.note, 'original');
    expect(await db.select(db.localChanges).get(), isEmpty);
  });

  test('delete rolls back its outbox record if deleting the row fails', () async {
    final id = await add();
    await db.delete(db.localChanges).go();
    await db.customStatement("""
      CREATE TRIGGER reject_delete BEFORE DELETE ON transactions
      BEGIN SELECT RAISE(ABORT, 'injected delete failure'); END
    """);
    await expectLater(repo.deleteTransaction(id), throwsA(isA<Exception>()));
    expect(await repo.getTransactionById(id), isNotNull);
    expect(await db.select(db.localChanges).get(), isEmpty);
  });

  test('successful create update delete each record exactly one change', () async {
    final id = await add();
    await repo.updateTransaction(id: id, type: 'expense', amount: 20);
    await repo.deleteTransaction(id);
    final changes = await db.select(db.localChanges).get();
    expect(changes.map((c) => c.action), ['create', 'update', 'delete']);
    expect(await db.select(db.transactions).get(), isEmpty);
  });

  test('attachment insert rolls back when its outbox update fails', () async {
    final id = await add();
    await db.delete(db.localChanges).go();
    await rejectOutbox('update');
    await expectLater(repo.createAttachment(transactionId: id, fileName: 'image.png'),
        throwsA(isA<Exception>()));
    expect(await db.select(db.transactionAttachments).get(), isEmpty);
    expect(await repo.getTransactionById(id), isNotNull);
    expect(await db.select(db.localChanges).get(), isEmpty);
  });

  test('attachment removal rolls back when its outbox update fails', () async {
    final id = await add();
    final attachment = await repo.createAttachment(
        transactionId: id, fileName: 'image.png');
    await db.delete(db.localChanges).go();
    await rejectOutbox('update');
    await expectLater(repo.deleteAttachment(attachment), throwsA(isA<Exception>()));
    expect(await db.select(db.transactionAttachments).get(), hasLength(1));
    await expectLater(repo.deleteAttachmentsByTransaction(id),
        throwsA(isA<Exception>()));
    expect(await db.select(db.transactionAttachments).get(), hasLength(1));
    expect(await db.select(db.localChanges).get(), isEmpty);
  });

  test('local-only writes still work without an outbox', () async {
    repo = LocalRepository(db);
    final id = await add();
    await repo.updateTransaction(id: id, type: 'expense', amount: 20);
    await repo.deleteTransaction(id);
    expect(await db.select(db.localChanges).get(), isEmpty);
  });
}
