import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../data/db.dart';
import '../../data/repositories/local/local_repository.dart';
import '../../l10n/app_localizations.dart';
import '../../providers.dart';
import '../../providers/budget_providers.dart';
import '../../services/attachment_service.dart';
import '../../services/billing/post_processor.dart';
import '../../services/data/transaction_detail_service.dart';
import '../../services/data/tx_author_service.dart';
import '../../styles/tokens.dart';
import '../../utils/currencies.dart';
import '../../utils/account_type_utils.dart';
import '../../utils/transaction_edit_utils.dart';
import '../../utils/shared_ledger_picker_filter.dart';
import '../../widgets/currency/currency_picker_sheet.dart';
import '../../widgets/ui/ui.dart';
import '../attachment/attachment_preview_page.dart';

/// Saved transaction: inspect first, edit only the field that was tapped.
class TransactionDetailPage extends ConsumerStatefulWidget {
  final int transactionId;
  const TransactionDetailPage({super.key, required this.transactionId});
  @override
  ConsumerState<TransactionDetailPage> createState() => _TransactionDetailPageState();
}

class _DetailData {
  final Transaction tx;
  final Ledger ledger;
  final List<Category> categories;
  final List<Account> accounts;
  final List<Tag> tags;
  final List<Tag> selectedTags;
  final List<TransactionAttachment> attachments;
  const _DetailData(this.tx, this.ledger, this.categories, this.accounts, this.tags, this.selectedTags, this.attachments);
}

class _TransactionDetailPageState extends ConsumerState<TransactionDetailPage> {
  _DetailData? _data;
  bool _loading = true;
  bool _busy = false;
  bool _failed = false;
  AppLocalizations get l10n => AppLocalizations.of(context);
  bool get _editable => _data != null && TransactionDetailService.canEdit(_data!.ledger) && !_busy;

  @override
  void initState() { super.initState(); _reload(); }

  Future<void> _reload() async {
    try {
      final repo = ref.read(repositoryProvider);
      final tx = await repo.getTransactionById(widget.transactionId);
      final ledger = tx == null ? null : await repo.getLedgerById(tx.ledgerId);
      if (tx == null || ledger == null) {
        if (mounted) setState(() { _data = null; _loading = false; });
        return;
      }
      var categories = await repo.getAllCategories();
      var accounts = await repo.getAllAccounts();
      var tags = await repo.getAllTags();
      var selectedTags = await repo.getTagsForTransaction(tx.id);
      if (repo is LocalRepository) {
        final scope = await repo.db.loadLedgerPickerContext(tx.ledgerId);
        categories = await repo.db.filterCategoriesForLedger(categories, scope, topLevelOnly: false);
        // Keep pinned hidden accounts visible in details; do not offer others.
        final all = accounts;
        accounts = await repo.db.filterAccountsForLedger(accounts, scope);
        for (final account in all.where((a) => a.id == tx.accountId || a.id == tx.toAccountId)) {
          if (!accounts.any((a) => a.id == account.id)) accounts = [...accounts, account];
        }
        tags = await repo.db.filterTagsForLedger(tags, scope);

      }
      selectedTags = TransactionDetailService.uniqueTags(selectedTags);
      final attachments = await repo.getAttachmentsByTransaction(tx.id);
      if (mounted) setState(() { _data = _DetailData(tx, ledger, categories, accounts, tags, selectedTags, attachments); _loading = false; _failed = false; });
    } catch (_) {
      if (mounted) setState(() { _loading = false; _failed = true; });
    }
  }

  String _label(String value) => value.replaceFirst(RegExp(r'^[^\p{L}\p{N}]+', unicode: true), '');
  String get _currency {
    if (_data!.tx.currencyCode != null) return _data!.tx.currencyCode!;
    final match = _data!.accounts.where((a) => a.id == _accountId(false));
    return match.isNotEmpty ? match.first.currency : _data!.ledger.currency;
  }
  int? _accountId(bool destination) {
    final tx = _data!.tx;
    final override = destination ? tx.toAccountSyncIdOverride : tx.accountSyncIdOverride;
    return override != null ? syntheticIdForSyncId(override) : destination ? tx.toAccountId : tx.accountId;
  }
  String _accountName(bool destination) {
    final id = _accountId(destination);
    final matches = _data!.accounts.where((a) => a.id == id);
    if (matches.isEmpty) return l10n.commonEmpty;
    final a = matches.first;
    return a.bankName?.isNotEmpty == true ? '${a.name} (${a.bankName})' : a.name;
  }
  String get _categoryName {
    final tx = _data!.tx;
    final id = tx.categorySyncIdOverride != null ? syntheticIdForSyncId(tx.categorySyncIdOverride!) : tx.categoryId;
    final matches = _data!.categories.where((c) => c.id == id);
    if (matches.isEmpty) return l10n.commonEmpty;
    final c = matches.first;
    final parent = _data!.categories.where((p) => p.id == c.parentId);
    return parent.isEmpty ? c.name : '${parent.first.name} / ${c.name}';
  }

  Future<void> _save(Map<String, dynamic> patch) async {
    if (!_editable) return;
    final oldLedger = _data!.tx.ledgerId;
    setState(() => _busy = true);
    try {
      await TransactionDetailService.update(ref.read(repositoryProvider), widget.transactionId, patch);
      if (!mounted) return;
      await TxAuthorService.markEdited(ref, widget.transactionId);
      if (!mounted) return;
      _refresh(oldLedger, patch['ledgerId'] as int?);
      await _reload();
    } catch (_) {
      if (mounted) showToast(context, l10n.transactionDetailSaveFailed);
    } finally { if (mounted) setState(() => _busy = false); }
  }

  void _refresh(int ledger, [int? target]) {
    ref.invalidate(countsForLedgerProvider(ledger));
    if (target != null) ref.invalidate(countsForLedgerProvider(target));
    ref.read(statsRefreshProvider.notifier).state++;
    ref.read(budgetRefreshProvider.notifier).state++;
    ref.read(tagListRefreshProvider.notifier).state++;
    ref.read(attachmentListRefreshProvider.notifier).state++;
    PostProcessor.sync(ref, ledgerId: target ?? ledger);
    updateAppWidget(ref, context);
  }

  Future<String?> _input(String title, String initial, {bool number = false}) async {
    final controller = TextEditingController(text: initial);
    String? error;
    final result = await showDialog<String>(context: context, builder: (dialog) => StatefulBuilder(builder: (ctx, setDialog) => AlertDialog(
      title: Text(title),
      content: TextField(key: const Key('detail-field-input'), controller: controller, autofocus: true,
        minLines: number ? 1 : 2, maxLines: number ? 1 : 6,
        keyboardType: number ? const TextInputType.numberWithOptions(decimal: true) : TextInputType.multiline,
        decoration: InputDecoration(errorText: error)),
      actions: [TextButton(onPressed: () => Navigator.pop(dialog), child: Text(l10n.commonCancel)),
        TextButton(onPressed: () {
          if (number) {
            final text = controller.text.trim();
            final amount = double.tryParse(text);
            final digits = NumberFormat.simpleCurrency(name: _currency).decimalDigits ?? 2;
            if (!RegExp(r'^\d+(?:\.\d{1,4})?$').hasMatch(text) || amount == null || !amount.isFinite || amount <= 0 || (amount - double.parse(amount.toStringAsFixed(digits))).abs() > 0.00000001) {
              setDialog(() => error = l10n.creditCardAmountInvalid); return;
            }
          }
          Navigator.pop(dialog, controller.text);
        }, child: Text(l10n.commonSave))],
    )));
    // Dialog route finishes its closing animation before disposing the controller.
    await Future<void>.delayed(const Duration(milliseconds: 250));
    controller.dispose();
    return result;
  }

  Future<T?> _choose<T>(String title, List<({String label, T value})> options) => showModalBottomSheet<T>(
    context: context, isScrollControlled: true,
    backgroundColor: BeeTokens.surfaceSheet(context),
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
    builder: (sheet) => SafeArea(child: SizedBox(height: MediaQuery.of(sheet).size.height * 0.65,
      child: Column(children: [Padding(padding: const EdgeInsets.all(20), child: Text(title, style: Theme.of(sheet).textTheme.titleLarge)),
        Expanded(child: ListView(children: [for (final option in options) ListTile(title: Text(option.label), onTap: () => Navigator.pop(sheet, option.value))]))]))));

  Future<void> _editNote() async {
    final value = await _input(_label(l10n.billCardNote), _data!.tx.note ?? '');
    if (value != null && mounted) await _save({'note': value});
  }
  Future<void> _editAmount() async {
    final value = await _input(_label(l10n.billCardAmount), _data!.tx.amount.toString(), number: true);
    if (value != null && mounted) await _save({'amount': double.parse(value.trim())});
  }
  Future<void> _editDate() async {
    final old = _data!.tx.happenedAt;
    final date = await showDatePicker(context: context, initialDate: old, firstDate: DateTime(1900), lastDate: DateTime(2100));
    if (date == null || !mounted) return;
    final time = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(old));
    if (time != null && mounted) await _save({'date': DateTime(date.year, date.month, date.day, time.hour, time.minute, old.second)});
  }
  Future<void> _editCategory() async {
    if (_data!.tx.type == 'transfer') { await _editAll(); return; }
    final options = _data!.categories.where((c) => c.kind == _data!.tx.type).map((c) {
      final parent = _data!.categories.where((p) => p.id == c.parentId);
      return (label: parent.isEmpty ? c.name : '${parent.first.name} / ${c.name}', value: c);
    }).toList();
    final selected = await _choose<Category>(_label(l10n.billCardCategory), options);
    if (selected != null && mounted) await _save({'category': selected});
  }
  Future<void> _editAccount(bool destination) async {
    final other = _accountId(!destination);
    final selected = await _choose<int>(_label(l10n.billCardAccount), [
      if (_data!.tx.type != 'transfer') (label: l10n.commonEmpty, value: 0),
      for (final a in _data!.accounts.where((a) => a.currency.toUpperCase() == _currency.toUpperCase() &&
        (!a.hidden || a.id == _accountId(destination)) &&
        isTradableType(a.type) &&
        (_data!.tx.type != 'transfer' || a.id != other))) (label: a.name, value: a.id)]);
    if (selected == null || !mounted) return;
    final match = _data!.accounts.where((a) => a.id == selected);
    await _save({destination ? 'toAccount' : 'account': selected == 0 ? null : match.first});
  }
  Future<void> _editLedger() async {
    final all = await ref.read(repositoryProvider).getAllLedgers();
    if (!mounted) return;
    final selected = await _choose<int>(l10n.transactionReceiptLedger, [for (final l in all.where((l) =>
      TransactionDetailService.canEdit(l) && (l.id == _data!.ledger.id || (!l.isShared && !_data!.ledger.isShared)))) (label: l.name, value: l.id)]);
    if (selected != null && mounted) await _save({'ledgerId': selected});
  }
  Future<void> _editCurrency() async {
    if (_data!.tx.type == 'transfer') { await _editAll(); return; }
    final value = await showCurrencyPickerSheet(context, selected: _currency,
      primaryColor: Theme.of(context).colorScheme.primary, title: l10n.txCurrencyPickerTitle);
    if (value == null || value == _currency || !mounted) return;
    final confirmed = await AppDialog.confirm<bool>(context, title: l10n.txCurrencyLabel, message: l10n.transactionDetailCurrencyHint);
    if (confirmed == true && mounted) await _save({'currency': value});
  }
  Future<void> _editTags() async {
    final selected = _data!.selectedTags.map((t) => t.id).toSet();
    final result = await showModalBottomSheet<List<Tag>>(context: context, isScrollControlled: true,
      builder: (sheet) => StatefulBuilder(builder: (ctx, setSheet) => SafeArea(child: SizedBox(
        height: MediaQuery.of(sheet).size.height * 0.65,
        child: Column(children: [Padding(padding: const EdgeInsets.all(16), child: Row(children: [
          Expanded(child: Text(l10n.transactionReceiptTags, style: Theme.of(sheet).textTheme.titleLarge)),
          TextButton(onPressed: () => Navigator.pop(sheet, _data!.tags.where((t) => selected.contains(t.id)).toList()), child: Text(l10n.commonSave))])),
          Expanded(child: ListView(children: [for (final tag in _data!.tags) CheckboxListTile(title: Text(tag.name),
            value: selected.contains(tag.id), onChanged: (checked) => setSheet(() { if (checked == true) { selected.add(tag.id); } else { selected.remove(tag.id); } }))]))])))));
    if (result != null && mounted) await _save({'tags': result});
  }
  Future<void> _images() async {
    if (_data!.attachments.isEmpty && _editable) {
      final source = await _choose<String>(l10n.transactionDetailImages, [
        (label: l10n.attachmentTakePhoto, value: 'camera'), (label: l10n.attachmentChooseFromGallery, value: 'gallery')]);
      if (source == null || !mounted) return;
      final service = ref.read(attachmentServiceProvider);
      final List<File> files;
      if (source == 'camera') { final file = await service.takePhoto(); files = file == null ? [] : [file]; }
      else { files = await service.pickFromGallery(maxCount: 9); }
      if (files.isEmpty || !mounted) return;
      if (!_editable) return;
      setState(() => _busy = true);
      try {
        final repo = ref.read(repositoryProvider);
        final latest = await repo.getTransactionById(widget.transactionId);
        final ledger = latest == null ? null : await repo.getLedgerById(latest.ledgerId);
        if (ledger == null || !TransactionDetailService.canEdit(ledger)) throw StateError('read_only');
        final saved = await service.saveAttachments(transactionId: widget.transactionId, sourceFiles: files, startIndex: 0);
        if (mounted && saved.length != files.length) {
          showToast(context, saved.isEmpty ? l10n.transactionDetailImagesFailed : l10n.transactionDetailImagesPartial);
        }
        if (mounted) { _refresh(_data!.ledger.id); await _reload(); }
      } catch (_) { if (mounted) showToast(context, l10n.commonFailed); }
      finally { if (mounted) setState(() => _busy = false); }
    } else if (_data!.attachments.isNotEmpty) {
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => AttachmentPreviewPage.fromTransaction(
        transactionId: widget.transactionId, allowAdd: _editable, allowDelete: _editable)));
      if (mounted) { if (_editable) _refresh(_data!.ledger.id); await _reload(); }
    }
  }
  Future<void> _editAll() async {
    if (!_editable) return;
    await TransactionEditUtils.editTransaction(context, ref, _data!.tx, null);
    if (mounted) await _reload();
  }
  Future<void> _delete() async {
    final ok = await AppDialog.confirm<bool>(context, title: l10n.deleteConfirmTitle, message: l10n.deleteConfirmMessage);
    if (ok != true || !mounted || !_editable) return;
    setState(() => _busy = true);
    try {
      final latest = await ref.read(repositoryProvider).getTransactionById(widget.transactionId);
      final ledger = latest == null ? null : await ref.read(repositoryProvider).getLedgerById(latest.ledgerId);
      if (ledger == null || !TransactionDetailService.canEdit(ledger)) throw StateError('read_only');
      await ref.read(repositoryProvider).deleteTransaction(widget.transactionId);
      if (mounted) { _refresh(ledger.id); Navigator.pop(context); }
    } catch (_) { if (mounted) { setState(() => _busy = false); showToast(context, l10n.commonFailed); } }
  }

  Widget _card(List<Widget> children) => Padding(padding: const EdgeInsets.only(bottom: 18), child: Material(
    color: BeeTokens.surface(context), borderRadius: BorderRadius.circular(24), clipBehavior: Clip.antiAlias,
    child: Column(children: [for (var i = 0; i < children.length; i++) ...[
      if (i > 0) Padding(padding: const EdgeInsets.symmetric(horizontal: 20), child: Divider(height: 1, color: BeeTokens.divider(context))), children[i]]])));
  Widget _row(String key, String title, String value, VoidCallback? onTap) => InkWell(
    key: Key('detail-$key'), onTap: onTap,
    child: Padding(padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: TextStyle(fontSize: 16, color: BeeTokens.textPrimary(context))), const SizedBox(width: 22),
      Expanded(child: Text(value, textAlign: TextAlign.end, style: TextStyle(fontSize: 16, height: 1.45, color: BeeTokens.textSecondary(context)))),
      if (onTap != null) ...[const SizedBox(width: 8), Icon(Icons.chevron_right, size: 22, color: BeeTokens.textTertiary(context))]])));
  Widget _action(IconData icon, String title, Color color, VoidCallback? onTap) => Expanded(child: Material(
    color: BeeTokens.surface(context), borderRadius: BorderRadius.circular(22),
    child: InkWell(onTap: onTap, borderRadius: BorderRadius.circular(22), child: Padding(padding: const EdgeInsets.symmetric(vertical: 22),
      child: Column(children: [Icon(icon, color: onTap == null ? BeeTokens.textTertiary(context) : color, size: 30), const SizedBox(height: 10), Text(title, style: TextStyle(color: color, fontSize: 16))])))));

  @override
  Widget build(BuildContext context) {
    final data = _data;
    return Scaffold(backgroundColor: BeeTokens.scaffoldBackground(context),
      appBar: AppBar(title: Text(l10n.transactionDetailTitle), centerTitle: true, backgroundColor: BeeTokens.scaffoldBackground(context), elevation: 0),
      body: _loading ? const Center(child: CircularProgressIndicator()) : data == null || _failed
        ? Center(child: TextButton(onPressed: () { setState(() => _loading = true); _reload(); }, child: Text(_failed ? l10n.commonFailed : l10n.commonEmpty)))
        : AbsorbPointer(absorbing: _busy, child: ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 32), children: [
          Row(children: [_action(Icons.edit_outlined, l10n.commonEdit, Colors.blue, _editable ? _editAll : null), const SizedBox(width: 14),
            _action(Icons.delete_outline, l10n.commonDelete, Colors.red, _editable ? _delete : null)]), const SizedBox(height: 22),
          _card([
            _row('category', _label(l10n.billCardType), '${data.tx.type == 'income' ? l10n.categoryIncome : data.tx.type == 'transfer' ? l10n.transferTitle : l10n.categoryExpense}${data.tx.type == 'transfer' ? '' : ' · $_categoryName'}', _editable ? _editCategory : null),
            _row('ledger', l10n.transactionReceiptLedger, data.ledger.name, _editable ? _editLedger : null)]),
          _card([
            _row('time', _label(l10n.billCardTime), DateFormat('yyyy-MM-dd HH:mm:ss').format(data.tx.happenedAt), _editable ? _editDate : null),
            _row('amount', _label(l10n.billCardAmount), NumberFormat.currency(name: _currency, symbol: getCurrencySymbol(_currency)).format(data.tx.amount), _editable ? _editAmount : null),
            _row('currency', l10n.txCurrencyLabel, displayCurrency(_currency, context), _editable ? _editCurrency : null),
            _row('account', data.tx.type == 'transfer' ? l10n.exportCsvHeaderFromAccount : _label(l10n.billCardAccount), _accountName(false), _editable ? () => _editAccount(false) : null),
            if (data.tx.type == 'transfer') _row('destination', l10n.exportCsvHeaderToAccount, _accountName(true), _editable ? () => _editAccount(true) : null)]),
          _card([
            _row('note', _label(l10n.billCardNote), data.tx.note?.isNotEmpty == true ? data.tx.note! : l10n.commonEmpty, _editable ? _editNote : null),
            _row('tags', l10n.transactionReceiptTags, data.selectedTags.isEmpty ? l10n.commonEmpty : data.selectedTags.map((t) => '#${t.name}').join('  '), _editable ? _editTags : null),
            _row('images', l10n.transactionDetailImages, data.attachments.isEmpty ? l10n.commonEmpty : '${data.attachments.length}', !_busy && (_editable || data.attachments.isNotEmpty) ? _images : null)]),
          if (data.tx.type != 'transfer') _card([
            SwitchListTile(key: const Key('detail-stats'), title: Text(l10n.txFlagExcludeFromStats), value: data.tx.excludeFromStats,
              onChanged: _editable ? (v) => _save({'excludeFromStats': v}) : null),
            if (data.tx.type == 'expense') SwitchListTile(key: const Key('detail-budget'), title: Text(l10n.txFlagExcludeFromBudget), value: data.tx.excludeFromBudget,
              onChanged: _editable ? (v) => _save({'excludeFromBudget': v}) : null)]),
          if (_busy) const LinearProgressIndicator(),
        ])));
  }
}
