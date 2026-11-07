import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../../data/db.dart';
import '../tag/tag_manage_page.dart';
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
                                  value: 'ocr', child: Text('原文关键词（图片本地 OCR／文字输入）'))
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
              return ListView(padding: const EdgeInsets.all(16), children: [
                const Text('确认后才保存',
                    style:
                        TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                const Text(
                    '支出可拆分后一次提交，取消不入账。标签点击即按顺序切换一个；预算点击即反转。图片／文字会发送至所配置的 AI 服务，识别前不重复弹说明。'),
                const SizedBox(height: 16),
                ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.label_outline),
                    title: const Text('管理标签（新增／删除）'),
                    subtitle: const Text('来源标签也可删除；仅移除标签及关联，不删除账目。'),
                    onTap: () async {
                      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const TagManagePage()));
                      if (mounted) refresh();
                    }),
                const ListTile(

                    contentPadding: EdgeInsets.zero,
                    title: Text('账本：使用 App 当前账本'),
                    subtitle: Text('可在图片记账或文字记账动作中预设账本覆盖。账户按内容识别，无法唯一匹配时弹出选择，不使用旧默认账户。')),
                DropdownButtonFormField<String>(
                    value: defaults['mode'] as String? ?? 'image',
                    decoration: const InputDecoration(labelText: '旧版图片动作的识别方式'),
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
                const Text('默认标签（确认菜单点击轮换单个标签）'),
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
                              values.clear();
                              if (selected) values.add(t.id);
                              defaults['tagIds'] = values.toList();
                              saveDefaults();
                            }))
                        .toList()),
                const Divider(height: 32),
                ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('个人分类规则（点击右侧＋新增）'),
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
                    '准备账单 → 确认并记账。第一步接收已准备的金额、类型、账本、分类、标签、账户、时间、备注、不计预算、原始文本和支付截屏等变量；第二步连接整份待确认账单，显示详情并逐项修改，最终确认后才保存一条。分类可只填二级名称，重名时选择；标签单选点击轮换，不计预算接文字是／否。金额编辑框可以为空，备注使用输入后的实际文本。不调用 AI、不做拆分、不计收入已取消；无须循环、JSON 或第三个保存动作。系统输入和支付截屏传递仍需对应新版真机验收。'),
                const SizedBox(height: 16),
                const Text('最近提交凭证（点击复制请求 ID）'),
                const Text(
                    '提交结果不明时先查看这里，并核对 App 中的账单，不要直接重新运行记账。凭证保留已提交事实，即使之后手动删除交易也不会重新记账。'),
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
