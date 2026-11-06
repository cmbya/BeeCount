import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' as d;
import '../../data/db.dart';
import '../../data/repositories/local/local_repository.dart';
import '../../utils/account_type_utils.dart';
import 'shortcut_schema.dart';

class ShortcutStore {
  final LocalRepository repo;
  BeeDatabase get db => repo.db;
  final Future<Directory> Function()? attachmentDirectory;
  ShortcutStore(this.repo, {this.attachmentDirectory});

  Future<Directory> _attachmentDirectory() async {
    if (attachmentDirectory != null) return attachmentDirectory!();
    final docs = await getApplicationDocumentsDirectory();
    return Directory('${docs.path}/attachments');
  }

  Future<void> _cleanupCreated(File? file) async {
    if (file == null) return;
    try {
      await db.transaction(() async {
        final name = file.uri.pathSegments.last;
        if (await repo.countAttachmentsByFileName(name) == 0 && file.existsSync()) file.deleteSync();
      });
    } catch (_) { /* Orphan-file maintenance may clean later; never undo a commit. */ }
  }

  Future<Map<String, dynamic>> query(String requestId) async {
    final row = await db.customSelect(
        'SELECT result_json FROM shortcut_receipts WHERE request_id = ?',
        variables: [
          d.Variable.withString(requestId.toLowerCase())
        ]).getSingleOrNull();
    if (row == null) return {'requestId': requestId, 'status': 'not_found'};
    return {
      ...jsonDecode(row.read<String>('result_json')) as Map<String, dynamic>,
      'replayed': true
    };
  }

  /// Reconcile a possibly completed split call without treating a different
  /// payload sharing the request ID as a successful retry.
  Future<Map<String, dynamic>> querySplit(ShortcutSubmission request) async {
    if (request.split == null) {
      throw const ShortcutFailure('INVALID_SPLIT', '查询逐笔结果需要拆分请求');
    }
    final row = await db.customSelect(
        'SELECT digest, result_json FROM shortcut_receipts WHERE request_id = ?',
        variables: [d.Variable.withString(request.requestId)]).getSingleOrNull();
    if (row == null) return {'status': 'not_found', 'requestId': request.requestId};
    final digest = sha256.convert(utf8.encode(request.canonical)).toString();
    if (row.read<String>('digest') != digest) {
      throw const ShortcutFailure('REQUEST_CONFLICT', '同一拆分序号已有不同内容，请查询原结果；不要再次保存');
    }
    return {...jsonDecode(row.read<String>('result_json')) as Map<String, dynamic>, 'replayed': true};
  }

  Future<Map<String, dynamic>> commit(ShortcutSubmission request,
      {bool validateOnly = false}) async {
    final digest = sha256.convert(utf8.encode(request.canonical)).toString();
    File? createdFile;
    try {
      return await db.transaction(() async {
        final receipt = await db.customSelect(
            'SELECT digest, result_json FROM shortcut_receipts WHERE request_id = ?',
            variables: [
              d.Variable.withString(request.requestId)
            ]).getSingleOrNull();
        if (receipt != null) {
          if (receipt.read<String>('digest') != digest) {
            throw const ShortcutFailure(
                'REQUEST_CONFLICT', '同一请求 ID 的内容已经改变，请查询原结果');
          }
          return {
            ...jsonDecode(receipt.read<String>('result_json'))
                as Map<String, dynamic>,
            'replayed': true
          };
        }
        final split = request.split;
        var paidMinor = 0;
        var savedCount = 0;
        var existingSession = false;
        if (split == null) {
          // A stale pre-split whole-bill confirmation must never double-book it.
          final started = await db.customSelect(
              'SELECT session_id FROM shortcut_split_sessions WHERE session_id = ?',
              variables: [d.Variable.withString(request.requestId)]).getSingleOrNull();
          if (started != null) {
            throw const ShortcutFailure('SPLIT_STARTED', '此原账单已经逐笔记入，不能再整笔保存');
          }
        } else {
          final wholeReceipt = await db.customSelect(
              'SELECT request_id FROM shortcut_receipts WHERE request_id = ?',
              variables: [d.Variable.withString(split.sessionId)]).getSingleOrNull();
          if (wholeReceipt != null) {
            throw const ShortcutFailure('SPLIT_CONFLICT', '原账单已整笔保存，不能再次拆分入账');
          }
          final session = await db.customSelect(
              'SELECT * FROM shortcut_split_sessions WHERE session_id = ?',
              variables: [d.Variable.withString(split.sessionId)]).getSingleOrNull();
          if (session != null) {
            existingSession = true;
            if (session.read<int>('ledger_id') != request.ledgerId ||
                session.read<int>('account_id') != request.accountId ||
                session.read<String>('currency') != request.currency ||
                session.read<int>('total_minor') != split.totalMinor) {
              throw const ShortcutFailure('SPLIT_CONFLICT', '已保存拆分的账本、账户、币种及原总额不能改变');
            }
            paidMinor = session.read<int>('paid_minor');
            savedCount = session.read<int>('saved_count');
          }
          if (split.partIndex != savedCount + 1 ||
              request.originalAmountMinor > split.totalMinor - paidMinor) {
            throw const ShortcutFailure('SPLIT_STALE', '此拆分步骤已过期、已保存或超出剩余金额，请查询原请求，不要重新记账');
          }
        }
        final ledger = await repo.getLedgerById(request.ledgerId);
        final account = await repo.getAccount(request.accountId);
        if (ledger == null ||
            ledger.isShared ||
            ledger.type != 'personal' ||
            ledger.currency.toUpperCase() != request.currency ||
            account == null ||
            account.hidden ||
            !isTradableType(account.type) ||
            account.currency.toUpperCase() != ledger.currency.toUpperCase()) {
          throw const ShortcutFailure('INVALID_REFERENCE', '请选择个人账本及同币种的有效账户');
        }
        final scale =
            [1, 10, 100, 1000, 10000][shortcutCurrencyDigits(ledger.currency)];
        if (request.type == 'transfer') {
          final destination = await repo.getAccount(request.toAccountId!);
          if (destination == null ||
              destination.hidden ||
              !isTradableType(destination.type) ||
              destination.id == account.id ||
              destination.currency.toUpperCase() != request.currency) {
            throw const ShortcutFailure('INVALID_REFERENCE', '请选择不同的有效同币种转入账户');
          }
        }
        final categoryIds = (await repo.getUsableCategories(request.type))
            .map((c) => c.id)
            .toSet();
        final tagIds = (await repo.getAllTags()).map((t) => t.id).toSet();
        for (final entry in request.entries) {
          if ((request.type != 'transfer' && entry.categoryId != null &&
                  !categoryIds.contains(entry.categoryId)) ||
              !tagIds.containsAll(entry.tagIds)) {
            throw const ShortcutFailure('INVALID_REFERENCE', '分类或标签已失效，请重新选择');
          }
        }
        if (validateOnly) return {'status': 'valid'};
        final transferCategoryId = request.type == 'transfer'
            ? (await repo.getTransferCategory()).id
            : null;
        final ids = await repo.insertTransactionsBatchWithRelations(
          transactions: request.entries
              .map((e) => TransactionsCompanion.insert(
                    ledgerId: request.ledgerId,
                    type: request.type,
                    amount: e.amountMinor / scale,
                    categoryId: d.Value(transferCategoryId ?? e.categoryId),
                    accountId: d.Value(request.accountId),
                    toAccountId: d.Value(request.toAccountId),
                    happenedAt: d.Value(request.occurredAt),
                    note: d.Value(e.note),
                    currencyCode: d.Value(ledger.currency),
                    nativeAmount: d.Value(e.amountMinor / scale),
                    excludeFromBudget: d.Value(e.excludeFromBudget),
                  ))
              .toList(),
          tagIdsByIndex: {
            for (var i = 0; i < request.entries.length; i++)
              i: request.entries[i].tagIds
          },
        );
        final attachment = request.attachment;
        if (attachment != null) {
          final directory = await _attachmentDirectory();
          if (!directory.existsSync()) directory.createSync(recursive: true);
          final file = File('${directory.path}/${attachment.fileName}');
          if (file.existsSync()) {
            if (sha256.convert(file.readAsBytesSync()).toString() != attachment.digest) {
              throw const ShortcutFailure('INVALID_ATTACHMENT', '已有附件文件校验失败，未入账');
            }
          } else {
            createdFile = file;
            file.writeAsBytesSync(attachment.bytes, flush: true);
          }
          // Shared physical file, one attachment row for each split transaction.
          // Repository also registers parent tx sync metadata in this transaction.
          for (final id in ids) {
            await repo.createAttachment(transactionId: id,
                fileName: attachment.fileName, originalName: 'shortcut.${attachment.extension}',
                fileSize: attachment.bytes.length, sortOrder: 0);
          }
        }
        final rows = await (db.select(db.transactions)
              ..where((t) => t.id.isIn(ids)))
            .get();
        final syncById = {for (final row in rows) row.id: row.syncId};
        await db.customStatement(
            'INSERT INTO shortcut_groups VALUES (?, ?, ?, ?)', [
          request.requestId,
          request.originalAmountMinor,
          ledger.currency,
          jsonEncode(ids.map((id) => syncById[id]).toList()),
        ]);
        // Same transaction as the bill, attachments and receipt. Validation
        // never creates this row; a rollback cannot consume the remaining money.
        if (split != null) {
          paidMinor += request.originalAmountMinor;
          savedCount += 1;
          if (existingSession) {
            await db.customStatement(
                'UPDATE shortcut_split_sessions SET paid_minor = ?, saved_count = ? WHERE session_id = ?',
                [paidMinor, savedCount, split.sessionId]);
          } else {
            await db.customStatement('INSERT INTO shortcut_split_sessions '
                '(session_id, ledger_id, account_id, currency, total_minor, paid_minor, saved_count) '
                'VALUES (?, ?, ?, ?, ?, ?, ?)',
                [split.sessionId, request.ledgerId, request.accountId, request.currency,
                  split.totalMinor, paidMinor, savedCount]);
          }
        }
        final result = <String, dynamic>{
          'requestId': request.requestId,
          'status': 'committed',
          'transactionIds': ids,
          'count': ids.length,
          'type': request.type,
          'totalAmountMinor': request.originalAmountMinor,
          'currency': ledger.currency,
          'minorDigits': shortcutCurrencyDigits(ledger.currency),
          'replayed': false,
          'attachmentCount': attachment == null ? 0 : ids.length,
          'syncStatus': 'pending',
          if (split != null) 'split': {
            ...split.toJson(), 'paidMinor': paidMinor,
            'remainingMinor': split.totalMinor - paidMinor, 'savedCount': savedCount,
          },
          'warnings': ['已在本机入账；云端状态请查看 App 同步状态，无需再次记账']
        };
        await db.customStatement(
            'INSERT INTO shortcut_receipts VALUES (?, ?, ?, ?)', [
          request.requestId,
          digest,
          jsonEncode(result),
          DateTime.now().millisecondsSinceEpoch
        ]);
        return result;
      });
    } on ShortcutFailure {
      await _cleanupCreated(createdFile);
      rethrow;
    } catch (_) {
      await _cleanupCreated(createdFile);
      throw const ShortcutFailure('COMMIT_FAILED', '保存失败，事务已回滚；可使用原请求重试');
    }
  }

  Future<List<Map<String, dynamic>>> rules() async => (await db
          .customSelect(
              'SELECT * FROM shortcut_rules ORDER BY priority DESC, id ASC')
          .get())
      .map((r) => r.data)
      .toList();

  Future<void> saveRule(Map<String, dynamic> rule) async {
    if (!['merchant', 'note', 'ocr'].contains(rule['field']) ||
        !['contains', 'exact'].contains(rule['match_mode']) ||
        (rule['keyword'] as String).trim().isEmpty ||
        (rule['name'] as String).trim().isEmpty) {
      throw const ShortcutFailure('INVALID_RULE', '请填写规则名称、关键词及有效匹配方式');
    }
    final cats = [
      ...await repo.getUsableCategories('expense'),
      ...await repo.getUsableCategories('income')
    ];
    if (rule['enabled'] != 0 && rule['ledger_id'] != null) {
      final ledger = await repo.getLedgerById(rule['ledger_id'] as int);
      if (ledger == null || ledger.isShared || ledger.type != 'personal') {
        throw const ShortcutFailure('INVALID_REFERENCE', '规则账本已失效');
      }
    }
    if (rule['enabled'] != 0 && !cats.any((c) => c.id == rule['category_id'])) {
      throw const ShortcutFailure('INVALID_REFERENCE', '请选择有效的收入或支出分类');
    }
    await db.customStatement(
        'INSERT OR REPLACE INTO shortcut_rules '
        '(id, name, enabled, ledger_id, field, match_mode, keyword, category_id, priority) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
        [
          'id',
          'name',
          'enabled',
          'ledger_id',
          'field',
          'match_mode',
          'keyword',
          'category_id',
          'priority'
        ].map((k) => rule[k]).toList());
  }

  Future<void> deleteRule(String id) =>
      db.customStatement('DELETE FROM shortcut_rules WHERE id = ?', [id]);
}
