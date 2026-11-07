import 'dart:io';

import 'package:beecount/data/db.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

// Exercises the production migration callback, including injected failure.
class _FailingMigrationDatabase extends BeeDatabase {
  bool failUpgrade = false;
  _FailingMigrationDatabase() : super.forTesting(NativeDatabase.memory());

  @override
  Future<void> customStatement(String statement, [List<Object?>? args]) {
    if (failUpgrade && statement.contains('idx_rate_override_pair')) {
      throw StateError('injected migration failure');
    }
    return super.customStatement(statement, args);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<Map<String, String>> indexes(BeeDatabase db) async {
    final rows = await db.customSelect(
      "SELECT name, sql FROM sqlite_master WHERE type = 'index' "
      "AND name LIKE 'idx_%' ORDER BY name",
    ).get();
    return {for (final r in rows) r.read<String>('name'): r.read<String>('sql')};
  }

  test('fresh and v35 databases have identical indexes and preserve data', () async {
    final dir = await Directory.systemTemp.createTemp('beecount-migrate-');
    final file = File('${dir.path}/v35.sqlite');
    BeeDatabase? upgraded;
    final fresh = BeeDatabase.forTesting(NativeDatabase.memory());
    try {
      final expected = await indexes(fresh);
      expect(expected, hasLength(13));
      final seed = BeeDatabase.forTesting(NativeDatabase(file));
      await seed.customStatement(
          "INSERT INTO ledgers(id, name, currency) VALUES(1, 'old', 'CNY')");
      await seed.customStatement(
          "INSERT INTO transactions(ledger_id, type, amount, note) "
          "VALUES(1, 'expense', 12, 'preserve')");
      await seed.close();
      // Recreate the v35 fresh-install condition: tables but no secondary indexes.
      final raw = sqlite.sqlite3.open(file.path);
      for (final name in expected.keys) {
        raw.execute('DROP INDEX IF EXISTS $name');
      }
      raw.execute('PRAGMA user_version = 35');
      raw.dispose();
      upgraded = BeeDatabase.forTesting(NativeDatabase(file));
      expect(await indexes(upgraded), expected);
      expect((await upgraded.select(upgraded.transactions).get()).single.note,
          'preserve');
      expect((await upgraded.customSelect('PRAGMA user_version').getSingle())
          .read<int>('user_version'), 36);
    } finally {
      await upgraded?.close();
      await fresh.close();
      await dir.delete(recursive: true);
    }
  });

  test('interrupted v27 state can rerun the production upgrade callback', () async {
    final db = BeeDatabase.forTesting(NativeDatabase.memory());
    try {
      await db.customStatement(
          "INSERT INTO ledgers(id, name, currency, month_start_day) "
          "VALUES(1, 'partial', 'CNY', 15)");
      // Model old partial state: month_start_day already added, old version kept.
      await db.migration.onUpgrade!(db.createMigrator(), 26, 36);
      expect((await db.select(db.ledgers).get()).single.monthStartDay, 15);
      expect(await indexes(db), hasLength(13));
    } finally {
      await db.close();
    }
  });

  test('DDL rolls back if a later upgrade statement fails; retry succeeds', () async {
    final db = _FailingMigrationDatabase();
    try {
      await db.customStatement(
          "INSERT INTO ledgers(id, name, currency) VALUES(1, 'old', 'CNY')");
      await db.customStatement('ALTER TABLE ledgers DROP COLUMN month_start_day');
      await db.customStatement('PRAGMA user_version = 26');
      db.failUpgrade = true;
      await expectLater(
        db.migration.onUpgrade!(db.createMigrator(), 26, 36),
        throwsStateError,
      );
      final columns = await db.customSelect('PRAGMA table_info(ledgers)').get();
      expect(columns.map((r) => r.read<String>('name')),
          isNot(contains('month_start_day')));
      expect((await db.customSelect('PRAGMA user_version').getSingle())
          .read<int>('user_version'), 26);
      db.failUpgrade = false;
      await db.migration.onUpgrade!(db.createMigrator(), 26, 36);
      expect((await db.select(db.ledgers).get()).single.monthStartDay, 1);
      expect((await db.customSelect('PRAGMA user_version').getSingle())
          .read<int>('user_version'), 36);
    } finally {
      await db.close();
    }
  });
}
