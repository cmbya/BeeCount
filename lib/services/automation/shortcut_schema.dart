import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';

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
  final int? categoryId;
  final String note;
  final List<int> tagIds;
  final bool excludeFromBudget;
  const ShortcutEntry(
      {required this.amountMinor,
      required this.categoryId,
      required this.note,
      required this.tagIds,
      required this.excludeFromBudget});

  factory ShortcutEntry.fromJson(Map<String, dynamic> json,
      {String type = 'expense'}) {
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
        categoryId:
            type == 'transfer' || json['categoryId'] == null
                ? null : shortcutInt(json['categoryId'], '分类'),
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


/// Optional attachment. It enters the store only after final confirmation.
class ShortcutAttachment {
  final Uint8List bytes;
  final String extension;
  final String digest;
  const ShortcutAttachment._(this.bytes, this.extension, this.digest);
  factory ShortcutAttachment.fromJson(dynamic raw) {
    if (raw is! Map<String, dynamic> || raw['dataBase64'] is! String ||
        raw['extension'] is! String || (raw['dataBase64'] as String).length > 54_000_000) {
      throw const ShortcutFailure('INVALID_ATTACHMENT', '附带图片格式无效或过大');
    }
    final ext = (raw['extension'] as String).toLowerCase();
    if (!{'jpg', 'jpeg', 'png', 'heic', 'heif', 'gif', 'webp', 'tif', 'tiff', 'bmp'}.contains(ext)) {
      throw const ShortcutFailure('INVALID_ATTACHMENT', '不支持的图片格式');
    }
    Uint8List bytes;
    try { bytes = base64Decode(raw['dataBase64'] as String); }
    catch (_) { throw const ShortcutFailure('INVALID_ATTACHMENT', '附带图片编码无效'); }
    if (bytes.isEmpty || bytes.length > 40_000_000) {
      throw const ShortcutFailure('INVALID_ATTACHMENT', '附带图片为空或超过 40 MB');
    }
    return ShortcutAttachment._(bytes, ext, sha256.convert(bytes).toString());
  }
  String get fileName => 'sha_$digest.$extension';
  Map<String, dynamic> get identity => {'sha256': digest, 'extension': extension};
}

/// Only successful parts are persisted by ShortcutStore. No draft content lives
/// in this metadata. Each part has one regular request ID and one ordered slot.
class ShortcutProgressiveSplit {
  final String sessionId;
  final int partIndex;
  final int totalMinor;
  const ShortcutProgressiveSplit({required this.sessionId,
    required this.partIndex, required this.totalMinor});
  factory ShortcutProgressiveSplit.fromJson(dynamic raw) {
    if (raw is! Map<String, dynamic> || raw['sessionId'] is! String ||
        !RegExp(r'^[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$').hasMatch(raw['sessionId'] as String) ||
        raw['partIndex'] is! int || (raw['partIndex'] as int) < 1 || (raw['partIndex'] as int) > 100) {
      throw const ShortcutFailure('INVALID_SPLIT', '逐笔拆分会话或序号无效');
    }
    return ShortcutProgressiveSplit(sessionId: (raw['sessionId'] as String).toLowerCase(),
        partIndex: raw['partIndex'] as int, totalMinor: shortcutInt(raw['totalMinor'], '拆分总额'));
  }
  Map<String, dynamic> toJson() => {'sessionId': sessionId,
    'partIndex': partIndex, 'totalMinor': totalMinor};
}

class ShortcutSubmission {
  final String type;
  final int? toAccountId;
  final String currency;
  final String requestId;
  final int ledgerId;
  final int accountId;
  final DateTime occurredAt;
  final int originalAmountMinor;
  final List<ShortcutEntry> entries;
  final ShortcutAttachment? attachment;
  final ShortcutProgressiveSplit? split;
  const ShortcutSubmission(
      {required this.requestId,
      this.attachment,
       this.split,
      this.type = 'expense',
      this.toAccountId,
      required this.currency,
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
        json['currency'] is! String ||
        !RegExp(r'^[A-Z]{3}$').hasMatch(json['currency'] as String) ||
        !['expense', 'income', 'transfer'].contains(json['type']) ||
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
      return ShortcutEntry.fromJson(v, type: json['type'] as String);
    }).toList();
    if (json['type'] != 'expense' &&
        (entries.length != 1 || entries.any((e) => e.excludeFromBudget))) {
      throw const ShortcutFailure('INVALID_REQUEST', '收入及转账只允许单笔，不使用预算排除标记');
    }
    final destination = json['type'] == 'transfer'
        ? shortcutInt(json['toAccountId'], '转入账户')
        : null;
    if (json['type'] != 'transfer' && json['toAccountId'] != null ||
        destination != null && destination == json['accountId']) {
      throw const ShortcutFailure(
          'INVALID_REFERENCE', '转出和转入账户必须不同，非转账不能指定转入账户');
    }
    final split = json['split'] == null ? null : ShortcutProgressiveSplit.fromJson(json['split']);
    if (split != null && (json['type'] != 'expense' || entries.length != 1 ||
        split.sessionId == id.toLowerCase() || entries.single.amountMinor > split.totalMinor)) {
      throw const ShortcutFailure('INVALID_SPLIT', '逐笔拆分只允许一条支出且不得超过原总额');
    }
    final original = shortcutInt(json['originalAmountMinor'], '原付款');
    if (entries.fold<int>(0, (s, e) => s + e.amountMinor) != original) {
      throw const ShortcutFailure('INVALID_AMOUNT', '明细合计必须等于原付款');
    }
    return ShortcutSubmission(
        type: json['type'] as String,
        toAccountId: destination,
        currency: json['currency'] as String,
        requestId: id.toLowerCase(),
        ledgerId: shortcutInt(json['ledgerId'], '账本'),
        accountId: shortcutInt(json['accountId'], '账户'),
        occurredAt: date.toUtc(),
        originalAmountMinor: original,
        entries: entries,
        split: split,
        attachment: json['attachment'] == null ? null : ShortcutAttachment.fromJson(json['attachment']));
  }

  /// Fixed key order, UTC time, sorted/deduplicated tags; display fields excluded.
  String get canonical => jsonEncode({
        'schemaVersion': 1,
        'currency': currency,
        'requestId': requestId,
        'ledgerId': ledgerId,
        'accountId': accountId,
        'type': type,
        if (toAccountId != null) 'toAccountId': toAccountId,
        'occurredAt': occurredAt.toIso8601String(),
        'originalAmountMinor': originalAmountMinor,
        'entries': entries.map((e) => e.toJson()).toList(),
         if (split != null) 'split': split!.toJson(),
        if (attachment != null) 'attachment': attachment!.identity
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
