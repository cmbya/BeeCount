import 'package:beecount/models/analytics_dashboard.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  AnalyticsQuery query(AnalyticsScope scope, DateTime anchor, {int sd = 1, DateTime? today}) =>
    (ledgerId: 1, scope: scope, anchor: anchor, startDay: sd, today: today ?? DateTime(2026, 11, 8));
  test('week is Monday-based, half-open and clipped to elapsed days', () {
    final period = AnalyticsPeriod.resolve(query(AnalyticsScope.week, DateTime(2026, 11, 5), today: DateTime(2026, 11, 5)));
    expect(period.start, DateTime(2026, 11, 2)); expect(period.fullEnd, DateTime(2026, 11, 9));
    expect(period.end, DateTime(2026, 11, 6)); expect(period.days, 4);
    expect(period.contains(DateTime(2026, 11, 2)), true); expect(period.contains(DateTime(2026, 11, 6)), false);
  });
  test('custom month and year retain ledger start-day semantics', () {
    final month = AnalyticsPeriod.resolve(query(AnalyticsScope.month, DateTime(2026, 11, 8), sd: 10));
    expect(month.start, DateTime(2026, 10, 10)); expect(month.fullEnd, DateTime(2026, 11, 10)); expect(month.days, 30);
    final year = AnalyticsPeriod.resolve(query(AnalyticsScope.year, DateTime(2026, 1, 5), sd: 10));
    expect(year.start, DateTime(2025, 1, 10)); expect(year.fullEnd, DateTime(2026, 1, 10));
  });
  test('historical leap month and all-data earliest date', () {
    expect(AnalyticsPeriod.resolve(query(AnalyticsScope.month, DateTime(2024, 2, 1))).days, 29);
    final all = query(AnalyticsScope.all, DateTime(2026, 11, 8));
    expect(AnalyticsPeriod.resolve(all, earliest: DateTime(2023, 5, 6, 12)).start, DateTime(2023, 5, 6));
    expect(AnalyticsPeriod.resolve(all).days, 1);
    expect(calendarDays(DateTime(2026, 3, 7), DateTime(2026, 3, 10)), 3);
  });
}
