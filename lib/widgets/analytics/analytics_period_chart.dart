import 'dart:math' as math;
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../models/analytics_dashboard.dart';
import '../../providers.dart';
import '../../l10n/app_localizations.dart';
import '../../styles/tokens.dart';
import '../biz/amount_text.dart';
import '../ui/ui.dart';

class AnalyticsPeriodChart extends ConsumerStatefulWidget {
  final AnalyticsDashboard data;
  final ValueChanged<({AnalyticsMetric metric, AnalyticsBucket bucket})> onDetail;
  const AnalyticsPeriodChart({super.key, required this.data, required this.onDetail});
  @override
  ConsumerState<AnalyticsPeriodChart> createState() => _AnalyticsPeriodChartState();
}
class _AnalyticsPeriodChartState extends ConsumerState<AnalyticsPeriodChart> {
  AnalyticsMetric _metric = AnalyticsMetric.expense;
  int? _selected;
  @override
  void didUpdateWidget(AnalyticsPeriodChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.data != widget.data) _selected = null;
  }
  double _value(AnalyticsBucket bucket) => _metric == AnalyticsMetric.expense ? bucket.expense
      : _metric == AnalyticsMetric.income ? bucket.income : bucket.balance;
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context), data = widget.data;
    final hide = ref.watch(hideAmountsProvider);
    final color = _metric == AnalyticsMetric.expense ? BeeTokens.expenseColor(context, ref)
        : _metric == AnalyticsMetric.income ? BeeTokens.incomeColor(context, ref) : ref.watch(primaryColorProvider);
    final selected = _selected == null || _selected! >= data.buckets.length ? null : data.buckets[_selected!];
    final title = _metric == AnalyticsMetric.expense ? l10n.insightsExpenseChart
        : _metric == AnalyticsMetric.income ? l10n.insightsIncomeChart : l10n.insightsBalanceChart;
    final values = data.buckets.map(_value).toList();
    final max = values.fold<double>(0, (a, b) => math.max(a, b)), min = values.fold<double>(0, (a, b) => math.min(a, b));
    final span = math.max(1.0, max - min);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(title, style: Theme.of(context).textTheme.titleMedium), const SizedBox(height: 12),
      CapsuleSwitcher<AnalyticsMetric>(selectedValue: _metric, options: [
        CapsuleOption(value: AnalyticsMetric.expense, label: l10n.homeExpense),
        CapsuleOption(value: AnalyticsMetric.income, label: l10n.homeIncome),
        CapsuleOption(value: AnalyticsMetric.balance, label: l10n.homeBalance),
      ], onChanged: (value) => setState(() { _metric = value; _selected = null; })),
      const SizedBox(height: 8),
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [Text('${l10n.analyticsOverallAvg} '),
        AmountText(value: values.isEmpty ? 0 : values.fold<double>(0, (sum, value) => sum + value) / values.length,
          currencyCode: data.ledger.currency, showCurrency: true)]),
      if (selected != null) TextButton(key: const Key('analytics-chart-detail'),
        onPressed: () => widget.onDetail((metric: _metric, bucket: selected)),
        child: Wrap(alignment: WrapAlignment.center, spacing: 8, children: [
          Text(DateFormat.yMd().format(selected.start)),
          AmountText(value: _value(selected), currencyCode: data.ledger.currency, showCurrency: true),
          const Icon(Icons.chevron_right),
        ])),
      const SizedBox(height: 12),
      if (data.buckets.isEmpty) Center(child: Text(l10n.commonEmpty)) else LayoutBuilder(builder: (context, constraints) =>
        SingleChildScrollView(scrollDirection: Axis.horizontal, child: SizedBox(
          width: math.max(constraints.maxWidth, data.buckets.length * 38.0), height: 220,
          child: BarChart(BarChartData(minY: min < 0 ? min - span * .1 : 0,
            maxY: max > 0 ? max + span * .1 : 1,
            borderData: FlBorderData(show: false), gridData: const FlGridData(show: false),
            titlesData: FlTitlesData(show: false),
            barTouchData: BarTouchData(handleBuiltInTouches: false,
              touchCallback: (event, response) {
                if (event is FlTapUpEvent && response?.spot != null) {
                  setState(() => _selected = response!.spot!.touchedBarGroupIndex);
                }
              }),
            barGroups: [for (var i = 0; i < values.length; i++) BarChartGroupData(x: i,
              barRods: [BarChartRodData(toY: values[i], width: 20,
                color: i == _selected ? color : color.withValues(alpha: .65),
                borderRadius: BorderRadius.circular(5))])],
          )),
        ))),
      if (data.buckets.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: Row(children: [
        Text(DateFormat.yMd().format(data.buckets.first.start)), const Spacer(),
        Text(DateFormat.yMd().format(DateTime(data.period.end.year, data.period.end.month, data.period.end.day - 1))),
      ])),
      if (hide) Text(l10n.insightsViewDetails, style: TextStyle(color: BeeTokens.textSecondary(context))),
    ]);
  }
}
