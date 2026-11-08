import 'package:beecount/models/refund_identity.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const request = '12345678-1234-4123-8123-123456789abc';
  test('versioned link round-trips without names or amounts', () {
    for (final parent in ['expense-uuid', '旧账单:id/é', 'a:b']) {
      final encoded = RefundIdentity(parent, request).encode();
      final parsed = RefundIdentity.parse(encoded)!;
      expect(parsed.originalSyncId, parent); expect(parsed.requestId, request);
      expect(RefundIdentity.isRefund(encoded), true);
    }
  });
  test('malformed, noncanonical and ordinary IDs are not refunds', () {
    for (final value in <String?>[null, '', request, 'beecount-refund-v2:YQ:$request',
      '${RefundIdentity.prefix}YQ==:$request', '${RefundIdentity.prefix}_w:$request',
      '${RefundIdentity.prefix}YQ:bad', '${RefundIdentity.prefix}YQ:$request:extra']) {
      expect(RefundIdentity.parse(value), isNull);
    }
    expect(() => const RefundIdentity('', request).encode(), throwsArgumentError);
    final encoded = const RefundIdentity('original', request).encode();
    expect(() => RefundIdentity(encoded, request).encode(), throwsArgumentError);
  });
}
