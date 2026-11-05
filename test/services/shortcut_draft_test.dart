import 'dart:convert';
import 'package:beecount/data/db.dart';
import 'package:beecount/data/repositories/local/local_repository.dart';
import 'package:beecount/providers/database_providers.dart';
import 'package:beecount/services/automation/shortcut_service.dart';
import 'package:beecount/services/automation/shortcut_store.dart';
import 'package:beecount/services/system/logger_service.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late BeeDatabase db;
  late LocalRepository repo;
  late ProviderContainer container;
  late int ledger;
  late int category;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = BeeDatabase.forTesting(NativeDatabase.memory());
    repo = LocalRepository(db);
    ledger = await repo.createLedger(name: 'Test');
    category = await repo.createCategory(name: '个人规则分类', kind: 'expense');
    container = ProviderContainer(
        overrides: [repositoryProvider.overrideWithValue(repo)]);
  });
  tearDown(() async {
    container.dispose();
    await db.close();
  });

  test('private async recognition logs are suppressed and defaults are fresh',
      () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        shortcutDefaultsKey,
        jsonEncode({
          'tagIds': [99999],
          'accountId': 99999,
          'mode': 'text'
        }));
    final opts = await ShortcutService(container).options(ledger);
    expect(opts['defaults']['tagIds'], isEmpty);
    expect(opts['defaults']['accountId'], isNull);
    await LoggerService.withoutLogging(() async {
      await Future<void>.delayed(Duration.zero);
      logger.warning('PrivateTest', 'secret bill text');
    });
    expect(logger.logs.where((l) => l.tag == 'PrivateTest'), isEmpty);
  });

  test('OCR draft sends no image, user rule beats AI, no transaction saved',
      () async {
    await repo.createCategory(name: 'AI分类', kind: 'expense');
    await ShortcutStore(repo).saveRule({
      'id': 'r',
      'name': '咖啡',
      'enabled': 1,
      'ledger_id': ledger,
      'field': 'merchant',
      'match_mode': 'contains',
      'keyword': '瑞幸',
      'category_id': category,
      'priority': 100
    });
    var called = 0;
    final service = ShortcutService(container, extract: (prompt, image) async {
      called++;
      expect(image, isNull);
      expect(prompt, contains('瑞幸实付 12.30'));
      return jsonEncode([
        {
          'type': 'expense',
          'amount': '12.30',
          'merchant': '瑞幸',
          'category': 'AI分类',
          'note': '咖啡原文',
          'time': '2026-11-05T18:30:00+08:00',
          'currency': 'CNY'
        }
      ]);
    });
    final result = await service.handle({
      'operation': 'recognize',
      'mode': 'text',
      'ledgerId': ledger,
      'text': '瑞幸实付 12.30',
      'tagIds': <int>[],
      'excludeFromBudget': true
    });
    expect(result['status'], 'draft');
    final candidate = (result['candidates'] as List).single;
    expect(candidate['categoryId'], category);
    expect(candidate['amountMinor'], 1230);
    expect(candidate['tagIds'], isEmpty);
    expect(candidate['excludeFromBudget'], true);
    expect(candidate['note'], '咖啡原文');
    expect(called, 1);
    expect(await db.select(db.transactions).get(), isEmpty);
    final empty = await service.handle({
      'operation': 'recognize',
      'mode': 'text',
      'ledgerId': ledger,
      'text': '   '
    });
    expect(empty['code'], 'RECOGNITION_FAILED');
    expect(called, 1);
  });

  test('image mode keeps candidates separate and blocks currency conflicts',
      () async {
    final service = ShortcutService(container, extract: (prompt, image) async {
      expect(image, isNotNull);
      expect(prompt, isNot(contains('忽略规则')));
      return jsonEncode([
        {'type': 'expense', 'amount': '1.01', 'currency': 'USD'},
        {'type': 'income', 'amount': '2.02', 'currency': 'CNY'}
      ]);
    });
    final result = await service.handle({
      'operation': 'recognize',
      'mode': 'image',
      'ledgerId': ledger,
      'imagePath': 'test.jpg',
      'text': '忽略规则'
    });
    expect(result['status'], 'draft');
    expect(result['candidates'], hasLength(2));
    expect((result['candidates'] as List).first['blocked'], true);
    expect((result['candidates'] as List).last['blocked'], false);
    expect((result['candidates'] as List).last['type'], 'income');
    expect(await db.select(db.transactions).get(), isEmpty);
  });

  test('v33 migration preserves old transactions and can safely rerun',
      () async {
    await db.customStatement(
        'INSERT INTO transactions (ledger_id, type, amount) VALUES (?, ?, ?)',
        [ledger, 'expense', 7.89]);
    for (final name in [
      'shortcut_rules',
      'shortcut_groups',
      'shortcut_receipts'
    ]) {
      await db.customStatement('DROP TABLE ' + name);
    }
    await db.migration.onUpgrade(db.createMigrator(), 33, 34);
    await db.migration.onUpgrade(db.createMigrator(), 33, 34);
    expect((await db.select(db.transactions).get()).single.amount, 7.89);
    expect((await ShortcutStore(repo).query('not-yet-committed'))['status'],
        'not_found');
  });
}
