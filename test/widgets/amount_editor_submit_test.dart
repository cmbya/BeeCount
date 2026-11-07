import 'dart:async';

import 'package:beecount/data/db.dart';
import 'package:beecount/data/repositories/local/local_repository.dart';
import 'package:beecount/l10n/app_localizations.dart';
import 'package:beecount/providers.dart';
import 'package:beecount/widgets/biz/amount_editor_sheet.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('awaits submit, blocks duplicate taps and allows retry on error', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final db = BeeDatabase.forTesting(NativeDatabase.memory());
    final repo = LocalRepository(db);
    final ledger = await repo.createLedger(name: 'submit');
    final row = await repo.getLedgerById(ledger);
    final pending = Completer<void>();
    var calls = 0;
    addTearDown(db.close);
    await tester.pumpWidget(ProviderScope(overrides: [
      repositoryProvider.overrideWithValue(repo),
      currentLedgerIdProvider.overrideWith((ref) => ledger),
      currentLedgerProvider.overrideWith((ref) => Stream.value(row)),
    ], child: MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: AmountEditorSheet(
        categoryName: 'submit', initialDate: DateTime(2026, 11, 8),
        initialAmount: 10, ledgerId: ledger,
        onSubmit: (_) async { calls++; if (calls == 1) await pending.future; },
      )),
    )));
    await tester.pumpAndSettle();
    final finish = find.widgetWithText(InkWell, '完成').last;
    final finishLocation = tester.getCenter(finish);
    await tester.tapAt(finishLocation);
    await tester.pump();
    expect(calls, 1);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.tapAt(finishLocation);
    await tester.pump();
    expect(calls, 1);
    pending.completeError(StateError('save failed'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('保存失败，请检查所选资料、编辑权限及有效汇率。'), findsOneWidget);
    await tester.tapAt(finishLocation);
    await tester.pump();
    expect(calls, 2);
    await tester.tapAt(finishLocation);
    await tester.pump();
    expect(calls, 2, reason: 'a committed callback must stay locked');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 3));
  });
}
