import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../l10n/app_localizations.dart';
import '../../models/analytics_dashboard.dart';
import '../../providers.dart';
import '../../providers/analytics_dashboard_provider.dart';
import '../../services/export/share_poster_service.dart';
import '../../styles/tokens.dart';
import '../../utils/month_range.dart';
import '../../widgets/analytics/analytics_dashboard_content.dart';
import '../../widgets/ui/ui.dart';

class AnalyticsPage extends ConsumerStatefulWidget {
  const AnalyticsPage({super.key});
  @override
  ConsumerState<AnalyticsPage> createState() => _AnalyticsPageState();
}
class _AnalyticsPageState extends ConsumerState<AnalyticsPage> {
  AnalyticsScope _scope = AnalyticsScope.month;
  DateTime? _anchor;
  bool _sharing = false;
  DateTime _initialAnchor(DateTime now, int startDay) {
    final selected = ref.read(selectedMonthProvider);
    final label = labelForDate(now, startDay);
    if (selected.year == label.year && selected.month == label.month) return calendarDay(now);
    return periodForLabel(selected.year, selected.month, startDay).start;
  }
  String _rangeLabel(AnalyticsPeriod period) {
    final last = DateTime(period.fullEnd.year, period.fullEnd.month, period.fullEnd.day - 1);
    return '${DateFormat.yMd().format(period.start)} – ${DateFormat.yMd().format(last)}';
  }
  DateTime _shift(DateTime anchor, int delta, int sd) {
    switch (_scope) {
      case AnalyticsScope.week: return DateTime(anchor.year, anchor.month, anchor.day + delta * 7);
      case AnalyticsScope.month:
        final label = labelForDate(anchor, sd);
        return periodForLabel(label.year, label.month + delta, sd).start;
      case AnalyticsScope.year:
        final year = labelForDate(anchor, sd).year;
        return yearRangeFor(year + delta, sd).start;
      case AnalyticsScope.all: return anchor;
    }
  }
  Future<void> _pick(DateTime anchor, int sd) async {
    if (_scope == AnalyticsScope.all) return;
    final now = DateTime.now();
    DateTime? result;
    if (_scope == AnalyticsScope.week) {
      result = await showDatePicker(context: context,
        initialDate: anchor.isAfter(now) ? now : anchor,
        firstDate: DateTime(1900), lastDate: now);
    } else {
      final label = labelForDate(anchor, sd);
      final current = labelForDate(now, sd);
      final picked = await showWheelDatePicker(context,
        initial: label, mode: _scope == AnalyticsScope.year ? WheelDatePickerMode.y : WheelDatePickerMode.ym,
        maxDate: DateTime(current.year, current.month, 1));
      if (picked != null) result = _scope == AnalyticsScope.year
          ? yearRangeFor(picked.year, sd).start : periodForLabel(picked.year, picked.month, sd).start;
    }
    if (result != null && mounted) setState(() => _anchor = result);
  }
  Future<void> _share(DateTime anchor, int sd, int ledgerId) async {
    if (_sharing || _scope == AnalyticsScope.week) return;
    setState(() => _sharing = true);
    final label = labelForDate(anchor, sd);
    try {
      await SharePosterService.showDynamicPosterPreview(context, ref,
        type: _scope == AnalyticsScope.month ? 'month' : _scope == AnalyticsScope.year ? 'year' : 'ledger',
        ledgerId: ledgerId, year: label.year, month: _scope == AnalyticsScope.month ? label.month : null);
    } catch (_) { if (mounted) showToast(context, AppLocalizations.of(context).commonFailed); }
    finally { if (mounted) setState(() => _sharing = false); }
  }

  /// v30 补折算横幅(01 §六):currencyCode≠本位币 且 nativeAmount==amount 的
  /// 存量外币交易 >0 时出现;确认后按当前有效汇率重算(逐笔记 change,L13)。
  Widget _buildRecalcForeignBanner(BuildContext context) {
    final count =
        ref.watch(ledgerUnconvertedForeignTxCountProvider).valueOrNull ?? 0;
    if (count <= 0) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
      child: Material(
        color: BeeTokens.surface(context),
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              Icon(Icons.currency_exchange,
                  size: 16, color: ref.watch(primaryColorProvider)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l10n.recalcForeignTxBanner,
                  style: BeeTextTokens.label(context),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              TextButton(
                onPressed: () => _runRecalcForeignTx(count),
                child: Text(l10n.recalcForeignTxAction,
                    style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 折算脚注:账本存在外币交易(含已折算)时,提示统计数字已折本位币。
  Widget _buildConvertedFootnote(BuildContext context) {
    final count = ref.watch(ledgerForeignTxCountProvider).valueOrNull ?? 0;
    if (count <= 0) return const SizedBox.shrink();
    final base = ref.watch(currentLedgerCurrencyProvider);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          AppLocalizations.of(context).statsConvertedFootnote(base),
          style: TextStyle(
            fontSize: 11,
            color: BeeTokens.textTertiary(context),
          ),
        ),
      ),
    );
  }

  Future<void> _runRecalcForeignTx(int count) async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: Text(l10n.recalcForeignTxAction),
        content: Text(l10n.recalcSyncCountHint(count)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dctx, false),
            child: Text(AppLocalizations.of(dctx).commonCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dctx, true),
            child: Text(AppLocalizations.of(dctx).commonConfirm),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final repo = ref.read(repositoryProvider);
    final ledgerId = ref.read(currentLedgerIdProvider);
    // 补折算前先确保本位币汇率组是新鲜的(反馈17 同款根因:缺组则整体跳过);
    // extraQuotes 带上账本交易实际涉及的外币 —— 无对应账户的币种(CSV 导入/
    // 手选)不在 usedCurrencies 里,不带的话这些币种永远补不上(审查发现)。
    final foreign = await repo.getLedgerForeignCurrencies(ledgerId);
    await refreshExchangeRatesFromUi(ref, force: true, extraQuotes: foreign);
    final n = await repo.recomputeForeignTxForLedger(ledgerId);
    if (!mounted) return;
    showToast(context, l10n.recalcForeignTxDone(n));
    // bump 统计刷新:横幅重查消失 + 各统计图表按新折算重算
    ref.read(statsRefreshProvider.notifier).state++;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final now = DateTime.now(), today = calendarDay(DateTime.now());
    final ledgerId = ref.watch(currentLedgerIdProvider), sd = ref.watch(currentMonthStartDayProvider);
    final anchor = _anchor ?? _initialAnchor(now, sd);
    final query = (ledgerId: ledgerId, scope: _scope, anchor: anchor, startDay: sd, today: today);
    final result = ref.watch(analyticsDashboardProvider(query));
    final period = result.valueOrNull?.period ?? AnalyticsPeriod.resolve(query);
    final next = _shift(anchor, 1, sd);
    final nextPeriod = AnalyticsPeriod.resolve((ledgerId: ledgerId, scope: _scope,
      anchor: next, startDay: sd, today: today));
    final canNext = _scope != AnalyticsScope.all && !nextPeriod.start.isAfter(today);
    return Scaffold(backgroundColor: BeeTokens.scaffoldBackground(context), body: Column(children: [
      PrimaryHeader(title: l10n.tabInsights, compact: true,
        actions: [IconButton(icon: const Icon(Icons.share),
          onPressed: _sharing || _scope == AnalyticsScope.week || ledgerId == 0 ? null : () => _share(anchor, sd, ledgerId))],
        bottom: Padding(padding: const EdgeInsets.fromLTRB(12, 0, 12, 12), child: CapsuleSwitcher<AnalyticsScope>(
          selectedValue: _scope, options: [
            CapsuleOption(value: AnalyticsScope.week, label: l10n.insightsWeek),
            CapsuleOption(value: AnalyticsScope.month, label: l10n.analyticsMonth),
            CapsuleOption(value: AnalyticsScope.year, label: l10n.analyticsYear),
            CapsuleOption(value: AnalyticsScope.all, label: l10n.analyticsAll),
          ], onChanged: (value) => setState(() { _anchor = anchor; _scope = value; })))),
      Row(children: [
        IconButton(key: const Key('analytics-period-previous'), icon: const Icon(Icons.arrow_circle_left),
          onPressed: _scope == AnalyticsScope.all || period.start.year <= 1900 ? null : () => setState(() => _anchor = _shift(anchor, -1, sd))),
        Expanded(child: TextButton(key: const Key('analytics-period-range'),
          onPressed: _scope == AnalyticsScope.all ? null : () => _pick(anchor, sd), child: Text(_rangeLabel(period), textAlign: TextAlign.center))),
        IconButton(key: const Key('analytics-period-next'), icon: const Icon(Icons.arrow_circle_right),
          onPressed: canNext ? () => setState(() => _anchor = next) : null),
      ]),
      _buildRecalcForeignBanner(context), _buildConvertedFootnote(context),
      Expanded(child: result.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, __) => Center(child: TextButton(onPressed: () => ref.invalidate(analyticsDashboardProvider(query)), child: Text(l10n.commonFailed))),
        data: (data) => RefreshIndicator(onRefresh: () async {
          ref.read(statsRefreshProvider.notifier).state++;
          ref.invalidate(analyticsDashboardProvider(query));
          await ref.read(analyticsDashboardProvider(query).future);
        }, child: SingleChildScrollView(key: ValueKey(query), physics: const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsets.fromLTRB(12, 4, 12, 100 + MediaQuery.paddingOf(context).bottom),
          child: AnalyticsDashboardContent(data: data))),
      )),
    ]));
  }
}
