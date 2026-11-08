import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../l10n/app_localizations.dart';
import '../../models/analytics_dashboard.dart';
import '../../providers/analytics_dashboard_provider.dart';
import '../../providers.dart';
import '../../widgets/biz/transaction_list.dart';
import '../../widgets/ui/ui.dart';
import '../../styles/tokens.dart';

/// Query, period and category IDs are captured at navigation. The data itself
/// remains reactive after edits/deletes; a list is never a stale copied snapshot.
class AnalyticsDetailPage extends ConsumerWidget {
  final AnalyticsQuery query;
  final AnalyticsMetric metric;
  final String title;
  final DateTime? start, end;
  final Set<int?>? categoryIds;
  const AnalyticsDetailPage({super.key, required this.query, required this.metric,
    required this.title, this.start, this.end, this.categoryIds});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final result = ref.watch(analyticsDashboardProvider(query));
    return ProviderScope(overrides: [currentLedgerIdProvider.overrideWith((ref) => query.ledgerId)],
      child: Scaffold(backgroundColor: BeeTokens.scaffoldBackground(context), body: Column(children: [
      PrimaryHeader(title: title, showBack: true, compact: true),
      Expanded(child: result.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, __) => Center(child: TextButton(onPressed: () => ref.invalidate(analyticsDashboardProvider(query)), child: Text(l10n.commonFailed))),
        data: (data) {
          final begin = start ?? data.period.start, until = end ?? data.period.end;
          final last = DateTime(until.year, until.month, until.day - 1);
          final rows = data.detail(metric, start: begin, end: until, categoryIds: categoryIds);
          return Column(children: [
            Padding(padding: const EdgeInsets.all(16), child: Text(
              '${DateFormat.yMd().format(begin)} – ${DateFormat.yMd().format(last)} · ${rows.length}',
              key: const Key('analytics-detail-range'))),
            Expanded(child: TransactionList(hideAmounts: ref.watch(hideAmountsProvider), transactions: rows,
              emptyWidget: Center(child: Text(l10n.commonEmpty)))),
          ]);
        },
      )),
    ])));
  }
}
