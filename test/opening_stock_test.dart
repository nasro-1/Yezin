import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:bayaa_pos/core/data/services/sqlite_manager.dart';
import 'package:bayaa_pos/core/security/permission_guard.dart';
import 'package:bayaa_pos/features/auth/data/models/user_model.dart';
import 'package:bayaa_pos/features/stock/data/models/opening_stock_model.dart';
import 'package:bayaa_pos/features/stock/data/repository/opening_stock_repository.dart';
import 'package:bayaa_pos/features/stock/services/opening_stock_service.dart';

void main() {
  late SQLiteManager manager;
  late Directory databaseDirectory;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    databaseDirectory =
        await Directory.systemTemp.createTemp('bayaa_opening_stock_');
    manager = SQLiteManager(
      databasePath: p.join(databaseDirectory.path, 'opening_stock.sqlite'),
    );
    await manager.initialize();
    await manager.insert('products', {
      'id': 'p-1',
      'barcode': '1001',
      'name': 'Test product',
      'price': 10.0,
      'created_at': DateTime.now().toIso8601String(),
      'updated_at': DateTime.now().toIso8601String(),
    });
  });

  tearDown(() async {
    await manager.close();
    await databaseDirectory.delete(recursive: true);
  });

  User managerUser() => User(
        username: 'manager',
        name: 'Test Manager',
        phone: '',
        password: '',
        userType: UserType.manager,
      );

  test('posts opening stock through canonical movement and writes audit atomically',
      () async {
    final service = OpeningStockService(sqliteManager: manager);

    final document = await service.post(
      user: managerUser(),
      reason: 'Initial inventory count',
      notes: 'Initial count',
      lines: const [
        OpeningStockLineInput(productId: 'p-1', quantity: 12),
      ],
    );

    expect(document.status, OpeningStockStatus.posted);
    expect(document.referenceNumber, startsWith('OS-'));
    expect(
      (await manager.query('products', where: 'id = ?', whereArgs: ['p-1']))
          .single['stock'],
      12.0,
    );
    expect(
      (await manager.query(
        'stock_movements',
        where: 'reference_id = ?',
        whereArgs: [document.id],
      )),
      hasLength(1),
    );
    expect(
      (await manager.query(
        'opening_stock_lines',
        where: 'document_id = ?',
        whereArgs: [document.id],
      )),
      hasLength(1),
    );
    final audit = await manager.query(
      'activity_logs',
      where: 'event_key = ?',
      whereArgs: ['openingStockPosted'],
    );
    expect(audit, hasLength(1));
    expect(audit.single['type'], 'openingStockPosted');

    final history =
        await OpeningStockRepository(sqliteManager: manager).getPostedDocuments();
    expect(history, hasLength(1));
    expect(history.single.lines.single.quantity, 12);
    expect(history.single.status, OpeningStockStatus.posted);
  });

  test('rejects cashier before opening stock transaction starts', () async {
    final service = OpeningStockService(sqliteManager: manager);
    final cashier = User(
      username: 'cashier',
      name: 'Cashier',
      phone: '',
      password: '',
      userType: UserType.cashier,
    );

    expect(
      () => service.post(
        user: cashier,
        lines: const [
          OpeningStockLineInput(productId: 'p-1', quantity: 1),
        ],
      ),
      throwsA(isA<PermissionDeniedException>()),
    );
    expect(await manager.query('opening_stock_documents'), isEmpty);
  });

  test('rolls back document, movement, audit, and stock when a line fails',
      () async {
    final service = OpeningStockService(sqliteManager: manager);

    expect(
      () => service.post(
        user: managerUser(),
        reason: 'Initial inventory count',
        lines: const [
          OpeningStockLineInput(productId: 'p-1', quantity: 5),
          OpeningStockLineInput(productId: 'missing', quantity: 2),
        ],
      ),
      throwsA(isA<StateError>()),
    );
    expect(await manager.query('opening_stock_documents'), isEmpty);
    expect(await manager.query('opening_stock_lines'), isEmpty);
    expect(await manager.query('stock_movements'), isEmpty);
    expect(
      (await manager.query('products', where: 'id = ?', whereArgs: ['p-1']))
          .single['stock'],
      0.0,
    );
    expect(await manager.query('activity_logs'), isEmpty);
  });

  test('rejects duplicate products and non-positive quantities', () async {
    final service = OpeningStockService(sqliteManager: manager);

    expect(
      () => service.post(
        user: managerUser(),
        lines: const [
          OpeningStockLineInput(productId: 'p-1', quantity: 1),
          OpeningStockLineInput(productId: 'p-1', quantity: 2),
        ],
      ),
      throwsArgumentError,
    );
    expect(
      () => service.post(
        user: managerUser(),
        lines: const [
          OpeningStockLineInput(productId: 'p-1', quantity: 0),
        ],
      ),
      throwsArgumentError,
    );
  });

  test('prevents duplicate posting, references, and movement/audit rows',
      () async {
    final service = OpeningStockService(sqliteManager: manager);
    final document = await service.post(
      user: managerUser(),
      reason: 'Initial inventory count',
      lines: const [
        OpeningStockLineInput(productId: 'p-1', quantity: 10),
      ],
    );

    final stockBefore = (await manager.query(
      'products',
      columns: ['stock'],
      where: 'id = ?',
      whereArgs: ['p-1'],
    )).single['stock'];
    expect(stockBefore, 10.0);

    expect(
      () => manager.transaction((txn) async {
        await txn.insert('opening_stock_documents', {
          'id': 'duplicate-document',
          'reference_number': document.referenceNumber,
          'status': 'posted',
          'opening_date': document.openingDate.toIso8601String(),
          'reason': document.reason,
          'posted_at': document.postedAt.toIso8601String(),
          'posted_by': document.postedBy,
          'created_at': document.createdAt.toIso8601String(),
        });
      }),
      throwsA(isA<DatabaseException>()),
    );

    expect(
      () => manager.transaction((txn) async {
        await txn.insert('stock_movements', {
          'id': '${document.id}_p-1',
          'product_id': 'p-1',
          'product_name': 'Test product',
          'movement_type': 'opening_stock',
          'quantity_change': 10.0,
          'running_stock': 20.0,
          'reference_type': 'opening_stock',
          'reference_id': document.id,
          'created_at': DateTime.now().toIso8601String(),
        });
      }),
      throwsA(isA<DatabaseException>()),
    );

    expect(
      (await manager.query('products', where: 'id = ?', whereArgs: ['p-1']))
          .single['stock'],
      stockBefore,
    );
    expect(
      await manager.query('stock_movements',
          where: 'reference_id = ?', whereArgs: [document.id]),
      hasLength(1),
    );
    expect(
      await manager.query('activity_logs',
          where: 'event_key = ?', whereArgs: ['openingStockPosted']),
      hasLength(1),
    );
    expect(
      (await manager.query('opening_stock_documents',
              where: 'id = ?', whereArgs: [document.id]))
          .single['status'],
      'posted',
    );
  });

  test('posted opening stock is immutable and cannot be deleted', () async {
    final service = OpeningStockService(sqliteManager: manager);
    final document = await service.post(
      user: managerUser(),
      openingDate: DateTime(2026, 9, 1),
      reason: 'Initial inventory count',
      notes: 'Counted',
      lines: const [
        OpeningStockLineInput(productId: 'p-1', quantity: 10),
      ],
    );

    for (final update in [
      {'quantity': 20.0},
      {'product_id': 'other-product'},
      {'reason': 'Changed'},
      {'opening_date': DateTime(2026, 9, 2).toIso8601String()},
    ]) {
      expect(
        () => manager.update(
          'opening_stock_documents',
          update,
          where: 'id = ?',
          whereArgs: [document.id],
        ),
        throwsA(isA<DatabaseException>()),
      );
    }
    expect(
      () => manager.delete('opening_stock_documents',
          where: 'id = ?', whereArgs: [document.id]),
      throwsA(isA<DatabaseException>()),
    );
    expect(
      () => manager.update(
        'opening_stock_lines',
        {'quantity': 99.0, 'product_id': 'other-product'},
        where: 'document_id = ?',
        whereArgs: [document.id],
      ),
      throwsA(isA<DatabaseException>()),
    );
    expect(
      () => manager.delete('opening_stock_lines',
          where: 'document_id = ?', whereArgs: [document.id]),
      throwsA(isA<DatabaseException>()),
    );
  });

  test('multi-line failure leaves stock, audit, and accounting unchanged',
      () async {
    await manager.insert('products', {
      'id': 'p-2',
      'barcode': '1002',
      'name': 'Second product',
      'price': 10.0,
      'created_at': DateTime.now().toIso8601String(),
      'updated_at': DateTime.now().toIso8601String(),
    });
    final service = OpeningStockService(sqliteManager: manager);
    final before = <String, int>{
      for (final table in [
        'purchases',
        'supplier_ledger',
        'customer_ledger',
        'sales',
        'activity_logs',
        'stock_movements',
      ])
        table: (await manager.query(table)).length,
    };

    expect(
      () => service.post(
        user: managerUser(),
        reason: 'Initial inventory count',
        lines: const [
          OpeningStockLineInput(productId: 'p-1', quantity: 10),
          OpeningStockLineInput(productId: 'p-2', quantity: 20),
          OpeningStockLineInput(productId: 'missing', quantity: 1),
        ],
      ),
      throwsA(isA<StateError>()),
    );

    expect(
      (await manager.query('products', where: 'id = ?', whereArgs: ['p-1']))
          .single['stock'],
      0.0,
    );
    expect(
      (await manager.query('products', where: 'id = ?', whereArgs: ['p-2']))
          .single['stock'],
      0.0,
    );
    expect(await manager.query('opening_stock_documents'), isEmpty);
    expect(await manager.query('opening_stock_lines'), isEmpty);
    for (final entry in before.entries) {
      expect((await manager.query(entry.key)).length, entry.value);
    }
  });

  test('posting preserves existing reconciliation baseline', () async {
    await manager.insert('stock_movements', {
      'id': 'historical-p-1',
      'product_id': 'p-1',
      'product_name': 'Test product',
      'movement_type': 'purchase',
      'quantity_change': 5.0,
      'running_stock': 5.0,
      'reference_type': 'purchase',
      'reference_id': 'historical',
      'created_at': DateTime.now().toIso8601String(),
    });
    final service = OpeningStockService(sqliteManager: manager);
    await service.post(
      user: managerUser(),
      reason: 'Initial inventory count',
      lines: const [
        OpeningStockLineInput(productId: 'p-1', quantity: 10),
      ],
    );

    expect(
      (await manager.query('products', where: 'id = ?', whereArgs: ['p-1']))
          .single['stock'],
      10.0,
    );
    expect(
      (await manager.query('stock_movements',
              where: 'product_id = ?', whereArgs: ['p-1']))
          .map((row) => row['quantity_change']),
      containsAll(<double>[5.0, 10.0]),
    );
  });
}
