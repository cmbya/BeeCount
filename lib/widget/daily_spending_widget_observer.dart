import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:home_widget/home_widget.dart';

import '../providers.dart';
import '../providers/budget_providers.dart';
import '../services/system/logger_service.dart';
import '../utils/app_localizations_resolver.dart';
import '../utils/currencies.dart' show getCurrencySymbol;
import 'daily_spending_widget_data.dart';

/// Independent from the PNG render catalog: this widget renders native text and
/// bars, and must publish data even when no old image-based widget is installed.
/// Registered on the root ProviderContainer, alongside the existing observer.
class DailySpendingWidgetObserver extends ProviderObserver
    with WidgetsBindingObserver {
  static const dataKey = 'widget_daily_spending_v1';
  static const kind = 'BeeCountDailySpendingWidget';

  ProviderContainer? _container;
  Timer? _debounce;
  bool _observingLifecycle = false;
  bool _running = false;
  bool _pending = false;
  int _revision = 0;

  @override
  void didUpdateProvider(
    ProviderBase provider,
    Object? previousValue,
    Object? newValue,
    ProviderContainer container,
  ) {
    if (!Platform.isIOS) return;
    if (provider != appInitStateProvider &&
        provider != currentLedgerIdProvider &&
        provider != repositoryProvider &&
        provider != statsRefreshProvider &&
        provider != budgetRefreshProvider &&
        provider != syncStatusRefreshProvider &&
        provider != ledgerListRefreshProvider &&
        provider != languageProvider) {
      return;
    }
    _container = container;
    if (!_observingLifecycle) {
      WidgetsBinding.instance.addObserver(this);
      _observingLifecycle = true;
    }
    _schedule();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _schedule();
  }

  void _schedule() {
    _revision++;
    _pending = true;
    // Stats, budget and sync notifications often arrive in the same burst.
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      unawaited(_publish());
    });
  }

  Future<void> _publish() async {
    if (_running) return;
    _running = true;
    try {
      while (_pending) {
        _pending = false;
        final container = _container;
        if (container == null ||
            container.read(appInitStateProvider) != AppInitState.ready) {
          return;
        }
        final revision = _revision;
        final repository = container.read(repositoryProvider);
        final ledgerId = container.read(currentLedgerIdProvider);
        final locale = resolveAppLocalizations(container.read(languageProvider));
        try {
          final snapshot = await DailySpendingWidgetDataService.gather(
              repository: repository, ledgerId: ledgerId);
          // Switching ledger / repository while gathering must not publish the
          // old ledger over a newer snapshot. Serialize writes and retry latest.
          if (revision != _revision) continue;
          final payload = snapshot?.toJson(
                locale: locale.localeName,
                currencySymbol: getCurrencySymbol(snapshot.currency),
              ) ??
              <String, Object?>{};
          // One encoded value: the extension never sees half of a new snapshot.
          await HomeWidget.saveWidgetData<String>(dataKey, jsonEncode(payload));
          if (revision != _revision) continue;
          await HomeWidget.updateWidget(iOSName: kind);
        } catch (error) {
          // Do not log amounts, account data or raw database/network exceptions.
          logger.warning('DailySpendingWidget',
              '桌面花销组件更新未完成 (${error.runtimeType})');
        }
      }
    } finally {
      _running = false;
    }
  }
}
