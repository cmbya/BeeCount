import 'package:beecount/data/db.dart';
import 'package:beecount/data/repositories/local/local_repository.dart';
import 'package:beecount/providers/database_providers.dart';
import 'package:beecount/providers/home_summary_providers.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('selected label month, ledger start day and budget exclusions stay aligned', () async {
    SharedPreferences.setMockInitialValues({});
    final db = BeeDatabase.forTesting(NativeDatabase.memory());
    final repo = LocalRepository(db);
    final ledger = await repo.createLedger(name: 'custom');
    await db.customStatement('UPDATE ledgers SET month_start_day = 10 WHERE id = ?', [ledger]);
    await repo.createBudget(ledgerId: ledger, type: 'total', amount: 200);
    await repo.addTransaction(ledgerId: ledger, type: 'expense', amount: 9,
        happenedAt: DateTime(2025, 11, 9));
    await repo.addTransaction(ledgerId: ledger, type: 'expense', amount: 30,
        happenedAt: DateTime(2025, 11, 10));
    await repo.addTransaction(ledgerId: ledger, type: 'expense', amount: 10,
        happenedAt: DateTime(2025, 11, 11), excludeFromBudget: true);
    final c = ProviderContainer(overrides: [repositoryProvider.overrideWithValue(repo)]);
    try {
      final data = await c.read(homeMonthlySummaryProvider((ledgerId: ledger,
        month: DateTime(2025, 11))).future);
      expect(data.expense, 40);
      expect(data.budget!.used, 30);
      expect(data.budget!.remaining, 170);
      expect(data.dailyAvailable, isNull);
      final other = await repo.createLedger(name: 'other');
      final empty = await c.read(homeMonthlySummaryProvider((ledgerId: other,
        month: DateTime(2025, 11))).future);
      expect(empty.expense, 0);
      expect(empty.budget, isNull);
    } finally {
      c.dispose(); await db.close();
    }
  });
}
