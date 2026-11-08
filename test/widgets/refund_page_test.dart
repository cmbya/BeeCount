import 'package:beecount/data/db.dart';
import 'package:beecount/data/repositories/local/local_repository.dart';
import 'package:beecount/l10n/app_localizations.dart';
import 'package:beecount/pages/transaction/refund_page.dart';
import 'package:beecount/pages/transaction/transaction_detail_page.dart';
import 'package:beecount/providers/database_providers.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('detail opens default full refund; partial switch and cancel never write', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final db = BeeDatabase.forTesting(NativeDatabase.memory());
    final repo = LocalRepository(db);
    final ledger = await repo.createLedger(name: '退款账本');
    final account = await repo.createAccount(ledgerId: ledger, name: '原支付账户');
    final original = await repo.addTransaction(ledgerId: ledger, type: 'expense',
      amount: 100, accountId: account, happenedAt: DateTime(2026, 11, 5, 12, 32));
    final container = ProviderContainer(overrides: [databaseProvider.overrideWithValue(db),
      repositoryProvider.overrideWithValue(repo), currentLedgerIdProvider.overrideWith((ref) => ledger)]);
    addTearDown(() async { container.dispose(); await db.close(); });
    await tester.pumpWidget(UncontrolledProviderScope(container: container, child: MaterialApp(
      locale: const Locale('zh'), localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: TransactionDetailPage(transactionId: original))));
    await tester.runAsync(() async { await Future<void>.delayed(const Duration(milliseconds: 150)); });
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('detail-refund')));
    await tester.tap(find.byKey(const Key('detail-refund')));
    await tester.pumpAndSettle();
    await tester.runAsync(() async { await Future<void>.delayed(const Duration(milliseconds: 150)); });
    await tester.pumpAndSettle();
    expect(find.byType(RefundPage), findsOneWidget);
    final toggle = tester.widget<SwitchListTile>(find.byKey(const Key('refund-custom-switch')));
    expect(toggle.value, false);
    expect(tester.widget<Text>(find.byKey(const Key('refund-full-amount'))).data, contains('100'));
    expect(find.byKey(const Key('refund-amount-input')), findsNothing);
    expect(find.text('原支付账户'), findsOneWidget);
    expect(find.text('2026-11-05 12:32:00'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    await tester.tap(find.byKey(const Key('refund-custom-switch')));
    await tester.pumpAndSettle();
    final input = find.byKey(const Key('refund-amount-input'));
    expect(tester.widget<TextField>(input).controller!.text, '100.00');
    await tester.enterText(input, '30');
    tester.testTextInput.hide();
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.byType(RefundPage), findsNothing);
    expect((await repo.getTransactionsByLedger(ledger)).length, 1);
    expect(await repo.getAccountBalance(account), -100);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('missing source account disables save instead of substituting another', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final db = BeeDatabase.forTesting(NativeDatabase.memory());
    final repo = LocalRepository(db);
    final ledger = await repo.createLedger(name: '退款账本');
    await repo.createAccount(ledgerId: ledger, name: '不能自动选此账户');
    final original = await repo.addTransaction(ledgerId: ledger, type: 'expense',
      amount: 100, happenedAt: DateTime(2026, 11, 5));
    final container = ProviderContainer(overrides: [databaseProvider.overrideWithValue(db),
      repositoryProvider.overrideWithValue(repo), currentLedgerIdProvider.overrideWith((ref) => ledger)]);
    addTearDown(() async { container.dispose(); await db.close(); });
    await tester.pumpWidget(UncontrolledProviderScope(container: container, child: MaterialApp(
      locale: const Locale('zh'), localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales, home: RefundPage(transactionId: original))));
    await tester.runAsync(() async { await Future<void>.delayed(const Duration(milliseconds: 150)); });
    await tester.pumpAndSettle();
    expect(tester.widget<TextButton>(find.byKey(const Key('refund-save'))).onPressed, isNull);
    expect(find.text('不能自动选此账户'), findsNothing);
    expect((await repo.getTransactionsByLedger(ledger)).length, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 3));
  });
}
