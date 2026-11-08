import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';

import '../../l10n/app_localizations.dart';
import '../../providers.dart';
import '../../data/repositories/local/local_repository.dart';
import '../../services/data/refund_service.dart';
import '../../services/data/tx_author_service.dart';
import '../../services/billing/post_processor.dart';
import '../../styles/tokens.dart';
import '../../utils/currencies.dart';

class RefundPage extends ConsumerStatefulWidget {
  final int transactionId;
  const RefundPage({super.key, required this.transactionId});
  @override
  ConsumerState<RefundPage> createState() => _RefundPageState();
}

class _RefundPageState extends ConsumerState<RefundPage> {
  final _amount = TextEditingController();
  final String _requestId = const Uuid().v4();
  RefundInfo? _info;
  bool _custom = false;
  bool _busy = false;
  bool _failed = false;
  bool _saved = false;
  String? _error;

  AppLocalizations get l10n => AppLocalizations.of(context);
  @override
  void initState() { super.initState(); _load(); }
  @override
  void dispose() { _amount.dispose(); super.dispose(); }

  Future<void> _load() async {
    final repo = ref.read(repositoryProvider);
    if (repo is! LocalRepository) { setState(() => _failed = true); return; }
    try {
      final info = await RefundService(repo).load(widget.transactionId);
      if (!mounted) return;
      setState(() {
        _info = info; _failed = false;
        _amount.text = info.value(info.remainingMinor).toStringAsFixed(info.digits);
      });
    } catch (_) { if (mounted) setState(() => _failed = true); }
  }

  String _money(RefundInfo info, int minor) => NumberFormat.currency(
    name: info.currency, symbol: getCurrencySymbol(info.currency),
    decimalDigits: info.digits).format(info.value(minor));

  Future<void> _save() async {
    final info = _info;
    if (info == null || _busy || _saved || info.remainingMinor <= 0) return;
    final repo = ref.read(repositoryProvider);
    if (repo is! LocalRepository) return;
    final container = ProviderScope.containerOf(context, listen: false);
    setState(() { _busy = true; _error = null; });
    var committed = false;
    try {
      final tx = await RefundService(repo).save(originalId: info.original.id,
        requestId: _requestId, customAmount: _custom ? _amount.text.trim() : null,
        expectedRemainingMinor: info.remainingMinor, expectedCurrency: info.currency, expected: info.original);
      committed = true;
      _saved = true;
      // Commit finished. Sync, widget or navigation errors must not invite a
      // second credit. A request UUID also makes an explicit retry idempotent.
      await PostProcessor.afterCommit(() async {
        await TxAuthorService.markCreatedC(container, tx.id);
      });
      await PostProcessor.afterCommit(() async {
        container.invalidate(countsForLedgerProvider(tx.ledgerId));
        await PostProcessor.runC(container, ledgerId: tx.ledgerId);
      });
      if (mounted) {
        PostProcessor.afterCommit(() => updateAppWidget(ref, context));
        setState(() => _busy = false);
        await WidgetsBinding.instance.endOfFrame;
        if (mounted) Navigator.of(context).pop(true);
      }
    } on RefundFailure catch (failure) {
      if (mounted) setState(() { _busy = false;
        _error = failure.code == 'exceeds' ? l10n.refundExceeds
            : failure.code == 'stale' ? l10n.refundStale
            : failure.code == 'account' ? l10n.refundAccountMissing : l10n.refundSaveFailed;
      });
    } catch (_) {
      if (mounted) {
        setState(() { _busy = false; _error = committed ? l10n.commonSuccess : l10n.refundSaveFailed; });
        if (committed) {
          await WidgetsBinding.instance.endOfFrame;
          if (mounted) Navigator.of(context).pop(true);
        }
      }
    }
  }

  Widget _card(List<Widget> rows) => Material(color: BeeTokens.surface(context),
    borderRadius: BorderRadius.circular(22), clipBehavior: Clip.antiAlias,
    child: Column(children: [for (var i = 0; i < rows.length; i++) ...[
      if (i > 0) const Divider(height: 1, indent: 18, endIndent: 18), rows[i]]]));

  @override
  Widget build(BuildContext context) {
    final info = _info;
    return PopScope(canPop: !_busy, child: Scaffold(
      backgroundColor: BeeTokens.scaffoldBackground(context),
      appBar: AppBar(centerTitle: true, title: Text(l10n.refundAmount),
        leadingWidth: 86,
        leading: TextButton(onPressed: _busy ? null : () => Navigator.pop(context),
          child: Text(l10n.commonCancel)),
        actions: [TextButton(key: const Key('refund-save'),
          onPressed: _busy || _saved || info == null || info.remainingMinor <= 0 || info.accountName == null ? null : _save,
          child: Text(l10n.commonSave))]),
      body: _failed ? Center(child: TextButton(onPressed: _load, child: Text(l10n.refundSaveFailed)))
        : info == null ? const Center(child: CircularProgressIndicator())
        : AbsorbPointer(absorbing: _busy, child: ListView(
          padding: EdgeInsets.fromLTRB(16, 24, 16, 24 + MediaQuery.viewInsetsOf(context).bottom),
          children: [
            Padding(padding: const EdgeInsets.fromLTRB(16, 0, 0, 10),
              child: Text(l10n.refundAmount, style: TextStyle(color: BeeTokens.textSecondary(context)))),
            _card([
              Padding(padding: const EdgeInsets.all(18), child: Row(children: [
                Expanded(child: Text(l10n.refundAmount)), const SizedBox(width: 12),
                Flexible(child: Text(_money(info, info.remainingMinor),
                  key: const Key('refund-full-amount'), textAlign: TextAlign.end)),
              ])),
              SwitchListTile(key: const Key('refund-custom-switch'),
                title: Text(l10n.refundDifferentAmount), value: _custom,
                onChanged: (value) => setState(() { _custom = value; _error = null;
                  if (!value) _amount.text = info.value(info.remainingMinor).toStringAsFixed(info.digits); })),
              if (_custom) Padding(padding: const EdgeInsets.all(18),
                child: TextField(key: const Key('refund-amount-input'), controller: _amount,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(labelText: l10n.refundActualAmount,
                    prefixText: '${getCurrencySymbol(info.currency)} ', helperText: info.currency),
                  onChanged: (_) { if (_error != null) setState(() => _error = null); })),
            ]),
            Padding(padding: const EdgeInsets.fromLTRB(16, 10, 0, 24),
              child: Text('${l10n.refundMaximum} ${_money(info, info.remainingMinor)}',
                style: TextStyle(color: BeeTokens.textSecondary(context)))),
            Padding(padding: const EdgeInsets.fromLTRB(16, 0, 0, 10),
              child: Text(l10n.refundAccountAndDate, style: TextStyle(color: BeeTokens.textSecondary(context)))),
            _card([
              ListTile(title: Text(l10n.refundDate),
                subtitle: Text(DateFormat('yyyy-MM-dd HH:mm:ss').format(info.original.happenedAt))),
              ListTile(title: Text(l10n.refundAccount),
                subtitle: Text(info.accountName ?? l10n.refundAccountMissing)),
            ]),
            Padding(padding: const EdgeInsets.all(16), child: Text(l10n.refundInherited,
              style: TextStyle(color: BeeTokens.textSecondary(context)))),
            if (info.refunds.isNotEmpty) ...[
              Text(l10n.refundHistory, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              _card([for (final row in info.refunds) ListTile(
                title: Text(_money(info, RefundService.minor(row.amount, info.currency))),
                subtitle: Text(DateFormat('yyyy-MM-dd HH:mm:ss').format(row.happenedAt)))])],
            if (_error != null) Padding(padding: const EdgeInsets.all(12),
              child: Text(_error!, key: const Key('refund-error'), style: TextStyle(color: Theme.of(context).colorScheme.error))),
            if (_busy) const LinearProgressIndicator(),
          ])),
    ));
  }
}
