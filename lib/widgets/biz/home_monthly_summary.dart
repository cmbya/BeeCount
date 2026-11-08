import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../pages/budget/budget_page.dart';
import '../../providers.dart';
import '../../providers/budget_providers.dart';
import '../../providers/home_summary_providers.dart';
import '../../styles/tokens.dart';
import 'amount_text.dart';

/// The pager owns only the summary, never the transaction list below it.
class HomeMonthlySummary extends ConsumerWidget {
  const HomeMonthlySummary({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ledgerId = ref.watch(currentLedgerIdProvider);
    final month = ref.watch(selectedMonthProvider);
    final key = (ledgerId: ledgerId, month: DateTime(month.year, month.month));
    final state = ref.watch(homeMonthlySummaryProvider(key));
    final showBudget = ref.watch(homeBudgetCardEnabledProvider);
    final data = state.valueOrNull;
    return _SummaryPager(
      key: ValueKey(key),
      data: data,
      failed: state.hasError && data == null,
      showBudget: showBudget,
      retry: () => ref.invalidate(homeMonthlySummaryProvider(key)),
    );
  }
}

class _SummaryPager extends ConsumerStatefulWidget {
  final HomeMonthlySummaryData? data;
  final bool failed;
  final bool showBudget;
  final VoidCallback retry;
  const _SummaryPager({super.key, required this.data, required this.failed,
    required this.showBudget, required this.retry});

  @override
  ConsumerState<_SummaryPager> createState() => _SummaryPagerState();
}

class _SummaryPagerState extends ConsumerState<_SummaryPager> {
  final PageController _controller = PageController(keepPage: false);
  int _page = 0;

  @override
  void dispose() { _controller.dispose(); super.dispose(); }

  @override
  void didUpdateWidget(covariant _SummaryPager oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.showBudget && _page == 2) {
      _page = 0;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _controller.hasClients) _controller.jumpToPage(0);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final data = widget.data;
    final primary = ref.watch(primaryColorProvider);
    final hide = ref.watch(hideAmountsProvider);
    final titles = [l10n.sharePosterTotalExpense, l10n.sharePosterTotalIncome,
      if (widget.showBudget) l10n.homeRemainingBudget];
    final scale = MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 2.5);
    Widget money(double? value, {bool large = false, Key? key}) => FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: value == null ? Text('—', key: key,
        style: TextStyle(fontSize: large ? 34 : 14,
          color: BeeTokens.textSecondary(context)))
      : AmountText(key: key, value: value, hide: hide, signed: false,
          showCurrency: true, currencyCode: data?.currency,
          style: TextStyle(fontSize: large ? 34 : 14,
            fontWeight: large ? FontWeight.w700 : FontWeight.w500,
            color: large ? BeeTokens.textPrimary(context)
                : BeeTokens.textSecondary(context))),
    );
    Widget small(String title, double? value) => SizedBox(width: 164, child: Row(mainAxisSize: MainAxisSize.min,
      children: [Flexible(child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13,
          color: BeeTokens.textSecondary(context)))),
        const SizedBox(width: 6), Expanded(child: money(value))]));
    Widget slide(int index) {
      final amount = index == 0 ? data?.expense : index == 1
          ? data?.income : data?.budget?.remaining;
      return Padding(padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [Icon(index == 0 ? Icons.arrow_circle_up_outlined
              : index == 1 ? Icons.arrow_circle_down_outlined
                  : Icons.account_balance_wallet_outlined,
              color: primary, size: 20),
            const SizedBox(width: 6),
            Expanded(child: Text(titles[index], maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600,
                color: BeeTokens.textPrimary(context)))),
            if (index == 2) IconButton(key: const Key('home-budget-settings'),
              tooltip: l10n.budgetTitle, visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.chevron_right, size: 20),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const BudgetPage()))),
          ]),
          const SizedBox(height: 8),
          Expanded(child: Align(alignment: Alignment.centerLeft, child: widget.failed
            ? TextButton(onPressed: widget.retry, child: Text(l10n.homeSummaryUnavailable))
            : index == 2 && data != null && data.budget == null
              ? TextButton(onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const BudgetPage())),
                  child: Text(l10n.budgetEmptyHint))
              : money(amount, large: true, key: ValueKey('home-summary-amount-$index')))),
          const SizedBox(height: 8),
          Wrap(spacing: 20, runSpacing: 4, children: index == 2
            ? [small(l10n.budgetTypeTotalLabel, data?.budget?.budget),
                small(l10n.homeDailyRemaining, data?.dailyAvailable)]
            : [small(index == 0 ? l10n.sharePosterTotalIncome
                  : l10n.sharePosterTotalExpense,
                index == 0 ? data?.income : data?.expense),
                small(l10n.sharePosterMonthBalance, data?.balance)]),
        ]));
    }
    return Container(margin: const EdgeInsets.fromLTRB(12, 8, 12, 10),
      decoration: BoxDecoration(color: BeeTokens.surface(context),
        borderRadius: BorderRadius.circular(22)),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        SizedBox(height: 196 + (scale - 1) * 80,
          child: PageView.builder(key: const Key('home-summary-pager'),
            controller: _controller,
            // Finger moving right: expense -> income -> budget, as requested.
            reverse: true, allowImplicitScrolling: true,
            itemCount: titles.length,
            onPageChanged: (value) => setState(() => _page = value),
            itemBuilder: (_, index) => slide(index))),
        Row(mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(titles.length, (index) => Semantics(
            button: true, selected: _page == index, label: titles[index],
            child: InkWell(key: ValueKey('home-summary-dot-$index'),
              borderRadius: BorderRadius.circular(12),
              onTap: () { if (_controller.hasClients) _controller.animateToPage(index,
                duration: const Duration(milliseconds: 220), curve: Curves.easeOut); },
              child: Padding(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
                child: Container(width: 6, height: 6,
                  decoration: BoxDecoration(shape: BoxShape.circle,
                    color: _page == index ? primary : BeeTokens.surfaceDisabled(context)))))))),
      ]));
  }
}
