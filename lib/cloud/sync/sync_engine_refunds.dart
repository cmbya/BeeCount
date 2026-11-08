part of 'sync_engine.dart';

// Validate an atomic pull batch's final state, not intermediate event order.
class _RefundSyncConflict implements Exception {
  final String code;
  const _RefundSyncConflict(this.code);
  @override
  String toString() => 'RefundSyncConflict($code)';
}

class _RefundSyncSnapshot {
  final Map<(int, String), List<Transaction>> refunds, originals;
  final Map<int, Ledger> ledgers;
  final Map<int, Account> accounts;
  final Map<(String, String), SharedLedgerAccount> sharedAccounts;
  const _RefundSyncSnapshot(this.refunds, this.originals, this.ledgers,
      this.accounts, this.sharedAccounts);

  String currency(Transaction tx) {
    final ledger = ledgers[tx.ledgerId];
    final accountCurrency = tx.accountSyncIdOverride != null
        ? sharedAccounts[(ledger?.syncId ?? '', tx.accountSyncIdOverride!)]?.currency
        : accounts[tx.accountId]?.currency;
    return (tx.currencyCode ?? accountCurrency ?? ledger?.currency ?? '').toUpperCase();
  }
}

extension SyncEngineRefundsExt on SyncEngine {
  Future<_RefundSyncSnapshot> _refundSnapshot() async {
    final rows = await db.customSelect(
      'SELECT * FROM transactions WHERE sync_id >= ?1 AND sync_id < ?2',
      variables: [d.Variable<String>(RefundIdentity.prefix),
        d.Variable<String>('beecount-refund-v1;')], readsFrom: {db.transactions}).get();
    final refunds = <(int, String), List<Transaction>>{};
    for (final row in rows) {
      final tx = db.transactions.map(row.data);
      final identity = RefundIdentity.parse(tx.syncId);
      if (identity == null) continue;
      refunds.putIfAbsent((tx.ledgerId, identity.originalSyncId), () => []).add(tx);
    }
    final originals = <(int, String), List<Transaction>>{};
    final keys = refunds.keys.map((key) => key.$2).toSet().toList();
    for (var offset = 0; offset < keys.length; offset += 400) {
      final end = offset + 400 < keys.length ? offset + 400 : keys.length;
      final sources = await (db.select(db.transactions)
        ..where((t) => t.syncId.isIn(keys.sublist(offset, end)))).get();
      for (final tx in sources) {
        originals.putIfAbsent((tx.ledgerId, tx.syncId!), () => []).add(tx);
      }
    }
    if (refunds.isEmpty) return _RefundSyncSnapshot(refunds, originals, {}, {}, {});
    return _RefundSyncSnapshot(refunds, originals,
      {for (final l in await db.select(db.ledgers).get()) l.id: l},
      {for (final a in await db.select(db.accounts).get()) a.id: a},
      {for (final a in await db.select(db.sharedLedgerAccounts).get())
        (a.ledgerSyncId, a.syncId): a});
  }

  int _refundMinor(double amount, String currency) {
    if (!amount.isFinite || amount <= 0) throw const _RefundSyncConflict('amount');
    final digits = shortcutCurrencyDigits(currency);
    final fixed = amount.toStringAsFixed(digits);
    if ((double.parse(fixed) - amount).abs() > 0.00000001) {
      throw const _RefundSyncConflict('precision');
    }
    try { return parseShortcutAmount(fixed, digits: digits); }
    catch (_) { throw const _RefundSyncConflict('amount'); }
  }

  bool _sameRefundMoney(Transaction a, Transaction b,
      _RefundSyncSnapshot before, _RefundSyncSnapshot after) =>
    a.ledgerId == b.ledgerId && a.type == b.type && a.amount == b.amount &&
    a.happenedAt == b.happenedAt && a.accountId == b.accountId &&
    a.accountSyncIdOverride == b.accountSyncIdOverride &&
    a.toAccountId == b.toAccountId && a.toAccountSyncIdOverride == b.toAccountSyncIdOverride &&
    before.currency(a) == after.currency(b) && a.nativeAmount == b.nativeAmount;

  Future<void> _validateRefundSync(_RefundSyncSnapshot before,
      List<BeeCountCloudSyncChange> changes) async {
    final after = await _refundSnapshot();
    final changed = {for (final ch in changes)
      if (ch.entityType == 'transaction') ch.entitySyncId};
    final changedAccounts = {for (final ch in changes)
      if (ch.entityType == 'account') ch.entitySyncId};
    final changedLedgers = {for (final ch in changes)
      if (ch.entityType == 'ledger') ch.entitySyncId};
    for (final entry in after.refunds.entries) {
      final key = entry.key;
      final credits = entry.value;
      final relatedSources = [...?before.originals[key], ...?after.originals[key]];
      final metadataChanged = relatedSources.any((tx) =>
        changedLedgers.contains(before.ledgers[tx.ledgerId]?.syncId) ||
        changedLedgers.contains(after.ledgers[tx.ledgerId]?.syncId) ||
        changedAccounts.contains(tx.accountSyncIdOverride) ||
        changedAccounts.contains(before.accounts[tx.accountId]?.syncId) ||
        changedAccounts.contains(after.accounts[tx.accountId]?.syncId));
      if (!metadataChanged && !changed.contains(key.$2) &&
          !credits.any((tx) => changed.contains(tx.syncId)) &&
          !(before.refunds[key] ?? <Transaction>[]).any((tx) => changed.contains(tx.syncId))) continue;
      final sources = after.originals[key] ?? <Transaction>[];
      if (sources.length != 1 || sources.single.type != 'expense') {
        throw const _RefundSyncConflict('original_missing_or_invalid');
      }
      final source = sources.single;
      final currency = after.currency(source);
      if (!after.ledgers.containsKey(source.ledgerId) || source.toAccountId != null ||
          source.toAccountSyncIdOverride != null || !RegExp(r'^[A-Z]{3}$').hasMatch(currency) ||
          (source.nativeAmount != null && (!source.nativeAmount!.isFinite || source.nativeAmount! <= 0))) {
        throw const _RefundSyncConflict('currency');
      }
      final shared = source.accountSyncIdOverride == null ? null :
          after.sharedAccounts[(after.ledgers[source.ledgerId]?.syncId ?? '', source.accountSyncIdOverride!)];
      final account = source.accountSyncIdOverride == null ? after.accounts[source.accountId] : null;
      final accountCurrency = shared?.currency ?? account?.currency;
      final accountType = shared?.accountType ?? account?.type;
      if (accountCurrency == null || accountCurrency.toUpperCase() != currency ||
          accountType == null || !isTradableType(accountType)) {
        throw const _RefundSyncConflict('account');
      }
      final previousSources = before.originals[key] ?? <Transaction>[];
      if (previousSources.length == 1 &&
          !_sameRefundMoney(previousSources.single, source, before, after)) {
        throw const _RefundSyncConflict('original_locked');
      }
      final previousCredits = {for (final tx in before.refunds[key] ?? <Transaction>[]) tx.syncId: tx};
      final sourceMinor = _refundMinor(source.amount, currency);
      var total = 0;
      final seen = <String>{};
      for (final credit in credits) {
        if (!seen.add(credit.syncId!) || credit.type != 'income' ||
            !credit.excludeFromStats || !credit.excludeFromBudget ||
            credit.accountId != source.accountId || credit.accountSyncIdOverride != source.accountSyncIdOverride ||
            credit.toAccountId != null || credit.toAccountSyncIdOverride != null ||
            credit.happenedAt != source.happenedAt || after.currency(credit) != currency) {
          throw const _RefundSyncConflict('credit_mismatch');
        }
        final previous = previousCredits[credit.syncId];
        if (previous != null && !_sameRefundMoney(previous, credit, before, after)) {
          throw const _RefundSyncConflict('credit_locked');
        }
        total += _refundMinor(credit.amount, currency);
        final expectedNative = source.nativeAmount == null ? null : source.nativeAmount! / source.amount * credit.amount;
        if (expectedNative == null ? credit.nativeAmount != null :
            credit.nativeAmount == null || !credit.nativeAmount!.isFinite ||
            (credit.nativeAmount! - expectedNative).abs() > 0.00000001 * (1 + expectedNative.abs())) {
          throw const _RefundSyncConflict('native_amount');
        }
      }
      if (total > sourceMinor) throw const _RefundSyncConflict('exceeds');
    }
  }
}
