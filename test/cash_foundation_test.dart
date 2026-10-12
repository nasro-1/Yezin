import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:bayaa_pos/core/data/services/canonical_cash_posting_service.dart';
import 'package:bayaa_pos/core/data/services/sqlite_manager.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late SQLiteManager manager;
  late CanonicalCashPostingService cash;
  late String databasePath;

  setUp(() async {
    databasePath =
        'cash_foundation_${DateTime.now().microsecondsSinceEpoch}.sqlite';
    manager = SQLiteManager(databasePath: databasePath);
    await manager.initialize();
    await manager.insert('users', {
      'id': 'cash-user',
      'username': 'cash-user',
      'display_name': 'Cash User',
      'password_hash': 'test',
      'role': 'manager',
      'created_at': DateTime.now().toIso8601String(),
    });
    cash = CanonicalCashPostingService();
  });

  tearDown(() async {
    await manager.close();
    for (final suffix in ['', '-wal', '-shm']) {
      final file = File('$databasePath$suffix');
      if (file.existsSync()) file.deleteSync();
    }
  });

  Future<String> post({
    required String type,
    required double amount,
    String? key,
    String? referenceId,
  }) {
    return manager.transaction(
      (txn) => cash.postInTransaction(
        txn: txn,
        movementType: type,
        amount: amount,
        userId: 'cash-user',
        referenceType: 'test',
        referenceId: referenceId,
        idempotencyKey: key,
        description: type,
      ),
    );
  }

  test('cash movement signs and balance are authoritative', () async {
    await post(type: 'opening_balance', amount: 1000);
    await post(type: 'sale_cash', amount: 200, referenceId: 'sale-1');
    await post(
        type: 'customer_payment_cash', amount: 100, referenceId: 'payment-1');
    await post(
        type: 'supplier_payment_cash', amount: -150, referenceId: 'payment-2');
    await post(type: 'expense_cash', amount: -50, referenceId: 'expense-1');
    await post(
        type: 'customer_refund_cash', amount: -40, referenceId: 'refund-1');

    final rows = await manager.query(
      'cash_movements',
      columns: ['COUNT(*) AS count', 'SUM(amount) AS balance'],
    );
    expect(rows.single['count'], 6);
    expect((rows.single['balance'] as num).toDouble(), 1060);
    expect(
      await manager.query(
        'activity_logs',
        where: 'type = ?',
        whereArgs: ['cashMovement'],
      ),
      hasLength(6),
    );
  });

  test('credit-neutral movement types are not posted by the cash service',
      () async {
    expect(
      () => post(type: 'sale_cash', amount: 0),
      throwsA(isA<ArgumentError>()),
    );
    expect(
      () => post(type: 'customer_refund_cash', amount: 10),
      throwsA(isA<ArgumentError>()),
    );
    expect(
      () => post(type: 'unknown', amount: 10),
      throwsA(isA<ArgumentError>()),
    );
    expect(await manager.query('cash_movements'), isEmpty);
  });

  test('idempotency returns one movement and retry after rollback succeeds',
      () async {
    final first = await post(
      type: 'sale_cash',
      amount: 25,
      key: 'sale:same:cash',
      referenceId: 'same',
    );
    final duplicate = await post(
      type: 'sale_cash',
      amount: 25,
      key: 'sale:same:cash',
      referenceId: 'same',
    );
    expect(duplicate, first);
    expect(await manager.query('cash_movements'), hasLength(1));

    expect(
      () => manager.transaction((txn) async {
        await cash.postInTransaction(
          txn: txn,
          movementType: 'sale_cash',
          amount: 10,
          idempotencyKey: 'rollback:key',
          description: 'rollback',
        );
        throw StateError('forced failure');
      }),
      throwsA(isA<StateError>()),
    );
    await post(type: 'sale_cash', amount: 10, key: 'rollback:key');
    expect(await manager.query('cash_movements'), hasLength(2));
  });

  test('cash movements are immutable at the database layer', () async {
    final id = await post(type: 'opening_balance', amount: 100);
    expect(
      () => manager.update(
        'cash_movements',
        {'amount': 999},
        where: 'id = ?',
        whereArgs: [id],
      ),
      throwsA(isA<DatabaseException>()),
    );
    expect(
      () => manager.delete(
        'cash_movements',
        where: 'id = ?',
        whereArgs: [id],
      ),
      throwsA(isA<DatabaseException>()),
    );
    final row = (await manager.query('cash_movements')).single;
    expect(row['amount'], 100);
  });

  test('default register is deterministic and seeded once', () async {
    expect(await manager.query('cash_registers'), hasLength(1));
    await manager.database.rawInsert(
      "INSERT OR IGNORE INTO cash_registers "
      "(id, name, code, is_active, created_at, updated_at) "
      "VALUES (?, ?, ?, 1, ?, ?)",
      [
        CanonicalCashPostingService.defaultRegisterId,
        'Main Register',
        'MAIN',
        DateTime.now().toIso8601String(),
        DateTime.now().toIso8601String(),
      ],
    );
    expect(await manager.query('cash_registers'), hasLength(1));
  });

  test('cash schema includes constraints, indexes, and immutability triggers',
      () async {
    final objects = await manager.database.rawQuery(
      "SELECT type, name FROM sqlite_master "
      "WHERE name IN (?, ?, ?, ?)",
      [
        'cash_registers',
        'cash_movements',
        'cash_movements_no_update',
        'cash_movements_no_delete',
      ],
    );
    expect(objects.map((row) => row['name']),
        containsAll(<String>['cash_registers', 'cash_movements']));
    expect(
        objects.map((row) => row['name']),
        containsAll(<String>[
          'cash_movements_no_update',
          'cash_movements_no_delete',
        ]));

    final indexes = await manager.database.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'index' "
      "AND name IN (?, ?)",
      [
        'idx_cash_movements_register_date',
        'idx_cash_movements_reference',
      ],
    );
    expect(indexes, hasLength(2));

    final foreignKeys = await manager.database
        .rawQuery('PRAGMA foreign_key_list(cash_movements)');
    expect(foreignKeys.map((row) => row['table']),
        containsAll(<String>['cash_registers', 'shifts', 'users']));
  });

  test('expense payment method does not assume cash for legacy-shaped rows',
      () async {
    await manager.insert('expenses', {
      'id': 'legacy-expense',
      'title': 'Legacy expense',
      'amount': 12,
      'category': 'operations',
      'created_at': DateTime.now().toIso8601String(),
    });
    final row = (await manager.query(
      'expenses',
      where: 'id = ?',
      whereArgs: ['legacy-expense'],
    ))
        .single;
    expect(row['payment_method'], 'unknown');
  });
}
