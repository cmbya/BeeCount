import 'dart:io';
import 'package:beecount/data/db.dart';
import 'package:beecount/data/repositories/local/local_repository.dart';
import 'package:beecount/l10n/app_localizations.dart';
import 'package:beecount/pages/transaction/transaction_detail_page.dart';
import 'package:beecount/providers/database_providers.dart';
import 'package:beecount/services/attachment_service.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../support/widget_waits.dart';

class _FakeImages extends AttachmentService {
  final int successCount;
  _FakeImages(super.ref, this.successCount);
  @override
  Future<List<File>> pickFromGallery({int maxCount = 9}) async => [File('fake-a.jpg'), File('fake-b.jpg')];
  @override
  Future<List<TransactionAttachment>> saveAttachments({required int transactionId, required List<File> sourceFiles, int startIndex = 0}) async {
    final repo = ref.read(repositoryProvider);
    final result = <TransactionAttachment>[];
    for (var i = 0; i < successCount; i++) {
      final id = await repo.createAttachment(transactionId: transactionId, fileName: 'fake-$i.jpg');
      result.add((await repo.getAttachmentById(id))!);
    }
    return result;
  }
}

void main() {
  for (final saved in [0, 1]) {
    testWidgets('reports image ${saved == 0 ? "failure" : "partial failure"} instead of silent success', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final db = BeeDatabase.forTesting(NativeDatabase.memory());
      final repo = LocalRepository(db);
      final ledger = await repo.createLedger(name: '测试');
      final id = await repo.addTransaction(ledgerId: ledger, type: 'expense', amount: 10, happenedAt: DateTime(2026, 11, 5));
      final container = ProviderContainer(overrides: [databaseProvider.overrideWithValue(db),
        repositoryProvider.overrideWithValue(repo), currentLedgerIdProvider.overrideWith((ref) => ledger),
        attachmentServiceProvider.overrideWith((ref) => _FakeImages(ref, saved))]);
      addTearDown(() async { container.dispose(); await db.close(); });
      await tester.pumpWidget(UncontrolledProviderScope(container: container, child: MaterialApp(
        locale: const Locale('zh'), localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales, home: TransactionDetailPage(transactionId: id))));
      await tester.runAsync(() async { await Future<void>.delayed(const Duration(milliseconds: 150)); });
      await tester.pumpAndSettle();
      await pumpUntilFound(tester, find.byKey(const Key('detail-category')));
      await revealRow(tester, find.byKey(const Key('detail-images')));
      await tester.tap(find.byKey(const Key('detail-images')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('从相册选择'));
      await tester.runAsync(() async { await Future<void>.delayed(const Duration(milliseconds: 150)); });
      await tester.pumpAndSettle();
      final l10n = AppLocalizations.of(tester.element(find.byType(TransactionDetailPage)));
      expect(find.text(saved == 0 ? l10n.transactionDetailImagesFailed : l10n.transactionDetailImagesPartial), findsOneWidget);
      expect((await repo.getAttachmentsByTransaction(id)).length, saved);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 3));
    });
  }

  testWidgets('saved shortcut screenshot is shown in bill detail images row', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final db = BeeDatabase.forTesting(NativeDatabase.memory()); final repo = LocalRepository(db);
    final ledger = await repo.createLedger(name: '附件账本');
    final id = await repo.addTransaction(ledgerId: ledger, type: 'expense', amount: 10, happenedAt: DateTime(2026, 11, 5));
    await repo.createAttachment(transactionId: id, fileName: 'sha_picture.png', originalName: 'payment-screenshot.png');
    final container = ProviderContainer(overrides: [databaseProvider.overrideWithValue(db),
      repositoryProvider.overrideWithValue(repo), currentLedgerIdProvider.overrideWith((ref) => ledger)]);
    addTearDown(() async { container.dispose(); await db.close(); });
    await tester.pumpWidget(UncontrolledProviderScope(container: container, child: MaterialApp(
      locale: const Locale('zh'), localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales, home: TransactionDetailPage(transactionId: id))));
    await tester.runAsync(() async => Future<void>.delayed(const Duration(milliseconds: 150)));
    await tester.pumpAndSettle();
    await pumpUntilFound(tester, find.byKey(const Key('detail-category')));
      await revealRow(tester, find.byKey(const Key('detail-images')));
    expect(find.descendant(of: find.byKey(const Key('detail-images')), matching: find.text('1')), findsOneWidget);
    expect((await repo.getAttachmentsByTransaction(id)).single.originalName, 'payment-screenshot.png');
    await tester.pumpWidget(const SizedBox.shrink()); await tester.pump(const Duration(seconds: 3));
  });
}
