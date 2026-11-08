import 'dart:convert';

/// Stable refund identity carried by existing transaction sync/backup formats.
/// No names, amounts or notes are embedded. The link uses existing syncId
/// fields; acceptance by a specific cloud server still requires integration testing.
class RefundIdentity {
  static const prefix = 'beecount-refund-v1:';
  final String originalSyncId;
  final String requestId;
  const RefundIdentity(this.originalSyncId, this.requestId);

  static final _uuid = RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');

  String encode() {
    if (originalSyncId.isEmpty || originalSyncId.length > 512 ||
        originalSyncId.startsWith(prefix) || !_uuid.hasMatch(requestId)) {
      throw ArgumentError('invalid_refund_identity');
    }
    final parent = base64Url.encode(utf8.encode(originalSyncId)).replaceAll('=', '');
    return '$prefix$parent:$requestId';
  }

  static RefundIdentity? parse(String? value) {
    if (value == null || !value.startsWith(prefix)) return null;
    final parts = value.substring(prefix.length).split(':');
    if (parts.length != 2 || !_uuid.hasMatch(parts[1]) || parts[0].length > 4096) {
      return null;
    }
    try {
      final parent = utf8.decode(base64Url.decode(base64Url.normalize(parts[0])));
      if (parent.isEmpty || parent.length > 512 || parent.startsWith(prefix)) return null;
      // Reject non-canonical aliases for the same link.
      final result = RefundIdentity(parent, parts[1]);
      return result.encode() == value ? result : null;
    } on FormatException {
      return null;
    } on ArgumentError {
      return null;
    }
  }

  static bool isRefund(String? syncId) => parse(syncId) != null;
}
