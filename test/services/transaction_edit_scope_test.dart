import 'package:beecount/data/db.dart';
import 'package:beecount/data/repositories/local/local_repository.dart';
import 'package:beecount/providers/database_providers.dart';
import 'package:beecount/providers/currency_providers.dart';
import 'package:beecount/providers/tag_providers.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('edit container resolves ledger currency rates and permissions without changing home', () async {
    SharedPreferences.setMockInitialValues({});
    final db = BeeDatabase.forTesting(NativeDatabase.memory());
    final repo = LocalRepository(db);
    final home = await repo.createLedger(name: '首页', currency: 'CNY');
    final edited = await repo.createLedger(name: '编辑', currency: 'USD');
    await repo.setOverride(base: 'USD', quote: 'CNY', rate: '0.14');
    final root = ProviderContainer(overrides: [databaseProvider.overrideWithValue(db),
      repositoryProvider.overrideWithValue(repo), currentLedgerIdProvider.overrideWith((ref) => home)]);
    final child = ProviderContainer(parent: root, overrides: [currentLedgerIdProvider.overrideWith((ref) => edited)]);
    addTearDown(() async { child.dispose(); root.dispose(); await db.close(); });
    expect((await root.read(currentLedgerProvider.future))!.id, home);
    expect((await child.read(currentLedgerProvider.future))!.id, edited);
    expect(root.read(currentLedgerCurrencyProvider), 'CNY');
    expect(child.read(currentLedgerCurrencyProvider), 'USD');
    expect((await child.read(effectiveRatesForLedgerProvider.future))['CNY']!.rate, '0.14');
    expect(child.read(canCreateTagForCurrentLedgerProvider), true);
    expect(root.read(currentLedgerIdProvider), home);
  });
}
