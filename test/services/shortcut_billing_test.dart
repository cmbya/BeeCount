import 'dart:convert';
import 'package:beecount/cloud/sync/change_tracker.dart';
import 'package:beecount/data/db.dart';
import 'package:beecount/data/repositories/local/local_repository.dart';
import 'package:beecount/services/automation/shortcut_schema.dart';
import 'package:beecount/services/automation/shortcut_store.dart';
import 'package:beecount/cloud/transactions_json.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});
  late BeeDatabase db;
  late LocalRepository repo;
  late ShortcutStore store;
  late int ledger;
  late int account;
  late int category;
  late int family;
  late int personal;
  const requestId = '7f1a7e00-b1cb-442f-9930-527f32bc9399';

  setUp(() async {
    db = BeeDatabase.forTesting(NativeDatabase.memory());
    repo = LocalRepository(db, changeTracker: ChangeTracker(db));
    store = ShortcutStore(repo);
    ledger = await repo.createLedger(name: '个人账本');
    account = await repo.createAccount(ledgerId: ledger, name: '支付宝');
    category = await repo.createCategory(name: '测试分类', kind: 'expense');
    family = await repo.createTag(name: '家庭');
    personal = await repo.createTag(name: '个人');
  });
  tearDown(() async => db.close());

  Map<String, dynamic> payload() => {
        'schemaVersion': 1,
        'currency': 'CNY',
        'confirmed': true,
        'requestId': requestId,
        'ledgerId': ledger,
        'accountId': account,
        'type': 'expense',
        'occurredAt': '2026-11-05T18:30:00+08:00',
        'originalAmountMinor': 30000,
        'entries': [
          {
            'amountMinor': 8000,
            'categoryId': category,
            'note': '',
            'tagIds': [personal],
            'excludeFromBudget': false
          },
          {
            'amountMinor': 15000,
            'categoryId': category,
            'note': '家电',
            'tagIds': [family],
            'excludeFromBudget': true
          },
          {
            'amountMinor': 7000,
            'categoryId': category,
            'note': '日用',
            'tagIds': [family],
            'excludeFromBudget': false
          },
        ],
      };
  Future<int> count(String table) async =>
      (await db.customSelect('SELECT COUNT(*) AS n FROM ' + table).getSingle())
          .read<int>('n');
  Matcher failure(String code) =>
      isA<ShortcutFailure>().having((e) => e.code, 'code', code);

  test(
      'existing JSON backup round trip preserves split rows, tags and budget flags',
      () async {
    await store.commit(ShortcutSubmission.fromJson(payload()));
    final backup = await exportTransactionsJson(db, ledger);
    final restoredDb = BeeDatabase.forTesting(NativeDatabase.memory());
    final restored = LocalRepository(restoredDb);
    try {
      final id = await restored.createLedger(name: '恢复');
      expect((await importTransactionsJson(restored, id, backup)).inserted, 3);
      final rows = await restoredDb.select(restoredDb.transactions).get();
      expect(rows.map((t) => t.amount).reduce((a, b) => a + b), 300);
      expect(rows.where((t) => t.excludeFromBudget).single.amount, 150);
      expect((await restored.getAllTags()).map((t) => t.name).toSet(),
          {'家庭', '个人'});
      expect((await restoredDb.select(restoredDb.transactionTags).get()),
          hasLength(3));
      final budget = await restored.createBudget(
          ledgerId: id, type: 'total', amount: 1000);
      expect(
          (await restored.getBudgetUsage(budget, DateTime(2026, 11, 5))).used,
          150);
      expect((await restoredDb.select(restoredDb.accounts).get()).single.name,
          '支付宝');
    } finally {
      await restoredDb.close();
    }
  });

  test(
      'transfer receipt failure rolls back transfer and virtual category creation',
      () async {
    final target = await repo.createAccount(ledgerId: ledger, name: '目标');
    final data = payload()..['type'] = 'transfer';
    data['toAccountId'] = target;
    data['entries'] = [
      {
        ...(data['entries'] as List).first as Map<String, dynamic>,
        'amountMinor': 30000,
        'categoryId': null
      }
    ];
    await db.customStatement(
        "CREATE TRIGGER fail_transfer_receipt BEFORE INSERT ON shortcut_receipts BEGIN SELECT RAISE(ABORT, 'test'); END");
    await expectLater(store.commit(ShortcutSubmission.fromJson(data)),
        throwsA(failure('COMMIT_FAILED')));
    expect(await count('transactions'), 0);
    expect(await count('shortcut_groups'), 0);
    expect((await repo.getAllCategories()).where((c) => c.kind == 'transfer'),
        isEmpty);
    expect(await repo.getAccountBalance(account), 0);
    expect(await repo.getAccountBalance(target), 0);
  });

  test(
      'income saves one row, increases balance and does not use expense budget',
      () async {
    final income = await repo.createCategory(name: '工资', kind: 'income');
    final budget =
        await repo.createBudget(ledgerId: ledger, type: 'total', amount: 1000);
    final data = payload()..['type'] = 'income';
    data['entries'] = [
      {
        ...(data['entries'] as List).first as Map<String, dynamic>,
        'amountMinor': 30000,
        'categoryId': income,
        'excludeFromBudget': false
      }
    ];
    final request = ShortcutSubmission.fromJson(data);
    expect(
        (await store.commit(request, validateOnly: true))['status'], 'valid');
    expect(await count('transactions'), 0);
    final result = await store.commit(request);
    expect(result['type'], 'income');
    expect(result['count'], 1);
    expect(await repo.getAccountBalance(account), 300);
    expect((await repo.getBudgetUsage(budget, DateTime(2026, 11, 5))).used, 0);
    expect((await store.commit(request))['replayed'], true);
  });

  test('transfer uses one transfer row and moves balances without expense',
      () async {
    final target = await repo.createAccount(ledgerId: ledger, name: '银行卡');
    final data = payload()..['type'] = 'transfer';
    data['toAccountId'] = target;
    data['entries'] = [
      {
        ...(data['entries'] as List).first as Map<String, dynamic>,
        'amountMinor': 30000,
        'categoryId': null
      }
    ];
    final request = ShortcutSubmission.fromJson(data);
    final result = await store.commit(request);
    expect(result['count'], 1);
    expect(await count('transactions'), 1);
    final row = (await db.select(db.transactions).get()).single;
    expect(row.type, 'transfer');
    expect(row.toAccountId, target);
    expect((await repo.getTransferCategory()).id, row.categoryId);
    expect(await repo.getAccountBalance(account), -300);
    expect(await repo.getAccountBalance(target), 300);
    await store.commit(request);
    expect(await count('transactions'), 1);
  });

  test('invalid transfer destination and non-expense split never write',
      () async {
    final foreign = await repo.createAccount(
        ledgerId: ledger, name: 'USD', currency: 'USD');
    for (final target in [account, foreign, 999999]) {
      final data = payload()..['type'] = 'transfer';
      data['toAccountId'] = target;
      data['entries'] = [
        {
          ...(data['entries'] as List).first as Map<String, dynamic>,
          'amountMinor': 30000,
          'categoryId': null
        }
      ];
      try {
        await store.commit(ShortcutSubmission.fromJson(data));
        fail('must reject');
      } on ShortcutFailure catch (e) {
        expect(e.code, 'INVALID_REFERENCE');
      }
    }
    for (final type in ['income', 'transfer']) {
      expect(() => ShortcutSubmission.fromJson(payload()..['type'] = type),
          throwsA(failure('INVALID_REQUEST')));
    }
    expect(await count('transactions'), 0);
    expect(await count('shortcut_receipts'), 0);
  });

  test('switching ledger validates selected currency and category kind',
      () async {
    final other = await repo.createLedger(name: '其他账本');
    final data = payload()..['ledgerId'] = other;
    await store.commit(ShortcutSubmission.fromJson(data));
    expect(
        (await db.select(db.transactions).get())
            .every((t) => t.ledgerId == other),
        true);
    final wrong = payload()..['currency'] = 'USD';
    await expectLater(store.commit(ShortcutSubmission.fromJson(wrong)),
        throwsA(failure('REQUEST_CONFLICT')));
  });

  test('ledger precision drives committed native amounts', () async {
    for (final currency in ['JPY', 'KWD', 'USD']) {
      final id = await repo.createLedger(name: currency, currency: currency);
      final a = await repo.createAccount(
          ledgerId: id, name: currency, currency: currency);
      final data = payload();
      data['requestId'] = requestId.replaceFirst(
          '7f1a7e00',
          currency == 'JPY'
              ? '00000001'
              : currency == 'KWD'
                  ? '00000002'
                  : '00000003');
      data['ledgerId'] = id;
      data['currency'] = currency;
      data['accountId'] = a;
      final result = await store.commit(ShortcutSubmission.fromJson(data));
      final digits = shortcutCurrencyDigits(currency);
      expect(result['minorDigits'], digits);
      expect(result['currency'], currency);
      expect(await repo.getAccountBalance(a),
          -30000 / [1, 10, 100, 1000, 10000][digits]);
    }
  });

  test('reject impossible dates and oversized decimal strings', () {
    for (final time in [
      '2026-02-30T18:30:00+08:00',
      '2026-01-01T24:30:00Z',
      '2026-01-01T12:00:00+14:30'
    ]) {
      final data = payload()..['occurredAt'] = time;
      expect(() => ShortcutSubmission.fromJson(data),
          throwsA(failure('INVALID_REQUEST')));
    }
    expect(() => parseShortcutAmount('9' * 100),
        throwsA(failure('INVALID_AMOUNT')));
    expect(parseShortcutAmount('12', digits: 0), 12);
    expect(() => parseShortcutAmount('12.3', digits: 0),
        throwsA(failure('INVALID_AMOUNT')));
    expect(parseShortcutAmount('1.234', digits: 3), 1234);
  });

  test(
      '300 split: three rows, account -300, budget 150, tags 220/80, no original payment',
      () async {
    final budget =
        await repo.createBudget(ledgerId: ledger, type: 'total', amount: 1000);
    final result = await store.commit(ShortcutSubmission.fromJson(payload()));
    expect(result['count'], 3);
    expect(await count('transactions'), 3);
    expect(await repo.getAccountBalance(account), -300);
    expect(
        (await repo.getBudgetUsage(budget, DateTime(2026, 11, 5))).used, 150);
    final rows = await db
        .customSelect(
            'SELECT tag_id, SUM(t.amount) AS amount FROM transaction_tags tt JOIN transactions t ON t.id = tt.transaction_id GROUP BY tag_id')
        .get();
    final sums = {
      for (final r in rows) r.read<int>('tag_id'): r.read<double>('amount')
    };
    expect(sums[family], 220);
    expect(sums[personal], 80);
    expect((await db.select(db.transactions).get()).first.note, '');
    expect(await count('shortcut_groups'), 1);
    expect(await count('shortcut_receipts'), 1);
    final group = await db
        .customSelect('SELECT transaction_sync_ids FROM shortcut_groups')
        .getSingle();
    expect(
        jsonDecode(group.read<String>('transaction_sync_ids')), hasLength(3));
    expect(await count('local_changes'), greaterThanOrEqualTo(3));
  });

  test(
      'parallel retries return the same ids; normalized tags/time do not conflict',
      () async {
    final request = ShortcutSubmission.fromJson(payload());
    final results =
        await Future.wait(List.generate(8, (_) => store.commit(request)));
    expect(results.where((r) => r['replayed'] == false), hasLength(1));
    for (final r in results) {
      expect(r['transactionIds'], results.first['transactionIds']);
    }
    final normalized = payload()..['occurredAt'] = '2026-11-05T10:30:00Z';
    ((normalized['entries'] as List).first as Map)['tagIds'] = [
      personal,
      personal
    ];
    expect(
        (await store
            .commit(ShortcutSubmission.fromJson(normalized)))['replayed'],
        true);
    expect(await count('transactions'), 3);
  });

  test(
      'same id changed note conflicts; receipt remains valid after transaction deletion',
      () async {
    final result = await store.commit(ShortcutSubmission.fromJson(payload()));
    final changed = payload();
    (changed['entries'] as List).first['note'] = 'changed';
    await expectLater(store.commit(ShortcutSubmission.fromJson(changed)),
        throwsA(failure('REQUEST_CONFLICT')));
    await db.delete(db.transactions).go();
    expect((await store.query(requestId))['transactionIds'],
        result['transactionIds']);
    expect(
        (await store
            .commit(ShortcutSubmission.fromJson(payload())))['replayed'],
        true);
    expect(await count('transactions'), 0);
  });

  test('late tag failure rolls back all rows, group, receipt and changes',
      () async {
    final before = await count('local_changes');
    await db.customStatement(
        "CREATE TRIGGER reject_test_tag BEFORE INSERT ON transaction_tags WHEN NEW.tag_id = " +
            family.toString() +
            " BEGIN SELECT RAISE(ABORT, 'test failure'); END");
    await expectLater(store.commit(ShortcutSubmission.fromJson(payload())),
        throwsA(failure('COMMIT_FAILED')));
    for (final table in [
      'transactions',
      'transaction_tags',
      'shortcut_groups',
      'shortcut_receipts'
    ]) {
      expect(await count(table), 0);
    }
    expect(await count('local_changes'), before);
  });

  test('failed receipt insert rolls back formal transactions and tags',
      () async {
    await db.customStatement(
        "CREATE TRIGGER reject_receipt BEFORE INSERT ON shortcut_receipts BEGIN SELECT RAISE(ABORT, 'test failure'); END");
    await expectLater(store.commit(ShortcutSubmission.fromJson(payload())),
        throwsA(failure('COMMIT_FAILED')));
    expect(await count('transactions'), 0);
    expect(await count('transaction_tags'), 0);
    expect(await count('shortcut_groups'), 0);
  });

  test('deleted category/tag and hidden account reject before any writes',
      () async {
    await repo.setAccountHidden(account, true);
    await expectLater(store.commit(ShortcutSubmission.fromJson(payload())),
        throwsA(failure('INVALID_REFERENCE')));
    await repo.setAccountHidden(account, false);
    await repo.deleteTag(personal);
    await expectLater(store.commit(ShortcutSubmission.fromJson(payload())),
        throwsA(failure('INVALID_REFERENCE')));
    expect(await count('transactions'), 0);
  });

  test('budget flag survives existing update path and updates budget use',
      () async {
    final budget =
        await repo.createBudget(ledgerId: ledger, type: 'total', amount: 1000);
    final result = await store.commit(ShortcutSubmission.fromJson(payload()));
    final id = (result['transactionIds'] as List<int>)[1];
    await repo.updateTransaction(
        id: id, type: 'expense', amount: 150, excludeFromBudget: false);
    expect(
        (await repo.getBudgetUsage(budget, DateTime(2026, 11, 5))).used, 300);
  });

  test('cancelled/unconfirmed and invalid sums never enter persistence',
      () async {
    expect(() => ShortcutSubmission.fromJson(payload()..['confirmed'] = false),
        throwsA(failure('INVALID_REQUEST')));
    for (final amount in [0, -1, 7999, 8001, 80.1]) {
      final bad = payload();
      (bad['entries'] as List).first['amountMinor'] = amount;
      expect(() => ShortcutSubmission.fromJson(bad),
          throwsA(isA<ShortcutFailure>()));
    }
    expect(await count('transactions'), 0);
    expect((await store.query(requestId))['status'], 'not_found');
  });

  test('decimal amount conversion is exact and rejects extra precision', () {
    expect(parseShortcutAmount('0.01'), 1);
    expect(parseShortcutAmount('299.99'), 29999);
    expect(parseShortcutAmount('300'), 30000);
    for (final text in ['0', '-1', '1.001', 'NaN', 'Infinity', '1e2', '']) {
      expect(() => parseShortcutAmount(text), throwsA(isA<ShortcutFailure>()));
    }
  });

  test('rule CRUD validates category, preserves priority, disabled flag',
      () async {
    final rule = {
      'id': 'rule-a',
      'name': '咖啡',
      'enabled': 1,
      'ledger_id': ledger,
      'field': 'merchant',
      'match_mode': 'contains',
      'keyword': '瑞幸',
      'category_id': category,
      'priority': 10
    };
    await store.saveRule(rule);
    await store.saveRule({...rule, 'enabled': 0, 'priority': 20});
    expect((await store.rules()).single['enabled'], 0);
    expect((await store.rules()).single['priority'], 20);
    await expectLater(store.saveRule({...rule, 'category_id': 999999}),
        throwsA(failure('INVALID_REFERENCE')));
    await store.deleteRule('rule-a');
    expect(await store.rules(), isEmpty);
  });
}
