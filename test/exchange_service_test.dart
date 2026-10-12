import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:bayaa_pos/core/data/services/sqlite_manager.dart';
import 'package:bayaa_pos/features/exchange/domain/exchange_service.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  test('parses exchange API decimal strings and numeric values', () {
    final cases = <Object?>['100.00', '0.00', '-50.00', 100.0];
    for (final value in cases) {
      final result = ExchangeResult.fromApiResponse({
        'exchange_id': 'exchange-test',
        'sale_id': 'sale-test',
        'difference_amount': value,
        'payment_method': 'cash',
        'posted_at': '2026-09-23T18:30:47.811320',
      });
      expect(result.differenceAmount, double.parse(value.toString()));
      expect(result.exchangeDocumentId, 'exchange-test');
    }
  });

  Future<SQLiteManager> openFreshDatabase() async {
    final dbPath =
        'exchange_service_${DateTime.now().microsecondsSinceEpoch}.sqlite';
    final manager = SQLiteManager(databasePath: dbPath);
    await manager.initialize();
    return manager;
  }

  Future<void> seedBaseData(SQLiteManager manager,
      {String saleId = 'sale-1',
      String customerId = 'cust-1',
      String userId = 'user-1'}) async {
    final now = DateTime.now().toIso8601String();
    await manager.insert('users', {
      'id': userId,
      'username': 'cashier-1',
      'display_name': 'Cashier 1',
      'password_hash': 'x',
      'role': 'cashier',
      'created_at': now,
    });
    await manager.insert('customers', {
      'id': customerId,
      'code': 'C-001',
      'name': 'Customer 1',
      'opening_balance': 0.0,
      'current_balance': 0.0,
      'created_at': now,
      'updated_at': now,
    });
    await manager.insert(
        'categories',
        {
          'id': 'cat-general',
          'name': 'General',
          'color': '#4F46E5',
          'sort_order': 0,
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
    await manager.insert(
        'cash_registers',
        {
          'id': 'main-register',
          'name': 'Main Register',
          'code': 'MAIN',
          'is_active': 1,
          'created_at': now,
          'updated_at': now,
          'created_by': userId,
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
    await manager.insert(
        'products',
        {
          'id': 'original-product',
          'barcode': 'orig-001',
          'name': 'Original Product',
          'price': 10.0,
          'min_price': 0.0,
          'wholesale_price': 7.0,
          'cost': 7.0,
          'stock': 25.0,
          'min_stock': 0.0,
          'category_id': 'cat-general',
          'is_active': 1,
          'created_at': now,
          'updated_at': now,
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
    await manager.insert(
        'products',
        {
          'id': 'replacement-product',
          'barcode': 'rep-001',
          'name': 'Replacement Product',
          'price': 15.0,
          'min_price': 0.0,
          'wholesale_price': 12.0,
          'cost': 12.0,
          'stock': 20.0,
          'min_stock': 0.0,
          'category_id': 'cat-general',
          'is_active': 1,
          'created_at': now,
          'updated_at': now,
        },
        conflictAlgorithm: ConflictAlgorithm.replace);

    await manager.insert(
        'sales',
        {
          'id': saleId,
          'reference_number': 'INV-000001',
          'total': 50.0,
          'items_count': 1,
          'created_at': DateTime.now().toIso8601String(),
          'cashier_name': 'Cashier 1',
          'user_id': userId,
          'customer_id': customerId,
          'shift_id': null,
          'is_refund': 0,
          'original_sale_id': null,
          'payment_method': 'cash',
        },
        conflictAlgorithm: ConflictAlgorithm.replace);

    final itemId = '${saleId}_item_1';
    await manager.insert(
        'sale_items',
        {
          'id': itemId,
          'sale_id': saleId,
          'product_id': 'original-product',
          'product_barcode': 'orig-001',
          'product_name': 'Original Product',
          'quantity': 5.0,
          'price': 10.0,
          'wholesale_price': 7.0,
          'subtotal': 50.0,
          'refunded_quantity': 0.0,
          'exchanged_quantity': 0.0,
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  test(
      'cash replacement more expensive creates replacement sale and cash movement',
      () async {
    final manager = await openFreshDatabase();
    try {
      await seedBaseData(manager, saleId: 'sale-cash-expensive');
      final service = ExchangeService(sqliteManager: manager);

      final result = await service.execute(ExchangeRequest(
        originalSaleId: 'sale-cash-expensive',
        items: [
          ExchangeLineRequest(
            originalSaleItemId: 'sale-cash-expensive_item_1',
            originalProductId: 'original-product',
            returnedQuantity: 2,
            replacementProductId: 'replacement-product',
            replacementQuantity: 2,
          ),
        ],
        customerId: 'cust-1',
        paymentMethod: 'cash',
        idempotencyKey: 'cash-expensive-1',
        actorUserId: 'user-1',
        notes: 'Cash exchange more expensive',
      ));

      expect(result.differenceAmount, greaterThan(0.0));
      expect(result.isDuplicate, isFalse);
      expect(result.replacementSaleId, isNotEmpty);
      final replacementSales = await manager.query('sales',
          where: 'id = ?', whereArgs: [result.replacementSaleId]);
      expect(replacementSales, hasLength(1));
      expect(result.replacementDocumentReference,
          replacementSales.single['reference_number']);
      expect(replacementSales.single['total'], 30.0);
      final replacementItems = await manager.query('sale_items',
          where: 'sale_id = ?', whereArgs: [result.replacementSaleId]);
      expect(replacementItems, hasLength(1));
      expect(replacementItems.single['product_id'], 'replacement-product');
      expect(replacementItems.single['quantity'], 2.0);
      expect(replacementItems.single['price'], 15.0);
      final cashRows = await manager.query('cash_movements',
          where: 'reference_id = ?', whereArgs: [result.replacementSaleId]);
      expect(cashRows, isNotEmpty);
      expect((cashRows.first['amount'] as num).toDouble(), greaterThan(0.0));
      final saleItems = await manager.query('sale_items',
          where: 'id = ?', whereArgs: ['sale-cash-expensive_item_1']);
      expect((saleItems.first['exchanged_quantity'] as num).toDouble(), 2.0);
    } finally {
      await manager.close();
    }
  });

  test(
      'credit replacement cheaper creates customer ledger delta and preserves original sale',
      () async {
    final manager = await openFreshDatabase();
    try {
      final now = DateTime.now().toIso8601String();
      await manager.insert(
          'users',
          {
            'id': 'user-1',
            'username': 'cashier-1',
            'display_name': 'Cashier 1',
            'password_hash': 'x',
            'role': 'cashier',
            'created_at': now,
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
      await manager.insert(
          'customers',
          {
            'id': 'cust-1',
            'code': 'C-001',
            'name': 'Customer 1',
            'opening_balance': 0.0,
            'current_balance': 0.0,
            'created_at': now,
            'updated_at': now,
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
      await manager.insert(
          'categories',
          {
            'id': 'cat-general',
            'name': 'General',
            'color': '#4F46E5',
            'sort_order': 0,
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
      await manager.insert(
          'products',
          {
            'id': 'original-product',
            'barcode': 'orig-001',
            'name': 'Original Product',
            'price': 10.0,
            'min_price': 0.0,
            'wholesale_price': 7.0,
            'cost': 7.0,
            'stock': 25.0,
            'min_stock': 0.0,
            'category_id': 'cat-general',
            'is_active': 1,
            'created_at': now,
            'updated_at': now,
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
      await manager.insert(
          'products',
          {
            'id': 'replacement-product',
            'barcode': 'rep-001',
            'name': 'Replacement Product',
            'price': 6.0,
            'min_price': 0.0,
            'wholesale_price': 4.0,
            'cost': 4.0,
            'stock': 20.0,
            'min_stock': 0.0,
            'category_id': 'cat-general',
            'is_active': 1,
            'created_at': now,
            'updated_at': now,
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
      await manager.insert(
          'sales',
          {
            'id': 'sale-credit-cheaper',
            'reference_number': 'INV-000002',
            'total': 50.0,
            'items_count': 1,
            'created_at': DateTime.now().toIso8601String(),
            'cashier_name': 'Cashier 1',
            'user_id': 'user-1',
            'customer_id': 'cust-1',
            'shift_id': null,
            'is_refund': 0,
            'original_sale_id': null,
            'payment_method': 'credit',
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
      await manager.insert(
          'sale_items',
          {
            'id': 'sale-credit-cheaper_item_1',
            'sale_id': 'sale-credit-cheaper',
            'product_id': 'original-product',
            'product_barcode': 'orig-001',
            'product_name': 'Original Product',
            'quantity': 5.0,
            'price': 10.0,
            'wholesale_price': 7.0,
            'subtotal': 50.0,
            'refunded_quantity': 0.0,
            'exchanged_quantity': 0.0,
          },
          conflictAlgorithm: ConflictAlgorithm.replace);

      final result =
          await ExchangeService(sqliteManager: manager).execute(ExchangeRequest(
        originalSaleId: 'sale-credit-cheaper',
        items: [
          ExchangeLineRequest(
            originalSaleItemId: 'sale-credit-cheaper_item_1',
            originalProductId: 'original-product',
            returnedQuantity: 2,
            replacementProductId: 'replacement-product',
            replacementQuantity: 2,
          ),
        ],
        customerId: 'cust-1',
        paymentMethod: 'credit',
        idempotencyKey: 'credit-cheaper-1',
        actorUserId: 'user-1',
      ));

      expect(result.differenceAmount, lessThan(0.0));
      final ledgerRows = await manager.query('customer_ledger',
          where: 'customer_id = ?', whereArgs: ['cust-1']);
      expect(ledgerRows, isNotEmpty);
      expect((ledgerRows.first['amount'] as num).toDouble(), lessThan(0.0));
      final originalSale = await manager
          .query('sales', where: 'id = ?', whereArgs: ['sale-credit-cheaper']);
      expect((originalSale.first['total'] as num).toDouble(), 50.0);
    } finally {
      await manager.close();
    }
  });

  test(
      'partial quantity exchange allows remaining quantity and then another exchange',
      () async {
    final manager = await openFreshDatabase();
    try {
      await seedBaseData(manager, saleId: 'sale-partial');
      final service = ExchangeService(sqliteManager: manager);

      final first = await service.execute(ExchangeRequest(
        originalSaleId: 'sale-partial',
        items: [
          ExchangeLineRequest(
            originalSaleItemId: 'sale-partial_item_1',
            originalProductId: 'original-product',
            returnedQuantity: 2,
            replacementProductId: 'replacement-product',
            replacementQuantity: 1,
          ),
        ],
        customerId: 'cust-1',
        paymentMethod: 'cash',
        idempotencyKey: 'partial-1',
        actorUserId: 'user-1',
      ));
      expect(first.isDuplicate, isFalse);

      final second = await service.execute(ExchangeRequest(
        originalSaleId: 'sale-partial',
        items: [
          ExchangeLineRequest(
            originalSaleItemId: 'sale-partial_item_1',
            originalProductId: 'original-product',
            returnedQuantity: 1,
            replacementProductId: 'replacement-product',
            replacementQuantity: 1,
          ),
        ],
        customerId: 'cust-1',
        paymentMethod: 'cash',
        idempotencyKey: 'partial-2',
        actorUserId: 'user-1',
      ));
      expect(second.isDuplicate, isFalse);
      final exchanged = await manager.query('sale_items',
          where: 'id = ?', whereArgs: ['sale-partial_item_1']);
      expect((exchanged.first['exchanged_quantity'] as num).toDouble(), 3.0);
    } finally {
      await manager.close();
    }
  });

  test('exact multi-item mapping does not create cartesian duplicates',
      () async {
    final manager = await openFreshDatabase();
    try {
      final now = DateTime.now().toIso8601String();
      await manager.insert(
          'users',
          {
            'id': 'user-1',
            'username': 'cashier-1',
            'display_name': 'Cashier 1',
            'password_hash': 'x',
            'role': 'cashier',
            'created_at': now,
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
      await manager.insert(
          'customers',
          {
            'id': 'cust-1',
            'code': 'C-001',
            'name': 'Customer 1',
            'opening_balance': 0.0,
            'current_balance': 0.0,
            'created_at': now,
            'updated_at': now,
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
      await manager.insert(
          'categories',
          {
            'id': 'cat-general',
            'name': 'General',
            'color': '#4F46E5',
            'sort_order': 0,
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
      await manager.insert(
          'products',
          {
            'id': 'original-a',
            'barcode': 'A-001',
            'name': 'Original A',
            'price': 100.0,
            'min_price': 0.0,
            'wholesale_price': 70.0,
            'cost': 70.0,
            'stock': 10.0,
            'min_stock': 0.0,
            'category_id': 'cat-general',
            'is_active': 1,
            'created_at': now,
            'updated_at': now,
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
      await manager.insert(
          'products',
          {
            'id': 'original-b',
            'barcode': 'B-001',
            'name': 'Original B',
            'price': 120.0,
            'min_price': 0.0,
            'wholesale_price': 80.0,
            'cost': 80.0,
            'stock': 10.0,
            'min_stock': 0.0,
            'category_id': 'cat-general',
            'is_active': 1,
            'created_at': now,
            'updated_at': now,
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
      await manager.insert(
          'products',
          {
            'id': 'replacement-d',
            'barcode': 'D-001',
            'name': 'Replacement D',
            'price': 90.0,
            'min_price': 0.0,
            'wholesale_price': 60.0,
            'cost': 60.0,
            'stock': 10.0,
            'min_stock': 0.0,
            'category_id': 'cat-general',
            'is_active': 1,
            'created_at': now,
            'updated_at': now,
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
      await manager.insert(
          'products',
          {
            'id': 'replacement-e',
            'barcode': 'E-001',
            'name': 'Replacement E',
            'price': 130.0,
            'min_price': 0.0,
            'wholesale_price': 100.0,
            'cost': 100.0,
            'stock': 10.0,
            'min_stock': 0.0,
            'category_id': 'cat-general',
            'is_active': 1,
            'created_at': now,
            'updated_at': now,
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
      await manager.insert(
          'sales',
          {
            'id': 'sale-multi-map',
            'reference_number': 'INV-000010',
            'total': 220.0,
            'items_count': 2,
            'created_at': now,
            'cashier_name': 'Cashier 1',
            'user_id': 'user-1',
            'customer_id': 'cust-1',
            'shift_id': null,
            'is_refund': 0,
            'original_sale_id': null,
            'payment_method': 'cash',
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
      await manager.insert(
          'sale_items',
          {
            'id': 'sale-multi-map_item_a',
            'sale_id': 'sale-multi-map',
            'product_id': 'original-a',
            'product_barcode': 'A-001',
            'product_name': 'Original A',
            'quantity': 1.0,
            'price': 100.0,
            'wholesale_price': 70.0,
            'subtotal': 100.0,
            'refunded_quantity': 0.0,
            'exchanged_quantity': 0.0,
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
      await manager.insert(
          'sale_items',
          {
            'id': 'sale-multi-map_item_b',
            'sale_id': 'sale-multi-map',
            'product_id': 'original-b',
            'product_barcode': 'B-001',
            'product_name': 'Original B',
            'quantity': 1.0,
            'price': 120.0,
            'wholesale_price': 80.0,
            'subtotal': 120.0,
            'refunded_quantity': 0.0,
            'exchanged_quantity': 0.0,
          },
          conflictAlgorithm: ConflictAlgorithm.replace);

      final result =
          await ExchangeService(sqliteManager: manager).execute(ExchangeRequest(
        originalSaleId: 'sale-multi-map',
        items: [
          ExchangeLineRequest(
            originalSaleItemId: 'sale-multi-map_item_a',
            originalProductId: 'original-a',
            returnedQuantity: 1,
            replacementProductId: 'replacement-d',
            replacementQuantity: 1,
          ),
          ExchangeLineRequest(
            originalSaleItemId: 'sale-multi-map_item_b',
            originalProductId: 'original-b',
            returnedQuantity: 1,
            replacementProductId: 'replacement-e',
            replacementQuantity: 1,
          ),
        ],
        customerId: 'cust-1',
        paymentMethod: 'cash',
        idempotencyKey: 'multi-map-key',
        actorUserId: 'user-1',
      ));

      final rows = await manager.query('exchange_items',
          where: 'exchange_id = ?', whereArgs: [result.exchangeDocumentId]);
      expect(rows, hasLength(2));
      expect(rows.map((row) => row['original_sale_item_id']).toSet(),
          {'sale-multi-map_item_a', 'sale-multi-map_item_b'});
      expect(rows.map((row) => row['replacement_product_id']).toSet(),
          {'replacement-d', 'replacement-e'});
    } finally {
      await manager.close();
    }
  });

  test(
      'multi-replacement original item maps only the requested replacement set',
      () async {
    final manager = await openFreshDatabase();
    try {
      final now = DateTime.now().toIso8601String();
      await manager.insert(
          'users',
          {
            'id': 'user-1',
            'username': 'cashier-1',
            'display_name': 'Cashier 1',
            'password_hash': 'x',
            'role': 'cashier',
            'created_at': now,
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
      await manager.insert(
          'customers',
          {
            'id': 'cust-1',
            'code': 'C-001',
            'name': 'Customer 1',
            'opening_balance': 0.0,
            'current_balance': 0.0,
            'created_at': now,
            'updated_at': now,
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
      await manager.insert(
          'categories',
          {
            'id': 'cat-general',
            'name': 'General',
            'color': '#4F46E5',
            'sort_order': 0,
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
      for (final product in [
        {
          'id': 'original-a',
          'barcode': 'A-001',
          'name': 'Original A',
          'price': 500.0,
          'min_price': 0.0,
          'wholesale_price': 300.0,
          'cost': 300.0,
          'stock': 10.0
        },
        {
          'id': 'replacement-b',
          'barcode': 'B-001',
          'name': 'Replacement B',
          'price': 300.0,
          'min_price': 0.0,
          'wholesale_price': 200.0,
          'cost': 200.0,
          'stock': 10.0
        },
        {
          'id': 'replacement-c',
          'barcode': 'C-001',
          'name': 'Replacement C',
          'price': 150.0,
          'min_price': 0.0,
          'wholesale_price': 100.0,
          'cost': 100.0,
          'stock': 10.0
        },
      ]) {
        await manager.insert(
            'products',
            {
              ...product,
              'category_id': 'cat-general',
              'is_active': 1,
              'created_at': now,
              'updated_at': now,
            },
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await manager.insert(
          'sales',
          {
            'id': 'sale-multi-replacement',
            'reference_number': 'INV-000011',
            'total': 500.0,
            'items_count': 1,
            'created_at': now,
            'cashier_name': 'Cashier 1',
            'user_id': 'user-1',
            'customer_id': 'cust-1',
            'shift_id': null,
            'is_refund': 0,
            'original_sale_id': null,
            'payment_method': 'cash',
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
      await manager.insert(
          'sale_items',
          {
            'id': 'sale-multi-replacement_item_1',
            'sale_id': 'sale-multi-replacement',
            'product_id': 'original-a',
            'product_barcode': 'A-001',
            'product_name': 'Original A',
            'quantity': 1.0,
            'price': 500.0,
            'wholesale_price': 300.0,
            'subtotal': 500.0,
            'refunded_quantity': 0.0,
            'exchanged_quantity': 0.0,
          },
          conflictAlgorithm: ConflictAlgorithm.replace);

      final result =
          await ExchangeService(sqliteManager: manager).execute(ExchangeRequest(
        originalSaleId: 'sale-multi-replacement',
        items: [
          ExchangeLineRequest(
            originalSaleItemId: 'sale-multi-replacement_item_1',
            originalProductId: 'original-a',
            returnedQuantity: 1,
            replacementProductId: 'replacement-b',
            replacementQuantity: 1,
          ),
          ExchangeLineRequest(
            originalSaleItemId: 'sale-multi-replacement_item_1',
            originalProductId: 'original-a',
            returnedQuantity: 1,
            replacementProductId: 'replacement-c',
            replacementQuantity: 1,
          ),
        ],
        customerId: 'cust-1',
        paymentMethod: 'cash',
        idempotencyKey: 'multi-replacement-key',
        actorUserId: 'user-1',
      ));

      final rows = await manager.query('exchange_items',
          where: 'exchange_id = ?', whereArgs: [result.exchangeDocumentId]);
      expect(rows, hasLength(2));
      expect(rows.map((row) => row['replacement_product_id']).toSet(),
          {'replacement-b', 'replacement-c'});
    } finally {
      await manager.close();
    }
  });

  test('duplicate exchange request is idempotent', () async {
    final manager = await openFreshDatabase();
    try {
      await seedBaseData(manager, saleId: 'sale-duplicate');
      final service = ExchangeService(sqliteManager: manager);
      final request = ExchangeRequest(
        originalSaleId: 'sale-duplicate',
        items: [
          ExchangeLineRequest(
            originalSaleItemId: 'sale-duplicate_item_1',
            originalProductId: 'original-product',
            returnedQuantity: 2,
            replacementProductId: 'replacement-product',
            replacementQuantity: 1,
          ),
        ],
        customerId: 'cust-1',
        paymentMethod: 'cash',
        idempotencyKey: 'duplicate-key',
        actorUserId: 'user-1',
      );

      final first = await service.execute(request);
      final second = await service.execute(request);

      expect(first.isDuplicate, isFalse);
      expect(second.isDuplicate, isTrue);
      expect(second.exchangeDocumentId, first.exchangeDocumentId);
      final docs = await manager.query('exchange_documents');
      expect(docs, hasLength(1));
    } finally {
      await manager.close();
    }
  });

  test('concurrent identical exchange creates exactly one exchange document',
      () async {
    final manager = await openFreshDatabase();
    try {
      await seedBaseData(manager, saleId: 'sale-concurrent');
      final service = ExchangeService(sqliteManager: manager);
      final request = ExchangeRequest(
        originalSaleId: 'sale-concurrent',
        items: [
          ExchangeLineRequest(
            originalSaleItemId: 'sale-concurrent_item_1',
            originalProductId: 'original-product',
            returnedQuantity: 1,
            replacementProductId: 'replacement-product',
            replacementQuantity: 1,
          ),
        ],
        customerId: 'cust-1',
        paymentMethod: 'cash',
        idempotencyKey: 'concurrent-key',
        actorUserId: 'user-1',
      );

      final results = await Future.wait(
          [service.execute(request), service.execute(request)]);
      expect(results.length, 2);
      expect(results.where((result) => !result.isDuplicate).length, 1);
      final docs = await manager.query('exchange_documents');
      expect(docs, hasLength(1));
    } finally {
      await manager.close();
    }
  });

  test('invalid exchange quantity is rejected', () async {
    final manager = await openFreshDatabase();
    try {
      await seedBaseData(manager, saleId: 'sale-invalid');
      final service = ExchangeService(sqliteManager: manager);

      expect(
        () => service.execute(ExchangeRequest(
          originalSaleId: 'sale-invalid',
          items: [
            ExchangeLineRequest(
              originalSaleItemId: 'sale-invalid_item_1',
              originalProductId: 'original-product',
              returnedQuantity: 99,
              replacementProductId: 'replacement-product',
              replacementQuantity: 1,
            ),
          ],
          customerId: 'cust-1',
          paymentMethod: 'cash',
          idempotencyKey: 'invalid-key',
          actorUserId: 'user-1',
        )),
        throwsA(isA<StateError>()),
      );
    } finally {
      await manager.close();
    }
  });

  test('insufficient replacement stock is rejected', () async {
    final manager = await openFreshDatabase();
    try {
      await seedBaseData(manager, saleId: 'sale-stock');
      await manager.update('products', {'stock': 0.0},
          where: 'id = ?', whereArgs: ['replacement-product']);
      final service = ExchangeService(sqliteManager: manager);

      expect(
        () => service.execute(ExchangeRequest(
          originalSaleId: 'sale-stock',
          items: [
            ExchangeLineRequest(
              originalSaleItemId: 'sale-stock_item_1',
              originalProductId: 'original-product',
              returnedQuantity: 2,
              replacementProductId: 'replacement-product',
              replacementQuantity: 1,
            ),
          ],
          customerId: 'cust-1',
          paymentMethod: 'cash',
          idempotencyKey: 'stock-key',
          actorUserId: 'user-1',
        )),
        throwsA(isA<StateError>()),
      );
    } finally {
      await manager.close();
    }
  });

  test('rollback then retry leaves one exchange after intentional failure',
      () async {
    final manager = await openFreshDatabase();
    try {
      await seedBaseData(manager, saleId: 'sale-rollback');
      final failingService = ExchangeService(
        sqliteManager: manager,
        failureInjector: (txn) async {
          throw StateError('Simulated rollback');
        },
      );
      final request = ExchangeRequest(
        originalSaleId: 'sale-rollback',
        items: [
          ExchangeLineRequest(
            originalSaleItemId: 'sale-rollback_item_1',
            originalProductId: 'original-product',
            returnedQuantity: 1,
            replacementProductId: 'replacement-product',
            replacementQuantity: 1,
          ),
        ],
        customerId: 'cust-1',
        paymentMethod: 'cash',
        idempotencyKey: 'rollback-key',
        actorUserId: 'user-1',
      );

      expect(() => failingService.execute(request), throwsA(isA<StateError>()));
      final docsAfterFailure = await manager.query('exchange_documents');
      expect(docsAfterFailure, isEmpty);

      final successful =
          await ExchangeService(sqliteManager: manager).execute(request);
      expect(successful.isDuplicate, isFalse);
      final docsAfterRetry = await manager.query('exchange_documents');
      expect(docsAfterRetry, hasLength(1));
    } finally {
      await manager.close();
    }
  });

  test('audit event is recorded once for a successful exchange', () async {
    final manager = await openFreshDatabase();
    try {
      await seedBaseData(manager, saleId: 'sale-audit');
      final service = ExchangeService(sqliteManager: manager);
      await service.execute(ExchangeRequest(
        originalSaleId: 'sale-audit',
        items: [
          ExchangeLineRequest(
            originalSaleItemId: 'sale-audit_item_1',
            originalProductId: 'original-product',
            returnedQuantity: 1,
            replacementProductId: 'replacement-product',
            replacementQuantity: 1,
          ),
        ],
        customerId: 'cust-1',
        paymentMethod: 'cash',
        idempotencyKey: 'audit-key',
        actorUserId: 'user-1',
      ));

      final activityRows = await manager
          .query('activity_logs', where: 'type = ?', whereArgs: ['exchange']);
      expect(activityRows, hasLength(1));
    } finally {
      await manager.close();
    }
  });

  test(
      'exchange preserves exact selected unit identity for packaged and weighted scenarios',
      () async {
    final manager = await openFreshDatabase();
    try {
      final now = DateTime.now().toIso8601String();
      await manager.insert(
          'users',
          {
            'id': 'user-1',
            'username': 'cashier-1',
            'display_name': 'Cashier 1',
            'password_hash': 'x',
            'role': 'cashier',
            'created_at': now,
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
      await manager.insert(
          'customers',
          {
            'id': 'cust-1',
            'code': 'C-001',
            'name': 'Customer 1',
            'opening_balance': 0.0,
            'current_balance': 0.0,
            'created_at': now,
            'updated_at': now,
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
      await manager.insert(
          'categories',
          {
            'id': 'cat-general',
            'name': 'General',
            'color': '#4F46E5',
            'sort_order': 0,
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
      await manager.insert(
          'products',
          {
            'id': 'product-original',
            'barcode': 'ORIG-1',
            'name': 'Original Product',
            'price': 2400.0,
            'min_price': 0.0,
            'wholesale_price': 1800.0,
            'cost': 1800.0,
            'stock': 20.0,
            'min_stock': 0.0,
            'category_id': 'cat-general',
            'is_active': 1,
            'base_unit': 'bottle',
            'created_at': now,
            'updated_at': now,
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
      await manager.insert(
          'products',
          {
            'id': 'product-replacement',
            'barcode': 'REPL-1',
            'name': 'Replacement Product',
            'price': 500.0,
            'min_price': 0.0,
            'wholesale_price': 300.0,
            'cost': 300.0,
            'stock': 40.0,
            'min_stock': 0.0,
            'category_id': 'cat-general',
            'is_active': 1,
            'base_unit': 'bottle',
            'allow_partial_package_sale': 1,
            'created_at': now,
            'updated_at': now,
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
      for (final unit in [
        {
          'id': 'unit-bottle',
          'name': 'Bottle',
          'conversion_to_base': 1.0,
          'selling_price': 500.0,
          'is_default': 1
        },
        {
          'id': 'unit-pack',
          'name': 'Pack',
          'conversion_to_base': 6.0,
          'selling_price': 2400.0,
          'is_default': 0
        },
        {
          'id': 'unit-carton',
          'name': 'Carton',
          'conversion_to_base': 12.0,
          'selling_price': 4500.0,
          'is_default': 0
        },
      ]) {
        await manager.insert(
            'product_selling_units',
            {
              'id': unit['id'] as String,
              'product_id': 'product-replacement',
              'name': unit['name'] as String,
              'conversion_to_base': unit['conversion_to_base'] as double,
              'selling_price': unit['selling_price'] as double,
              'barcode': (unit['id'] as String).replaceAll('unit-', 'unit-'),
              'is_default': (unit['is_default'] as int == 1) ? 1 : 0,
              'is_active': 1,
              'created_at': now,
              'updated_at': now,
            },
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await manager.insert(
          'sales',
          {
            'id': 'sale-package-cases',
            'reference_number': 'INV-000055',
            'total': 2400.0,
            'items_count': 1,
            'created_at': now,
            'cashier_name': 'Cashier 1',
            'user_id': 'user-1',
            'customer_id': 'cust-1',
            'shift_id': null,
            'is_refund': 0,
            'original_sale_id': null,
            'payment_method': 'cash',
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
      await manager.insert(
          'sale_items',
          {
            'id': 'sale-package-cases_item_1',
            'sale_id': 'sale-package-cases',
            'product_id': 'product-original',
            'product_barcode': 'ORIG-1',
            'product_name': 'Original Product',
            'quantity': 1.0,
            'price': 2400.0,
            'wholesale_price': 1800.0,
            'subtotal': 2400.0,
            'refunded_quantity': 0.0,
            'exchanged_quantity': 0.0,
            'selling_unit_id': 'unit-pack',
            'selling_quantity': 1.0,
            'base_quantity': 6.0,
            'conversion_factor_snapshot': 6.0,
            'selling_unit_name_snapshot': 'Pack',
            'base_unit_snapshot': 'bottle',
          },
          conflictAlgorithm: ConflictAlgorithm.replace);

      final packagedScenarioChecks = <Map<String, Object>>[
        {
          'name': 'pack to bottle',
          'returnedQuantity': 1.0,
          'replacementQuantity': 1.0,
          'replacementUnitId': 'unit-bottle',
          'expectedReturnedBase': 6.0,
          'expectedReplacementBase': 1.0,
          'expectedReplacementConversion': 1.0,
          'expectedDifference': -1900.0
        },
        {
          'name': 'pack to 2 bottles',
          'returnedQuantity': 1.0,
          'replacementQuantity': 2.0,
          'replacementUnitId': 'unit-bottle',
          'expectedReturnedBase': 6.0,
          'expectedReplacementBase': 2.0,
          'expectedReplacementConversion': 1.0,
          'expectedDifference': -1400.0
        },
        {
          'name': 'pack to pack',
          'returnedQuantity': 1.0,
          'replacementQuantity': 1.0,
          'replacementUnitId': 'unit-pack',
          'expectedReturnedBase': 6.0,
          'expectedReplacementBase': 6.0,
          'expectedReplacementConversion': 6.0,
          'expectedDifference': 0.0
        },
      ];

      for (final scenario in packagedScenarioChecks) {
        // Each row below is an independent identity scenario; restore the
        // original fixture state before exercising the next unit selection.
        await manager.database.update(
          'sale_items',
          {'refunded_quantity': 0.0, 'exchanged_quantity': 0.0},
          where: 'id = ?',
          whereArgs: ['sale-package-cases_item_1'],
        );
        await manager.database.update(
          'products',
          {'stock': 20.0},
          where: 'id = ?',
          whereArgs: ['product-original'],
        );
        await manager.database.update(
          'products',
          {'stock': 40.0},
          where: 'id = ?',
          whereArgs: ['product-replacement'],
        );
        final idempotencyKey = 'packaged-check-${scenario['name']}';
        final result = await ExchangeService(sqliteManager: manager)
            .execute(ExchangeRequest(
          originalSaleId: 'sale-package-cases',
          items: [
            ExchangeLineRequest(
              originalSaleItemId: 'sale-package-cases_item_1',
              originalProductId: 'product-original',
              returnedQuantity: scenario['returnedQuantity'] as double,
              replacementProductId: 'product-replacement',
              replacementQuantity: scenario['replacementQuantity'] as double,
              replacementSellingUnitId: scenario['replacementUnitId'] as String,
            ),
          ],
          customerId: 'cust-1',
          paymentMethod: 'cash',
          idempotencyKey: idempotencyKey,
          actorUserId: 'user-1',
        ));
        final rows = await manager.query('exchange_items',
            where: 'exchange_id = ?', whereArgs: [result.exchangeDocumentId]);
        final row = rows.single;
        expect((row['original_base_quantity'] as num).toDouble(), 6.0);
        expect((row['replacement_base_quantity'] as num).toDouble(),
            scenario['expectedReplacementBase'] as double);
        expect(
          (row['replacement_conversion_factor_snapshot'] as num).toDouble(),
          scenario['expectedReplacementConversion'] as double,
        );
        expect((row['difference_amount'] as num).toDouble(),
            scenario['expectedDifference'] as double);
      }

      final weightedManager = await openFreshDatabase();
      try {
        final weightedNow = DateTime.now().toIso8601String();
        await weightedManager.insert(
            'users',
            {
              'id': 'user-weight',
              'username': 'cashier-1',
              'display_name': 'Cashier 1',
              'password_hash': 'x',
              'role': 'cashier',
              'created_at': weightedNow
            },
            conflictAlgorithm: ConflictAlgorithm.replace);
        await weightedManager.insert(
            'customers',
            {
              'id': 'cust-weight',
              'code': 'C-002',
              'name': 'Customer 2',
              'opening_balance': 0.0,
              'current_balance': 0.0,
              'created_at': weightedNow,
              'updated_at': weightedNow
            },
            conflictAlgorithm: ConflictAlgorithm.replace);
        await weightedManager.insert(
            'categories',
            {
              'id': 'cat-weight',
              'name': 'Weight',
              'color': '#4F46E5',
              'sort_order': 0
            },
            conflictAlgorithm: ConflictAlgorithm.replace);
        await weightedManager.insert(
            'products',
            {
              'id': 'product-weight-original',
              'barcode': 'WT-ORIG',
              'name': 'Weighted Original',
              'price': 600.0,
              'min_price': 0.0,
              'wholesale_price': 400.0,
              'cost': 400.0,
              'stock': 10.0,
              'min_stock': 0.0,
              'category_id': 'cat-weight',
              'is_active': 1,
              'base_unit': 'kg',
              'created_at': weightedNow,
              'updated_at': weightedNow
            },
            conflictAlgorithm: ConflictAlgorithm.replace);
        await weightedManager.insert(
            'products',
            {
              'id': 'product-weight-replacement',
              'barcode': 'WT-REPL',
              'name': 'Weighted Replacement',
              'price': 400.0,
              'min_price': 0.0,
              'wholesale_price': 300.0,
              'cost': 300.0,
              'stock': 10.0,
              'min_stock': 0.0,
              'category_id': 'cat-weight',
              'is_active': 1,
              'base_unit': 'kg',
              'created_at': weightedNow,
              'updated_at': weightedNow
            },
            conflictAlgorithm: ConflictAlgorithm.replace);
        await weightedManager.insert(
            'sales',
            {
              'id': 'sale-weighted',
              'reference_number': 'INV-000056',
              'total': 600.0,
              'items_count': 1,
              'created_at': weightedNow,
              'cashier_name': 'Cashier 1',
              'user_id': 'user-weight',
              'customer_id': 'cust-weight',
              'shift_id': null,
              'is_refund': 0,
              'original_sale_id': null,
              'payment_method': 'cash'
            },
            conflictAlgorithm: ConflictAlgorithm.replace);
        await weightedManager.insert(
            'sale_items',
            {
              'id': 'sale-weighted_item_1',
              'sale_id': 'sale-weighted',
              'product_id': 'product-weight-original',
              'product_barcode': 'WT-ORIG',
              'product_name': 'Weighted Original',
              'quantity': 0.750,
              'price': 600.0,
              'wholesale_price': 400.0,
              'subtotal': 600.0,
              'refunded_quantity': 0.0,
              'exchanged_quantity': 0.0,
              'selling_unit_id': null,
              'selling_quantity': 0.750,
              'base_quantity': 0.750,
              'conversion_factor_snapshot': 1.0,
              'selling_unit_name_snapshot': 'kg',
              'base_unit_snapshot': 'kg'
            },
            conflictAlgorithm: ConflictAlgorithm.replace);
        final weightedResult =
            await ExchangeService(sqliteManager: weightedManager)
                .execute(ExchangeRequest(
          originalSaleId: 'sale-weighted',
          items: [
            ExchangeLineRequest(
                originalSaleItemId: 'sale-weighted_item_1',
                originalProductId: 'product-weight-original',
                returnedQuantity: 0.750,
                replacementProductId: 'product-weight-replacement',
                replacementQuantity: 0.500,
                replacementSellingUnitId: null)
          ],
          customerId: 'cust-weight',
          paymentMethod: 'cash',
          idempotencyKey: 'weighted-exchange-key',
          actorUserId: 'user-weight',
        ));
        final weightedRows = await weightedManager.query('exchange_items',
            where: 'exchange_id = ?',
            whereArgs: [weightedResult.exchangeDocumentId]);
        expect(
            (weightedRows.single['replacement_selling_quantity'] as num)
                .toDouble(),
            0.5);
        expect(
            (weightedRows.single['replacement_base_quantity'] as num)
                .toDouble(),
            0.5);
        expect((weightedRows.single['difference_amount'] as num).toDouble(),
            -250.0);
      } finally {
        await weightedManager.close();
      }
    } finally {
      await manager.close();
    }
  });

  test(
      'exchange rejects a missing smaller package unit when the product is configured without it',
      () async {
    final manager = await openFreshDatabase();
    try {
      final now = DateTime.now().toIso8601String();
      await manager.insert(
          'users',
          {
            'id': 'user-1',
            'username': 'cashier-1',
            'display_name': 'Cashier 1',
            'password_hash': 'x',
            'role': 'cashier',
            'created_at': now
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
      await manager.insert(
          'customers',
          {
            'id': 'cust-1',
            'code': 'C-001',
            'name': 'Customer 1',
            'opening_balance': 0.0,
            'current_balance': 0.0,
            'created_at': now,
            'updated_at': now
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
      await manager.insert(
          'categories',
          {
            'id': 'cat-general',
            'name': 'General',
            'color': '#4F46E5',
            'sort_order': 0
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
      await manager.insert(
          'products',
          {
            'id': 'replacement-product-no-bottle',
            'barcode': 'RB-001',
            'name': 'Replacement Product',
            'price': 500.0,
            'min_price': 0.0,
            'wholesale_price': 300.0,
            'cost': 300.0,
            'stock': 20.0,
            'min_stock': 0.0,
            'category_id': 'cat-general',
            'is_active': 1,
            'allow_partial_package_sale': 1,
            'base_unit': 'bottle',
            'created_at': now,
            'updated_at': now
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
      await manager.insert(
          'product_selling_units',
          {
            'id': 'unit-pack-only',
            'product_id': 'replacement-product-no-bottle',
            'name': 'Pack',
            'conversion_to_base': 6.0,
            'selling_price': 2400.0,
            'barcode': 'PACK-ONLY',
            'is_default': 1,
            'is_active': 1,
            'created_at': now,
            'updated_at': now
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
      await manager.insert(
          'sales',
          {
            'id': 'sale-policy',
            'reference_number': 'INV-000057',
            'total': 2400.0,
            'items_count': 1,
            'created_at': now,
            'cashier_name': 'Cashier 1',
            'user_id': 'user-1',
            'customer_id': 'cust-1',
            'shift_id': null,
            'is_refund': 0,
            'original_sale_id': null,
            'payment_method': 'cash'
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
      await manager.insert(
          'sale_items',
          {
            'id': 'sale-policy_item_1',
            'sale_id': 'sale-policy',
            'product_id': 'replacement-product-no-bottle',
            'product_barcode': 'RB-001',
            'product_name': 'Replacement Product',
            'quantity': 1.0,
            'price': 2400.0,
            'wholesale_price': 1800.0,
            'subtotal': 2400.0,
            'refunded_quantity': 0.0,
            'exchanged_quantity': 0.0,
            'selling_unit_id': 'unit-pack-only',
            'selling_quantity': 1.0,
            'base_quantity': 6.0,
            'conversion_factor_snapshot': 6.0,
            'selling_unit_name_snapshot': 'Pack',
            'base_unit_snapshot': 'bottle'
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
      expect(
        () => ExchangeService(sqliteManager: manager).execute(ExchangeRequest(
          originalSaleId: 'sale-policy',
          items: [
            ExchangeLineRequest(
                originalSaleItemId: 'sale-policy_item_1',
                originalProductId: 'replacement-product-no-bottle',
                returnedQuantity: 1.0,
                replacementProductId: 'replacement-product-no-bottle',
                replacementQuantity: 1.0,
                replacementSellingUnitId: 'missing-bottle')
          ],
          customerId: 'cust-1',
          paymentMethod: 'cash',
          idempotencyKey: 'policy-reject-key',
          actorUserId: 'user-1',
        )),
        throwsA(isA<StateError>()),
      );
    } finally {
      await manager.close();
    }
  });
}
