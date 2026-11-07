import 'dart:io';

import 'package:beecount/cloud/sync/change_tracker.dart';
import 'package:beecount/data/db.dart';
import 'package:beecount/data/repositories/local/local_repository.dart';
import 'package:drift/native.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Paths extends PathProviderPlatform {
  final String directory;
  _Paths(this.directory);
  @override
  Future<String?> getApplicationDocumentsPath() async => directory;
  @override
  Future<String?> getTemporaryPath() async => directory;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late PathProviderPlatform previousPaths;
  late Directory directory;
  late BeeDatabase db;
  late LocalRepository repo;
  late File image;
  late int id;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('bill-delete-');
    previousPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(directory.path);
    db = BeeDatabase.forTesting(NativeDatabase.memory());
    repo = LocalRepository(db, changeTracker: ChangeTracker(db));
    final ledger = await repo.createLedger(name: 'cleanup');
    id = await repo.addTransaction(ledgerId: ledger, type: 'expense', amount: 10,
        happenedAt: DateTime(2026, 11, 8));
    await Directory('${directory.path}/attachments').create();
    image = await File('${directory.path}/attachments/shared.png').writeAsBytes([1, 2, 3]);
    await repo.createAttachment(transactionId: id, fileName: 'shared.png');
    await db.delete(db.localChanges).go();
  });
  tearDown(() async {
    await db.close();
    PathProviderPlatform.instance = previousPaths;
    await directory.delete(recursive: true);
  });

  test('failed deletion preserves file, bill, tags and outbox state', () async {
    final tag = await repo.createTag(name: 'keep');
    await repo.updateTransactionTags(transactionId: id, tagIds: [tag]);
    await db.delete(db.localChanges).go();
    await db.customStatement("""
      CREATE TRIGGER fail_delete BEFORE DELETE ON transactions
      BEGIN SELECT RAISE(ABORT, 'delete failed'); END
    """);
    await expectLater(repo.deleteTransaction(id), throwsA(isA<Exception>()));
    expect(await image.exists(), isTrue);
    expect(await repo.getTransactionById(id), isNotNull);
    expect(await db.select(db.transactionAttachments).get(), hasLength(1));
    expect(await db.select(db.transactionTags).get(), hasLength(1));
    expect(await db.select(db.localChanges).get(), isEmpty);
  });

  test('outer rollback never runs physical cleanup', () async {
    await expectLater(db.transaction(() async {
      await repo.deleteTransaction(id);
      expect(await image.exists(), isTrue);
      throw StateError('rollback outer');
    }), throwsStateError);
    expect(await image.exists(), isTrue);
    expect(await repo.getTransactionById(id), isNotNull);
    expect(await db.select(db.transactionAttachments).get(), hasLength(1));
  });

  test('committed deletion removes unreferenced image', () async {
    await repo.deleteTransaction(id);
    expect(await repo.getTransactionById(id), isNull);
    expect(await image.exists(), isFalse);
    expect((await db.select(db.localChanges).get()).single.action, 'delete');
  });

  test('shared image remains until the last referring bill is deleted', () async {
    final tx = (await repo.getTransactionById(id))!;
    final other = await repo.addTransaction(ledgerId: tx.ledgerId,
        type: 'expense', amount: 5, happenedAt: tx.happenedAt);
    await repo.createAttachment(transactionId: other, fileName: 'shared.png');
    await repo.deleteTransaction(id);
    expect(await image.exists(), isTrue);
    await repo.deleteTransaction(other);
    expect(await image.exists(), isFalse);
  });
}
