/// Local rule keywords are literal text, never executable regular expressions.
/// The legacy modes keep treating pipes as part of a single keyword.
class ShortcutRuleMatcher {
  static const containsAny = 'contains_any';
  static const modes = {'contains', 'exact', containsAny};
  static const maxKeywordLength = 4096;
  static const maxTerms = 100;

  static List<String> terms(String keyword) => keyword
      .split('|')
      .map((term) => term.trim().toLowerCase())
      .where((term) => term.isNotEmpty)
      .toSet()
      .toList();

  static bool validMany(String keyword) {
    if (keyword.length > maxKeywordLength) return false;
    final values = terms(keyword);
    return values.isNotEmpty && values.length <= maxTerms;
  }

  static bool matches({required String source, required String keyword,
    required String mode}) {
    final text = source.toLowerCase();
    if (mode == containsAny) {
      // Empty alternatives cannot match every bill. Invalid legacy/corrupt rules
      // also fail closed instead of blocking the rest of the category rules.
      if (!validMany(keyword)) return false;
      return terms(keyword).any((term) => text.contains(term));
    }
    final key = keyword.toLowerCase();
    return mode == 'exact' ? text == key : text.contains(key);
  }
}
