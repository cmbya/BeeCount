import 'package:beecount/services/automation/shortcut_rule_matcher.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  bool matches(String source, String keyword, [String mode = 'contains_any']) =>
      ShortcutRuleMatcher.matches(source: source, keyword: keyword, mode: mode);

  test('any literal keyword is enough; no hit or empty source does not match', () {
    expect(matches('古茗购买奶茶', '古茗|蜜雪冰城'), true);
    expect(matches('支付给蜜雪冰城', '古茗|蜜雪冰城'), true);
    expect(matches('其他商店', '古茗|蜜雪冰城'), false);
    expect(matches('', '古茗|蜜雪冰城'), false);
  });

  test('trims each keyword, ignores case, duplicates and empty alternatives', () {
    expect(ShortcutRuleMatcher.terms(' 古茗 | | COFFEE || coffee | '), ['古茗', 'coffee']);
    expect(matches('Coffee shop', ' 古茗 | COFFEE '), true);
    expect(matches('其他商店', '| 古茗 || '), false);
    expect(matches('anything', ' | || '), false);
    expect(ShortcutRuleMatcher.validMany(' | || '), false);
  });

  test('regex metacharacters are literal and never broaden the match', () {
    expect(matches('shopXYZ', 'shop.*|[奶茶]'), false);
    expect(matches('门店shop.*', 'shop.*|[奶茶]'), true);
    expect(matches('支付[奶茶]', 'shop.*|[奶茶]'), true);
    expect(matches('aaaaa', r'(a+)+$|^.*$'), false);
  });

  test('legacy contains and exact preserve pipes and whitespace as literal text', () {
    expect(matches('古茗', '古茗|蜜雪冰城', 'contains'), false);
    expect(matches('古茗|蜜雪冰城 门店', '古茗|蜜雪冰城', 'contains'), true);
    expect(matches('古茗|蜜雪冰城', '古茗|蜜雪冰城', 'exact'), true);
    expect(matches('古茗', '古茗|蜜雪冰城', 'exact'), false);
    expect(matches('prefix exact suffix', 'EXACT', 'exact'), false);
    expect(matches('exact', 'EXACT', 'exact'), true);
    expect(matches('古茗', ' 古茗 ', 'contains'), false);
  });

  test('term and total-length limits reject oversized expressions', () {
    final allowed = List.generate(100, (i) => 'term$i').join('|');
    final tooMany = List.generate(101, (i) => 'term$i').join('|');
    expect(ShortcutRuleMatcher.validMany(allowed), true);
    expect(ShortcutRuleMatcher.validMany(tooMany), false);
    expect(matches('term0', tooMany), false);
    final atLimit = List.filled(4096, 'a').join();
    final overLimit = '$atLimit|b';
    expect(ShortcutRuleMatcher.validMany(atLimit), true);
    expect(ShortcutRuleMatcher.validMany(overLimit), false);
    expect(matches('b', overLimit), false);
  });
}
