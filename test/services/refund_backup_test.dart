import 'dart:convert';
import 'package:beecount/cloud/sync/entity_serializer.dart';
import 'package:beecount/cloud/transactions_json.dart';
import 'package:beecount/data/db.dart';
import 'package:beecount/data/repositories/local/local_repository.dart';
import 'package:beecount/models/refund_identity.dart';
import 'package:beecount/services/data/refund_service.dart';
import 'package:beecount/services/data_import_service.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('JSON export/import keeps the link, account credit, flags and source', () async {
    SharedPreferences.setMockInitialValues({});
    final db = BeeDatabase.forTesting(NativeDatabase.memory());
    final other = BeeDatabase.forTesting(NativeDatabase.memory());
    addTearDown(() async { await db.close(); await other.close(); });
    final repo = LocalRepository(db);
    final restored = LocalRepository(other);
    final ledger = await repo.createLedger(name: 'Backup source');
    final account = await repo.createAccount(ledgerId: ledger, name: 'Bank', initialBalance: 1000);
    final originalId = await repo.addTransaction(ledgerId: ledger, type: 'expense',
      amount: 100, accountId: account, happenedAt: DateTime(2026, 11, 5));
    final service = RefundService(repo);
    final info = await service.load(originalId);
    final credit = await service.save(originalId: originalId,
      requestId: '00000000-0000-4000-8000-000000000001', customAmount: '30',
      expectedRemainingMinor: info.remainingMinor, expectedCurrency: info.currency, expected: info.original);
    // Even a legacy writer clearing flags must not turn a refund into ordinary
    // income when serializing or restoring the versioned identity.
    final payload = EntitySerializer.serializeTransaction(credit.copyWith(
      excludeFromStats: false, excludeFromBudget: false));
    expect(payload['syncId'], credit.syncId); expect(payload['type'], 'income');
    expect(payload['excludeFromStats'], true); expect(payload['excludeFromBudget'], true);
    expect(payload['nativeAmount'], credit.nativeAmount);
    final backup = await exportTransactionsJson(db, ledger);
    final document = jsonDecode(backup) as Map<String, dynamic>;
    final items = (document['items'] as List).cast<Map<String, dynamic>>();
    final item = items.singleWhere((item) => item['syncId'] == credit.syncId);
    item.remove('excludeFromStats'); item['excludeFromBudget'] = false;
    final parsed = parseJsonToImportData(jsonEncode(document));
    final parsedRefund = parsed.transactions.singleWhere((t) => RefundIdentity.isRefund(t.syncId));
    expect(parsedRefund.excludeFromStats, true); expect(parsedRefund.excludeFromBudget, true);
    final target = await restored.createLedger(name: 'Restore');
    final result = await DataImportService().importData(restored, target, parsed);
    expect(result.inserted, 2); expect(result.failed, 0);
    final source = (await restored.getTransactionsByLedger(target))
        .singleWhere((t) => t.syncId == info.original.syncId);
    final restoredInfo = await RefundService(restored).load(source.id);
    expect(restoredInfo.refundedMinor, 3000); expect(restoredInfo.remainingMinor, 7000);
    expect(restoredInfo.refunds.single.syncId, credit.syncId);
    expect(source.amount, 100);
    expect(await restored.getAccountBalance(source.accountId!), 930);
  });
}
