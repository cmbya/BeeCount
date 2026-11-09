import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'daily_spending_widget_bridge.dart';
import 'daily_spending_widget_observer.dart';

/// Scoped to the new widget: does not change old widgets' storage or move the DB.
class DailySpendingWidgetDiagnostics extends ConsumerStatefulWidget {
  const DailySpendingWidgetDiagnostics({super.key});

  @override
  ConsumerState<DailySpendingWidgetDiagnostics> createState() =>
      _DailySpendingWidgetDiagnosticsState();
}

class _DailySpendingWidgetDiagnosticsState
    extends ConsumerState<DailySpendingWidgetDiagnostics> {
  Map<String, dynamic>? _status;
  String? _message;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    try {
      final status = await DailySpendingWidgetBridge.diagnostics();
      if (mounted) setState(() => _status = status);
    } catch (_) {
      if (mounted) setState(() => _message = '共享权限检查失败，请重新打开 App');
    }
  }

  Future<void> _refresh() async {
    setState(() { _busy = true; _message = null; });
    try {
      await DailySpendingWidgetObserver.refreshNow();
    } catch (_) {
      if (mounted) setState(() => _message = '刷新未完成，请检查下方共享权限状态');
    } finally {
      await _check();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _choose(String group) async {
    final confirmed = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
      title: const Text('使用这个已授权共享组？'),
      content: Text('$group\n只写入可重新生成的花销快照，不迁移或删除账本。此操作不能授予签名权限。'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
        TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('确认')),
      ],
    ));
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await DailySpendingWidgetBridge.chooseGroup(group);
      await DailySpendingWidgetObserver.refreshNow();
    } catch (_) {
      if (mounted) setState(() => _message = '共享组选择或刷新失败，未改动账本');
    } finally {
      await _check();
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final candidates = (_status?['candidates'] as List? ?? []).whereType<String>();
    return Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('每日花销 · 数据与共享权限', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        const Text('显示今日已花、本月已花、还能花和近 7 天；这张组件固定中文，不含记账入口。'),
        const SizedBox(height: 8),
        Text(ref.watch(dailySpendingWidgetStatusProvider)),
        if (_status != null) Text(_status!['message']?.toString() ?? '等待检查'),
        if (_status?['group'] != null) Text('共享组：${_status!['group']}'),
        if (_status?['available'] == true)
          Text(_status?['hasSnapshot'] == true ? '已存在共享快照' : '尚无共享快照，请刷新'),
        if (_message != null) Text(_message!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        Wrap(spacing: 8, children: [
          OutlinedButton(onPressed: _busy ? null : _refresh,
              child: Text(_busy ? '正在刷新…' : '刷新每日花销')),
          TextButton(onPressed: _busy ? null : _check, child: const Text('检查共享权限')),
        ]),
        if (_status?['code'] == 'chooseGroup')
          for (final group in candidates)
            TextButton(onPressed: _busy ? null : () => _choose(group), child: Text('选择 $group')),
        const Text('重签名时主 App 和组件必须获准访问同一 App Group；代码不能补签名授权。不要卸载或清空账本。',
            style: TextStyle(fontSize: 12)),
      ],
    )));
  }
}
