import 'package:beecount/data/db.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late BeeDatabase db;
  setUp(() { SharedPreferences.setMockInitialValues({});
    db = BeeDatabase.forTesting(NativeDatabase.memory()); });
  tearDown(() async => db.close());

  test('cleanup runs after outer commit, not after a nested savepoint', () async {
    final seen = <String>[];
    await db.transaction(() async {
      await db.customStatement(
          "INSERT INTO ledgers(id, name, currency) VALUES(1, 'saved', 'CNY')");
      await db.transaction(() async {
        await db.afterSuccessfulTransaction(() async {
          seen.add((await db.select(db.ledgers).get()).single.name);
        });
      });
      expect(seen, isEmpty);
    });
    expect(seen, ['saved']);
  });

  test('outer rollback discards cleanup registered in successful child', () async {
    var calls = 0;
    await expectLater(db.transaction(() async {
      await db.transaction(() => db.afterSuccessfulTransaction(() async { calls++; }));
      throw StateError('rollback');
    }), throwsStateError);
    expect(calls, 0);
  });

  test('failed child discards its cleanup but parent can commit', () async {
    final seen = <String>[];
    await db.transaction(() async {
      try {
        await db.transaction(() async {
          await db.afterSuccessfulTransaction(() async { seen.add('child'); });
          throw StateError('rollback child');
        });
      } on StateError {
        // Intentionally recover and commit the outer transaction.
      }
      await db.afterSuccessfulTransaction(() async { seen.add('parent'); });
    });
    expect(seen, ['parent']);
  });

  test('cleanup failure does not turn a committed write into an error', () async {
    await db.transaction(() async {
      await db.customStatement(
          "INSERT INTO ledgers(id, name, currency) VALUES(1, 'saved', 'CNY')");
      await db.afterSuccessfulTransaction(() async { throw StateError('cleanup'); });
    });
    expect((await db.select(db.ledgers).get()).single.name, 'saved');
  });
}
