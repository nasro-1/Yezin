import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:bayaa_pos/core/data/services/sqlite_manager.dart';
import 'package:bayaa_pos/core/data/services/document_number_service.dart';
import 'package:bayaa_pos/core/error/failure.dart';
import 'package:bayaa_pos/features/auth/data/models/user_model.dart';
import 'package:bayaa_pos/features/orders/data/models/order_model.dart';
import 'package:bayaa_pos/features/orders/data/models/proforma_model.dart';
import 'package:bayaa_pos/features/orders/data/repository/orders_proformas_repository.dart';

void main() {
  late SQLiteManager manager;
  late OrdersProformasRepository repository;
  final admin = User(
    username: 'admin',
    name: 'Admin',
    phone: '',
    password: '',
    userType: UserType.admin,
  );
  late String path;

  setUp(() async {
    path = 'm6_orders_test_${DateTime.now().microsecondsSinceEpoch}.sqlite';
    final file = File(path);
    if (file.existsSync()) file.deleteSync();
    manager = SQLiteManager(databasePath: path);
    await manager.initialize();
    await manager.insert('users', {
      'id': 'admin',
      'username': 'admin',
      'display_name': 'Admin',
      'password_hash': 'x',
      'role': 'admin',
      'created_at': DateTime.now().toIso8601String(),
    });
    await manager.insert('products', {
      'id': 'p1',
      'barcode': 'p1',
      'name': 'Phone',
      'price': 10.0,
      'stock': 5.0,
      'created_at': DateTime.now().toIso8601String(),
      'updated_at': DateTime.now().toIso8601String(),
    });
    await manager.insert('customers', {
      'id': 'c1',
      'code': 'c1',
      'name': 'Customer',
      'is_active': 1,
      'created_at': DateTime.now().toIso8601String(),
      'updated_at': DateTime.now().toIso8601String(),
    });
    repository = OrdersProformasRepository(database: manager.database);
  });

  tearDown(() async {
    await manager.close();
    final file = File(path);
    if (file.existsSync()) file.deleteSync();
    final wal = File('$path-wal');
    if (wal.existsSync()) wal.deleteSync();
    final shm = File('$path-shm');
    if (shm.existsSync()) shm.deleteSync();
  });

  Order order(String id) => Order(
        id: id,
        referenceNumber: 'ORD-$id',
        customerId: 'c1',
        orderDate: DateTime(2026),
        lines: const [
          OrderLine(
            productId: 'p1',
            productName: 'Phone',
            productBarcode: 'p1',
            quantity: 1,
            unitPrice: 10,
          ),
        ],
      );

  test('A: validates lifecycle transitions and manager authorization',
      () async {
    expect(
        OrdersProformasRepository.canTransition('draft', 'confirmed'), isTrue);
    expect(
        OrdersProformasRepository.canTransition('confirmed', 'draft'), isFalse);
    final cashier = User(
      username: 'cashier',
      name: 'Cashier',
      phone: '',
      password: '',
      userType: UserType.cashier,
    );
    final result = await repository.createOrder(order('unauthorized'), cashier);
    expect(result.isLeft(), isTrue);
    expect(result.fold((failure) => failure, (_) => null),
        isA<AuthorizationFailure>());
  });

  test('B: create, confirm and cancel never mutate stock or movements',
      () async {
    await repository.createOrder(order('lifecycle'), admin);
    expect((await manager.query('products')).single['stock'], 5.0);
    expect(await manager.query('stock_movements'), isEmpty);
    await repository.confirmOrder('lifecycle', admin);
    await repository.cancelOrder('lifecycle', admin);
    expect((await manager.query('products')).single['stock'], 5.0);
    expect(await manager.query('stock_movements'), isEmpty);
  });

  test('C: proforma conversion is atomic and cannot be repeated', () async {
    final result = await repository.createProforma(
      Proforma(
        id: 'pf1',
        referenceNumber: 'PF-1',
        customerId: 'c1',
        proformaDate: DateTime(2026),
        lines: const [
          ProformaLine(
            productId: 'p1',
            productName: 'Phone',
            productBarcode: 'p1',
            quantity: 1,
            unitPrice: 10,
          ),
        ],
      ),
      admin,
    );
    expect(result.isRight(), isTrue);
    await repository.confirmProforma('pf1', admin);
    final converted = await repository.convertProforma('pf1', admin);
    expect(converted.isRight(), isTrue);
    expect((await manager.query('products')).single['stock'], 4.0);
    expect((await manager.query('proformas')).single['status'], 'converted');
    expect((await manager.query('stock_movements')).length, 1);
    expect((await repository.convertProforma('pf1', admin)).isLeft(), isTrue);
    expect((await manager.query('sales')).length, 1);
  });

  test('D: conversion failure rolls back sale and status', () async {
    final document = await repository.createOrder(order('rollback'), admin);
    expect(document.isRight(), isTrue);
    await repository.confirmOrder('rollback', admin);
    await manager.update('products', {'stock': 0.0},
        where: 'id = ?', whereArgs: ['p1']);
    expect((await repository.convertOrder('rollback', admin)).isLeft(), isTrue);
    expect((await manager.query('orders')).single['status'], 'confirmed');
    expect(await manager.query('sales'), isEmpty);
    expect(await manager.query('stock_movements'), isEmpty);
  });

  test(
      'E: conversion rolls back after sale, stock, movement and ledger mutations',
      () async {
    final document = await repository.createProforma(
      Proforma(
        id: 'rollback-after-mutations',
        referenceNumber: 'PF-ROLLBACK',
        customerId: 'c1',
        proformaDate: DateTime(2026),
        lines: const [
          ProformaLine(
            productId: 'p1',
            productName: 'Phone',
            productBarcode: 'p1',
            quantity: 1,
            unitPrice: 10,
          ),
        ],
      ),
      admin,
    );
    expect(document.isRight(), isTrue);
    await repository.confirmProforma('rollback-after-mutations', admin);
    await manager.insert('customer_ledger', {
      'id': 'baseline-ledger',
      'customer_id': 'c1',
      'entry_type': 'sale',
      'amount': 100.0,
      'balance_after': 100.0,
      'reference_type': 'sale',
      'reference_id': 'baseline',
      'created_at': DateTime.now().toIso8601String(),
    });
    final failingRepository = OrdersProformasRepository(
      database: manager.database,
      failureInjector: (_) async =>
          throw StateError('injected conversion failure'),
    );

    expect(
        (await failingRepository.convertProforma(
                'rollback-after-mutations', admin))
            .isLeft(),
        isTrue);
    expect((await manager.query('products')).single['stock'], 5.0);
    expect(await manager.query('sales'), isEmpty);
    expect(await manager.query('sale_items'), isEmpty);
    expect(await manager.query('stock_movements'), isEmpty);
    expect((await manager.query('customer_ledger')).length, 1);
    expect((await manager.query('proformas')).single['status'], 'confirmed');
    expect(
        (await manager.query('proformas')).single['converted_sale_id'], isNull);
    expect(
        await manager.query('activity_logs',
            where: 'type = ?', whereArgs: ['proformaConverted']),
        isEmpty);
  });

  test('F: rejects missing customers and duplicate references', () async {
    final missingCustomer = await repository.createOrder(
      Order(
        id: 'missing-customer',
        referenceNumber: 'ORD-MISSING-CUSTOMER',
        customerId: 'missing',
        orderDate: DateTime(2026),
        lines: const [
          OrderLine(
            productId: 'p1',
            productName: 'Phone',
            productBarcode: 'p1',
            quantity: 1,
            unitPrice: 10,
          ),
        ],
      ),
      admin,
    );
    expect(missingCustomer.isLeft(), isTrue);
    await repository.createOrder(order('reference-one'), admin);
    final duplicate = await repository.createOrder(
      Order(
        id: 'reference-two',
        referenceNumber: 'ORD-reference-one',
        customerId: 'c1',
        orderDate: DateTime(2026),
        lines: order('reference-two').lines,
      ),
      admin,
    );
    expect(duplicate.isLeft(), isTrue);
    expect(await manager.query('orders'), hasLength(1));
  });

  test('Central document sequences roll back and persist committed numbers',
      () async {
    String? failedNumber;
    try {
      await manager.transaction((txn) async {
        failedNumber = await DocumentNumberService.next(
          txn,
          sequenceKey: 'verification',
          prefix: 'TST',
          year: '2026',
        );
        throw StateError('rollback');
      });
    } catch (_) {}
    expect(failedNumber, 'TST-2026-000001');

    final committed = await manager.transaction((txn) {
      return DocumentNumberService.next(
        txn,
        sequenceKey: 'verification',
        prefix: 'TST',
        year: '2026',
      );
    });
    expect(committed, 'TST-2026-000001');

    final afterRestart = SQLiteManager(databasePath: path);
    await manager.close();
    await afterRestart.initialize();
    final next = await afterRestart.transaction((txn) {
      return DocumentNumberService.next(
        txn,
        sequenceKey: 'verification',
        prefix: 'TST',
        year: '2026',
      );
    });
    expect(next, 'TST-2026-000002');
    await afterRestart.close();
    manager = SQLiteManager(databasePath: path);
    await manager.initialize();
  });

  test('G: confirmed history cannot be edited or deleted', () async {
    await repository.createOrder(order('immutable'), admin);
    await repository.confirmOrder('immutable', admin);
    expect(
      () => manager.update('orders', {'total': 99.0},
          where: 'id = ?', whereArgs: ['immutable']),
      throwsA(isA<Exception>()),
    );
    expect(
      () => manager.delete('orders', where: 'id = ?', whereArgs: ['immutable']),
      throwsA(isA<Exception>()),
    );
  });

  test('H: invalid document lines are rejected before persistence', () async {
    final invalid = Order(
      id: 'invalid',
      referenceNumber: 'ORD-invalid',
      orderDate: DateTime(2026),
      lines: const [
        OrderLine(
          productId: 'p1',
          productName: 'Phone',
          productBarcode: 'p1',
          quantity: 0,
          unitPrice: 10,
        ),
      ],
    );
    final result = await repository.createOrder(invalid, admin);
    expect(result.isLeft(), isTrue);
    expect(await manager.query('orders'), isEmpty);
  });

  test('I: queries match reference and customer name and filter status',
      () async {
    await repository.createOrder(order('searchable'), admin);
    final byReference = await repository.getOrders(search: 'ORD-searchable');
    expect(byReference.fold((_) => <Order>[], (value) => value), hasLength(1));
    final byCustomer = await repository.getOrders(search: 'Customer');
    expect(byCustomer.fold((_) => <Order>[], (value) => value), hasLength(1));
    await repository.confirmOrder('searchable', admin);
    final drafts = await repository.getOrders(status: OrderStatus.draft);
    expect(drafts.fold((_) => <Order>[], (value) => value), isEmpty);
    final confirmed = await repository.getOrders(status: OrderStatus.confirmed);
    expect(confirmed.fold((_) => <Order>[], (value) => value), hasLength(1));
    final outsideDate = await repository.getOrders(from: DateTime(2026, 2));
    expect(outsideDate.fold((_) => <Order>[], (value) => value), isEmpty);
  });

  test('J: draft update replaces customer, lines and notes without ledgers',
      () async {
    await repository.createOrder(order('editable'), admin);
    final updated = Order(
      id: 'editable',
      referenceNumber: 'ORD-EDITED',
      customerId: 'c1',
      orderDate: DateTime(2026, 2),
      notes: 'updated note',
      lines: const [
        OrderLine(
          productId: 'p1',
          productName: 'Phone',
          productBarcode: 'p1',
          quantity: 2,
          unitPrice: 12,
        ),
      ],
    );
    expect(
        (await repository.updateOrderDraft(updated, admin)).isRight(), isTrue);
    final row = (await manager.query('orders')).single;
    expect(row['reference_number'], 'ORD-EDITED');
    expect(row['total'], 24.0);
    expect((await manager.query('order_items')).single['quantity'], 2.0);
    expect(await manager.query('stock_movements'), isEmpty);
    expect(await manager.query('customer_ledger'), isEmpty);
  });

  test('K: confirmed, cancelled and converted documents cannot be edited',
      () async {
    await repository.createOrder(order('confirmed-edit'), admin);
    await repository.confirmOrder('confirmed-edit', admin);
    expect(
        (await repository.updateOrderDraft(order('confirmed-edit'), admin))
            .isLeft(),
        isTrue);

    await repository.createOrder(order('cancelled-edit'), admin);
    await repository.cancelOrder('cancelled-edit', admin);
    expect(
        (await repository.updateOrderDraft(order('cancelled-edit'), admin))
            .isLeft(),
        isTrue);

    await repository.createOrder(order('converted-edit'), admin);
    await repository.confirmOrder('converted-edit', admin);
    expect((await repository.convertOrder('converted-edit', admin)).isRight(),
        isTrue);
    expect(
        (await repository.updateOrderDraft(order('converted-edit'), admin))
            .isLeft(),
        isTrue);
  });

  test('L: v16 migration preserves representative pre-v16 data', () async {
    await manager.close();
    final legacyPath = '${path}_v15';
    path = legacyPath;
    final databaseFile = File(legacyPath);
    if (databaseFile.existsSync()) databaseFile.deleteSync();
    for (final suffix in ['-wal', '-shm']) {
      final sidecar = File('$path$suffix');
      if (sidecar.existsSync()) sidecar.deleteSync();
    }
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final legacy = await databaseFactoryFfi.openDatabase(
      legacyPath,
      options: OpenDatabaseOptions(
          version: 15,
          onCreate: (db, _) async {
            await db.execute('''
          CREATE TABLE categories (
            id TEXT PRIMARY KEY NOT NULL,
            name TEXT NOT NULL UNIQUE,
            color TEXT,
            sort_order INTEGER DEFAULT 0
          )
        ''');
            await db.execute('''
          CREATE TABLE products (
            id TEXT PRIMARY KEY NOT NULL, barcode TEXT UNIQUE, name TEXT NOT NULL,
            price REAL NOT NULL, stock REAL NOT NULL DEFAULT 0,
            min_stock REAL NOT NULL DEFAULT 0, category_id TEXT,
            is_active INTEGER NOT NULL DEFAULT 1,
            created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
            FOREIGN KEY (category_id) REFERENCES categories(id)
          )
        ''');
            await db.execute('''
          CREATE TABLE customers (
            id TEXT PRIMARY KEY, code TEXT NOT NULL UNIQUE, name TEXT NOT NULL,
            is_active INTEGER NOT NULL DEFAULT 1, created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
          )
        ''');
            await db.execute(
                'CREATE TABLE suppliers (id TEXT PRIMARY KEY, name TEXT NOT NULL)');
            await db.execute('''
          CREATE TABLE sales (
            id TEXT PRIMARY KEY, total REAL NOT NULL, customer_id TEXT,
            created_at TEXT NOT NULL
          )
        ''');
            await db.execute('''
          CREATE TABLE sale_items (
            id TEXT PRIMARY KEY, sale_id TEXT NOT NULL, product_id TEXT NOT NULL,
            quantity REAL NOT NULL, subtotal REAL NOT NULL
          )
        ''');
            await db.execute('''
          CREATE TABLE stock_movements (
            id TEXT PRIMARY KEY, product_id TEXT NOT NULL,
            movement_type TEXT NOT NULL, quantity_change REAL NOT NULL
          )
        ''');
            await db.execute('''
          CREATE TABLE customer_ledger (
            id TEXT PRIMARY KEY, customer_id TEXT NOT NULL,
            amount REAL NOT NULL, reference_id TEXT
          )
        ''');
            await db.execute('''
          CREATE TABLE supplier_ledger (
            id TEXT PRIMARY KEY, supplier_id TEXT NOT NULL,
            amount REAL NOT NULL, reference_id TEXT
          )
        ''');
            await db.execute('''
          CREATE TABLE purchases (
            id TEXT PRIMARY KEY, supplier_id TEXT, total REAL NOT NULL
          )
        ''');
            await db.execute('''
          CREATE TABLE purchase_items (
            id TEXT PRIMARY KEY, purchase_id TEXT NOT NULL,
            product_id TEXT NOT NULL, quantity REAL NOT NULL
          )
        ''');
            await db.execute('''
          CREATE TABLE customer_payments (
            id TEXT PRIMARY KEY, customer_id TEXT NOT NULL, amount REAL NOT NULL
          )
        ''');
            await db.execute('''
          CREATE TABLE supplier_payments (
            id TEXT PRIMARY KEY, supplier_id TEXT NOT NULL, amount REAL NOT NULL
          )
        ''');
            await db.insert('products', {
              'id': 'legacy-product',
              'barcode': 'legacy-product',
              'name': 'Legacy phone',
              'price': 5.0,
              'created_at': '2026-01-01',
              'updated_at': '2026-01-01',
            });
            await db.insert('customers', {
              'id': 'legacy-customer',
              'code': 'legacy-customer',
              'name': 'Legacy customer',
              'created_at': '2026-01-01',
              'updated_at': '2026-01-01',
            });
            await db.insert('suppliers',
                {'id': 'legacy-supplier', 'name': 'Legacy supplier'});
            await db.insert('sales', {
              'id': 'legacy-sale',
              'total': 25.0,
              'customer_id': 'legacy-customer',
              'created_at': '2026-01-01',
            });
            await db.insert('sale_items', {
              'id': 'legacy-sale-item',
              'sale_id': 'legacy-sale',
              'product_id': 'legacy-product',
              'quantity': 5.0,
              'subtotal': 25.0,
            });
            await db.insert('stock_movements', {
              'id': 'legacy-movement',
              'product_id': 'legacy-product',
              'movement_type': 'sale',
              'quantity_change': -5.0,
            });
            await db.insert('customer_ledger', {
              'id': 'legacy-customer-ledger',
              'customer_id': 'legacy-customer',
              'amount': 25.0,
              'reference_id': 'legacy-sale',
            });
            await db.insert('supplier_ledger', {
              'id': 'legacy-supplier-ledger',
              'supplier_id': 'legacy-supplier',
              'amount': 40.0,
              'reference_id': 'legacy-purchase',
            });
            await db.insert('purchases', {
              'id': 'legacy-purchase',
              'supplier_id': 'legacy-supplier',
              'total': 40.0,
            });
            await db.insert('purchase_items', {
              'id': 'legacy-purchase-item',
              'purchase_id': 'legacy-purchase',
              'product_id': 'legacy-product',
              'quantity': 8.0,
            });
            await db.insert('customer_payments', {
              'id': 'legacy-customer-payment',
              'customer_id': 'legacy-customer',
              'amount': 5.0,
            });
            await db.insert('supplier_payments', {
              'id': 'legacy-supplier-payment',
              'supplier_id': 'legacy-supplier',
              'amount': 10.0,
            });
          }),
    );
    await legacy.close();
    manager = SQLiteManager(databasePath: path);
    await manager.initialize();
    expect((await manager.query('products')).single['name'], 'Legacy phone');
    expect(
        (await manager.query('customers')).single['name'], 'Legacy customer');
    expect(
        (await manager.query('suppliers')).single['name'], 'Legacy supplier');
    expect((await manager.query('sales')).single['total'], 25.0);
    expect((await manager.query('sale_items')).single['quantity'], 5.0);
    expect((await manager.query('stock_movements')).single['quantity_change'],
        -5.0);
    expect((await manager.query('customer_ledger')).single['amount'], 25.0);
    expect((await manager.query('supplier_ledger')).single['amount'], 40.0);
    expect((await manager.query('purchases')).single['total'], 40.0);
    expect((await manager.query('purchase_items')).single['quantity'], 8.0);
    expect((await manager.query('customer_payments')).single['amount'], 5.0);
    expect((await manager.query('supplier_payments')).single['amount'], 10.0);
    expect(await manager.query('orders'), isEmpty);
    expect(await manager.query('proformas'), isEmpty);
    final tables = await manager.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name IN "
        "('orders', 'order_items', 'proformas', 'proforma_items')");
    expect(tables, hasLength(4));
    final indexes = await manager.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'index' AND name IN "
        "('idx_orders_status_date', 'idx_order_items_order', "
        "'idx_proformas_status_date', 'idx_proforma_items_parent')");
    expect(indexes, hasLength(4));
    final orderSql = await manager.rawQuery(
        "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'orders'");
    expect(orderSql.single['sql'], contains('UNIQUE'));
    expect(orderSql.single['sql'], contains('CHECK(status IN'));
  });
}
