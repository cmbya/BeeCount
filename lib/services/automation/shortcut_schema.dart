import 'dart:convert';

class ShortcutFailure implements Exception {
  final String code;
  final String message;
  const ShortcutFailure(this.code, this.message);
  Map<String, dynamic> toJson() =>
      {'status': 'error', 'code': code, 'message': message};
}

const maxShortcutMinor = 999999999999;

/// ISO 4217 minor-unit precision; currency follows the ledger, never a menu.
int shortcutCurrencyDigits(String currency) {
  final code = currency.toUpperCase();
  if (const {
    'BIF',
    'CLP',
    'DJF',
    'GNF',
    'ISK',
    'JPY',
    'KMF',
    'KRW',
    'PYG',
    'RWF',
    'UGX',
    'UYI',
    'VND',
    'VUV',
    'XAF',
    'XOF',
    'XPF'
  }.contains(code)) {
    return 0;
  }
  if (const {'BHD', 'IQD', 'JOD', 'KWD', 'LYD', 'OMR', 'TND'}.contains(code)) {
    return 3;
  }
  if (const {'CLF', 'UYW'}.contains(code)) return 4;
  return 2;
}

int shortcutInt(dynamic value, String field) {
  if (value is! int || value <= 0 || value > maxShortcutMinor) {
    throw ShortcutFailure('INVALID_AMOUNT', '$field 必须是有效的正整数');
  }
  return value;
}

/// Decimal text -> minor units without a floating point intermediate.
int parseShortcutAmount(String text, {int digits = 2}) {
  final parts = text.trim().split('.');
  if (text.length > 32 ||
      digits < 0 ||
      digits > 4 ||
      parts.length > 2 ||
      parts.any((s) => s.isEmpty || s.codeUnits.any((c) => c < 48 || c > 57)) ||
      (parts.length == 2 && parts[1].length > digits)) {
    throw const ShortcutFailure('INVALID_AMOUNT', '金额格式或小数位数无效');
  }
  return shortcutInt(
      int.tryParse(
          parts[0] + (parts.length == 2 ? parts[1] : '').padRight(digits, '0')),
      '金额');
}

class ShortcutEntry {
  final int amountMinor;
  final int categoryId;
  final String note;
  final List<int> tagIds;
  final bool excludeFromBudget;
  const ShortcutEntry(
      {required this.amountMinor,
      required this.categoryId,
      required this.note,
      required this.tagIds,
      required this.excludeFromBudget});

  factory ShortcutEntry.fromJson(Map<String, dynamic> json) {
    final tags = json['tagIds'];
    if (tags is! List ||
        tags.length > 100 ||
        tags.any((v) => v is! int || v <= 0) ||
        json['note'] is! String ||
        (json['note'] as String).length > 10000 ||
        json['excludeFromBudget'] is! bool) {
      throw const ShortcutFailure('INVALID_REFERENCE', '备注、标签或预算标记无效');
    }
    return ShortcutEntry(
        amountMinor: shortcutInt(json['amountMinor'], '金额'),
        categoryId: shortcutInt(json['categoryId'], '分类'),
        note: json['note'] as String,
        tagIds: tags.cast<int>().toSet().toList()..sort(),
        excludeFromBudget: json['excludeFromBudget'] as bool);
  }
  Map<String, dynamic> toJson() => {
        'amountMinor': amountMinor,
        'categoryId': categoryId,
        'note': note,
        'tagIds': tagIds,
        'excludeFromBudget': excludeFromBudget
      };
}

class ShortcutSubmission {
  final String requestId;
  final int ledgerId;
  final int accountId;
  final DateTime occurredAt;
  final int originalAmountMinor;
  final List<ShortcutEntry> entries;
  const ShortcutSubmission(
      {required this.requestId,
      required this.ledgerId,
      required this.accountId,
      required this.occurredAt,
      required this.originalAmountMinor,
      required this.entries});

  factory ShortcutSubmission.fromJson(Map<String, dynamic> json) {
    final id = json['requestId'];
    final raw = json['entries'];
    final time = json['occurredAt'];
    if (json['schemaVersion'] != 1 ||
        json['type'] != 'expense' ||
        json['confirmed'] != true ||
        id is! String ||
        !RegExp(r'^[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')
            .hasMatch(id) ||
        raw is! List ||
        raw.isEmpty ||
        raw.length > 100 ||
        time is! String ||
        !RegExp(r'(Z|[+-][0-9]{2}:[0-9]{2})$').hasMatch(time)) {
      throw const ShortcutFailure('INVALID_REQUEST', '请完成确认；协议、请求 ID、日期或明细无效');
    }
    final date = parseShortcutDate(time);
    if (date == null || date.year < 2000 || date.year > 2200) {
      throw const ShortcutFailure('INVALID_REQUEST', '日期时间无效');
    }
    final entries = raw.map((v) {
      if (v is! Map<String, dynamic>)
        throw const ShortcutFailure('INVALID_REQUEST', '明细无效');
      return ShortcutEntry.fromJson(v);
    }).toList();
    final original = shortcutInt(json['originalAmountMinor'], '原付款');
    if (entries.fold<int>(0, (s, e) => s + e.amountMinor) != original) {
      throw const ShortcutFailure('INVALID_AMOUNT', '明细合计必须等于原付款');
    }
    return ShortcutSubmission(
        requestId: id.toLowerCase(),
        ledgerId: shortcutInt(json['ledgerId'], '账本'),
        accountId: shortcutInt(json['accountId'], '账户'),
        occurredAt: date.toUtc(),
        originalAmountMinor: original,
        entries: entries);
  }

  /// Fixed key order, UTC time, sorted/deduplicated tags; display fields excluded.
  String get canonical => jsonEncode({
        'schemaVersion': 1,
        'requestId': requestId,
        'ledgerId': ledgerId,
        'accountId': accountId,
        'type': 'expense',
        'occurredAt': occurredAt.toIso8601String(),
        'originalAmountMinor': originalAmountMinor,
        'entries': entries.map((e) => e.toJson()).toList()
      });
}

/// DateTime.parse normalizes impossible dates; reject them before conversion.
DateTime? parseShortcutDate(String time) {
  final m = RegExp(
          r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d{1,6})?(Z|[+-](\d{2}):(\d{2}))$')
      .firstMatch(time);
  if (m == null) return null;
  final year = int.parse(m[1]!);
  final month = int.parse(m[2]!);
  final day = int.parse(m[3]!);
  if (month < 1 ||
      month > 12 ||
      day < 1 ||
      day > DateTime.utc(year, month + 1, 0).day ||
      int.parse(m[4]!) > 23 ||
      int.parse(m[5]!) > 59 ||
      int.parse(m[6]!) > 59 ||
      int.parse(m[8] ?? '0') > 14 ||
      int.parse(m[9] ?? '0') > 59 ||
      (m[8] == '14' && m[9] != '00')) return null;
  return DateTime.tryParse(time);
}
