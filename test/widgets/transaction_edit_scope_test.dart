import 'package:beecount/data/db.dart';
import 'package:beecount/data/repositories/local/local_repository.dart';
import 'package:beecount/l10n/app_localizations.dart';
import 'package:beecount/providers/database_providers.dart';
import 'package:beecount/providers/currency_providers.dart';
import 'package:beecount/utils/transaction_edit_utils.dart';
import 'package:beecount/widgets/biz/amount_editor_sheet.dart';
import 'package:beecount/pages/tag/widgets/tag_selector.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('foreign-ledger full edit and nested tag sheet retain ledger scope', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final db = BeeDatabase.forTesting(NativeDatabase.memory());
    final repo = LocalRepository(db);
    final home = await repo.createLedger(name: '首页 CNY', currency: 'CNY');
    final target = await repo.createLedger(name: '交易 USD', currency: 'USD');
    final categoryId = await repo.createCategory(name: '餐饮', kind: 'expense');
    final id = await repo.addTransaction(ledgerId: target, type: 'expense', amount: 10,
      categoryId: categoryId, happenedAt: DateTime(2026, 11, 5), currencyCode: 'USD', nativeAmount: 10);
    final tx = (await repo.getTransactionById(id))!;
    final container = ProviderContainer(overrides: [databaseProvider.overrideWithValue(db),
      repositoryProvider.overrideWithValue(repo), currentLedgerIdProvider.overrideWith((ref) => home)]);
    addTearDown(() async { container.dispose(); await db.close(); });
    await tester.pumpWidget(UncontrolledProviderScope(container: container, child: MaterialApp(
      locale: const Locale('zh'), localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Consumer(builder: (context, ref, _) => Scaffold(body: TextButton(
        onPressed: () => TransactionEditUtils.editTransaction(context, ref, tx, null), child: const Text('open')))))));
    await tester.tap(find.text('open'));
    await tester.runAsync(() async { await Future<void>.delayed(const Duration(milliseconds: 200)); });
    await tester.pumpAndSettle();
    final sheet = find.byType(AmountEditorSheet);
    expect(sheet, findsOneWidget);
    final scope = ProviderScope.containerOf(tester.element(sheet), listen: false);
    expect(scope.read(currentLedgerIdProvider), target);
    expect(scope.read(currentLedgerCurrencyProvider), 'USD');
    expect(container.read(currentLedgerIdProvider), home);
    await tester.tap(find.text('选择标签'));
    await tester.pumpAndSettle();
    final tags = find.byType(TagSelector);
    expect(tags, findsOneWidget);
    expect(ProviderScope.containerOf(tester.element(tags), listen: false), same(scope));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 3));
  });
}
