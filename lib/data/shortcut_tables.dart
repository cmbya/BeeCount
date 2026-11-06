/// These local tables share the database and transaction of formal rows.
/// Full database backups retain them. CSV/entity sync contain formal rows only.
const shortcutTablesSql = [
  'CREATE TABLE IF NOT EXISTS shortcut_receipts ('
      'request_id TEXT PRIMARY KEY, digest TEXT NOT NULL, result_json TEXT NOT NULL, '
      'created_at INTEGER NOT NULL)',
  'CREATE TABLE IF NOT EXISTS shortcut_groups ('
      'request_id TEXT PRIMARY KEY, original_amount_minor INTEGER NOT NULL, '
      'currency TEXT NOT NULL, transaction_sync_ids TEXT NOT NULL)',
  'CREATE TABLE IF NOT EXISTS shortcut_rules ('
      'id TEXT PRIMARY KEY, name TEXT NOT NULL, enabled INTEGER NOT NULL, '
      'ledger_id INTEGER, field TEXT NOT NULL, match_mode TEXT NOT NULL, '
      'keyword TEXT NOT NULL, category_id INTEGER NOT NULL, priority INTEGER NOT NULL)',
];

/// Progress of confirmed/committed parts only. Never contains editable notes.
const shortcutProgressiveTablesSql = [
  'CREATE TABLE IF NOT EXISTS shortcut_split_sessions ('
      'session_id TEXT PRIMARY KEY, ledger_id INTEGER NOT NULL, '
      'account_id INTEGER NOT NULL, currency TEXT NOT NULL, '
      'total_minor INTEGER NOT NULL, paid_minor INTEGER NOT NULL, '
      'saved_count INTEGER NOT NULL)',
];
