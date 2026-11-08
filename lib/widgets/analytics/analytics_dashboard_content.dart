import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../l10n/app_localizations.dart';
import '../../models/analytics_dashboard.dart';
import '../../pages/transaction/analytics_detail_page.dart';
import '../../providers.dart';
import '../../styles/tokens.dart';
import '../biz/amount_text.dart';
import '../charts/category_pie_chart.dart';
import '../charts/line_chart.dart';
import '../ui/ui.dart';
import 'analytics_period_chart.dart';

class AnalyticsDashboardContent extends ConsumerWidget {
  final AnalyticsDashboard data;
  const AnalyticsDashboardContent({super.key, required this.data});
  void _open(BuildContext context, AnalyticsMetric metric, String title,
      {DateTime? start, DateTime? end, Set<int?>? categoryIds}) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => AnalyticsDetailPage(
      query: data.query, metric: metric, title: title, start: start, end: end, categoryIds: categoryIds)));
  }
  Widget _card(BuildContext context, List<Widget> children) => Container(
    margin: const EdgeInsets.only(bottom: 16), padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(color: BeeTokens.surface(context), borderRadius: BorderRadius.circular(24)),
    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children));
  Widget _title(BuildContext context, String label) => Padding(padding: const EdgeInsets.only(bottom: 12),
    child: Text(label, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)));
  Widget _metric(BuildContext context, AnalyticsMetric metric, String label) => Material(
    color: BeeTokens.scaffoldBackground(context), borderRadius: BorderRadius.circular(16),
    child: InkWell(key: Key('analytics-metric-${metric.name}'), borderRadius: BorderRadius.circular(16),
      onTap: () => _open(context, metric, label), child: Padding(padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [Expanded(child: Text(label, style: TextStyle(color: BeeTokens.textSecondary(context)))),
            const Icon(Icons.chevron_right, size: 16)]), const SizedBox(height: 8),
          FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: AmountText(
            value: data.total(metric), currencyCode: data.ledger.currency, showCurrency: true,
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600))),
        ]))));
  Widget _pair(Widget left, Widget right) => Padding(padding: const EdgeInsets.only(bottom: 8),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Expanded(child: left), const SizedBox(width: 8), Expanded(child: right)]));
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    return Column(children: [
      _card(context, [
        _title(context, l10n.insightsSummary),
        _pair(_metric(context, AnalyticsMetric.expense, l10n.homeExpense), _metric(context, AnalyticsMetric.income, l10n.homeIncome)),
        _pair(_metric(context, AnalyticsMetric.balance, l10n.homeBalance), _metric(context, AnalyticsMetric.dailyExpense, l10n.insightsDailyExpense)),
        _pair(_metric(context, AnalyticsMetric.refund, l10n.refundTitle), _metric(context, AnalyticsMetric.refundIncome, l10n.insightsRefundIncome)),
        Text(l10n.insightsAverageHint, style: TextStyle(fontSize: 12, color: BeeTokens.textSecondary(context))),
        const SizedBox(height: 6), Text(l10n.insightsRefundHint, style: TextStyle(fontSize: 12, color: BeeTokens.textSecondary(context))),
      ]),
      _card(context, [
        _title(context, l10n.insightsTransferSummary),
        _metric(context, AnalyticsMetric.transfer, l10n.insightsTransferTotal),
      ]),
      _card(context, [AnalyticsPeriodChart(data: data, onDetail: (selection) => _open(context,
        selection.metric, l10n.insightsViewDetails, start: selection.bucket.start, end: selection.bucket.end))]),
      _card(context, [AnalyticsAssetTrend(period: data.period)]),
      _card(context, [AnalyticsCategorySection(key: ValueKey((data.query, 'expense')), data: data, type: 'expense')]),
      _card(context, [AnalyticsCategorySection(key: ValueKey((data.query, 'income')), data: data, type: 'income')]),
      _card(context, [_title(context, l10n.insightsBillSummary),
        for (final bucket in data.buckets) ListTile(contentPadding: EdgeInsets.zero,
          title: Text(DateFormat.yMd().format(bucket.start)),
          subtitle: Wrap(spacing: 12, runSpacing: 4, children: [
            _summaryAmount(l10n.homeExpense, bucket.expense),
            _summaryAmount(l10n.homeIncome, bucket.income),
            _summaryAmount(l10n.homeBalance, bucket.balance),
          ]), trailing: const Icon(Icons.chevron_right),
          onTap: () => _open(context, AnalyticsMetric.balance, l10n.insightsBillSummary,
            start: bucket.start, end: bucket.end)),
      ]),
    ]);
  }
  Widget _summaryAmount(String label, double value) => Row(mainAxisSize: MainAxisSize.min, children: [
    Text('$label '), AmountText(value: value, showCurrency: true, currencyCode: data.ledger.currency)]);
}

/// Asset scope is explicitly global, matching the existing asset card/trend.
/// This is not a fabricated ledger-only balance or a sum of different currencies.
class AnalyticsAssetTrend extends ConsumerStatefulWidget {
  final AnalyticsPeriod period;
  const AnalyticsAssetTrend({super.key, required this.period});
  @override
  ConsumerState<AnalyticsAssetTrend> createState() => _AnalyticsAssetTrendState();
}
class _AnalyticsAssetTrendState extends ConsumerState<AnalyticsAssetTrend> {
  String _line = 'net';
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context), period = widget.period;
    final hide = ref.watch(hideAmountsProvider), base = ref.watch(baseCurrencyProvider);
    final end = DateTime(period.end.year, period.end.month, period.end.day - 1);
    final series = ref.watch(netWorthTrendSeriesProvider((startDate: period.start, endDate: end)));
    final used = ref.watch(usedCurrenciesProvider).valueOrNull;
    final rates = ref.watch(effectiveRatesProvider).valueOrNull;
    final missing = used?.where((code) {
      if (code.toUpperCase() == base.toUpperCase()) return false;
      final rate = double.tryParse(rates?[code.toUpperCase()]?.rate ?? '');
      return rate == null || !rate.isFinite || rate <= 0;
    }).toList() ?? <String>[];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(l10n.netWorthTrendTitle, style: Theme.of(context).textTheme.titleMedium), const SizedBox(height: 12),
      CapsuleSwitcher<String>(selectedValue: _line, options: [
        CapsuleOption(value: 'net', label: l10n.netWorthTrendLineNet),
        CapsuleOption(value: 'assets', label: l10n.netWorthTrendLineAssets),
        CapsuleOption(value: 'liabilities', label: l10n.netWorthTrendLineLiabilities),
      ], onChanged: (value) => setState(() => _line = value)), const SizedBox(height: 12),
      series.when(loading: () => const SizedBox(height: 180, child: Center(child: CircularProgressIndicator())),
        error: (_, __) => TextButton(onPressed: () => ref.invalidate(netWorthTrendSeriesProvider((startDate: period.start, endDate: end))), child: Text(l10n.commonFailed)),
        data: (daily) {
          if (daily.isEmpty) return Center(child: Text(l10n.commonEmpty));
          // Keep the last point in each displayed chart bucket, including the final
          // selected date. Never let an all-years graph allocate one label per day.
          final sampled = <({DateTime date, double assets, double liabilities, double net})>[];
          final stride = (daily.length / 120).ceil();
          for (var i = 0; i < daily.length; i += stride) sampled.add(daily[i]);
          if (sampled.last.date != daily.last.date) sampled.add(daily.last);
          double value(({DateTime date, double assets, double liabilities, double net}) row) =>
            _line == 'assets' ? row.assets : _line == 'liabilities' ? row.liabilities.abs() : row.net;
          return Column(children: [
            AmountText(value: value(daily.last), currencyCode: base, showCurrency: true,
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600)), const SizedBox(height: 12),
            SizedBox(height: 200, child: LineChart(values: sampled.map(value).toList(),
              xLabels: sampled.map((row) => DateFormat.yMd().format(row.date)).toList(),
              highlightIndex: sampled.length - 1, onSwipeLeft: () {}, onSwipeRight: () {},
              showHint: false, hideAmounts: hide, themeColor: ref.watch(primaryColorProvider),
              whiteBg: !BeeTokens.isDark(context), isDark: BeeTokens.isDark(context))),
          ]);
        }),
      const SizedBox(height: 8), Text('${l10n.insightsAssetsHint}${missing.isEmpty ? '' : ' (${missing.join(', ')})'}',
        style: TextStyle(fontSize: 12, color: BeeTokens.textSecondary(context))),
    ]);
  }
}

class AnalyticsCategorySection extends StatefulWidget {
  final AnalyticsDashboard data;
  final String type;
  const AnalyticsCategorySection({super.key, required this.data, required this.type});
  @override
  State<AnalyticsCategorySection> createState() => _AnalyticsCategorySectionState();
}
class _AnalyticsCategorySectionState extends State<AnalyticsCategorySection> {
  final _expanded = <int?>{};
  void _open(Set<int?> ids, String name) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => AnalyticsDetailPage(
    query: widget.data.query, metric: widget.type == 'expense' ? AnalyticsMetric.expense : AnalyticsMetric.income,
    title: name, categoryIds: ids)));
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context), data = widget.data;
    final groups = widget.type == 'expense' ? data.expenseCategories : data.incomeCategories;
    final total = data.total(widget.type == 'expense' ? AnalyticsMetric.expense : AnalyticsMetric.income);
    final pie = <PieCategoryItem>[for (final group in groups) (
      id: group.category?.id, name: group.category?.name ?? l10n.commonUncategorized, category: group.category,
      total: group.total, subCategories: [for (final child in group.children)
        if (child.category != null) (id: child.category!.id, category: child.category!, name: child.category!.name, total: child.total)])];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(widget.type == 'expense' ? l10n.insightsExpenseCategories : l10n.insightsIncomeCategories,
        style: Theme.of(context).textTheme.titleMedium), const SizedBox(height: 12),
      if (groups.isEmpty) Center(child: Text(l10n.commonEmpty)) else ...[
        CategoryPieChart(data: pie, sum: total,
          onSectionTap: (index) { if (index >= 0 && index < groups.length) setState(() {
            final id = groups[index].category?.id;
            if (!_expanded.remove(id)) _expanded.add(id);
          }); }),
        for (final group in groups) ...[
          ListTile(key: ValueKey('analytics-group-${widget.type}-${group.category?.id}'), contentPadding: EdgeInsets.zero,
            title: Text(group.category?.name ?? l10n.commonUncategorized),
            subtitle: Text('${total > 0 ? (group.total / total * 100).toStringAsFixed(1) : '0'}% · ${group.count}'),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              ConstrainedBox(constraints: const BoxConstraints(maxWidth: 140),
                child: FittedBox(fit: BoxFit.scaleDown, child: AmountText(value: group.total, currencyCode: data.ledger.currency, showCurrency: true))),
              Icon(_expanded.contains(group.category?.id) ? Icons.expand_less : Icons.chevron_right)]),
            onTap: () {
              if (group.children.any((child) => child.id != group.category?.id)) {
                setState(() { if (!_expanded.remove(group.category?.id)) _expanded.add(group.category?.id); });
              } else { _open(group.categoryIds, group.category?.name ?? l10n.commonUncategorized); }
            }),
          if (_expanded.contains(group.category?.id)) ...[
            Align(alignment: Alignment.centerRight, child: TextButton(onPressed: () => _open(group.categoryIds,
              group.category?.name ?? l10n.commonUncategorized), child: Text(l10n.insightsViewDetails))),
            for (final child in group.children) Padding(padding: const EdgeInsets.only(left: 20), child: ListTile(
              title: Text(child.category?.name ?? l10n.commonUncategorized),
              trailing: AmountText(value: child.total, currencyCode: data.ledger.currency, showCurrency: true),
              onTap: () => _open({child.id}, child.category?.name ?? l10n.commonUncategorized))),
          ],
        ],
      ],
    ]);
  }
}
