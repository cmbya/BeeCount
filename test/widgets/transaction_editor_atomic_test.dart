import 'package:beecount/cloud/sync/change_tracker.dart';
import 'package:beecount/cloud/sync_service.dart';
import 'package:beecount/data/db.dart';
import 'package:beecount/data/repositories/local/local_repository.dart';
import 'package:beecount/l10n/app_localizations.dart';
import 'package:beecount/pages/transaction/transaction_editor_page.dart';
import 'package:beecount/providers.dart';
import 'package:beecount/widgets/biz/amount_editor_sheet.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('manual bill and tags roll back together before retry', (tester) async {
    SharedPreferences.setMockInitialValues({});
    const channel = MethodChannel('home_widget');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      channel, (call) async => call.method == 'getInstalledWidgets' ? <dynamic>[] : null);
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, null));
    final db = BeeDatabase.forTesting(NativeDatabase.memory());
    final repo = LocalRepository(db, changeTracker: ChangeTracker(db));
    final ledger = await repo.createLedger(name: 'manual');
    final row = await repo.getLedgerById(ledger);
    final category = await repo.createCategory(name: 'manual-category', kind: 'expense');
    final tag = await repo.createTag(name: 'manual-tag');
    await db.delete(db.localChanges).go();
    await db.customStatement("""
      CREATE TRIGGER reject_tag BEFORE INSERT ON transaction_tags
      BEGIN SELECT RAISE(ABORT, 'injected tag failure'); END
    """);
    final c = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      repositoryProvider.overrideWithValue(repo),
      currentLedgerIdProvider.overrideWith((ref) => ledger),
      currentLedgerProvider.overrideWith((ref) => Stream.value(row)),
      syncServiceProvider.overrideWithValue(LocalOnlySyncService()),
      beecountCloudProviderInstance.overrideWith((ref) async => null),
    ]);
    addTearDown(() async { c.dispose(); await db.close(); });
    await tester.pumpWidget(UncontrolledProviderScope(container: c,
      child: MaterialApp(locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: TransactionEditorPage(initialKind: 'expense', quickAdd: true,
          initialCategoryId: category, initialAmount: 10, initialTagIds: [tag]),
      ),
    ));
    await tester.runAsync(() async { await Future<void>.delayed(const Duration(milliseconds: 150)); });
    await tester.pumpAndSettle();
    expect(find.byType(AmountEditorSheet), findsOneWidget);
    final sheet = tester.widget<AmountEditorSheet>(find.byType(AmountEditorSheet));
    final AmountEditorResult result = (amount: 10.0, continueAdding: false, note: 'manual',
      date: DateTime(2026, 11, 8), accountId: null, tagIds: [tag],
      pendingAttachments: [], excludeFromStats: false,
      excludeFromBudget: false, currencyCode: 'CNY', nativeAmount: 10.0);
    await tester.runAsync(() async {
      await expectLater(Future.sync(() => sheet.onSubmit(result)), throwsA(isA<Exception>()));
      expect(await db.select(db.transactions).get(), isEmpty);
      expect(await db.select(db.transactionTags).get(), isEmpty);
      expect(await db.select(db.localChanges).get(), isEmpty);
      await db.customStatement('DROP TRIGGER reject_tag');
      await sheet.onSubmit(result);
      expect(await db.select(db.transactions).get(), hasLength(1));
      expect(await db.select(db.transactionTags).get(), hasLength(1));
      expect((await db.select(db.localChanges).get()).where((c) => c.entityType == 'transaction'), hasLength(1));
    });
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 3));
  }, timeout: const Timeout(Duration(minutes: 2)));
}
