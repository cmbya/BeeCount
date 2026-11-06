import 'dart:convert';
import 'package:beecount/data/db.dart';
import 'package:beecount/data/repositories/local/local_repository.dart';
import 'package:beecount/services/automation/shortcut_schema.dart';
import 'package:beecount/services/automation/shortcut_store.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late BeeDatabase db;
  late LocalRepository repo;
  late ShortcutStore store;
  late int ledger;
  late int account;
  late int category;
  const session = '12345678-1111-4222-8333-123456789abc';
  String id(int index) => '87654321-1111-4222-8333-${index.toString().padLeft(12, '0')}';
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = BeeDatabase.forTesting(NativeDatabase.memory());
    repo = LocalRepository(db);
    store = ShortcutStore(repo);
    ledger = await repo.createLedger(name: '拆分测试');
    account = await repo.createAccount(ledgerId: ledger, name: '付款账户');
    category = await repo.createCategory(name: '拆分分类', kind: 'expense');
  });
  tearDown(() async => db.close());
  Map<String, dynamic> payload(int index, int amount) => {
    'schemaVersion': 1, 'confirmed': true, 'requestId': id(index),
    'ledgerId': ledger, 'accountId': account, 'currency': 'CNY', 'type': 'expense',
    'occurredAt': '2026-11-06T18:30:00+08:00', 'originalAmountMinor': amount,
    'entries': [{'amountMinor': amount, 'categoryId': category,
      'note': '第$index笔', 'tagIds': <int>[], 'excludeFromBudget': index == 2}],
    'split': {'sessionId': session, 'partIndex': index, 'totalMinor': 30000},
  };
  Future<int> count(String table) async =>
      (await db.customSelect('SELECT COUNT(*) AS n FROM $table').getSingle()).read<int>('n');
  Future<Map<String, dynamic>> progress() async =>
      (await db.customSelect('SELECT * FROM shortcut_split_sessions').getSingle()).data;
  Matcher failure(String code) => isA<ShortcutFailure>().having((e) => e.code, 'code', code);

  test('each confirmed part saves immediately; identical retries cannot double-charge', () async {
    final first = ShortcutSubmission.fromJson(payload(1, 8000));
    expect((await store.commit(first, validateOnly: true))['status'], 'valid');
    expect(await count('transactions'), 0);
    expect(await count('shortcut_split_sessions'), 0, reason: 'Validation must not create a persisted draft/session');
    final saved1 = await store.commit(first);
    expect(saved1['split']['paidMinor'], 8000);
    expect(saved1['split']['remainingMinor'], 22000);
    expect(await count('transactions'), 1);
    expect((await store.commit(first))['replayed'], true);
    expect((await store.querySplit(first))['replayed'], true);
    expect(await count('transactions'), 1);
    expect((await progress())['saved_count'], 1);

    final saved2 = await store.commit(ShortcutSubmission.fromJson(payload(2, 15000)));
    expect(saved2['split']['paidMinor'], 23000);
    expect(saved2['split']['remainingMinor'], 7000);
    expect(await count('transactions'), 2, reason: 'Stopping now must leave both parts saved');
    // Retry an old state after the next bill is already saved: no extra record.
    expect((await store.commit(first))['split']['paidMinor'], 8000);
    expect((await progress())['paid_minor'], 23000);
    final saved3 = await store.commit(ShortcutSubmission.fromJson(payload(3, 7000)));
    expect(saved3['split']['remainingMinor'], 0);
    expect(saved3['split']['savedCount'], 3);
    final rows = await db.select(db.transactions).get();
    expect(rows.map((r) => r.amount).toList(), [80, 150, 70]);
    expect(rows.where((r) => r.excludeFromBudget).single.amount, 150);
    expect(await count('shortcut_receipts'), 3);
  });

  test('stale slot, skipped slot, over-allocation and changed payload are rejected', () async {
    final first = ShortcutSubmission.fromJson(payload(1, 8000));
    await store.commit(first);
    final changed = payload(1, 7000);
    await expectLater(store.commit(ShortcutSubmission.fromJson(changed)), throwsA(failure('REQUEST_CONFLICT')));
    await expectLater(store.querySplit(ShortcutSubmission.fromJson(changed)), throwsA(failure('REQUEST_CONFLICT')));
    final fork = payload(1, 8000)..['requestId'] = id(50);
    await expectLater(store.commit(ShortcutSubmission.fromJson(fork)), throwsA(failure('SPLIT_STALE')));
    await expectLater(store.commit(ShortcutSubmission.fromJson(payload(3, 1000))), throwsA(failure('SPLIT_STALE')));
    await expectLater(store.commit(ShortcutSubmission.fromJson(payload(2, 23000))), throwsA(failure('SPLIT_STALE')));
    expect(await count('transactions'), 1);
    expect((await progress())['paid_minor'], 8000);
  });

  test('failed part rolls back only that part and does not consume balance', () async {
    await store.commit(ShortcutSubmission.fromJson(payload(1, 8000)));
    await db.customStatement("CREATE TRIGGER fail_part_receipt BEFORE INSERT ON shortcut_receipts BEGIN SELECT RAISE(ABORT, 'test'); END");
    await expectLater(store.commit(ShortcutSubmission.fromJson(payload(2, 15000))), throwsA(failure('COMMIT_FAILED')));
    expect(await count('transactions'), 1);
    expect(await count('shortcut_receipts'), 1);
    expect((await progress())['paid_minor'], 8000);
    expect((await progress())['saved_count'], 1);
    await db.customStatement('DROP TRIGGER fail_part_receipt');
    expect((await store.commit(ShortcutSubmission.fromJson(payload(2, 15000))))['split']['remainingMinor'], 7000);
  });

  test('first-part rollback leaves no persisted split session or transaction', () async {
    await db.customStatement("CREATE TRIGGER fail_first_receipt BEFORE INSERT ON shortcut_receipts BEGIN SELECT RAISE(ABORT, 'test'); END");
    await expectLater(store.commit(ShortcutSubmission.fromJson(payload(1, 8000))), throwsA(failure('COMMIT_FAILED')));
    expect(await count('transactions'), 0);
    expect(await count('shortcut_split_sessions'), 0);
    expect(await count('shortcut_groups'), 0);
  });

  test('ledger account currency and total cannot change after a successful part', () async {
    await store.commit(ShortcutSubmission.fromJson(payload(1, 8000)));
    final otherAccount = await repo.createAccount(ledgerId: ledger, name: '其他账户');
    final accountChanged = payload(2, 1000)..['accountId'] = otherAccount;
    await expectLater(store.commit(ShortcutSubmission.fromJson(accountChanged)), throwsA(failure('SPLIT_CONFLICT')));
    final totalChanged = payload(2, 1000);
    totalChanged['split'] = {'sessionId': session, 'partIndex': 2, 'totalMinor': 50000};
    await expectLater(store.commit(ShortcutSubmission.fromJson(totalChanged)), throwsA(failure('SPLIT_CONFLICT')));
    expect((await progress())['paid_minor'], 8000);
  });

  test('whole-bill and progressive save mutually exclude the same source request', () async {
    final whole = payload(1, 30000)..remove('split');
    whole['requestId'] = session;
    await store.commit(ShortcutSubmission.fromJson(whole));
    await expectLater(store.commit(ShortcutSubmission.fromJson(payload(1, 8000))), throwsA(failure('SPLIT_CONFLICT')));
    expect(await count('transactions'), 1);
  });

  test('cannot save old whole-bill confirmation after any progressive part', () async {
    await store.commit(ShortcutSubmission.fromJson(payload(1, 8000)));
    final whole = payload(1, 30000)..remove('split');
    whole['requestId'] = session;
    await expectLater(store.commit(ShortcutSubmission.fromJson(whole)), throwsA(failure('SPLIT_STARTED')));
    expect(await count('transactions'), 1);
  });

  test('query result includes durable progress and schema migration is repeatable', () async {
    final first = ShortcutSubmission.fromJson(payload(1, 8000));
    expect((await store.querySplit(first))['status'], 'not_found');
    await store.commit(first);
    final result = await store.query(first.requestId);
    expect(jsonDecode(jsonEncode(result))['split']['remainingMinor'], 22000);
    await db.migration.onUpgrade(db.createMigrator(), 34, 35);
    await db.migration.onUpgrade(db.createMigrator(), 34, 35);
    expect((await progress())['paid_minor'], 8000);
    expect(await count('transactions'), 1);
  });

  test('schema rejects income, multi-entry and invalid part-index progressive requests', () {
    final invalid = payload(1, 8000)..['type'] = 'income';
    expect(() => ShortcutSubmission.fromJson(invalid), throwsA(failure('INVALID_SPLIT')));
    final multiple = payload(1, 8000);
    multiple['entries'] = [
      {...(multiple['entries'] as List).single as Map<String, dynamic>, 'amountMinor': 4000},
      {...(multiple['entries'] as List).single as Map<String, dynamic>, 'amountMinor': 4000},
    ];
    expect(() => ShortcutSubmission.fromJson(multiple), throwsA(failure('INVALID_SPLIT')));
    final index = payload(1, 8000);
    index['split'] = {'sessionId': session, 'partIndex': 101, 'totalMinor': 30000};
    expect(() => ShortcutSubmission.fromJson(index), throwsA(failure('INVALID_SPLIT')));
  });
}
