import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:bayaa_pos/core/data/services/sqlite_manager.dart';
import 'package:bayaa_pos/core/security/permission_guard.dart';
import 'package:bayaa_pos/features/auth/data/models/user_model.dart';
import 'package:bayaa_pos/features/stock/data/models/stock_adjustment_model.dart';
import 'package:bayaa_pos/features/stock/data/repository/stock_adjustment_repository.dart';
import 'package:bayaa_pos/features/stock/data/repository/stock_movement_repository.dart';
import 'package:bayaa_pos/features/stock/services/stock_adjustment_service.dart';

void main() {
  late SQLiteManager manager;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    manager = SQLiteManager(databasePath: ':memory:');
    await manager.initialize();
    await manager.insert('products', {
      'id': 'p-1',
      'barcode': '1001',
      'name': 'Test product',
      'price': 10.0,
      'stock': 10.0,
      'created_at': DateTime.now().toIso8601String(),
      'updated_at': DateTime.now().toIso8601String(),
    });
    await manager.insert('products', {
      'id': 'p-2',
      'barcode': '1002',
      'name': 'Second product',
      'price': 10.0,
      'stock': 4.0,
      'created_at': DateTime.now().toIso8601String(),
      'updated_at': DateTime.now().toIso8601String(),
    });
  });

  tearDown(() => manager.close());

  User managerUser() => User(
        username: 'manager',
        name: 'Test Manager',
        phone: '',
        password: '',
        userType: UserType.manager,
      );

  User adminUser() => User(
        username: 'admin',
        name: 'Test Admin',
        phone: '',
        password: '',
        userType: UserType.admin,
      );

  test('posts positive and negative counted deltas atomically', () async {
    final document = await StockAdjustmentService(sqliteManager: manager).post(
      idempotencyKey: 'positive-negative',
      user: managerUser(),
      adjustmentDate: DateTime(2026, 9, 5),
      reason: 'Cycle count',
      lines: const [
        StockAdjustmentLineInput(
          productId: 'p-1',
          countedQuantity: 13,
          unitCost: 200,
        ),
        StockAdjustmentLineInput(
          productId: 'p-2',
          countedQuantity: 2,
          unitCost: 210,
        ),
      ],
    );

    expect(document.referenceNumber, 'ADJ-2026-000001');
    expect(document.lines[0].currentQuantity, 10);
    expect(document.lines[0].delta, 3);
    expect(document.lines[1].delta, -2);
    expect(
        (await manager.query('products', where: 'id = ?', whereArgs: ['p-1']))
            .single['stock'],
        13.0);
    expect(
        (await manager.query('products', where: 'id = ?', whereArgs: ['p-2']))
            .single['stock'],
        2.0);
    expect(await manager.query('stock_adjustment_items'), hasLength(2));
    expect(
      await manager.query('stock_movements',
          where: 'reference_id = ?', whereArgs: [document.id]),
      hasLength(2),
    );
    expect(document.lines[0].unitCost, 200);
    expect(document.lines[1].unitCost, 210);
    expect(
      (await manager.query('stock_adjustment_items',
              where: 'document_id = ?', whereArgs: [document.id]))
          .map((row) => row['unit_cost']),
      containsAll([200.0, 210.0]),
    );
    expect(
      (await manager.query('stock_movements',
              where: 'reference_id = ?', whereArgs: [document.id]))
          .map((row) => row['unit_cost']),
      containsAll([200.0, 210.0]),
    );
    final audit = (await manager.query(
      'activity_logs',
      where: 'event_key = ?',
      whereArgs: ['stockAdjustmentPosted'],
    ))
        .single;
    expect(audit['description'], contains(document.referenceNumber));
    expect(audit['details'], contains('Cycle count'));
    final movement = (await manager.query(
      'stock_movements',
      where: 'reference_id = ? AND product_id = ?',
      whereArgs: [document.id, 'p-1'],
    ))
        .single;
    expect(movement['movement_type'], 'stock_adjustment');
    expect(movement['reference_type'], 'stock_adjustment');
    expect(movement['quantity_change'], 3.0);
    expect(movement['running_stock'], 13.0);
    expect(movement['id'], '${document.id}_p-1_movement');
  });

  test('supports initial inventory from zero stock', () async {
    await manager.update(
      'products',
      {'stock': 0.0},
      where: 'id = ?',
      whereArgs: ['p-1'],
    );
    final document = await StockAdjustmentService(sqliteManager: manager).post(
      idempotencyKey: 'initial-inventory',
      user: managerUser(),
      reason: 'Initial inventory',
      notes: 'Opening count recorded through Stock Adjustment',
      lines: const [
        StockAdjustmentLineInput(productId: 'p-1', countedQuantity: 50),
      ],
    );
    expect(document.lines.single.currentQuantity, 0);
    expect(document.lines.single.countedQuantity, 50);
    expect(document.lines.single.quantityChange, 50);
    expect(
        (await manager.query('products', where: 'id = ?', whereArgs: ['p-1']))
            .single['stock'],
        50.0);
    final movement = (await manager.query('stock_movements',
            where: 'reference_id = ?', whereArgs: [document.id]))
        .single;
    expect(movement['movement_type'], 'stock_adjustment');
    expect(movement['quantity_change'], 50.0);
  });

  test('reconciles packaged unit conversion across initial stock and mixed adjustments', () async {
    const productId = 'p-packaged-egg';
    await manager.insert('products', {
      'id': productId,
      'barcode': 'egg-packaged',
      'name': 'Eggs',
      'price': 0.0,
      'stock': 0.0,
      'created_at': DateTime.now().toIso8601String(),
      'updated_at': DateTime.now().toIso8601String(),
    });

    final service = StockAdjustmentService(sqliteManager: manager);
    final initial = await service.post(
      idempotencyKey: 'egg-initial',
      user: managerUser(),
      reason: 'Initial inventory',
      lines: const [
        StockAdjustmentLineInput(productId: productId, countedQuantity: 100),
      ],
    );
    expect(
        (await manager.query('products', where: 'id = ?', whereArgs: [productId]))
            .single['stock'],
        100.0);
    expect((await manager.query('stock_movements',
            where: 'reference_id = ?', whereArgs: [initial.id])).length,
        1);

    final pieceAdjust = await service.post(
      idempotencyKey: 'egg-remove-piece',
      user: managerUser(),
      reason: 'Damaged goods',
      lines: const [
        StockAdjustmentLineInput(productId: productId, countedQuantity: 90),
      ],
    );
    expect(pieceAdjust.lines.single.quantityChange, -10);
    expect(
        (await manager.query('products', where: 'id = ?', whereArgs: [productId]))
            .single['stock'],
        90.0);

    final packAdjust = await service.post(
      idempotencyKey: 'egg-add-pack',
      user: managerUser(),
      reason: 'Stock correction',
      lines: const [
        StockAdjustmentLineInput(productId: productId, countedQuantity: 130),
      ],
    );
    expect(packAdjust.lines.single.quantityChange, 40);
    expect(
        (await manager.query('products', where: 'id = ?', whereArgs: [productId]))
            .single['stock'],
        130.0);

    final boxAdjust = await service.post(
      idempotencyKey: 'egg-remove-box',
      user: managerUser(),
      reason: 'Damaged goods',
      lines: const [
        StockAdjustmentLineInput(productId: productId, countedQuantity: 70),
      ],
    );
    expect(boxAdjust.lines.single.quantityChange, -60);
    expect(
        (await manager.query('products', where: 'id = ?', whereArgs: [productId]))
            .single['stock'],
        70.0);

    final movements = await manager.query('stock_movements',
        where: 'product_id = ?', whereArgs: [productId]);
    expect(movements, hasLength(4));
    expect(movements.map((row) => row['quantity_change']).cast<num>().toList(),
        [100.0, -10.0, 40.0, -60.0]);
  });

  test('calculates a positive adjustment from the counted quantity', () async {
    await manager.update(
      'products',
      {'stock': 20.0},
      where: 'id = ?',
      whereArgs: ['p-1'],
    );
    final document = await StockAdjustmentService(sqliteManager: manager).post(
      idempotencyKey: 'counted-50',
      user: managerUser(),
      reason: 'Physical count',
      lines: const [
        StockAdjustmentLineInput(productId: 'p-1', countedQuantity: 50),
      ],
    );
    expect(document.lines.single.currentQuantity, 20);
    expect(document.lines.single.countedQuantity, 50);
    expect(document.lines.single.quantityChange, 30);
    expect(document.reason, 'Physical count');
  });

  test('calculates a negative adjustment from the counted quantity', () async {
    await manager.update(
      'products',
      {'stock': 20.0},
      where: 'id = ?',
      whereArgs: ['p-1'],
    );
    final document = await StockAdjustmentService(sqliteManager: manager).post(
      idempotencyKey: 'counted-15',
      user: managerUser(),
      reason: 'Damage',
      lines: const [
        StockAdjustmentLineInput(productId: 'p-1', countedQuantity: 15),
      ],
    );
    expect(document.lines.single.currentQuantity, 20);
    expect(document.lines.single.countedQuantity, 15);
    expect(document.lines.single.quantityChange, -5);
    expect(document.reason, 'Damage');
  });

  test('product stock history is limited to the selected product', () async {
    final service = StockAdjustmentService(sqliteManager: manager);
    await service.post(
      idempotencyKey: 'history-p1',
      user: managerUser(),
      reason: 'Physical count',
      lines: const [
        StockAdjustmentLineInput(productId: 'p-1', countedQuantity: 12),
      ],
    );
    await service.post(
      idempotencyKey: 'history-p2',
      user: managerUser(),
      reason: 'Physical count',
      lines: const [
        StockAdjustmentLineInput(productId: 'p-2', countedQuantity: 5),
      ],
    );

    final movements = await StockMovementRepository(sqliteManager: manager)
        .getProductMovements('p-1');
    expect(movements, hasLength(1));
    expect(movements.single.productId, 'p-1');
    expect(movements.single.movementType, 'stock_adjustment');
    expect(movements.single.notes, 'Physical count');
  });

  test('rejects cashier and zero deltas without mutation', () async {
    final service = StockAdjustmentService(sqliteManager: manager);
    final cashier = User(
      username: 'cashier',
      name: 'Cashier',
      phone: '',
      password: '',
      userType: UserType.cashier,
    );
    expect(
      () => service.post(
        idempotencyKey: 'cashier',
        user: cashier,
        lines: const [
          StockAdjustmentLineInput(productId: 'p-1', countedQuantity: 12),
        ],
      ),
      throwsA(isA<PermissionDeniedException>()),
    );
    expect(
      () => service.post(
        idempotencyKey: 'zero',
        user: managerUser(),
        reason: 'Cycle count',
        lines: const [
          StockAdjustmentLineInput(productId: 'p-1', countedQuantity: 10),
          StockAdjustmentLineInput(productId: 'p-2', countedQuantity: 6),
        ],
      ),
      throwsArgumentError,
    );
    expect(await manager.query('stock_adjustment_documents'), isEmpty);
    expect(await manager.query('stock_movements'), isEmpty);
    expect(
        (await manager.query('products', where: 'id = ?', whereArgs: ['p-1']))
            .single['stock'],
        10.0);
  });

  test('rolls back all rows when a later item cannot be posted', () async {
    final service = StockAdjustmentService(sqliteManager: manager);
    expect(
      () => service.post(
        idempotencyKey: 'rollback',
        user: managerUser(),
        reason: 'Cycle count',
        lines: const [
          StockAdjustmentLineInput(productId: 'p-1', countedQuantity: 12),
          StockAdjustmentLineInput(productId: 'missing', countedQuantity: 1),
        ],
      ),
      throwsA(isA<StateError>()),
    );
    expect(await manager.query('stock_adjustment_documents'), isEmpty);
    expect(await manager.query('stock_adjustment_items'), isEmpty);
    expect(await manager.query('stock_movements'), isEmpty);
    expect(await manager.query('activity_logs'), isEmpty);
  });

  test('rejects negative counted quantities before mutation', () async {
    final service = StockAdjustmentService(sqliteManager: manager);
    expect(
      () => service.post(
        idempotencyKey: 'negative-count',
        user: managerUser(),
        reason: 'Cycle count',
        lines: const [
          StockAdjustmentLineInput(productId: 'p-1', countedQuantity: -1),
        ],
      ),
      throwsArgumentError,
    );
    expect(await manager.query('stock_adjustment_documents'), isEmpty);
    expect(await manager.query('stock_movements'), isEmpty);
    expect(await manager.query('activity_logs'), isEmpty);
    expect(
        (await manager.query('products', where: 'id = ?', whereArgs: ['p-1']))
            .single['stock'],
        10.0);
  });

  test('rejects negative adjustment costs before mutation', () async {
    final service = StockAdjustmentService(sqliteManager: manager);
    expect(
      () => service.post(
        idempotencyKey: 'negative-cost',
        user: managerUser(),
        reason: 'Cycle count',
        lines: const [
          StockAdjustmentLineInput(
            productId: 'p-1',
            countedQuantity: 11,
            unitCost: -5,
          ),
        ],
      ),
      throwsArgumentError,
    );
    expect(await manager.query('stock_adjustment_documents'), isEmpty);
    expect(await manager.query('stock_movements'), isEmpty);
  });

  test('rejects duplicate products and inactive products atomically', () async {
    await manager.update(
      'products',
      {'is_active': 0},
      where: 'id = ?',
      whereArgs: ['p-2'],
    );
    final service = StockAdjustmentService(sqliteManager: manager);
    expect(
      () => service.post(
        idempotencyKey: 'duplicate-products',
        user: managerUser(),
        reason: 'Cycle count',
        lines: const [
          StockAdjustmentLineInput(productId: 'p-1', countedQuantity: 11),
          StockAdjustmentLineInput(productId: 'p-1', countedQuantity: 12),
        ],
      ),
      throwsArgumentError,
    );
    expect(
      () => service.post(
        idempotencyKey: 'inactive',
        user: managerUser(),
        reason: 'Cycle count',
        lines: const [
          StockAdjustmentLineInput(productId: 'p-2', countedQuantity: 3),
        ],
      ),
      throwsA(isA<StateError>()),
    );
    expect(await manager.query('stock_adjustment_documents'), isEmpty);
    expect(await manager.query('stock_adjustment_items'), isEmpty);
    expect(await manager.query('stock_movements'), isEmpty);
    expect(await manager.query('activity_logs'), isEmpty);
  });

  test('admin is allowed and blank reasons are rejected', () async {
    expect(
      () => StockAdjustmentService(sqliteManager: manager).post(
        idempotencyKey: 'blank-reason',
        user: adminUser(),
        reason: '   ',
        lines: const [
          StockAdjustmentLineInput(productId: 'p-1', countedQuantity: 11),
        ],
      ),
      throwsArgumentError,
    );
    final document = await StockAdjustmentService(sqliteManager: manager).post(
      idempotencyKey: 'admin',
      user: adminUser(),
      reason: 'Admin count',
      lines: const [
        StockAdjustmentLineInput(productId: 'p-1', countedQuantity: 11),
      ],
    );
    expect(document.status, StockAdjustmentStatus.posted);
  });

  test('duplicate references are rejected by the database', () async {
    final document = await StockAdjustmentService(sqliteManager: manager).post(
      idempotencyKey: 'duplicate-reference',
      user: managerUser(),
      reason: 'Cycle count',
      lines: const [
        StockAdjustmentLineInput(productId: 'p-1', countedQuantity: 11),
      ],
    );
    expect(
      () => manager.insert('stock_adjustment_documents', {
        'id': 'duplicate-id',
        'reference_number': document.referenceNumber,
        'idempotency_key': 'duplicate-reference-key',
        'status': 'posted',
        'adjustment_date': DateTime.now().toIso8601String(),
        'reason': 'Duplicate',
        'posted_at': DateTime.now().toIso8601String(),
        'posted_by': 'manager',
        'created_at': DateTime.now().toIso8601String(),
      }),
      throwsA(isA<DatabaseException>()),
    );
    expect(await manager.query('stock_adjustment_documents'), hasLength(1));
  });

  test('rejects the same logical request without a second mutation', () async {
    final service = StockAdjustmentService(sqliteManager: manager);
    final first = await service.post(
      idempotencyKey: 'same-request',
      user: managerUser(),
      reason: 'Physical count',
      lines: const [
        StockAdjustmentLineInput(productId: 'p-1', countedQuantity: 15),
      ],
    );
    expect(
      () => service.post(
        idempotencyKey: 'same-request',
        user: managerUser(),
        reason: 'Physical count',
        lines: const [
          StockAdjustmentLineInput(productId: 'p-1', countedQuantity: 15),
        ],
      ),
      throwsA(isA<StateError>()),
    );
    expect(await manager.query('stock_adjustment_documents'), hasLength(1));
    expect(await manager.query('stock_adjustment_items'), hasLength(1));
    expect(
      await manager.query('stock_movements',
          where: 'reference_id = ?', whereArgs: [first.id]),
      hasLength(1),
    );
    expect(
        await manager.query('activity_logs',
            where: 'event_key = ?', whereArgs: ['stockAdjustmentPosted']),
        hasLength(1));
    expect(
        (await manager.query('products', where: 'id = ?', whereArgs: ['p-1']))
            .single['stock'],
        15.0);
  });

  test('rejects a blank idempotency key before opening a transaction',
      () async {
    expect(
      () => StockAdjustmentService(sqliteManager: manager).post(
        idempotencyKey: '  ',
        user: managerUser(),
        reason: 'Physical count',
        lines: const [
          StockAdjustmentLineInput(productId: 'p-1', countedQuantity: 15),
        ],
      ),
      throwsArgumentError,
    );
    expect(await manager.query('stock_adjustment_documents'), isEmpty);
    expect(await manager.query('stock_movements'), isEmpty);
  });

  test('allows different logical requests with identical business values',
      () async {
    final service = StockAdjustmentService(sqliteManager: manager);
    await service.post(
      idempotencyKey: 'batch-a',
      user: managerUser(),
      reason: 'Physical count',
      lines: const [
        StockAdjustmentLineInput(productId: 'p-1', countedQuantity: 15),
      ],
    );
    await service.post(
      idempotencyKey: 'batch-b',
      user: managerUser(),
      reason: 'Physical count',
      lines: const [
        StockAdjustmentLineInput(productId: 'p-1', countedQuantity: 20),
      ],
    );
    expect(await manager.query('stock_adjustment_documents'), hasLength(2));
    expect(
        await manager.query('stock_movements',
            where: 'product_id = ?', whereArgs: ['p-1']),
        hasLength(2));
    expect(
        (await manager.query('products', where: 'id = ?', whereArgs: ['p-1']))
            .single['stock'],
        20.0);
  });

  test('failed request can be retried with the same idempotency key', () async {
    final service = StockAdjustmentService(sqliteManager: manager);
    expect(
      () => service.post(
        idempotencyKey: 'retryable',
        user: managerUser(),
        reason: 'Physical count',
        lines: const [
          StockAdjustmentLineInput(productId: 'p-1', countedQuantity: 15),
          StockAdjustmentLineInput(productId: 'missing', countedQuantity: 1),
        ],
      ),
      throwsA(isA<StateError>()),
    );
    expect(await manager.query('stock_adjustment_documents'), isEmpty);
    final document = await service.post(
      idempotencyKey: 'retryable',
      user: managerUser(),
      reason: 'Physical count',
      lines: const [
        StockAdjustmentLineInput(productId: 'p-1', countedQuantity: 15),
      ],
    );
    expect(document.referenceNumber, 'ADJ-2026-000001');
    expect(await manager.query('stock_adjustment_documents'), hasLength(1));
    expect(await manager.query('stock_movements'), hasLength(1));
    expect(await manager.query('activity_logs'), hasLength(1));
  });

  test('concurrent same-key requests produce one committed adjustment',
      () async {
    final service = StockAdjustmentService(sqliteManager: manager);
    final results = await Future.wait(
      [
        service.post(
          idempotencyKey: 'concurrent',
          user: managerUser(),
          reason: 'Physical count',
          lines: const [
            StockAdjustmentLineInput(productId: 'p-1', countedQuantity: 15),
          ],
        ),
        service.post(
          idempotencyKey: 'concurrent',
          user: managerUser(),
          reason: 'Physical count',
          lines: const [
            StockAdjustmentLineInput(productId: 'p-1', countedQuantity: 15),
          ],
        ),
      ].map((request) async {
        try {
          await request;
          return true;
        } on StateError {
          return false;
        }
      }),
    );
    expect(results.where((posted) => posted).length, 1);
    expect(await manager.query('stock_adjustment_documents'), hasLength(1));
    expect(await manager.query('stock_movements'), hasLength(1));
    expect(await manager.query('activity_logs'), hasLength(1));
    expect(
        (await manager.query('products', where: 'id = ?', whereArgs: ['p-1']))
            .single['stock'],
        15.0);
  });

  test('does not mutate accounting or ledger tables', () async {
    final tables = [
      'purchases',
      'purchase_items',
      'supplier_ledger',
      'customer_ledger',
      'sales',
      'sale_items',
      'supplier_payments',
      'customer_payments',
      'shifts',
      'expenses',
    ];
    final before = <String, int>{
      for (final table in tables) table: (await manager.query(table)).length,
    };
    await StockAdjustmentService(sqliteManager: manager).post(
      idempotencyKey: 'accounting-isolation',
      user: managerUser(),
      reason: 'Cycle count',
      lines: const [
        StockAdjustmentLineInput(productId: 'p-1', countedQuantity: 11),
      ],
    );
    for (final table in tables) {
      expect((await manager.query(table)).length, before[table]);
    }
  });

  test('preserves a pre-existing reconciliation difference', () async {
    await manager.update(
      'products',
      {'stock': 50.0},
      where: 'id = ?',
      whereArgs: ['p-1'],
    );
    await manager.insert('stock_movements', {
      'id': 'historical-p-1',
      'product_id': 'p-1',
      'product_name': 'Test product',
      'quantity_change': 30.0,
      'running_stock': 30.0,
      'movement_type': 'opening_stock',
      'reference_type': 'opening_stock',
      'reference_id': 'historical',
      'notes': 'Historical baseline',
      'user_id': 'system',
      'created_at': DateTime.now().toIso8601String(),
    });
    await StockAdjustmentService(sqliteManager: manager).post(
      idempotencyKey: 'reconciliation',
      user: managerUser(),
      reason: 'Cycle count',
      lines: const [
        StockAdjustmentLineInput(productId: 'p-1', countedQuantity: 55),
      ],
    );
    expect(
        (await manager.query('products', where: 'id = ?', whereArgs: ['p-1']))
            .single['stock'],
        55.0);
    final movements = await manager
        .query('stock_movements', where: 'product_id = ?', whereArgs: ['p-1']);
    expect(
      movements.fold<double>(
        0,
        (sum, row) => sum + (row['quantity_change'] as num).toDouble(),
      ),
      35.0,
    );
  });

  test('posted documents and items are immutable', () async {
    final document = await StockAdjustmentService(sqliteManager: manager).post(
      idempotencyKey: 'immutability',
      user: managerUser(),
      reason: 'Cycle count',
      lines: const [
        StockAdjustmentLineInput(productId: 'p-1', countedQuantity: 11),
      ],
    );

    expect(
      () => manager.update(
        'stock_adjustment_documents',
        {'reason': 'changed'},
        where: 'id = ?',
        whereArgs: [document.id],
      ),
      throwsA(isA<DatabaseException>()),
    );
    expect(
      () => manager.delete(
        'stock_adjustment_items',
        where: 'document_id = ?',
        whereArgs: [document.id],
      ),
      throwsA(isA<DatabaseException>()),
    );
    expect(
      () => manager.update(
        'stock_adjustment_items',
        {'counted_quantity': 99, 'delta': 99, 'product_id': 'p-2'},
        where: 'document_id = ?',
        whereArgs: [document.id],
      ),
      throwsA(isA<DatabaseException>()),
    );
    expect(
      () => manager.delete(
        'stock_adjustment_documents',
        where: 'id = ?',
        whereArgs: [document.id],
      ),
      throwsA(isA<DatabaseException>()),
    );
    final history = await StockAdjustmentRepository(sqliteManager: manager)
        .getPostedDocuments();
    expect(history.single.lines.single.countedQuantity, 11);
    expect(history.single.lines.single.quantityChange, 1);
    expect(history.single.lines.single.currentQuantity, 10);
  });
}
