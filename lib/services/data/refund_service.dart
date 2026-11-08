import 'package:drift/drift.dart' as d;
import 'package:uuid/uuid.dart';

import '../../data/db.dart';
import '../../data/repositories/local/local_repository.dart';
import '../../models/refund_identity.dart';
import '../../utils/account_type_utils.dart';
import '../../utils/shared_ledger_picker_filter.dart';
import '../automation/shortcut_schema.dart' show parseShortcutAmount, shortcutCurrencyDigits;
import 'transaction_detail_service.dart';

class RefundFailure implements Exception {
  final String code;
  const RefundFailure(this.code);
}

class RefundInfo {
  final Transaction original;
  final Ledger ledger;
  final String currency;
  final String? accountName;
  final int originalMinor;
  final int refundedMinor;
  final List<Transaction> refunds;
  const RefundInfo({required this.original, required this.ledger,
    required this.currency, required this.accountName, required this.originalMinor,
    required this.refundedMinor, required this.refunds});

  /// Both future refund statistics use these same credit records, not a second
  /// transaction or another balance adjustment.
  int get remainingMinor => originalMinor - refundedMinor;
  int get digits => shortcutCurrencyDigits(currency);
  double value(int minor) => minor / _pow10(digits);
  static int _pow10(int digits) { var n = 1; for (var i = 0; i < digits; i++) { n *= 10; } return n; }
}

/// A refund is one excluded-from-ordinary-statistics income transaction. This
/// credits balances/net worth exactly once, without editing account initial
/// balances, the original expense, or its budget usage.
class RefundService {
  final LocalRepository repo;
  RefundService(this.repo);

  static int minor(double amount, String currency) {
    final digits = shortcutCurrencyDigits(currency);
    if (!amount.isFinite || amount <= 0) throw const RefundFailure('amount');
    final fixed = amount.toStringAsFixed(digits);
    if ((double.parse(fixed) - amount).abs() > 0.00000001) {
      throw const RefundFailure('amount');
    }
    try { return parseShortcutAmount(fixed, digits: digits); }
    catch (_) { throw const RefundFailure('amount'); }
  }

  Future<RefundInfo> load(int originalId) => repo.db.transaction(() async {
    final original = await repo.getTransactionById(originalId);
    if (original == null) throw const RefundFailure('not_found');
    if (original.type != 'expense' || RefundIdentity.isRefund(original.syncId)) {
      throw const RefundFailure('expense_only');
    }
    final ledger = await repo.getLedgerById(original.ledgerId);
    if (ledger == null || !TransactionDetailService.canEdit(ledger)) {
      throw const RefundFailure('read_only');
    }
    Account? account;
    if (original.accountSyncIdOverride != null) {
      final rows = await (repo.db.select(repo.db.sharedLedgerAccounts)
            ..where((a) => a.ledgerSyncId.equals(ledger.syncId ?? '') &
                a.syncId.equals(original.accountSyncIdOverride!)))
          .get();
      if (rows.length != 1) throw const RefundFailure('account');
      final shared = rows.single;
      account = Account(id: syntheticIdForSyncId(shared.syncId), ledgerId: 0,
        name: shared.name, type: shared.accountType, currency: shared.currency,
        initialBalance: shared.initialBalance ?? 0, sortOrder: 0, hidden: false,
        syncId: shared.syncId);
    } else if (original.accountId != null) {
      account = await repo.getAccount(original.accountId!);
    }
    final currency = (original.currencyCode ?? account?.currency ?? ledger.currency).toUpperCase();
    if (!RegExp(r'^[A-Z]{3}$').hasMatch(currency) ||
        (original.nativeAmount != null &&
            (!original.nativeAmount!.isFinite || original.nativeAmount! <= 0))) {
      throw const RefundFailure('inconsistent');
    }
    if (account != null && (!isTradableType(account.type) ||
        account.currency.toUpperCase() != currency)) {
      throw const RefundFailure('account');
    }
    // A deleted referenced account is not silently replaced by a default.
    if (account == null && (original.accountId != null || original.accountSyncIdOverride != null)) {
      throw const RefundFailure('account');
    }
    if (original.syncId?.isNotEmpty == true) {
      final parents = await (repo.db.select(repo.db.transactions)
            ..where((t) => t.syncId.equals(original.syncId!) & t.ledgerId.equals(original.ledgerId)))
          .get();
      if (parents.length != 1) throw const RefundFailure('inconsistent');
    }
    final rows = original.syncId == null ? <Transaction>[]
        : await repo.getRefundTransactions(original.syncId!, ledgerId: original.ledgerId);
    var refunded = 0;
    final seen = <String>{};
    for (final row in rows) {
      if (!seen.add(row.syncId!) || row.type != 'income' || row.ledgerId != ledger.id ||
          !row.excludeFromStats || !row.excludeFromBudget ||
          row.accountId != original.accountId ||
          row.accountSyncIdOverride != original.accountSyncIdOverride ||
          row.happenedAt != original.happenedAt ||
          (row.currencyCode ?? currency).toUpperCase() != currency) {
        throw const RefundFailure('inconsistent');
      }
      refunded += minor(row.amount, currency);
    }
    final total = minor(original.amount, currency);
    if (refunded > total) throw const RefundFailure('inconsistent');
    return RefundInfo(original: original, ledger: ledger, currency: currency,
      accountName: account?.name, originalMinor: total,
      refundedMinor: refunded, refunds: List.unmodifiable(rows));
  });

  Future<Transaction> save({required int originalId, required String requestId,
    String? customAmount, required int expectedRemainingMinor, required String expectedCurrency,
    required Transaction expected}) => repo.db.transaction(() async {
    var info = await load(originalId);
    var source = info.original;
    if (info.currency != expectedCurrency.toUpperCase() ||
        source.type != expected.type || source.amount != expected.amount ||
        source.ledgerId != expected.ledgerId || source.accountId != expected.accountId ||
        source.accountSyncIdOverride != expected.accountSyncIdOverride ||
        source.happenedAt != expected.happenedAt || source.currencyCode != expected.currencyCode ||
        source.nativeAmount != expected.nativeAmount ||
        (expected.syncId?.isNotEmpty == true && source.syncId != expected.syncId)) {
      throw const RefundFailure('stale');
    }
    if (source.accountId == null && source.accountSyncIdOverride == null) {
      throw const RefundFailure('account');
    }
    if (source.syncId == null || source.syncId!.isEmpty) {
      final syncId = const Uuid().v4();
      await (repo.db.update(repo.db.transactions)..where((t) => t.id.equals(source.id)))
          .write(TransactionsCompanion(syncId: d.Value(syncId)));
      if (repo.changeTracker != null) {
        await repo.changeTracker!.recordLedgerChange(entityType: 'transaction',
          entityId: source.id, entitySyncId: syncId, ledgerId: source.ledgerId, action: 'update');
      }
      info = await load(originalId);
      source = info.original;
    }
    final identity = RefundIdentity(source.syncId!, requestId).encode();
    final matching = info.refunds.where((tx) => tx.syncId == identity).toList();
    if (matching.length > 1) throw const RefundFailure('inconsistent');
    final previous = matching.isEmpty ? null : matching.single;
    int requested;
    try { requested = customAmount == null ? expectedRemainingMinor
        : parseShortcutAmount(customAmount, digits: info.digits); }
    catch (_) { throw const RefundFailure('amount'); }
    if (previous != null) {
      // A retry of this exact operation returns its existing credit, never adds one.
      if (minor(previous.amount, info.currency) != requested) {
        throw const RefundFailure('conflict');
      }
      return previous;
    }
    if (customAmount == null && expectedRemainingMinor != info.remainingMinor) {
      throw const RefundFailure('stale');
    }
    if (requested <= 0 || requested > info.remainingMinor) {
      throw const RefundFailure('exceeds');
    }
    final amount = info.value(requested);
    // Keep the original ledger-currency snapshot and its implicit rate.
    // Legacy NULL snapshots also remain NULL (ordinary reports use amount as
    // their existing fallback); never invent a fresh 1:1 FX snapshot here.
    final native = source.nativeAmount == null ? null
        : source.nativeAmount! / source.amount * amount;
    final id = await repo.addTransaction(ledgerId: source.ledgerId, type: 'income',
      amount: amount, accountId: source.accountId,
      accountSyncIdOverride: source.accountSyncIdOverride,
      happenedAt: source.happenedAt, note: source.note,
      syncId: identity, excludeFromStats: true, excludeFromBudget: true,
      currencyCode: info.currency, nativeAmount: native);
    return (await repo.getTransactionById(id))!;
  });

  Future<void> remove(int refundId) => repo.db.transaction(() async {
    final refund = await repo.getTransactionById(refundId);
    if (refund == null) return;
    if (!RefundIdentity.isRefund(refund.syncId)) throw const RefundFailure('not_found');
    final ledger = await repo.getLedgerById(refund.ledgerId);
    if (ledger == null || !TransactionDetailService.canEdit(ledger)) {
      throw const RefundFailure('read_only');
    }
    // Deleting this single credit reverses its account effect; original stays.
    await repo.deleteTransaction(refundId);
  });
}
