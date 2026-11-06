import 'package:drift/drift.dart' as d;
import 'package:intl/intl.dart';
import '../../utils/account_type_utils.dart';
import '../../data/db.dart';
import '../../data/repositories/base_repository.dart';
import '../../data/repositories/local/local_repository.dart';
import '../../utils/shared_ledger_picker_filter.dart';
import '../currency/rate_math.dart';

/// Single-field edits always merge into the latest row, preserving unrelated
/// category/account overrides, transfer endpoints, flags and currency snapshots.
class TransactionDetailService {
  static bool canEdit(Ledger ledger) => !ledger.isShared || const {'owner', 'editor'}.contains(ledger.myRole);

  static Future<void> update(BaseRepository repo, int id, Map<String, dynamic> patch) async {
    Future<void> write() async {
      final tx = await repo.getTransactionById(id);
      if (tx == null) throw StateError('not_found');
      final ledger = await repo.getLedgerById(tx.ledgerId);
      if (ledger == null || !canEdit(ledger)) throw StateError('read_only');
      if (patch.containsKey('ledgerId')) {
        final target = await repo.getLedgerById(patch['ledgerId'] as int);
        if (target == null || !canEdit(target)) throw StateError('read_only');
        // Moving owner/editor resources across shared ledgers requires a separate
        // reference remap workflow. Never carry incompatible overrides silently.
        if (target.id != ledger.id && (target.isShared || ledger.isShared)) throw StateError('shared_move');
        if (target.id != ledger.id) {
          final currency = tx.currencyCode ?? ledger.currency;
          final native = await _native(repo, tx.amount, currency, target.currency);
          await repo.updateTransactionLedger(id: id, ledgerId: target.id);
          await repo.updateTransaction(id: id, type: tx.type, amount: tx.amount,
            categoryId: tx.categoryId, note: tx.note,
            categorySyncIdOverride: tx.categorySyncIdOverride,
            accountSyncIdOverride: tx.accountSyncIdOverride, toAccountSyncIdOverride: tx.toAccountSyncIdOverride,
            currencyCode: currency, nativeAmount: native);
        }
        return;
      }
      final category = patch['category'] as Category?;
      final hasCategory = patch.containsKey('category');
      final account = patch['account'] as Account?;
      final hasAccount = patch.containsKey('account');
      final toAccount = patch['toAccount'] as Account?;
      final hasToAccount = patch.containsKey('toAccount');
      final storedCurrency = tx.currencyCode ?? ((tx.accountSyncIdOverride != null || tx.accountId != null) ? await repo.getAccountCurrencyByAnyId(tx.accountSyncIdOverride != null ? syntheticIdForSyncId(tx.accountSyncIdOverride!) : tx.accountId!) : null) ?? ledger.currency;
      final currency = (patch['currency'] as String? ?? storedCurrency).toUpperCase();
      if (!RegExp(r'^[A-Z]{3}$').hasMatch(currency)) throw StateError('currency');
      final amount = patch['amount'] as double? ?? tx.amount;
      if (!amount.isFinite || amount <= 0) throw StateError('amount');
      final digits = NumberFormat.simpleCurrency(name: currency).decimalDigits ?? 2;
      if (patch.containsKey('amount') && (amount - double.parse(amount.toStringAsFixed(digits))).abs() > 0.00000001) throw StateError('amount');
      if (hasCategory && category != null && category.kind != tx.type) throw StateError('category');
      if (patch['excludeFromBudget'] == true && tx.type != 'expense') throw StateError('flags');
      if (patch['excludeFromStats'] == true && tx.type == 'transfer') throw StateError('flags');
      if ((account != null && !isTradableType(account.type)) || (toAccount != null && !isTradableType(toAccount.type))) throw StateError('account');
      if (repo is LocalRepository) {
        final scope = await repo.db.loadLedgerPickerContext(tx.ledgerId);
        if (hasCategory && category != null) {
          final available = await repo.db.filterCategoriesForLedger(await repo.getAllCategories(), scope, kind: tx.type, topLevelOnly: false);
          if (!available.any((c) => c.id == category.id && c.syncId == category.syncId)) throw StateError('category');
        }
        for (final selected in [if (hasAccount && account != null) account, if (hasToAccount && toAccount != null) toAccount]) {
          var available = await repo.db.filterAccountsForLedger(await repo.getAllAccounts(), scope);
          final pinned = await repo.getAccount(selected.id);
          if (pinned != null && (pinned.id == tx.accountId || pinned.id == tx.toAccountId)) available = [...available, pinned];
          if (!available.any((a) => a.id == selected.id && a.syncId == selected.syncId)) throw StateError('account');
        }
        if (patch.containsKey('tags')) {
          final available = await repo.db.filterTagsForLedger(await repo.getAllTags(), scope);
          if ((patch['tags'] as List<Tag>).any((tag) => !available.any((t) => t.id == tag.id && t.syncId == tag.syncId))) throw StateError('tags');
        }
      }
      if ((hasAccount && account != null && account.currency.toUpperCase() != currency) ||
          (hasToAccount && toAccount != null && toAccount.currency.toUpperCase() != currency)) throw StateError('currency');
      final accountId = hasAccount ? account?.id : (tx.accountSyncIdOverride != null ? syntheticIdForSyncId(tx.accountSyncIdOverride!) : tx.accountId);
      final toAccountId = hasToAccount ? toAccount?.id : (tx.toAccountSyncIdOverride != null ? syntheticIdForSyncId(tx.toAccountSyncIdOverride!) : tx.toAccountId);
      if (tx.type == 'transfer' && (accountId == null || toAccountId == null || accountId == toAccountId)) throw StateError('accounts');
      final currencyChanged = currency != storedCurrency.toUpperCase();
      // Changing a transfer's denomination without remapping both accounts is unsafe.
      if (currencyChanged && tx.type == 'transfer') throw StateError('currency');
      double? native;
      if (currencyChanged) {
        native = await _native(repo, amount, currency, ledger.currency);
      } else if (patch.containsKey('amount')) {
        native = tx.nativeAmount == null || tx.amount <= 0 ? await _native(repo, amount, currency, ledger.currency) : tx.nativeAmount! / tx.amount * amount;
      }
      await repo.updateTransaction(id: id, type: tx.type, amount: amount,
        categoryId: hasCategory ? (category != null && category.id >= 0 ? category.id : null) : tx.categoryId,
        categorySyncIdOverride: hasCategory ? (category != null && category.id < 0 ? category.syncId : null) : tx.categorySyncIdOverride,
        note: patch.containsKey('note') ? patch['note'] as String : tx.note,
        happenedAt: patch['date'] as DateTime?,
        accountId: hasAccount || currencyChanged ? d.Value<int?>(currencyChanged || accountId == null || accountId < 0 ? null : accountId) : null,
        accountSyncIdOverride: currencyChanged ? null : hasAccount ? (account != null && account.id < 0 ? account.syncId : null) : tx.accountSyncIdOverride,
        toAccountSyncIdOverride: hasToAccount ? (toAccount != null && toAccount.id < 0 ? toAccount.syncId : null) : tx.toAccountSyncIdOverride,
        excludeFromStats: patch['excludeFromStats'] as bool?,
        excludeFromBudget: patch['excludeFromBudget'] as bool?,
        currencyCode: currency, nativeAmount: native ?? tx.nativeAmount);
      if (hasToAccount) {
        await repo.updateTransactionFields(id: id,
          toAccountId: d.Value<int?>(toAccount != null && toAccount.id >= 0 ? toAccount.id : null),
          toAccountSyncIdOverride: toAccount != null && toAccount.id < 0 ? toAccount.syncId : null,
          writeToAccountSyncIdOverride: true);
      }
      if (patch.containsKey('tags')) {
        final tags = patch['tags'] as List<Tag>;
        await repo.updateTransactionTags(transactionId: id, tagIds: tags.where((t) => t.id >= 0).map((t) => t.id).toList());
        if (repo is LocalRepository && tx.syncId != null) {
          await (repo.db.delete(repo.db.transactionTagOverrides)..where((r) => r.transactionSyncId.equals(tx.syncId!))).go();
          for (final tag in tags.where((t) => t.id < 0 && t.syncId != null)) {
            await repo.db.into(repo.db.transactionTagOverrides).insert(TransactionTagOverridesCompanion.insert(
              transactionSyncId: tx.syncId!, tagSyncId: tag.syncId!, createdAt: DateTime.now().toUtc()));
          }
        }
      }
    }
    if (repo is LocalRepository) { await repo.db.transaction(write); }
    else { await write(); }
  }

  static Future<double> _native(BaseRepository repo, double amount, String currency, String base) async {
    if (currency.toUpperCase() == base.toUpperCase()) return amount;
    final autos = await repo.getLatestAutoRates(base);
    final overrides = await repo.getOverrides(base);
    final rates = mergeEffectiveRates(
      autoRates: [for (final r in autos) (quote: r.quoteCurrency, rate: r.rate, rateDate: r.rateDate)],
      overrides: [for (final r in overrides) (quote: r.quoteCurrency, rate: r.rate)]);
    final result = computeNativeAmount(amount: amount, accountCurrency: currency, ledgerBase: base, rates: rates);
    if (result == null || !result.isFinite) throw StateError('rate');
    return result;
  }
}
