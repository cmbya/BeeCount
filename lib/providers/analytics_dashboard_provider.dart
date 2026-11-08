import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/analytics_dashboard.dart';
import '../services/data/analytics_service.dart';
import 'database_providers.dart';
import 'statistics_providers.dart';

final analyticsDashboardProvider = FutureProvider.autoDispose
    .family<AnalyticsDashboard, AnalyticsQuery>((ref, query) {
  ref.watch(statsRefreshProvider);
  return AnalyticsService(ref.watch(repositoryProvider)).load(query);
});
