import 'package:beecount/cloud/sync_service.dart';
import 'package:beecount/data/db.dart';
import 'package:beecount/data/repositories/local/local_repository.dart';
import 'package:beecount/providers.dart';
import 'package:beecount/providers/budget_providers.dart';
import 'package:beecount/services/billing/post_processor.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late BeeDatabase db;
  late LocalRepository repo;
  late ProviderContainer c;
  late int ledger;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = BeeDatabase.forTesting(NativeDatabase.memory());
    repo = LocalRepository(db);
    ledger = await repo.createLedger(name: 'budget');
    await repo.createBudget(ledgerId: ledger, type: 'total', amount: 1000);
    c = ProviderContainer(overrides: [
      repositoryProvider.overrideWithValue(repo),
      currentLedgerIdProvider.overrideWith((ref) => ledger),
      syncServiceProvider.overrideWithValue(LocalOnlySyncService()),
    ]);
  });
  tearDown(() async { c.dispose(); await db.close(); });

  test('container post-processing refreshes an already loaded budget', () async {
    final subscription = c.listen(budgetOverviewProvider, (_, __) {});
    addTearDown(subscription.close);
    expect((await c.read(budgetOverviewProvider.future))!.totalBudget!.used, 0);
    await repo.addTransaction(ledgerId: ledger, type: 'expense', amount: 35,
        happenedAt: DateTime.now());
    await PostProcessor.runC(c, ledgerId: ledger);
    expect(c.read(budgetRefreshProvider), 1);
    expect((await c.read(budgetOverviewProvider.future))!.totalBudget!.used, 35);
  });

  test('post-commit sync error cannot become a failed bill save', () async {
    final id = await repo.addTransaction(ledgerId: ledger, type: 'expense',
        amount: 10, happenedAt: DateTime.now());
    final failing = ProviderContainer(overrides: [
      syncServiceProvider.overrideWith((ref) => throw StateError('sync unavailable')),
    ]);
    try {
      await PostProcessor.afterCommit(() => PostProcessor.runC(failing, ledgerId: ledger));
      expect(await repo.getTransactionById(id), isNotNull);
      expect(failing.read(budgetRefreshProvider), 1);
      expect(await db.select(db.transactions).get(), hasLength(1));
    } finally {
      failing.dispose();
    }
  });

  test('Ref post-processing refreshes the budget', () async {
    final provider = Provider<Future<void> Function()>((ref) =>
        () => PostProcessor.runR(ref, ledgerId: ledger));
    // Invoke after provider initialization, as a real event handler does.
    await c.read(provider)();
    expect(c.read(budgetRefreshProvider), 1);
  });

  test('download post-processing refreshes the budget without uploading', () {
    PostProcessor.runAfterDownloadC(c);
    expect(c.read(budgetRefreshProvider), 1);
  });

  testWidgets('WidgetRef post-processing and downloads refresh the budget', (tester) async {
    late WidgetRef widgetRef;
    await tester.pumpWidget(UncontrolledProviderScope(container: c,
      child: MaterialApp(home: Consumer(builder: (context, ref, _) {
        widgetRef = ref;
        return const SizedBox.shrink();
      })),
    ));
    await tester.runAsync(() => PostProcessor.run(widgetRef, ledgerId: ledger));
    expect(c.read(budgetRefreshProvider), 1);
    PostProcessor.runAfterDownload(widgetRef);
    expect(c.read(budgetRefreshProvider), 2);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 3));
  });
}
