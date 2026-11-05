import 'dart:convert';
import 'package:beecount/data/db.dart';
import 'package:beecount/data/repositories/local/local_repository.dart';
import 'package:beecount/providers/database_providers.dart';
import 'package:beecount/services/automation/shortcut_service.dart';
import 'package:beecount/services/automation/shortcut_store.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
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
    ledger = await repo.createLedger(name: '当前账本');
    category = await repo.createCategory(name: '自建支出', kind: 'expense');
    container = ProviderContainer(overrides: [repositoryProvider.overrideWithValue(repo)]);
    container.read(currentLedgerIdProvider.notifier).state = ledger;
  });
  tearDown(() async { container.dispose(); await db.close(); });

  test('current ledger beats obsolete shortcut default; explicit preset wins', () async {
    final other = await repo.createLedger(name: '旧默认账本');
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(shortcutDefaultsKey, jsonEncode({'ledgerId': other}));
    final service = ShortcutService(container);
    expect((await service.options(null))['ledgerId'], ledger);
    expect((await service.options(other))['ledgerId'], other);
    await prefs.setInt('current_ledger_id', other);
    expect((await service.options(null))['ledgerId'], other);
    await prefs.setInt('current_ledger_id', 999999);
    expect((await service.handle({'operation': 'options'}))['code'], 'INVALID_REFERENCE');
    expect((await service.handle({'operation': 'options', 'ledgerId': 999999}))['code'], 'INVALID_REFERENCE');
  });

  test('account evidence must be unique; bank ambiguity prompts, tail resolves', () {
    final accounts = <Map<String, dynamic>>[
      {'id': 1, 'name': '招商储蓄', 'bankName': '招商银行', 'cardLastFour': '1234'},
      {'id': 2, 'name': '招商信用', 'bankName': '招商银行', 'cardLastFour': '5678'},
      {'id': 3, 'name': '支付宝'},
      {'id': 4, 'name': '工行卡', 'bankName': '工商银行', 'cardLastFour': '9876'}
    ];
    expect(ShortcutService.matchAccount(accounts, clue: '招商银行', text: ''), isNull);
    expect(ShortcutService.matchAccount(accounts, clue: '招商银行 尾号5678', text: ''), 2);
    expect(ShortcutService.matchAccount(accounts, clue: '', text: '付款方式 支付宝'), 3);
    expect(ShortcutService.matchAccount(accounts, clue: '不存在的卡', text: ''), isNull);
    expect(ShortcutService.matchAccount(accounts, clue: '', text: ''), isNull);
    expect(ShortcutService.matchAccount(accounts, clue: '招商银行尾号9876', text: ''), isNull);
    expect(ShortcutService.matchAccount(accounts, clue: '订单号912349', text: ''), isNull);
  });

  test('AI account clue matches existing account; absent clue never uses saved default', () async {
    final account = await repo.createAccount(ledgerId: ledger, name: '支付宝');
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(shortcutDefaultsKey, jsonEncode({'accountId': account}));
    var clue = '支付宝';
    final service = ShortcutService(container, extract: (prompt, image) async {
      expect(prompt, contains('有效账户'));
      expect(prompt, contains('支付宝'));
      return jsonEncode([{'type': 'expense', 'amount': '12.30', 'categoryId': category, 'account': clue}]);
    });
    Future<Map<String, dynamic>> recognize() => service.handle({'operation': 'recognize', 'mode': 'text', 'text': '消费12.30元'});
    final first = await recognize();
    expect(first['candidates'][0]['accountId'], account);
    clue = '';
    final missing = await recognize();
    expect(missing['candidates'][0]['accountId'], isNull);
    expect(missing['candidates'][0]['requiresAccountSelection'], true);
    expect(await db.select(db.transactions).get(), isEmpty);
  });

  test('image-local OCR feeds rules, not the vision prompt; personal rule beats AI', () async {
    final alternative = await repo.createCategory(name: 'AI建议', kind: 'expense');
    await ShortcutStore(repo).saveRule({'id': 'image-rule', 'name': '图片原文规则', 'enabled': 1,
      'ledger_id': ledger, 'field': 'ocr', 'match_mode': 'contains', 'keyword': '家电维修',
      'category_id': category, 'priority': 100});
    final service = ShortcutService(container, extract: (prompt, image) async {
      expect(image, isNotNull);
      expect(prompt, isNot(contains('原文家电维修')));
      return jsonEncode([{'type': 'expense', 'amount': '30', 'categoryId': alternative}]);
    });
    final result = await service.handle({'operation': 'recognize', 'mode': 'image',
      'imagePath': 'fixture.jpg', 'ruleText': '原文家电维修30元'});
    expect(result['candidates'][0]['categoryId'], category);
    expect(await db.select(db.transactions).get(), isEmpty);
  });

  test('AI category IDs are checked by type; duplicate leaf names stay unselected', () async {
    // Simulate legacy/imported overlapping display labels without violating
    // the current repository's global category-name uniqueness constraint.
    final labels = <Map<String, dynamic>>[
      {'id': 101, 'name': '家庭/重复类别', 'leafName': '重复类别', 'kind': 'expense'},
      {'id': 102, 'name': '个人/重复类别', 'leafName': '重复类别', 'kind': 'expense'}
    ];
    expect(ShortcutService.matchSuggestedCategory(labels, type: 'expense', name: '重复类别'), isNull);
    expect(ShortcutService.matchSuggestedCategory(labels, type: 'expense', id: 102, name: '重复类别'), 102);
    expect(ShortcutService.matchSuggestedCategory(labels, type: 'expense', name: '家庭/重复类别'), 101);
    final a = category;
    var suggestion = <String, dynamic>{'category': '重复类别'};
    final service = ShortcutService(container, extract: (_, __) async => jsonEncode([
      {'type': 'expense', 'amount': '10', ...suggestion}
    ]));
    Future<Map<String, dynamic>> recognize() => service.handle({'operation': 'recognize', 'mode': 'text', 'text': '支付10元'});
    expect((await recognize())['candidates'][0]['categoryId'], isNull);
    suggestion = {'categoryId': a};
    expect((await recognize())['candidates'][0]['categoryId'], a);
    final income = await repo.createCategory(name: '工资', kind: 'income');
    suggestion = {'categoryId': income};
    expect((await recognize())['candidates'][0]['categoryId'], isNull);
  });

  test('income retains type, clears budget flag and missing time uses now', () async {
    final income = await repo.createCategory(name: '工资', kind: 'income');
    final tag = await repo.createTag(name: '个人');
    final service = ShortcutService(container, extract: (_, __) async => jsonEncode([
      {'type': 'income', 'amount': '100', 'categoryId': income, 'note': '工资到账'}
    ]));
    final before = DateTime.now().toUtc();
    final result = await service.handle({'operation': 'recognize', 'mode': 'text', 'text': '工资到账100元',
      'tagIds': [tag], 'excludeFromBudget': true});
    final candidate = result['candidates'][0];
    expect(candidate['type'], 'income');
    expect(candidate['categoryId'], income);
    expect(candidate['excludeFromBudget'], false);
    expect(candidate['tagIds'], [tag]);
    final time = DateTime.parse(candidate['occurredAt'] as String);
    expect(time.isBefore(before), false);
    expect(time.isAfter(DateTime.now().toUtc()), false);
    expect(await db.select(db.transactions).get(), isEmpty);
  });
  test('receipt local time survives missing timezone and wins over AI current time', () {
    const offset = 8 * 3600;
    final result = ShortcutService.recognizedTime('2026-11-06T01:43:14+08:00',
      sourceText: '支付时间：2026年11月5日 12:32:45\n商品：生活缴费', offsetSeconds: offset);
    expect(result, DateTime.utc(2026, 11, 5, 4, 32, 45));
    expect(ShortcutService.recognizedTime('2026-11-05T12:32:45', offsetSeconds: offset), result);
    expect(ShortcutService.recognizedTime('2026-02-30T12:32:45', offsetSeconds: offset), isNull);
    expect(ShortcutService.recognizedTime('', offsetSeconds: offset), isNull);
  });

  test('generated note has stable structure and ignores page metadata', () {
    const text = '当前状态：支付成功\n支付时间：2026年11月5日 12:32:45\n商品：生活缴费\n商户全称：广东电网有限责任公司\n交易单号：TEST-ORDER';
    final first = ShortcutService.buildNote({'merchant': '电网', 'purpose': '缴费', 'note': '支付成功；交易单号：OTHER'}, sourceText: text);
    final second = ShortcutService.buildNote({'merchant': '不同模型内容', 'note': '收单机构：中国光大银行；交易单号：OTHER'}, sourceText: text);
    expect(first, '广东电网有限责任公司｜生活缴费');
    expect(second, first);
    expect(first, isNot(contains('TEST-ORDER')));
    expect(ShortcutService.buildNote({'merchant': '商户', 'purpose': '消费', 'userNote': '家庭用电'}), '商户｜消费｜家庭用电');
  });

  test('unclassified drafts can commit without inventing a category', () async {
    final account = await repo.createAccount(ledgerId: ledger, name: '测试账户');
    final service = ShortcutService(container);
    final result = await service.handle({'operation': 'commit', 'submission': {
      'schemaVersion': 1, 'confirmed': true, 'currency': 'CNY',
      'requestId': '238e3341-3e15-47d7-9fe1-e6fb68e41257',
      'ledgerId': ledger, 'accountId': account, 'type': 'expense',
      'occurredAt': '2026-11-05T04:32:45Z', 'originalAmountMinor': 12789,
      'entries': [{'amountMinor': 12789, 'categoryId': null, 'note': '生活缴费',
        'tagIds': <int>[], 'excludeFromBudget': false}]
    }});
    expect(result['status'], 'committed');
    final row = (await db.select(db.transactions).get()).single;
    expect(row.categoryId, isNull);
    expect(row.amount, 127.89);
  });

}
