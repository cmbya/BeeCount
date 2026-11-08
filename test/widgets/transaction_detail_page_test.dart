import 'package:beecount/data/db.dart';
import 'package:beecount/data/repositories/local/local_repository.dart';
import 'package:beecount/l10n/app_localizations.dart';
import 'package:beecount/pages/transaction/transaction_detail_page.dart';
import 'package:beecount/providers/database_providers.dart';
import 'package:beecount/widgets/biz/amount_editor_sheet.dart';
import 'package:beecount/widgets/biz/transaction_list.dart';
import 'package:beecount/widgets/biz/transaction_list_item.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../support/widget_waits.dart';

void main() {
  testWidgets('saved row opens grouped details without amount keyboard; note is prefilled', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final db = BeeDatabase.forTesting(NativeDatabase.memory());
    final repo = LocalRepository(db);
    final ledger = await repo.createLedger(name: '默认账本');
    final categoryId = await repo.createCategory(name: '水电燃气', kind: 'expense');
    final id = await repo.addTransaction(ledgerId: ledger, type: 'expense', amount: 127.89,
      categoryId: categoryId, happenedAt: DateTime(2026, 11, 5, 12, 32), note: '广东电网｜生活缴费');
    final tx = (await repo.getTransactionById(id))!;
    final category = await repo.getCategoryById(categoryId);
    final container = ProviderContainer(overrides: [databaseProvider.overrideWithValue(db),
      repositoryProvider.overrideWithValue(repo), currentLedgerIdProvider.overrideWith((ref) => ledger)]);
    addTearDown(() async { container.dispose(); await db.close(); });
    await tester.pumpWidget(UncontrolledProviderScope(container: container, child: MaterialApp(
      locale: const Locale('zh'), localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: TransactionList(hideAmounts: false, transactions: [(t: tx, category: category, account: null, toAccount: null)])))));
    await tester.pumpAndSettle();
    await pumpUntilFound(tester, find.byType(TransactionListItem, skipOffstage: false));
    await tester.tap(find.byType(TransactionListItem, skipOffstage: false));
    await tester.runAsync(() async { await Future<void>.delayed(const Duration(milliseconds: 150)); });
    await tester.pumpAndSettle();
    expect(find.byType(TransactionDetailPage), findsOneWidget);
    expect(find.text('账单详情'), findsOneWidget);
    expect(find.byType(AmountEditorSheet), findsNothing);
    expect(find.byType(TextField), findsNothing);
    await pumpUntilFound(tester, find.byKey(const Key('detail-category')));
    await revealRow(tester, find.byKey(const Key('detail-note')));
    await tester.tap(find.byKey(const Key('detail-note')));
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(find.byKey(const Key('detail-field-input')));
    expect(field.controller!.text, '广东电网｜生活缴费');
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect((await repo.getTransactionById(id))!.note, '广东电网｜生活缴费');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 3));
  });
}
