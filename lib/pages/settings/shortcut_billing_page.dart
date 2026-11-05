import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../../data/db.dart';
import '../../data/repositories/local/local_repository.dart';
import '../../providers.dart';
import '../../services/automation/shortcut_service.dart';
import '../../services/automation/shortcut_store.dart';
import '../../services/automation/shortcut_schema.dart';
import '../../utils/account_type_utils.dart';

/// Personal shortcut settings. Rules are local and intentionally not cloud synced.
class ShortcutBillingPage extends ConsumerStatefulWidget {
  const ShortcutBillingPage({super.key});
  @override
  ConsumerState<ShortcutBillingPage> createState() =>
      _ShortcutBillingPageState();
}

class _ShortcutBillingPageState extends ConsumerState<ShortcutBillingPage> {
  late Future<void> loading;
  List<Ledger> ledgers = [];
  List<Account> accounts = [];
  List<Category> categories = [];
  List<Tag> tags = [];
  List<Map<String, dynamic>> rules = [];
  List<Map<String, dynamic>> receipts = [];
  Map<String, dynamic> defaults = {};
  ShortcutStore get store =>
      ShortcutStore(ref.read(repositoryProvider) as LocalRepository);

  @override
  void initState() {
    super.initState();
    loading = load();
  }

  Future<void> load() async {
    final repo = ref.read(repositoryProvider);
    ledgers = (await repo.getAllLedgers())
        .where((l) => !l.isShared && l.type == 'personal')
        .toList();
    accounts = (await repo.getAllAccounts())
        .where((a) => !a.hidden && isTradableType(a.type))
        .toList();
    categories = [
      ...await repo.getUsableCategories('expense'),
      ...await repo.getUsableCategories('income')
    ];
    tags = await repo.getAllTags();
    rules = await store.rules();
    receipts = (await store.db
            .customSelect(
                'SELECT request_id, result_json, created_at FROM shortcut_receipts ORDER BY created_at DESC LIMIT 20')
            .get())
        .map((r) => r.data)
        .toList();
    final prefs = await SharedPreferences.getInstance();
    defaults = jsonDecode(prefs.getString(shortcutDefaultsKey) ?? '{}')
        as Map<String, dynamic>;
  }

  Future<void> saveDefaults() async {
    await (await SharedPreferences.getInstance())
        .setString(shortcutDefaultsKey, jsonEncode(defaults));
    if (mounted) setState(() {});
  }

  void refresh() {
    setState(() {
      loading = load();
    });
  }

  Future<void> editRule([Map<String, dynamic>? existing]) async {
    if (categories.isEmpty) {
      message('请先创建收入或支出分类');
      return;
    }
    final name =
        TextEditingController(text: existing?['name'] as String? ?? '');
    final keyword =
        TextEditingController(text: existing?['keyword'] as String? ?? '');
    final priority =
        TextEditingController(text: (existing?['priority'] ?? 0).toString());
    var field = existing?['field'] as String? ?? 'merchant';
    var mode = existing?['match_mode'] as String? ?? 'contains';
    int? ledgerId = existing?['ledger_id'] as int?;
    var categoryId = existing?['category_id'] as int?;
    if (!categories.any((c) => c.id == categoryId)) categoryId = null;
    final invalidLedgerId =
        ledgerId != null && !ledgers.any((l) => l.id == ledgerId)
            ? ledgerId
            : null;
    var enabled = existing?['enabled'] != 0;
    String? error;
    final route = DialogRoute<void>(
        context: context,
        builder: (ctx) => StatefulBuilder(
            builder: (ctx, update) => AlertDialog(
                  title: Text(existing == null ? '新增个人分类规则' : '编辑个人分类规则'),
                  content: SizedBox(
                      width: 420,
                      child: SingleChildScrollView(
                          child:
                              Column(mainAxisSize: MainAxisSize.min, children: [
                        TextField(
                            controller: name,
                            decoration:
                                const InputDecoration(labelText: '规则名称')),
                        TextField(
                            controller: keyword,
                            decoration:
                                const InputDecoration(labelText: '关键词')),
                        DropdownButtonFormField<String>(
                            value: field,
                            decoration:
                                const InputDecoration(labelText: '匹配字段'),
                            items: const [
                              DropdownMenuItem(
                                  value: 'merchant', child: Text('商户')),
                              DropdownMenuItem(
                                  value: 'note', child: Text('备注')),
                              DropdownMenuItem(
                                  value: 'ocr', child: Text('OCR 原文（文字模式）'))
                            ],
                            onChanged: (v) => update(() => field = v!)),
                        DropdownButtonFormField<String>(
                            value: mode,
                            decoration:
                                const InputDecoration(labelText: '匹配方式'),
                            items: const [
                              DropdownMenuItem(
                                  value: 'contains', child: Text('包含')),
                              DropdownMenuItem(
                                  value: 'exact', child: Text('完全匹配'))
                            ],
                            onChanged: (v) => update(() => mode = v!)),
                        DropdownButtonFormField<int>(
                            value: ledgerId ?? 0,
                            decoration:
                                const InputDecoration(labelText: '账本范围'),
                            items: [
                              const DropdownMenuItem(
                                  value: 0, child: Text('所有个人账本')),
                              if (invalidLedgerId != null)
                                DropdownMenuItem(
                                    value: invalidLedgerId,
                                    child: const Text('原账本已失效，请重新选择')),
                              ...ledgers.map((l) => DropdownMenuItem(
                                  value: l.id, child: Text(l.name)))
                            ],
                            onChanged: (v) =>
                                update(() => ledgerId = v == 0 ? null : v)),
                        DropdownButtonFormField<int>(
                            value: categoryId,
                            decoration:
                                const InputDecoration(labelText: '目标分类'),
                            isExpanded: true,
                            items: categories
                                .map((c) => DropdownMenuItem(
                                    value: c.id,
                                    child: Text((c.kind == 'income'
                                            ? '收入 · '
                                            : '支出 · ') +
                                        c.name)))
                                .toList(),
                            onChanged: (v) => update(() => categoryId = v)),
                        TextField(
                            controller: priority,
                            keyboardType: const TextInputType.numberWithOptions(
                                signed: true),
                            decoration:
                                const InputDecoration(labelText: '优先级（越大越优先）')),
                        SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('启用'),
                            value: enabled,
                            onChanged: (v) => update(() => enabled = v)),
                        if (error != null)
                          Text(error!,
                              style: TextStyle(
                                  color: Theme.of(ctx).colorScheme.error)),
                      ]))),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text('取消')),
                    FilledButton(
                        onPressed: () async {
                          try {
                            if (categoryId == null ||
                                int.tryParse(priority.text) == null)
                              throw const ShortcutFailure(
                                  'INVALID_RULE', '请选择分类并填写整数优先级');
                            await store.saveRule({
                              'id': existing?['id'] ?? const Uuid().v4(),
                              'name': name.text.trim(),
                              'keyword': keyword.text.trim(),
                              'enabled': enabled ? 1 : 0,
                              'field': field,
                              'match_mode': mode,
                              'ledger_id': ledgerId,
                              'category_id': categoryId,
                              'priority': int.parse(priority.text)
                            });
                            if (ctx.mounted) Navigator.pop(ctx);
                          } on ShortcutFailure catch (e) {
                            update(() => error = e.message);
                          } catch (_) {
                            update(() => error = '保存失败，请重试');
                          }
                        },
                        child: const Text('保存'))
                  ],
                )));
    await Navigator.of(context).push(route);
    await route.completed;
    name.dispose();
    keyword.dispose();
    priority.dispose();
    if (mounted) refresh();
  }

  void message(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('iOS 快捷确认记账')),
        body: FutureBuilder<void>(
            future: loading,
            builder: (context, snapshot) {
              if (snapshot.hasError)
                return Center(
                    child: TextButton(
                        onPressed: refresh, child: const Text('读取失败，点击重试')));
              if (snapshot.connectionState != ConnectionState.done)
                return const Center(child: CircularProgressIndicator());
              final validCats = categories.map((c) => c.id).toSet();
              final ledgerId = defaults['ledgerId'] as int?;
              final accountId = defaults['accountId'] as int?;
              final currency =
                  ledgers.where((l) => l.id == ledgerId).firstOrNull?.currency;
              final usableAccounts = accounts
                  .where((a) => currency == null || a.currency == currency)
                  .toList();
              return ListView(padding: const EdgeInsets.all(16), children: [
                const Text('确认后才保存',
                    style:
                        TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                const Text(
                    '支出可拆分后一次提交，取消不入账。支持个人账本与同币种账户，金额精度跟随账本。原截图自动记账入口保持原行为。'),
                const SizedBox(height: 16),
                DropdownButtonFormField<int>(
                    value:
                        ledgers.any((l) => l.id == ledgerId) ? ledgerId : null,
                    decoration: const InputDecoration(labelText: '默认账本'),
                    items: ledgers
                        .map((l) =>
                            DropdownMenuItem(value: l.id, child: Text(l.name)))
                        .toList(),
                    onChanged: (v) {
                      defaults['ledgerId'] = v;
                      saveDefaults();
                    }),
                DropdownButtonFormField<int>(
                    value: usableAccounts.any((a) => a.id == accountId)
                        ? accountId
                        : null,
                    decoration: const InputDecoration(labelText: '默认账户'),
                    items: usableAccounts
                        .map((a) =>
                            DropdownMenuItem(value: a.id, child: Text(a.name)))
                        .toList(),
                    onChanged: (v) {
                      defaults['accountId'] = v;
                      saveDefaults();
                    }),
                DropdownButtonFormField<String>(
                    value: defaults['mode'] as String? ?? 'image',
                    decoration: const InputDecoration(labelText: '默认识别方式'),
                    items: const [
                      DropdownMenuItem(value: 'image', child: Text('图片 AI')),
                      DropdownMenuItem(
                          value: 'text', child: Text('本地 OCR → 文字 AI'))
                    ],
                    onChanged: (v) {
                      defaults['mode'] = v;
                      saveDefaults();
                    }),
                SwitchListTile(
                    title: const Text('默认不计入预算'),
                    subtitle: const Text('仍正常计入支出和账户余额'),
                    value: defaults['excludeFromBudget'] == true,
                    onChanged: (v) {
                      defaults['excludeFromBudget'] = v;
                      saveDefaults();
                    }),
                const Text('默认标签（可多选）'),
                Wrap(
                    spacing: 8,
                    children: tags
                        .map((t) => FilterChip(
                            label: Text(t.name),
                            selected: (defaults['tagIds'] as List? ?? [])
                                .contains(t.id),
                            onSelected: (selected) {
                              final values = (defaults['tagIds'] as List? ?? [])
                                  .cast<int>()
                                  .toSet();
                              if (selected) {
                                values.add(t.id);
                              } else {
                                values.remove(t.id);
                              }
                              defaults['tagIds'] = values.toList()..sort();
                              saveDefaults();
                            }))
                        .toList()),
                const Divider(height: 32),
                ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('个人分类规则'),
                    subtitle: const Text(
                        '优先级越大越优先，同级按稳定 ID 排序；个人规则优先于内置规则和 AI。仅保存在本机。'),
                    trailing: IconButton(
                        onPressed: editRule, icon: const Icon(Icons.add))),
                for (final rule in rules)
                  Card(
                      child: ListTile(
                    title: Text(rule['name'] as String),
                    subtitle: Text((validCats.contains(rule['category_id'])
                            ? ''
                            : '⚠ 目标分类失效 · ') +
                        rule['keyword'].toString() +
                        ' → ' +
                        (categories
                                .where((c) => c.id == rule['category_id'])
                                .firstOrNull
                                ?.name ??
                            '请选择分类') +
                        ' · 优先级 ' +
                        rule['priority'].toString()),
                    leading: Switch(
                        value: rule['enabled'] == 1,
                        onChanged: validCats.contains(rule['category_id']) ||
                                rule['enabled'] == 1
                            ? (v) async {
                                try {
                                  await store.saveRule(
                                      {...rule, 'enabled': v ? 1 : 0});
                                  refresh();
                                } on ShortcutFailure catch (e) {
                                  if (mounted) message(e.message);
                                }
                              }
                            : null),
                    onTap: () => editRule(rule),
                    trailing: IconButton(
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () async {
                          final remove = await showDialog<bool>(
                              context: context,
                              builder: (c) => AlertDialog(
                                      title: const Text('删除这条规则？'),
                                      actions: [
                                        TextButton(
                                            onPressed: () =>
                                                Navigator.pop(c, false),
                                            child: const Text('取消')),
                                        TextButton(
                                            onPressed: () =>
                                                Navigator.pop(c, true),
                                            child: const Text('删除'))
                                      ]));
                          if (remove == true) {
                            await store.deleteRule(rule['id'] as String);
                            refresh();
                          }
                        }),
                  )),
                const Divider(height: 32),
                const Text('快捷指令配置'),
                const SelectableText(
                    '截图 → 图片生成记账草稿（或本地取字 → 文字生成记账草稿）→ 确认编辑记账草稿 → 提交已确认账单。也可以用“识别并确认记账”组合动作。\n图片模式将图片发送给 App 中配置的视觉服务；OCR 模式只发送文字给文字服务，仍可能联网。失败不会自动切换为上传图片。'),
                const SizedBox(height: 16),
                const Text('最近提交凭证（点击复制请求 ID）'),
                const Text(
                    '提交超时先用“查询快捷记账结果”，或查看这里。凭证保留已提交事实，即使之后手动删除交易也不会重新记账。'),
                for (final receipt in receipts)
                  ListTile(
                      title: Text(receipt['request_id'] as String),
                      subtitle: Text('已在本机入账 · ' +
                          DateTime.fromMillisecondsSinceEpoch(
                                  receipt['created_at'] as int)
                              .toLocal()
                              .toString()),
                      onTap: () async {
                        await Clipboard.setData(ClipboardData(
                            text: receipt['request_id'] as String));
                        if (mounted) message('请求 ID 已复制');
                      }),
              ]);
            }),
      );
}
