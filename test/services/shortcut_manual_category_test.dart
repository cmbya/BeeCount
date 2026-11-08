import 'package:beecount/data/db.dart';
import 'package:beecount/data/repositories/local/local_repository.dart';
import 'package:beecount/providers/database_providers.dart';
import 'package:beecount/services/automation/shortcut_service.dart';
import 'package:beecount/services/automation/shortcut_store.dart';
import 'package:beecount/services/automation/shortcut_schema.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late BeeDatabase db;
  late LocalRepository repo;
  late ProviderContainer container;
  late ShortcutService service;
  late int ledger;
  late int otherLedger;
  late int dining;
  late int personal;
  late int income;
  var aiCalls = 0;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = BeeDatabase.forTesting(NativeDatabase.memory());
    repo = LocalRepository(db);
    ledger = await repo.createLedger(name: '当前账本');
    otherLedger = await repo.createLedger(name: '其他账本');
    dining = await repo.createCategory(name: '餐饮', kind: 'expense');
    personal = await repo.createCategory(name: '个人自定义', kind: 'expense');
    income = await repo.createCategory(name: '工资', kind: 'income');
    container = ProviderContainer(overrides: [repositoryProvider.overrideWithValue(repo)]);
    aiCalls = 0;
    service = ShortcutService(container, extract: (_, __) async {
      aiCalls++;
      throw StateError('Manual classification must not invoke AI');
    });
  });
  tearDown(() async {
    expect(aiCalls, 0);
    expect(await db.select(db.transactions).get(), isEmpty);
    expect(await db.customSelect('SELECT * FROM shortcut_receipts').get(), isEmpty);
    container.dispose();
    await db.close();
  });

  Future<void> rule(String id, {String field = 'note', String keyword = '瑞幸',
      int? target, int? forLedger, int priority = 100, int enabled = 1,
      String mode = 'contains'}) => ShortcutStore(repo).saveRule({
    'id': id, 'name': id, 'enabled': enabled,
    'ledger_id': forLedger ?? ledger, 'field': field, 'match_mode': mode,
    'keyword': keyword, 'category_id': target ?? personal, 'priority': priority,
  });
  Future<Map<String, dynamic>> classify({String type = 'expense', String note = '',
      String merchant = '', String fullText = '', int? categoryId}) => service.handle({
    'operation': 'classify', 'ledgerId': ledger, 'type': type,
    'note': note, 'merchant': merchant, 'ruleText': fullText,
    if (categoryId != null) 'categoryId': categoryId,
  });

  test('personal rule overrides an incoming category during initialization', () async {
    await rule('personal');
    expect((await classify(note: '瑞幸咖啡'))['categoryId'], personal);
    expect((await classify(note: '瑞幸咖啡', categoryId: dining))['categoryId'], personal);
    final other = await repo.createCategory(name: '其它', kind: 'expense');
    await rule('meifu', keyword: '美福');
    expect((await classify(note: '美福便利店付款', categoryId: other))['categoryId'], personal);
    expect((await classify(note: 'no_rule_evidence', categoryId: other))['categoryId'], other);
    expect((await classify(note: '瑞幸咖啡', categoryId: other))['categoryId'], personal);
    final invalid = await classify(note: '瑞幸', categoryId: income);
    expect(invalid['code'], 'INVALID_REFERENCE');
  });

  test('ambiguous supplied category requests only personal rules, not built-in guessing', () async {
    final unmatched = await service.handle({'operation': 'classify', 'ledgerId': ledger,
      'type': 'expense', 'note': '瑞幸咖啡', 'personalOnly': true});
    expect(unmatched['categoryId'], isNull);
    await rule('personal');
    final matched = await service.handle({'operation': 'classify', 'ledgerId': ledger,
      'type': 'expense', 'note': '瑞幸咖啡', 'personalOnly': true});
    expect(matched['categoryId'], personal);
  });

  test('without a rule built-in keywords use only available same-type categories', () async {
    expect((await classify(note: '瑞幸咖啡'))['categoryId'], dining);
    expect((await classify(note: '瑞幸咖啡', categoryId: personal))['categoryId'], personal,
      reason: 'Built-in keywords must not override a supplied category without a personal rule');
    expect((await classify(type: 'income', note: '工资到账'))['categoryId'], income);
    expect((await classify(type: 'income', note: '瑞幸'))['categoryId'], isNull);
    expect((await classify(note: 'zqx_no_matching_evidence'))['categoryId'], isNull);
    expect((await classify())['categoryId'], isNull);
  });

  test('merchant and original-text rules require actual supplied evidence', () async {
    await rule('merchant', field: 'merchant', keyword: '甲商户');
    await rule('fulltext', field: 'ocr', keyword: '甲原文', priority: 90);
    expect((await classify(note: '甲商户 甲原文'))['categoryId'], isNull);
    expect((await classify(merchant: '甲商户'))['categoryId'], personal);
    expect((await classify(fullText: '甲原文'))['categoryId'], personal);
    expect((await classify(note: '甲商户 甲原文'))['categoryId'], isNull,
        reason: 'No evidence persists into a later invocation');
  });

  test('rules respect priority, enabled state, ledger and income/expense types', () async {
    await rule('wrong-ledger', keyword: '线索甲', target: dining, forLedger: otherLedger, priority: 1000);
    await rule('disabled', keyword: '线索甲', target: dining, priority: 900, enabled: 0);
    await rule('wrong-type', keyword: '线索甲', target: income, priority: 800);
    await rule('right', keyword: '线索甲', priority: 10);
    await rule('lower', keyword: '线索甲', target: dining, priority: 1);
    expect((await classify(note: '线索甲'))['categoryId'], personal);
    expect((await classify(type: 'income', note: '线索甲'))['categoryId'], income);
    await rule('exact', keyword: 'ExactOnly', target: dining, mode: 'exact', priority: 2000);
    expect((await classify(note: 'exactonly'))['categoryId'], dining);
    expect((await classify(note: 'prefix exactonly suffix'))['categoryId'], isNull);
  });

  test('stale target is ignored with warning; transfer never gets income/expense rule', () async {
    final stale = await repo.createCategory(name: '即将删除', kind: 'expense');
    await rule('stale', keyword: '线索乙', target: stale);
    await db.customStatement('DELETE FROM categories WHERE id = ?', [stale]);
    final result = await classify(note: '线索乙');
    expect(result['categoryId'], isNull);
    expect(result['warnings'], contains('个人规则目标分类已失效'));
    await rule('transfer-skip', keyword: '转账线索');
    expect((await classify(type: 'transfer', note: '转账线索'))['categoryId'], isNull);
    expect((await classify(type: 'transfer', note: '瑞幸', categoryId: dining))['categoryId'], isNull);
  });

  test('invalid evidence fails instead of being coerced into a category', () async {
    final invalid = await service.handle({'operation': 'classify', 'ledgerId': ledger,
      'type': 'expense', 'note': 42});
    expect(invalid['code'], 'INVALID_REQUEST');
  });

  test('options expose only usable child IDs with parent metadata for two-level selection', () async {
    final food = await repo.createCategory(name: '食品', kind: 'expense', level: 2, parentId: dining);
    final response = await service.handle({'operation': 'options', 'ledgerId': ledger, 'type': 'expense'});
    expect(response['status'], 'ok');
    final categories = (response['categories'] as List).cast<Map<String, dynamic>>();
    final child = categories.singleWhere((row) => row['id'] == food);
    expect(child['name'], '餐饮/食品');
    expect(child['leafName'], '食品');
    expect(child['parentId'], dining);
    expect(child['parentName'], '餐饮');
    expect(categories.any((row) => row['id'] == dining), isFalse,
        reason: 'A parent with children is a selector group, not a valid transaction category');
    final unrelated = categories.singleWhere((row) => row['id'] == personal);
    expect(unrelated['parentId'], isNull);
    expect(unrelated['parentName'], isNull);
  });


  test('multiple keywords classify either brand; old single modes stay literal', () async {
    await rule('multi', keyword: ' 古茗 | 蜜雪冰城 ', mode: 'contains_any');
    expect((await classify(note: '古茗门店购买'))['categoryId'], personal);
    expect((await classify(note: '付款蜜雪冰城'))['categoryId'], personal);
    expect((await classify(note: 'zqx_no_matching_evidence'))['categoryId'], isNull);
    final saved = (await ShortcutStore(repo).rules()).single;
    expect(saved['match_mode'], 'contains_any');
    expect(saved['keyword'], ' 古茗 | 蜜雪冰城 ');
    await rule('multi', keyword: '古茗|蜜雪冰城', mode: 'contains');
    // Built-in categories may still match a known brand, but this personal
    // literal rule must no longer win without the pipe in the source.
    expect((await classify(note: '古茗'))['categoryId'], isNot(personal));
  });

  test('multi-keyword mode respects merchant, note and original-text evidence', () async {
    for (final field in ['merchant', 'note', 'ocr']) {
      await rule('evidence', field: field, keyword: ' AlphaBrand | BetaBrand ', mode: 'contains_any');
      expect((await classify(merchant: field == 'merchant' ? 'BetaBrand门店' : '',
        note: field == 'note' ? '付款BETABRAND' : '',
        fullText: field == 'ocr' ? '原文BetaBrand' : ''))['categoryId'], personal);
      expect((await classify(merchant: field != 'merchant' ? 'BetaBrand' : '',
        note: field != 'note' ? 'BetaBrand' : '',
        fullText: field != 'ocr' ? 'BetaBrand' : ''))['categoryId'], isNull);
    }
  });

  test('multi-keyword rules preserve scope, type, priority and override incoming categories', () async {
    const keywords = '线索甲|线索乙';
    await rule('wrong-ledger', keyword: keywords, mode: 'contains_any', target: dining, forLedger: otherLedger, priority: 1000);
    await rule('disabled', keyword: keywords, mode: 'contains_any', target: dining, enabled: 0, priority: 900);
    await rule('wrong-type', keyword: keywords, mode: 'contains_any', target: income, priority: 800);
    await rule('winner', keyword: keywords, mode: 'contains_any', priority: 100);
    await rule('lower', keyword: keywords, mode: 'contains_any', target: dining, priority: 1);
    expect((await classify(note: '线索乙'))['categoryId'], personal);
    expect((await classify(note: '线索乙', categoryId: dining))['categoryId'], personal);
    expect((await classify(type: 'income', note: '线索乙'))['categoryId'], income);
    expect((await classify(type: 'transfer', note: '线索乙'))['categoryId'], isNull);
  });

  test('saving invalid alternatives is rejected without replacing the old rule', () async {
    await rule('edit', keyword: '古茗|蜜雪冰城', mode: 'contains_any');
    for (final keyword in [' | || ', List.generate(101, (i) => 'term$i').join('|'), List.filled(4097, 'a').join()]) {
      await expectLater(rule('edit', keyword: keyword, mode: 'contains_any'),
        throwsA(isA<ShortcutFailure>().having((e) => e.code, 'code', 'INVALID_RULE')));
    }
    expect((await ShortcutStore(repo).rules()).single['keyword'], '古茗|蜜雪冰城');
  });

  test('all-empty corrupt multi rule cannot match everything or block a valid rule', () async {
    await rule('bad', keyword: '古茗', mode: 'contains_any', target: dining, priority: 1000);
    await db.customStatement('UPDATE shortcut_rules SET keyword = ? WHERE id = ?', ['|||', 'bad']);
    await rule('good', keyword: '线索甲|线索乙', mode: 'contains_any');
    expect((await classify(note: '线索乙'))['categoryId'], personal);
    expect((await classify(note: 'zqx_no_matching_evidence'))['categoryId'], isNull);
  });
}
