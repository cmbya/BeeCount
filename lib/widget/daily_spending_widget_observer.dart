import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers.dart';
import '../providers/budget_providers.dart';
import '../services/system/logger_service.dart';
import '../utils/currencies.dart' show getCurrencySymbol;
import 'daily_spending_widget_bridge.dart';
import 'daily_spending_widget_data.dart';

final dailySpendingWidgetStatusProvider = StateProvider<String>(
    (ref) => '尚未刷新；请检查共享权限后刷新');

/// Explicitly attached at startup. Initial provider creation does not always
/// produce didUpdateProvider, so relying on that callback alone can miss seeding.
class DailySpendingWidgetObserver extends ProviderObserver
    with WidgetsBindingObserver {
  DailySpendingWidgetObserver({
    Future<void> Function(String)? publish,
    bool? supported,
  })  : _publishNative = publish ?? DailySpendingWidgetBridge.publish,
        _supported = supported ?? Platform.isIOS;

  static DailySpendingWidgetObserver? _active;
  static Future<void> refreshNow() async {
    final observer = _active;
    if (observer == null) throw StateError('组件刷新服务尚未初始化');
    observer._revision++;
    observer._pending = true;
    observer._debounce?.cancel();
    final running = observer._inFlight;
    if (running != null) await running;
    if (observer._pending) await observer._drain();
    if (observer._lastError != null) throw StateError(observer._lastError!);
  }

  final Future<void> Function(String) _publishNative;
  final bool _supported;
  ProviderContainer? _container;
  Timer? _debounce;
  Future<void>? _inFlight;
  bool _pending = false;
  int _revision = 0;
  String? _lastError;

  void attach(ProviderContainer container) {
    if (!_supported) return;
    _container = container;
    _active = this;
    WidgetsBinding.instance.addObserver(this);
    _schedule();
  }

  @override
  void didAddProvider(ProviderBase provider, Object? value,
      ProviderContainer container) {
    _changed(provider);
  }

  @override
  void didUpdateProvider(ProviderBase provider, Object? previousValue,
      Object? newValue, ProviderContainer container) {
    _changed(provider);
  }

  void _changed(ProviderBase provider) {
    if (!_supported || _container == null) return;
    if (provider == appInitStateProvider ||
        provider == currentLedgerIdProvider ||
        provider == currentLedgerProvider ||
        provider == repositoryProvider ||
        provider == statsRefreshProvider ||
        provider == budgetRefreshProvider ||
        provider == syncStatusRefreshProvider ||
        provider == ledgerListRefreshProvider) {
      _schedule();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _schedule();
    } else if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused) {
      // Flush before suspension instead of leaving the only write behind a timer.
      _debounce?.cancel();
      if (_pending) unawaited(_drain());
    }
  }

  void _schedule() {
    _revision++;
    _pending = true;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 150), () {
      unawaited(_drain());
    });
  }

  Future<void> _drain() {
    final existing = _inFlight;
    if (existing != null) return existing;
    // Install the future before running any reads that can notify observers.
    final completer = Completer<void>();
    _inFlight = completer.future;
    () async {
      try {
        while (_pending) {
          _pending = false;
          final container = _container;
          if (container == null) return;
          try {
            if (container.read(appInitStateProvider) != AppInitState.ready) {
              _lastError = 'App 尚未初始化完成，请进入首页后刷新';
              container.read(dailySpendingWidgetStatusProvider.notifier).state = _lastError!;
              return;
            }
            final repository = container.read(repositoryProvider);
            final ledgerId = container.read(currentLedgerIdProvider);
            final revision = _revision;
            final snapshot = await DailySpendingWidgetDataService.gather(
                repository: repository, ledgerId: ledgerId);
            if (revision != _revision) continue;
            final payload = snapshot == null
                ? <String, Object?>{'status': 'noLedger'}
                : snapshot.toJson(locale: 'zh_CN',
                    currencySymbol: getCurrencySymbol(snapshot.currency));
            await _publishNative(jsonEncode(payload));
            if (revision != _revision) continue;
            _lastError = null;
            container.read(dailySpendingWidgetStatusProvider.notifier).state = snapshot == null
                ? '当前账本不可用，请选择账本后刷新'
                : '快照已写入并回读校验，已请求刷新；实际显示由 iOS 调度';
          } catch (error) {
            // The diagnostic page checks precise native failure codes separately.
            // Do not leak database exceptions, amounts or paths in UI/logs.
            _lastError = '刷新失败，请检查共享权限与当前账本后重试';
            container.read(dailySpendingWidgetStatusProvider.notifier).state = _lastError!;
            try {
              logger.warning('DailySpendingWidget', '组件刷新失败 (${error.runtimeType})');
            } catch (_) {}
          }
        }
      } catch (_) {
        _lastError = '组件刷新服务不可用，请重新打开 App';
      } finally {
        _inFlight = null;
        completer.complete();
      }
    }();
    return completer.future;
  }

  void dispose() {
    _debounce?.cancel();
    _pending = false;
    _revision++;
    _container = null;
    if (_active == this) _active = null;
    if (_supported) WidgetsBinding.instance.removeObserver(this);
  }
}
