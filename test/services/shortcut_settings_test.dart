import 'package:beecount/data/db.dart';
import 'package:beecount/data/repositories/local/local_repository.dart';
import 'package:beecount/pages/settings/shortcut_billing_page.dart';
import 'package:beecount/providers/database_providers.dart';
import 'package:beecount/services/automation/shortcut_store.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets(
      'personal rules can be created, disabled, edited and deleted in App',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final db = BeeDatabase.forTesting(NativeDatabase.memory());
    final repo = LocalRepository(db);
    addTearDown(db.close);
    await repo.createLedger(name: '个人账本');
    await repo.createCategory(name: '自建餐饮', kind: 'expense');
    tester.view.physicalSize = const Size(1000, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(ProviderScope(
      overrides: [repositoryProvider.overrideWithValue(repo)],
      child: const MaterialApp(home: ShortcutBillingPage()),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(0), '咖啡规则');
    await tester.enterText(find.byType(TextField).at(1), '瑞幸');
    await tester.enterText(find.byType(TextField).at(2), '42');
    await tester.tap(find.text('目标分类'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('自建餐饮').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    var rule = (await ShortcutStore(repo).rules()).single;
    expect(rule['name'], '咖啡规则');
    expect(rule['priority'], 42);
    expect(rule['enabled'], 1);
    await tester.tap(find.byType(Switch).last);
    await tester.pumpAndSettle();
    expect((await ShortcutStore(repo).rules()).single['enabled'], 0);
    await tester.tap(find.text('咖啡规则'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(0), '修改后的规则');
    await tester.enterText(find.byType(TextField).at(2), '80');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    rule = (await ShortcutStore(repo).rules()).single;
    expect(rule['name'], '修改后的规则');
    expect(rule['priority'], 80);
    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(await ShortcutStore(repo).rules(), isEmpty);
    expect(tester.takeException(), isNull);
  });
}
