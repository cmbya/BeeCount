import 'dart:io';

import 'package:beecount/cloud/sync/change_tracker.dart';
import 'package:beecount/cloud/sync_service.dart';
import 'package:beecount/data/db.dart';
import 'package:beecount/data/repositories/local/local_repository.dart';
import 'package:beecount/l10n/app_localizations.dart';
import 'package:beecount/providers.dart';
import 'package:beecount/services/attachment_service.dart';
import 'package:beecount/utils/shared_ledger_picker_filter.dart';
import 'package:beecount/widgets/biz/amount_editor_sheet.dart';
import 'package:beecount/widgets/transaction/transfer_form.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FailedImages extends AttachmentService {
  _FailedImages(super.ref);
  @override
  Future<AttachmentSaveResult> saveAttachmentsWithResult({
    required int transactionId, required List<File> sourceFiles,
    int startIndex = 0,
  }) async => AttachmentSaveResult(saved: [], failedIndexes: [startIndex]);
}

void main() {
  for (final editing in [false, true]) {
    testWidgets('transfer ${editing ? 'edit' : 'create'} rolls back all fields and tags', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final db = BeeDatabase.forTesting(NativeDatabase.memory());
      final repo = LocalRepository(db, changeTracker: ChangeTracker(db));
      final ledger = await repo.createLedger(name: 'transfer');
      final row = await repo.getLedgerById(ledger);
      final from = await repo.createAccount(ledgerId: ledger, name: 'from');
      final oldTo = await repo.createAccount(ledgerId: ledger, name: 'old to');
      final newTo = await repo.createAccount(ledgerId: ledger, name: 'new to');
      final tag = await repo.createTag(name: 'tag');
      final id = editing ? await repo.addTransaction(ledgerId: ledger,
        type: 'transfer', amount: 5, accountId: from, toAccountId: oldTo,
        happenedAt: DateTime(2026, 11, 8), note: 'original') : null;
      await db.delete(db.localChanges).go();
      final c = ProviderContainer(overrides: [
        databaseProvider.overrideWithValue(db),
        repositoryProvider.overrideWithValue(repo),
        currentLedgerIdProvider.overrideWith((ref) => ledger),
        currentLedgerProvider.overrideWith((ref) => Stream.value(row)),
        syncServiceProvider.overrideWithValue(LocalOnlySyncService()),
        beecountCloudProviderInstance.overrideWith((ref) async => null),
        attachmentServiceProvider.overrideWith((ref) => _FailedImages(ref)),
      ]);
      var completed = 0;
      addTearDown(() async { c.dispose(); await db.close(); });
      await tester.pumpWidget(UncontrolledProviderScope(container: c,
        child: MaterialApp(locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: TransferForm(onTransferComplete: () { completed++; },
            editingTransactionId: id, initialFromAccountId: from,
            initialToAccountId: newTo, initialAmount: 10, initialTagIds: [tag])),
        ),
      ));
      await tester.runAsync(() async { await Future<void>.delayed(const Duration(milliseconds: 150)); });
      await tester.pumpAndSettle();
      expect(find.byType(AmountEditorSheet), findsOneWidget);
      final sheet = tester.widget<AmountEditorSheet>(find.byType(AmountEditorSheet));
      final AmountEditorResult result = (
        amount: 10.0, continueAdding: false, note: 'changed',
        date: DateTime(2026, 11, 8), accountId: null, tagIds: [tag],
        pendingAttachments: [File('/unused-test-image.png')],
        excludeFromStats: false, excludeFromBudget: false,
        currencyCode: 'CNY', nativeAmount: 10.0,
      );
      await tester.runAsync(() async {
        await db.customStatement("""
          CREATE TRIGGER fail_transfer_tag BEFORE INSERT ON transaction_tags
          BEGIN SELECT RAISE(ABORT, 'tag failed'); END
        """);
        await expectLater(Future.sync(() => sheet.onSubmit(result)),
            throwsA(isA<Exception>()));
        if (editing) {
          final tx = (await repo.getTransactionById(id!))!;
          expect(tx.amount, 5);
          expect(tx.note, 'original');
          expect(tx.toAccountId, oldTo);
        } else {
          expect(await db.select(db.transactions).get(), isEmpty);
        }
        expect(await db.select(db.transactionTags).get(), isEmpty);
        expect(await db.select(db.localChanges).get(), isEmpty);
        expect(completed, 0);
        await db.customStatement('DROP TRIGGER fail_transfer_tag');
        final AmountEditorResult staleTag = (
          amount: result.amount, continueAdding: result.continueAdding,
          note: result.note, date: result.date, accountId: result.accountId,
          tagIds: [syntheticIdForSyncId('missing-owner-tag')],
          pendingAttachments: result.pendingAttachments,
          excludeFromStats: result.excludeFromStats,
          excludeFromBudget: result.excludeFromBudget,
          currencyCode: result.currencyCode, nativeAmount: result.nativeAmount,
        );
        await expectLater(Future.sync(() => sheet.onSubmit(staleTag)), throwsStateError);
        expect(completed, 0);
        await sheet.onSubmit(result);
        final tx = (await db.select(db.transactions).get()).single;
        expect(tx.amount, 10);
        expect(tx.toAccountId, newTo);
        expect(await db.select(db.transactionTags).get(), hasLength(1));
      });
      await tester.pump();
      expect(completed, 1);
      expect(find.text('账单已保存，但部分附件保存失败。请在账单详情中补添附件，不要重复记账。'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 6));
    });
  }
}
