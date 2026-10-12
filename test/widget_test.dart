import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;

import 'package:bayaa_pos/core/data/models/activity_log.dart';
import 'package:bayaa_pos/core/data/services/debug_seeder.dart';
import 'package:bayaa_pos/core/data/services/persistence_initializer.dart';
import 'package:bayaa_pos/core/data/services/sqlite_manager.dart';
import 'package:bayaa_pos/core/data/services/background_write_queue.dart';
import 'package:bayaa_pos/core/data/services/canonical_cash_posting_service.dart';
import 'package:bayaa_pos/core/di/dependency_injection.dart';
import 'package:bayaa_pos/core/security/permission_guard.dart';
import 'package:bayaa_pos/features/auth/data/models/user_model.dart';
import 'package:bayaa_pos/features/auth/data/repository/user_repository_imp.dart';
import 'package:bayaa_pos/features/auth/presentation/cubit/user_cubit.dart';
import 'package:bayaa_pos/features/customers/data/models/customer_model.dart';
import 'package:bayaa_pos/features/customers/data/repository/customer_repository_impl.dart';
import 'package:bayaa_pos/features/customers/data/models/customer_payment_model.dart';
import 'package:bayaa_pos/features/customers/data/repository/customer_payment_repository_impl.dart';
import 'package:bayaa_pos/features/customers/presentation/customer_returns_screen.dart';
import 'package:bayaa_pos/features/invoice/presentation/cubit/invoice_cubit.dart';
import 'package:bayaa_pos/features/invoice/data/invoice_models.dart';
import 'package:bayaa_pos/features/invoice/domain/invoice_pdf_service.dart';
import 'package:bayaa_pos/features/invoice/presentation/widgets/partial_refund_dialog.dart';
import 'package:bayaa_pos/features/sales/data/models/cart_item_model.dart';
import 'package:bayaa_pos/features/sales/data/models/sale_model.dart';
import 'package:bayaa_pos/features/sales/data/repository/sales_repository_impl.dart';
import 'package:bayaa_pos/features/stock/data/models/stock_movement_model.dart';
import 'package:bayaa_pos/features/stock/services/canonical_stock_posting_service.dart';
import 'package:bayaa_pos/features/stock/services/inventory_reconciliation_service.dart';
import 'package:bayaa_pos/features/suppliers/data/models/supplier_model.dart';
import 'package:bayaa_pos/features/suppliers/data/repository/supplier_repository_impl.dart';
import 'package:bayaa_pos/features/suppliers/data/models/supplier_payment_model.dart';
import 'package:bayaa_pos/features/suppliers/data/repository/supplier_payment_repository_impl.dart';
import 'package:bayaa_pos/features/suppliers/data/models/supplier_return_model.dart';
import 'package:bayaa_pos/features/suppliers/data/repository/supplier_return_repository_impl.dart';
import 'package:bayaa_pos/features/expenses/data/expense_model.dart';
import 'package:bayaa_pos/features/expenses/data/expense_repository.dart';
import 'package:bayaa_pos/features/analytics/data/analytics_repository_impl.dart';
import 'package:bayaa_pos/features/purchases/data/models/purchase_model.dart';
import 'package:bayaa_pos/features/purchases/data/repository/purchase_repository_impl.dart';
import 'package:bayaa_pos/features/dashboard/presentation/widgets/side_bar.dart';
import 'package:bayaa_pos/core/session/session_manager.dart';

Future<void> _initializeIsolatedPersistence() async {
  if (getIt.isRegistered<SessionManager>()) {
    getIt<SessionManager>().clearCurrentSession();
  }
  final existing = PersistenceInitializer.persistenceManager;
  if (existing != null) {
    await existing.shutdown();
  }

  final testDirectory = Directory(
    p.join(
      Directory.systemTemp.path,
      'bayaa_widget_test_${DateTime.now().microsecondsSinceEpoch}',
    ),
  );
  final uniqueRoot = Directory(p.join(testDirectory.path, 'data'));
  await uniqueRoot.create(recursive: true);
  for (final child in [
    'config',
    'ledger',
    'ledger/archived',
    'db',
    'checkpoints',
    'logs',
    'assets'
  ]) {
    await Directory(p.join(uniqueRoot.path, child)).create(recursive: true);
  }
  final systemConfigFile =
      File(p.join(testDirectory.path, 'system_config.json'));
  await systemConfigFile.writeAsString(
    jsonEncode({'data_root_path': uniqueRoot.path}),
    flush: true,
  );
  await File(p.join(uniqueRoot.path, 'config', 'bayaa.json')).writeAsString(
    jsonEncode({
      'app_mode': 'development',
      'development_data_root_path': uniqueRoot.path,
    }),
    flush: true,
  );
  await PersistenceInitializer.initialize(systemConfigFile: systemConfigFile);
}

Future<void> _seedCanonicalSupplier() async {
  final db = PersistenceInitializer.persistenceManager!.sqliteManager;
  final now = DateTime.now().toIso8601String();
  await db.insert(
    'suppliers',
    {
      'id': 'canonical-supplier',
      'code': 'SUP-CANONICAL',
      'name': 'Canonical Supplier',
      'phone': '01000000000',
      'is_active': 1,
      'created_at': now,
      'updated_at': now,
    },
    conflictAlgorithm: ConflictAlgorithm.replace,
  );
}

CustomerPayment _customerPayment(String id, double amount,
    {String customerId = 'payment-customer', String? reference}) {
  return CustomerPayment(
    id: id,
    customerId: customerId,
    amount: amount,
    paymentDate: DateTime(2026, 9, 3),
    paymentMethod: 'cash',
    reference: reference ?? 'CP-$id',
    createdBy: 'manager',
  );
}

Future<void> _seedCustomerReceivable({double amount = 1000}) async {
  final db = PersistenceInitializer.persistenceManager!.sqliteManager;
  await db.insert('customers', {
    'id': 'payment-customer',
    'code': 'PAY-C',
    'name': 'Payment Customer',
    'is_active': 1,
    'created_at': DateTime.now().toIso8601String(),
    'updated_at': DateTime.now().toIso8601String(),
  });
  await db.insert('customer_ledger', {
    'id': 'payment-sale-ledger',
    'customer_id': 'payment-customer',
    'entry_type': 'sale',
    'amount': amount,
    'balance_after': amount,
    'reference_type': 'sale',
    'reference_id': 'payment-sale',
    'created_at': DateTime.now().toIso8601String(),
  });
}

Future<void> _seedSaleFixture({bool customer = true}) async {
  final db = PersistenceInitializer.persistenceManager!.sqliteManager;
  await db.insert('users', {
    'id': 'cashier-1',
    'username': 'cashier-1',
    'display_name': 'Cashier',
    'password_hash': 'test',
    'role': 'cashier',
    'is_active': 1,
    'created_at': DateTime.now().toIso8601String(),
    'created_by': null,
  });
  await db.insert('categories', {
    'id': 'sale-category',
    'name': 'General',
    'color': '#000000',
    'sort_order': 0,
  });
  if (customer) {
    await db.insert('customers', {
      'id': 'sale-customer',
      'code': 'SALE-C',
      'name': 'Sale Customer',
      'is_active': 1,
      'created_at': DateTime.now().toIso8601String(),
      'updated_at': DateTime.now().toIso8601String(),
    });
  }

  await db.insert('products', {
    'id': 'sale-product',
    'barcode': 'SALE-P',
    'name': 'Sale Product',
    'price': 450.0,
    'min_price': 1.0,
    'wholesale_price': 300.0,
    'stock': 10.0,
    'min_stock': 1.0,
    'category_id': 'sale-category',
    'is_active': 1,
    'created_at': DateTime.now().toIso8601String(),
    'updated_at': DateTime.now().toIso8601String(),
  });
}

CartItemModel _saleFixtureItem() => CartItemModel(
      id: 'sale-product',
      name: 'Sale Product',
      originalPrice: 450.0,
      salePrice: 450.0,
      qty: 1,
      date: DateTime.now(),
      minPrice: 1.0,
      wholesalePrice: 300.0,
    );

Future<void> _seedRefundManager() async {
  final db = PersistenceInitializer.persistenceManager!.sqliteManager;
  await db.insert('users', {
    'id': 'manager',
    'username': 'manager',
    'display_name': 'Manager',
    'password_hash': 'test',
    'role': 'manager',
    'is_active': 1,
    'created_at': DateTime.now().toIso8601String(),
  });
}

Future<void> _seedPurchaseFixtures({int products = 1}) async {
  final db = PersistenceInitializer.persistenceManager!.sqliteManager;
  await db.insert('suppliers', {
    'id': 'purchase-supplier',
    'code': 'SUP-P',
    'name': 'Purchase Supplier',
    'is_active': 1,
    'created_at': DateTime.now().toIso8601String(),
    'updated_at': DateTime.now().toIso8601String(),
  });
  await db.insert('categories', {
    'id': 'purchase-category',
    'name': 'Purchase Category',
    'color': '#000',
    'sort_order': 0,
  });
  for (var i = 1; i <= products; i++) {
    await db.insert('products', {
      'id': 'purchase-product-$i',
      'barcode': 'PUR-$i',
      'name': 'Purchase Product $i',
      'price': 20.0,
      'min_price': 1.0,
      'wholesale_price': 10.0,
      'stock': 20.0,
      'min_stock': 2.0,
      'category_id': 'purchase-category',
      'is_active': 1,
      'created_at': DateTime.now().toIso8601String(),
      'updated_at': DateTime.now().toIso8601String(),
    });
  }
}

Purchase _purchase(String id, List<PurchaseLine> lines,
    {String? supplierId, String status = 'confirmed'}) {
  return Purchase(
    id: id,
    referenceNumber: 'REF-$id',
    supplierId: supplierId ?? 'purchase-supplier',
    purchaseDate: DateTime(2026, 9, 3),
    lines: lines,
    status: status,
    createdBy: 'manager',
  );
}

PurchaseLine _line(int product, double quantity, double cost) {
  return PurchaseLine(
    productId: 'purchase-product-$product',
    productName: 'Purchase Product $product',
    productBarcode: 'PUR-$product',
    quantity: quantity,
    unitCost: cost,
  );
}

SupplierPayment _payment(String id, double amount, {String? supplierId}) {
  return SupplierPayment(
    id: id,
    supplierId: supplierId ?? 'purchase-supplier',
    amount: amount,
    paymentDate: DateTime(2026, 9, 3),
    paymentMethod: 'cash',
    reference: 'PAY-$id',
    createdBy: 'manager',
  );
}

SupplierReturn _returnValue(
    String id, String purchaseId, List<SupplierReturnLine> lines,
    {String status = 'confirmed', String supplierId = 'purchase-supplier'}) {
  return SupplierReturn(
    id: id,
    reference: 'RET-$id',
    supplierId: supplierId,
    purchaseId: purchaseId,
    returnDate: DateTime(2026, 9, 3),
    lines: lines,
    status: status,
    createdBy: 'manager',
  );
}

void main() {
  setUpAll(() async {
    await _initializeIsolatedPersistence();
    setup();
    getIt<UserCubit>().currentUser = User(
      username: 'manager',
      name: 'Manager',
      phone: '010',
      userType: UserType.manager,
      password: 'pass',
    );
  });

  setUp(() async {
    await _initializeIsolatedPersistence();
    getIt<UserCubit>().currentUser = User(
      username: 'manager',
      name: 'Manager',
      phone: '010',
      userType: UserType.manager,
      password: 'pass',
    );
  });

  tearDownAll(() async {
    await PersistenceInitializer.persistenceManager?.shutdown();
  });

  test('local analytics uses historical FIFO cost and half-open date totals',
      () async {
    final db = PersistenceInitializer.persistenceManager!.sqliteManager;
    await db.insert('products', {
      'id': 'analytics-product',
      'name': 'Analytics Product',
      'price': 15.0,
      'wholesale_price': 999.0,
      'cost': 777.0,
      'stock': 10.0,
      'created_at': '2026-09-01T08:00:00.000',
      'updated_at': '2026-09-01T08:00:00.000',
    });
    await db.insert('stock_movements', {
      'id': 'analytics-opening-stock',
      'product_id': 'analytics-product',
      'product_name': 'Analytics Product',
      'movement_type': 'opening_stock',
      'quantity_change': 10.0,
      'unit_cost': 5.0,
      'running_stock': 10.0,
      'created_at': '2026-09-01T08:00:00.000',
    });
    await db.insert('sales', {
      'id': 'analytics-sale',
      'total': 30.0,
      'created_at': '2026-09-01T09:00:00.000',
      'is_refund': 0,
    });
    await db.insert('sale_items', {
      'id': 'analytics-sale-item',
      'sale_id': 'analytics-sale',
      'product_id': 'analytics-product',
      'product_name': 'Analytics Product',
      'quantity': 2.0,
      'base_quantity': 2.0,
      'price': 15.0,
      'subtotal': 30.0,
      'wholesale_price': 999.0,
    });
    await db.insert('stock_movements', {
      'id': 'analytics-sale-item_movement',
      'product_id': 'analytics-product',
      'product_name': 'Analytics Product',
      'movement_type': 'sale',
      'quantity_change': -2.0,
      'unit_cost': 5.0,
      'running_stock': 8.0,
      'reference_type': 'sale',
      'reference_id': 'analytics-sale',
      'lineage_id': 'analytics-sale-item',
      'created_at': '2026-09-01T09:00:00.000',
    });
    await db.insert('sales', {
      'id': 'analytics-refund',
      'total': 10.0,
      'created_at': '2026-09-01T10:00:00.000',
      'is_refund': 1,
    });
    await db.insert('sale_items', {
      'id': 'analytics-refund-item',
      'sale_id': 'analytics-refund',
      'product_id': 'analytics-product',
      'product_name': 'Analytics Product',
      'quantity': 1.0,
      'base_quantity': 1.0,
      'price': 10.0,
      'subtotal': 10.0,
      'wholesale_price': 999.0,
    });
    await db.insert('stock_movements', {
      'id': 'analytics-refund-item_movement',
      'product_id': 'analytics-product',
      'product_name': 'Analytics Product',
      'movement_type': 'customer_return',
      'quantity_change': 1.0,
      'unit_cost': 5.0,
      'running_stock': 9.0,
      'reference_type': 'sale',
      'reference_id': 'analytics-refund',
      'lineage_id': 'analytics-sale-item',
      'created_at': '2026-09-01T10:00:00.000',
    });
    await db.insert('sales', {
      'id': 'analytics-out-of-range-sale',
      'total': 100.0,
      'created_at': '2026-09-02T00:00:00.000',
      'is_refund': 0,
    });
    await db.insert('sale_items', {
      'id': 'analytics-out-of-range-item',
      'sale_id': 'analytics-out-of-range-sale',
      'product_id': 'analytics-product',
      'product_name': 'Analytics Product',
      'quantity': 1.0,
      'base_quantity': 1.0,
      'price': 100.0,
      'subtotal': 100.0,
      'wholesale_price': 999.0,
    });
    await db.insert('expenses', {
      'id': 'analytics-expense',
      'title': 'Analytics Expense',
      'amount': 2.0,
      'category': 'General',
      'created_at': '2026-09-01T11:00:00.000',
    });

    final repository = AnalyticsRepositoryImpl();
    final summaryResult = await repository.getSummary(
      DateTime(2026, 9, 1),
      DateTime(2026, 9, 1),
    );
    expect(summaryResult.isRight(), isTrue);
    final summary =
        summaryResult.getOrElse(() => throw StateError('missing summary'));
    expect(summary.totalRevenue, 20);
    expect(summary.totalCost, 5);
    expect(summary.totalExpenses, 2);
    expect(summary.totalProfit, 13);
    expect(summary.returnRate, 50);

    final productsResult = await repository.getTopProducts(
      10,
      DateTime(2026, 9, 1),
      DateTime(2026, 9, 1),
    );
    expect(productsResult.isRight(), isTrue);
    final products =
        productsResult.getOrElse(() => throw StateError('missing products'));
    expect(products, hasLength(1));
    expect(products.single.quantitySold, 1);
    expect(products.single.revenue, 20);
    expect(products.single.cost, 5);
  });

  test('local Analytics replays FIFO lots across refunds and exchanges',
      () async {
    final db = PersistenceInitializer.persistenceManager!.sqliteManager;
    const productA = 'fifo-analytics-a';
    const productB = 'fifo-analytics-b';
    const categoryA = 'fifo-category-a';
    const categoryB = 'fifo-category-b';
    const categoryZero = 'fifo-category-zero';
    const originalSale = 'fifo-original-sale';
    const originalItem = 'fifo-original-item';
    const refundSale = 'fifo-refund-sale';
    const refundItem = 'fifo-refund-item';
    const replacementSale = 'fifo-replacement-sale';
    const replacementItem = 'fifo-replacement-item';
    const exchange = 'fifo-exchange';
    const productZero = 'fifo-analytics-zero';

    await db.insert('categories', {
      'id': categoryA,
      'name': 'Pantry',
      'color': '#112233',
      'sort_order': 1,
    });
    await db.insert('categories', {
      'id': categoryB,
      'name': 'Cold Drinks',
      'color': '#223344',
      'sort_order': 2,
    });
    await db.insert('categories', {
      'id': categoryZero,
      'name': 'Zero Net',
      'color': '#334455',
      'sort_order': 3,
    });
    await db.insert('products', {
      'id': productA,
      'name': 'FIFO Original',
      'price': 10.0,
      'wholesale_price': 900.0,
      'cost': 2.0,
      'stock': 0.0,
      'category_id': categoryA,
      'created_at': '2026-08-01T08:00:00.000',
      'updated_at': '2026-08-01T08:00:00.000',
    });
    await db.insert('products', {
      'id': productB,
      'name': 'FIFO Replacement',
      'price': 12.0,
      'wholesale_price': 900.0,
      'cost': 3.0,
      'stock': 0.0,
      'category_id': categoryB,
      'created_at': '2026-08-01T08:00:00.000',
      'updated_at': '2026-08-01T08:00:00.000',
    });
    await db.insert('products', {
      'id': productZero,
      'name': 'Fully Returned',
      'price': 4.0,
      'wholesale_price': 900.0,
      'cost': 2.0,
      'stock': 0.0,
      'category_id': categoryZero,
      'created_at': '2026-08-01T08:00:00.000',
      'updated_at': '2026-08-01T08:00:00.000',
    });
    await db.insert('users', {
      'id': 'fifo-analytics-user',
      'username': 'fifo-analytics-user',
      'display_name': 'FIFO Analytics Test',
      'password_hash': 'test',
      'role': 'manager',
      'created_at': '2026-08-01T08:00:00.000',
    });
    await db.insert('sales', {
      'id': originalSale,
      'total': 150.0,
      'created_at': '2026-09-01T09:00:00.000',
      'is_refund': 0,
    });
    await db.insert('sale_items', {
      'id': originalItem,
      'sale_id': originalSale,
      'product_id': productA,
      'product_name': 'FIFO Original',
      'quantity': 15.0,
      'base_quantity': 15.0,
      'price': 10.0,
      'subtotal': 150.0,
      'wholesale_price': 900.0,
      'refunded_quantity': 5.0,
      'exchanged_quantity': 1.0,
    });
    await db.insert('sales', {
      'id': refundSale,
      'original_sale_id': originalSale,
      'total': 50.0,
      'created_at': '2026-09-02T10:00:00.000',
      'is_refund': 1,
    });
    await db.insert('sale_items', {
      'id': refundItem,
      'sale_id': refundSale,
      'product_id': productA,
      'product_name': 'FIFO Original',
      'quantity': 5.0,
      'base_quantity': 5.0,
      'price': 10.0,
      'subtotal': 50.0,
      'wholesale_price': 900.0,
    });
    await db.insert('sales', {
      'id': replacementSale,
      'total': 12.0,
      'created_at': '2026-09-03T10:00:00.000',
      'is_refund': 0,
    });
    await db.insert('sale_items', {
      'id': replacementItem,
      'sale_id': replacementSale,
      'product_id': productB,
      'product_name': 'FIFO Replacement',
      'quantity': 1.0,
      'base_quantity': 1.0,
      'price': 12.0,
      'subtotal': 12.0,
      'wholesale_price': 900.0,
    });
    await db.insert('sales', {
      'id': 'fifo-zero-sale',
      'total': 4.0,
      'created_at': '2026-09-02T11:00:00.000',
      'is_refund': 0,
    });
    await db.insert('sale_items', {
      'id': 'fifo-zero-sale-item',
      'sale_id': 'fifo-zero-sale',
      'product_id': productZero,
      'product_name': 'Fully Returned',
      'quantity': 1.0,
      'base_quantity': 1.0,
      'price': 4.0,
      'subtotal': 4.0,
      'wholesale_price': 900.0,
    });
    await db.insert('sales', {
      'id': 'fifo-zero-refund',
      'original_sale_id': 'fifo-zero-sale',
      'total': 4.0,
      'created_at': '2026-09-02T12:00:00.000',
      'is_refund': 1,
    });
    await db.insert('sale_items', {
      'id': 'fifo-zero-refund-item',
      'sale_id': 'fifo-zero-refund',
      'product_id': productZero,
      'product_name': 'Fully Returned',
      'quantity': 1.0,
      'base_quantity': 1.0,
      'price': 4.0,
      'subtotal': 4.0,
      'wholesale_price': 900.0,
    });
    await db.insert('exchange_documents', {
      'id': exchange,
      'original_sale_id': originalSale,
      'replacement_sale_id': replacementSale,
      'payment_method': 'cash',
      'difference_amount': 2.0,
      'status': 'posted',
      'idempotency_key': 'fifo-analytics-exchange',
      'created_at': '2026-09-03T10:00:00.000',
      'created_by': 'fifo-analytics-user',
    });
    await db.insert('exchange_items', {
      'id': 'fifo-exchange-item',
      'exchange_id': exchange,
      'original_sale_item_id': originalItem,
      'original_product_id': productA,
      'returned_quantity': 1.0,
      'original_base_quantity': 1.0,
      'replacement_product_id': productB,
      'replacement_quantity': 1.0,
      'replacement_base_quantity': 1.0,
      'old_unit_price': 10.0,
      'new_unit_price': 12.0,
      'old_total': 10.0,
      'new_total': 12.0,
      'difference_amount': 2.0,
    });

    Future<void> movement({
      required String id,
      required String productId,
      required String type,
      required double quantity,
      required double unitCost,
      required String createdAt,
      String? referenceType,
      String? referenceId,
      String? lineageId,
    }) async {
      await db.insert('stock_movements', {
        'id': id,
        'product_id': productId,
        'product_name': switch (productId) {
          productA => 'FIFO Original',
          productB => 'FIFO Replacement',
          _ => 'Fully Returned',
        },
        'movement_type': type,
        'quantity_change': quantity,
        'unit_cost': unitCost,
        'running_stock': 0.0,
        'reference_type': referenceType,
        'reference_id': referenceId,
        'lineage_id': lineageId,
        'created_at': createdAt,
      });
    }

    await movement(
      id: 'fifo-lot-a',
      productId: productA,
      type: 'purchase',
      quantity: 10,
      unitCost: 50,
      createdAt: '2026-08-01T09:00:00.000',
      referenceType: 'purchase',
      referenceId: 'purchase-a',
    );
    await movement(
      id: 'fifo-lot-b',
      productId: productA,
      type: 'purchase',
      quantity: 10,
      unitCost: 80,
      createdAt: '2026-08-02T09:00:00.000',
      referenceType: 'purchase',
      referenceId: 'purchase-b',
    );
    await movement(
      id: 'fifo-replacement-lot',
      productId: productB,
      type: 'purchase',
      quantity: 10,
      unitCost: 30,
      createdAt: '2026-08-03T09:00:00.000',
      referenceType: 'purchase',
      referenceId: 'purchase-c',
    );
    await movement(
      id: 'fifo-zero-lot',
      productId: productZero,
      type: 'purchase',
      quantity: 1,
      unitCost: 2,
      createdAt: '2026-08-04T09:00:00.000',
      referenceType: 'purchase',
      referenceId: 'purchase-d',
    );
    await movement(
      id: 'fifo-original-issue',
      productId: productA,
      type: 'sale',
      quantity: -15,
      unitCost: 900,
      createdAt: '2026-09-01T09:00:00.000',
      referenceType: 'sale',
      referenceId: originalSale,
      lineageId: originalItem,
    );
    await movement(
      id: 'fifo-refund-return',
      productId: productA,
      type: 'customer_return',
      quantity: 5,
      unitCost: 900,
      createdAt: '2026-09-02T10:00:00.000',
      referenceType: 'refund',
      referenceId: refundSale,
      lineageId: originalItem,
    );
    await movement(
      id: 'fifo-exchange-return',
      productId: productA,
      type: 'customer_return',
      quantity: 1,
      unitCost: 80,
      createdAt: '2026-09-03T10:00:00.000',
      referenceType: 'sale',
      referenceId: originalSale,
      lineageId: originalItem,
    );
    await movement(
      id: 'fifo-replacement-issue',
      productId: productB,
      type: 'sale',
      quantity: -1,
      unitCost: 900,
      createdAt: '2026-09-03T10:00:00.000',
      referenceType: 'sale',
      referenceId: replacementSale,
      lineageId: replacementItem,
    );
    await movement(
      id: 'fifo-zero-sale-movement',
      productId: productZero,
      type: 'sale',
      quantity: -1,
      unitCost: 900,
      createdAt: '2026-09-02T11:00:00.000',
      referenceType: 'sale',
      referenceId: 'fifo-zero-sale',
      lineageId: 'fifo-zero-sale-item',
    );
    await movement(
      id: 'fifo-zero-refund-movement',
      productId: productZero,
      type: 'customer_return',
      quantity: 1,
      unitCost: 900,
      createdAt: '2026-09-02T12:00:00.000',
      referenceType: 'refund',
      referenceId: 'fifo-zero-refund',
      lineageId: 'fifo-zero-sale-item',
    );

    final repository = AnalyticsRepositoryImpl();
    final full = await repository.getSummary(
      DateTime(2026, 9, 1),
      DateTime(2026, 9, 3),
    );
    expect(full.isRight(), isTrue);
    final summary = full.getOrElse(() => throw StateError('missing summary'));
    expect(summary.totalRevenue, 102);
    expect(summary.totalCost, 480);
    expect(summary.totalExpenses, 0);
    expect(summary.totalProfit, -378);
    expect(summary.returnRate, closeTo(35.294117647058826, 1e-9));

    final refundOnly = await repository.getSummary(
      DateTime(2026, 9, 2),
      DateTime(2026, 9, 2),
    );
    expect(refundOnly.isRight(), isTrue);
    final refundSummary =
        refundOnly.getOrElse(() => throw StateError('missing refund summary'));
    expect(refundSummary.totalRevenue, -50);
    expect(refundSummary.totalCost, -400);

    final exchangeOnly = await repository.getSummary(
      DateTime(2026, 9, 3),
      DateTime(2026, 9, 3),
    );
    expect(exchangeOnly.isRight(), isTrue);
    final exchangeSummary = exchangeOnly
        .getOrElse(() => throw StateError('missing exchange summary'));
    expect(exchangeSummary.totalRevenue, 2);
    expect(exchangeSummary.totalCost, -20);

    final beforeRefundBoundary = await repository.getSummary(
      DateTime(2026, 9, 1),
      DateTime(2026, 9, 1),
    );
    expect(beforeRefundBoundary.isRight(), isTrue);
    final boundarySummary = beforeRefundBoundary
        .getOrElse(() => throw StateError('missing boundary summary'));
    expect(boundarySummary.totalRevenue, 150);
    expect(boundarySummary.totalCost, 900);

    final productsResult = await repository.getTopProducts(
      10,
      DateTime(2026, 9, 1),
      DateTime(2026, 9, 3),
    );
    expect(productsResult.isRight(), isTrue);
    final products = productsResult
        .getOrElse(() => throw StateError('missing top products'));
    final original = products.singleWhere((item) => item.productId == productA);
    final replacement =
        products.singleWhere((item) => item.productId == productB);
    expect(original.quantitySold, 9);
    expect(original.revenue, 90);
    expect(original.cost, 450);
    expect(replacement.cost, 30);
    expect(products.any((item) => item.productId == productZero), isFalse);

    final categories = await repository.getSalesByCategory(
      DateTime(2026, 9, 1),
      DateTime(2026, 9, 3),
    );
    expect(categories.isRight(), isTrue);
    final categoryMap =
        categories.getOrElse(() => throw StateError('missing categories'));
    expect(categoryMap, containsPair('Pantry', 90));
    expect(categoryMap, containsPair('Cold Drinks', 12));
    expect(categoryMap, isNot(contains('Zero Net')));
    expect(categoryMap.containsKey(categoryA), isFalse);

    final zeroNet = await repository.getSummary(
      DateTime(2026, 9, 2),
      DateTime(2026, 9, 2),
    );
    expect(zeroNet.isRight(), isTrue);
  });

  test('seedIfNeeded restores missing demo users without duplicating them',
      () async {
    final db = PersistenceInitializer.persistenceManager!.sqliteManager;
    await db.delete('users');
    await db.insert(
        'categories',
        {
          'id': 'demo-cat',
          'name': 'Demo',
          'sort_order': 1,
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
    await db.insert(
        'products',
        {
          'id': 'seeded-product',
          'barcode': 'seeded-product',
          'name': 'Seeded Product',
          'price': 100.0,
          'min_price': 80.0,
          'wholesale_price': 90.0,
          'stock': 5.0,
          'min_stock': 1.0,
          'category_id': 'demo-cat',
          'is_active': 1,
          'created_at': DateTime.now().toIso8601String(),
          'updated_at': DateTime.now().toIso8601String(),
        },
        conflictAlgorithm: ConflictAlgorithm.replace);

    await DebugSeeder.seedIfNeeded();

    final rows = await db.query(
      'users',
      where: 'username IN (?, ?, ?)',
      whereArgs: ['admin', 'cashier-1', 'cashier'],
    );

    final usernames = rows.map((row) => row['username'] as String).toSet();
    expect(usernames, containsAll(['admin', 'cashier-1', 'cashier']));

    final adminRow = rows.firstWhere((row) => row['username'] == 'admin');
    final cashierRow = rows.firstWhere((row) => row['username'] == 'cashier-1');
    expect(adminRow['password_hash'], 'admin');
    expect(cashierRow['password_hash'], 'cashier');

    final adminCount = await db.query(
      'users',
      where: 'username = ?',
      whereArgs: ['admin'],
    );
    final cashierCount = await db.query(
      'users',
      where: 'username = ?',
      whereArgs: ['cashier-1'],
    );
    expect(adminCount, hasLength(1));
    expect(cashierCount, hasLength(1));

    await DebugSeeder.seedIfNeeded();
    final rowsAfterRetry = await db.query('users',
        where: 'username IN (?, ?, ?)',
        whereArgs: ['admin', 'cashier-1', 'cashier']);
    expect(rowsAfterRetry, hasLength(3));
  });

  test(
      'demo credentials authenticate successfully and wrong credentials are rejected',
      () async {
    await DebugSeeder.seedIfNeeded();
    final repository = UserRepositoryImp();

    final adminResult = await repository.getUser('admin');
    final cashierResult = await repository.getUser('cashier-1');
    final unknownResult = await repository.getUser('missing-user');

    expect(adminResult.fold((failure) => false, (user) => true), isTrue);
    expect(cashierResult.fold((failure) => false, (user) => true), isTrue);
    expect(unknownResult.fold((failure) => true, (user) => false), isTrue);

    final adminUser = adminResult.fold(
        (failure) => throw StateError(failure.message), (user) => user);
    final cashierUser = cashierResult.fold(
        (failure) => throw StateError(failure.message), (user) => user);
    expect(adminUser.password, 'admin');
    expect(adminUser.userType, UserType.admin);
    expect(cashierUser.password, 'cashier');
    expect(cashierUser.userType, UserType.cashier);
    expect(adminUser.password == 'wrong-password', isFalse);
    expect(cashierUser.password == 'wrong-password', isFalse);

    final adminCount =
        await PersistenceInitializer.persistenceManager!.sqliteManager.query(
      'users',
      where: 'username = ?',
      whereArgs: ['admin'],
    );
    final cashierCount =
        await PersistenceInitializer.persistenceManager!.sqliteManager.query(
      'users',
      where: 'username = ?',
      whereArgs: ['cashier-1'],
    );
    expect(adminCount, hasLength(1));
    expect(cashierCount, hasLength(1));
  });

  test('Sale retry after rollback reuses the same logical identity', () async {
    await _seedSaleFixture();
    final repository = SalesRepositoryImpl();
    final failedSale = Sale(
      id: 'retry-sale',
      total: 900,
      items: 2,
      date: DateTime(2026, 9, 3),
      cashierName: 'Cashier',
      cashierUsername: 'cashier-1',
      customerId: 'sale-customer',
      paymentMethod: 'credit',
      saleItems: [
        SaleItem(
          productId: 'sale-product',
          name: 'Sale Product',
          price: 450,
          quantity: 1,
          total: 450,
          wholesalePrice: 300,
        ),
        SaleItem(
          productId: 'missing-product',
          name: 'Missing',
          price: 450,
          quantity: 1,
          total: 450,
          wholesalePrice: 300,
        ),
      ],
    );
    expect((await repository.saveSale(failedSale)).isLeft(), isTrue);

    final db = PersistenceInitializer.persistenceManager!.sqliteManager;
    expect(await db.query('sales'), isEmpty);
    expect(await db.query('sale_items'), isEmpty);
    expect((await db.query('products')).single['stock'], 10.0);
    expect(await db.query('stock_movements'), isEmpty);
    expect(await db.query('customer_ledger'), isEmpty);

    final retry = Sale(
      id: failedSale.id,
      total: 450,
      items: 1,
      date: failedSale.date,
      cashierName: failedSale.cashierName,
      cashierUsername: failedSale.cashierUsername,
      customerId: failedSale.customerId,
      paymentMethod: failedSale.paymentMethod,
      saleItems: [failedSale.saleItems.first],
    );
    expect((await repository.saveSale(retry)).isRight(), isTrue);
    expect(await db.query('sales'), hasLength(1));
    expect(await db.query('sale_items'), hasLength(1));
    expect(await db.query('stock_movements'), hasLength(1));
    expect((await db.query('products')).single['stock'], 9.0);
    expect(await db.query('customer_ledger'), hasLength(1));
  });

  test('Completed Sale submission does not duplicate stock or ledger effects',
      () async {
    await _seedSaleFixture();
    final sale = Sale(
      id: 'completed-sale',
      total: 450,
      items: 1,
      date: DateTime(2026, 9, 3),
      cashierName: 'Cashier',
      cashierUsername: 'cashier-1',
      customerId: 'sale-customer',
      paymentMethod: 'credit',
      saleItems: [
        SaleItem(
          productId: 'sale-product',
          name: 'Sale Product',
          price: 450,
          quantity: 1,
          total: 450,
          wholesalePrice: 300,
        )
      ],
    );
    final repository = SalesRepositoryImpl();
    expect((await repository.saveSale(sale)).isRight(), isTrue);
    expect((await repository.saveSale(sale)).isLeft(), isTrue);
    final db = PersistenceInitializer.persistenceManager!.sqliteManager;
    expect(await db.query('sales'), hasLength(1));
    expect(await db.query('sale_items'), hasLength(1));
    expect(await db.query('stock_movements'), hasLength(1));
    expect((await db.query('products')).single['stock'], 9.0);
    expect(await db.query('customer_ledger'), hasLength(1));
  });

  test('Purchase retry after rollback reuses the same document identity',
      () async {
    await _seedPurchaseFixtures();
    final repository = PurchaseRepositoryImpl();
    expect(
        (await repository.createPurchase(_purchase(
          'retry-purchase',
          [_line(1, 5, 10), _line(99, 1, 10)],
        )))
            .isLeft(),
        isTrue);
    final db = PersistenceInitializer.persistenceManager!.sqliteManager;
    expect(await db.query('purchases'), isEmpty);
    expect((await db.query('products')).single['stock'], 20.0);
    expect(await db.query('stock_movements'), isEmpty);
    expect(await db.query('supplier_ledger'), isEmpty);

    expect(
        (await repository
                .createPurchase(_purchase('retry-purchase', [_line(1, 5, 10)])))
            .isRight(),
        isTrue);
    expect(await db.query('purchases'), hasLength(1));
    expect(await db.query('purchase_items'), hasLength(1));
    expect(await db.query('stock_movements'), hasLength(1));
    expect((await db.query('products')).single['stock'], 25.0);
    expect(await db.query('supplier_ledger'), hasLength(1));
    expect(await db.query('cash_movements'), isEmpty);
  });

  test('Supplier Return retry after rollback reuses the same return identity',
      () async {
    await _seedPurchaseFixtures();
    await PurchaseRepositoryImpl()
        .createPurchase(_purchase('retry-return-purchase', [_line(1, 5, 10)]));
    final line = const SupplierReturnLine(
      purchaseItemId: 'retry-return-purchase_purchase-product-1',
      productId: 'purchase-product-1',
      quantity: 2,
    );
    final failedRepository = SupplierReturnRepositoryImpl(
      failureInjector: (_) async => throw StateError('forced return failure'),
    );
    expect(
        (await failedRepository.createReturn(
          _returnValue('retry-return', 'retry-return-purchase', [line]),
        ))
            .isLeft(),
        isTrue);
    final db = PersistenceInitializer.persistenceManager!.sqliteManager;
    expect(await db.query('supplier_returns'), isEmpty);
    expect((await db.query('products')).single['stock'], 25.0);
    expect(
        await db.query('stock_movements',
            where: 'movement_type = ?', whereArgs: ['supplier_return']),
        isEmpty);
    expect(
        await db.query('supplier_ledger',
            where: 'entry_type = ?', whereArgs: ['supplier_return']),
        isEmpty);

    expect(
        (await SupplierReturnRepositoryImpl().createReturn(
                _returnValue('retry-return', 'retry-return-purchase', [line])))
            .isRight(),
        isTrue);
    expect(await db.query('supplier_returns'), hasLength(1));
    expect(
        await db.query('stock_movements',
            where: 'movement_type = ?', whereArgs: ['supplier_return']),
        hasLength(1));
    expect((await db.query('products')).single['stock'], 23.0);
    expect(
        await db.query('supplier_ledger',
            where: 'entry_type = ?', whereArgs: ['supplier_return']),
        hasLength(1));
  });

  test('Concurrent identical purchases commit at most one posting', () async {
    await _seedPurchaseFixtures();
    final purchase = _purchase('concurrent-purchase', [_line(1, 2, 10)]);
    final results = await Future.wait([
      PurchaseRepositoryImpl().createPurchase(purchase),
      PurchaseRepositoryImpl().createPurchase(purchase),
    ]);
    expect(results.every((result) => result.isRight()), isTrue);
    final db = PersistenceInitializer.persistenceManager!.sqliteManager;
    expect(await db.query('purchases'), hasLength(1));
    expect(await db.query('stock_movements'), hasLength(1));
    expect(await db.query('supplier_ledger'), hasLength(1));
    expect((await db.query('products')).single['stock'], 22.0);
  });

  test('Customer and supplier models serialize correctly', () {
    final createdAt = DateTime(2025, 1, 2, 12, 30);
    final updatedAt = DateTime(2025, 1, 2, 13, 0);

    final customer = Customer(
      id: 'cust-1',
      code: 'CUST-001',
      name: 'Ahmed Ali',
      phone: '01000000000',
      email: 'ahmed@example.com',
      address: 'Cairo',
      currentBalance: 150.5,
      createdAt: createdAt,
      updatedAt: updatedAt,
    );

    final supplier = Supplier(
      id: 'sup-1',
      code: 'SUP-001',
      name: 'Omar Supply',
      phone: '01111111111',
      email: 'omar@example.com',
      address: 'Alexandria',
      currentBalance: 350.0,
      createdAt: createdAt,
      updatedAt: updatedAt,
    );

    final movement = StockMovement(
      id: 'mv-1',
      productId: 'prod-1',
      productBarcode: '123',
      productName: 'Rice 5kg',
      movementType: 'sale',
      quantityChange: -2,
      unitCost: 20,
      runningStock: 18,
      referenceType: 'sale',
      referenceId: 'sale-1',
      createdAt: createdAt,
    );

    expect(customer.toMap()['current_balance'], 150.5);
    expect(supplier.toMap()['name'], 'Omar Supply');
    expect(movement.toMap()['movement_type'], 'sale');
    expect(Customer.fromMap(customer.toMap()).id, 'cust-1');
    expect(Supplier.fromMap(supplier.toMap()).name, 'Omar Supply');
  });

  test(
      'Permission guard allows managers and denies cashiers for customer access',
      () {
    final manager = User(
      username: 'manager1',
      name: 'Manager',
      phone: '010',
      userType: UserType.manager,
      password: 'pass',
    );

    final cashier = User(
      username: 'cashier1',
      name: 'Cashier',
      phone: '011',
      userType: UserType.cashier,
      password: 'pass',
    );

    expect(PermissionGuard.canAccessCustomerModule(manager), isTrue);
    expect(PermissionGuard.canAccessCustomerModule(cashier), isFalse);

    expect(
      () => PermissionGuard.requireCustomerAccess(cashier),
      throwsA(isA<PermissionDeniedException>()),
    );
  });

  test('Manager sidebar filter retains customer and supplier navigation items',
      () {
    final items = [
      SidebarItem(
          id: 'dashboard',
          icon: Icons.home,
          title: 'Dashboard',
          screen: const SizedBox()),
      SidebarItem(
          id: 'customers',
          icon: Icons.people,
          title: 'Customers',
          screen: const SizedBox()),
      SidebarItem(
          id: 'suppliers',
          icon: Icons.local_shipping,
          title: 'Suppliers',
          screen: const SizedBox()),
    ];
    final filtered = CustomSidebar.filterItems(items);
    expect(filtered.map((item) => item.id),
        containsAll(['customers', 'suppliers']));
  });

  test('Backup contains ERP tables and persisted customer data', () async {
    final db = PersistenceInitializer.persistenceManager!.sqliteManager;
    await db.insert(
        'customers',
        Customer(
          id: 'backup-customer',
          code: 'BACKUP-001',
          name: 'Backup Customer',
          phone: '010',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ).toMap());

    final manager = PersistenceInitializer.persistenceManager!.backupManager;
    expect(await manager.createBackup(), isTrue);
    final backup = await manager.getLatestBackup();
    expect(backup, isNotNull);

    final backupDbPath = p.join(
        backup!.path,
        p.basename(
          PersistenceInitializer.persistenceManager!.sqliteManager.databasePath,
        ));
    final backupDb = await openDatabase(backupDbPath, readOnly: true);
    final tables = await backupDb.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table'",
    );
    final tableNames = tables.map((row) => row['name']).toSet();
    expect(
        tableNames,
        containsAll([
          'customers',
          'suppliers',
          'customer_ledger',
          'supplier_ledger',
          'stock_movements',
          'sales',
          'sale_items',
        ]));
    expect(
      await backupDb
          .query('customers', where: 'id = ?', whereArgs: ['backup-customer']),
      hasLength(1),
    );
    await backupDb.close();
  });

  test('SQLite online backup creates a valid standalone database snapshot',
      () async {
    final db = PersistenceInitializer.persistenceManager!.sqliteManager;
    await db.insert(
      'customers',
      Customer(
        id: 'native-backup-customer',
        code: 'NATIVE-001',
        name: 'Native Backup Customer',
        phone: '013',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ).toMap(),
    );

    final manager = PersistenceInitializer.persistenceManager!.backupManager;
    expect(await manager.createBackup(), isTrue);

    final backup = await manager.getLatestBackup();
    expect(backup, isNotNull);

    final nativeDbPath = p.join(
      backup!.path,
      p.basename(PersistenceInitializer
          .persistenceManager!.sqliteManager.databasePath),
    );
    final nativeDb =
        sqlite3.sqlite3.open(nativeDbPath, mode: sqlite3.OpenMode.readOnly);
    try {
      final tableNames = nativeDb.select(
        "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name",
      );
      expect(tableNames, isNotEmpty);
      expect(tableNames.any((row) => row['name'] == 'customers'), isTrue);
    } finally {
      nativeDb.dispose();
    }
  });

  test(
      'Backup validation rejects corrupted manifests and valid backups restore cleanly',
      () async {
    final db = PersistenceInitializer.persistenceManager!.sqliteManager;
    await db.insert(
      'customers',
      Customer(
        id: 'restore-customer',
        code: 'RESTORE-001',
        name: 'Restored Customer',
        phone: '011',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ).toMap(),
    );

    final manager = PersistenceInitializer.persistenceManager!.backupManager;
    expect(await manager.createBackup(), isTrue);

    final backup = await manager.getLatestBackup();
    expect(backup, isNotNull);

    final manifestFile = File(p.join(backup!.path, 'backup_manifest.json'));
    final manifestText = await manifestFile.readAsString();
    await manifestFile.writeAsString(
      manifestText.replaceFirst(
        '"database_schema_version": ${SQLiteManager.databaseSchemaVersion}',
        '"database_schema_version": 999',
      ),
    );
    expect(await manager.validateBackup(backup.path), isFalse);
    await manifestFile.writeAsString(manifestText);

    await db.insert(
      'customers',
      Customer(
        id: 'restore-customer-2',
        code: 'RESTORE-002',
        name: 'Customer After Backup',
        phone: '012',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ).toMap(),
    );

    expect(await manager.restoreFromBackup(backup.path), isTrue);
    expect(await db.checkIntegrity(), isTrue);
    final activeDb = PersistenceInitializer.persistenceManager!.sqliteManager;
    expect(
      await activeDb
          .query('customers', where: 'id = ?', whereArgs: ['restore-customer']),
      hasLength(1),
    );
  });

  test('ERP activity types are registered for audit logging', () {
    expect(ActivityType.customerCreated.name, 'customerCreated');
    expect(ActivityType.supplierPayment.name, 'supplierPayment');
    expect(ActivityType.stockAdjustment.name, 'stockAdjustment');
  });

  test('Successful purchase atomically increases stock and supplier balance',
      () async {
    final db = PersistenceInitializer.persistenceManager!.sqliteManager;
    await db.insert('suppliers', {
      'id': 'supplier-purchase',
      'code': 'SUP-P',
      'name': 'Purchase Supplier',
      'is_active': 1,
      'created_at': DateTime.now().toIso8601String(),
      'updated_at': DateTime.now().toIso8601String(),
    });
    await db.insert('categories', {
      'id': 'cat-purchase',
      'name': 'Purchase',
      'color': '#000',
      'sort_order': 0,
    });
    await db.insert('products', {
      'id': 'PUR-001',
      'barcode': 'PUR-001',
      'name': 'Purchased product',
      'price': 20.0,
      'min_price': 1.0,
      'wholesale_price': 10.0,
      'stock': 20.0,
      'min_stock': 2.0,
      'category_id': 'cat-purchase',
      'is_active': 1,
      'created_at': DateTime.now().toIso8601String(),
      'updated_at': DateTime.now().toIso8601String(),
    });
    final result = await PurchaseRepositoryImpl().createPurchase(Purchase(
      id: 'purchase-1',
      referenceNumber: 'PUR-001',
      supplierId: 'supplier-purchase',
      purchaseDate: DateTime.now(),
      lines: const [
        PurchaseLine(
          productId: 'PUR-001',
          productName: 'Purchased product',
          productBarcode: 'PUR-001',
          quantity: 50,
          unitCost: 10,
        ),
      ],
      createdBy: 'manager',
    ));
    expect(result.isRight(), isTrue);
    expect(await db.query('purchases'), hasLength(1));
    expect(await db.query('purchase_items'), hasLength(1));
    expect((await db.query('products')).first['stock'], 70.0);
    expect((await db.query('stock_movements')).first['quantity_change'], 50.0);
    expect((await db.query('supplier_ledger')).first['amount'], 500.0);
    expect(
        (await db.query('activity_logs',
            where: 'type = ?', whereArgs: ['purchaseCreated'])),
        hasLength(1));
  });

  test('Purchase posting is confirmed-only and idempotent', () async {
    await _seedPurchaseFixtures();
    final repository = PurchaseRepositoryImpl();
    final draft =
        _purchase('draft-purchase', [_line(1, 2, 10)], status: 'draft');
    expect((await repository.createPurchase(draft)).isLeft(), isTrue);
    final purchase = _purchase('idempotent-purchase', [_line(1, 2, 10)]);
    expect((await repository.createPurchase(purchase)).isRight(), isTrue);
    expect((await repository.createPurchase(purchase)).isRight(), isTrue);
    final db = PersistenceInitializer.persistenceManager!.sqliteManager;
    expect(await db.query('purchases'), hasLength(1));
    expect(await db.query('purchase_items'), hasLength(1));
    expect(await db.query('stock_movements'), hasLength(1));
    expect(await db.query('supplier_ledger'), hasLength(1));
  });

  test('Cashier cannot create a purchase', () async {
    getIt<UserCubit>().currentUser = User(
      username: 'cashier',
      name: 'Cashier',
      phone: '011',
      userType: UserType.cashier,
      password: 'pass',
    );
    final result = await PurchaseRepositoryImpl().createPurchase(Purchase(
      id: 'purchase-denied',
      referenceNumber: 'PUR-DENIED',
      supplierId: 'missing',
      purchaseDate: DateTime(2025),
      lines: [],
    ));
    expect(result.isLeft(), isTrue);
    getIt<UserCubit>().currentUser = User(
      username: 'manager',
      name: 'Manager',
      phone: '010',
      userType: UserType.manager,
      password: 'pass',
    );
  });

  test('Purchase rolls back all mutations after a downstream product failure',
      () async {
    await _seedPurchaseFixtures();
    final db = PersistenceInitializer.persistenceManager!.sqliteManager;
    final result = await PurchaseRepositoryImpl().createPurchase(_purchase(
      'rollback-purchase',
      [_line(1, 50, 10), _line(99, 1, 10)],
    ));
    expect(result.isLeft(), isTrue);
    expect((await db.query('purchases')), isEmpty);
    expect((await db.query('purchase_items')), isEmpty);
    expect(
        (await db.query('products',
                where: 'id = ?', whereArgs: ['purchase-product-1']))
            .single['stock'],
        20.0);
    expect(
        (await db.query('stock_movements',
            where: 'reference_id = ?', whereArgs: ['rollback-purchase'])),
        isEmpty);
    expect(
        (await db.query('supplier_ledger',
            where: 'reference_id = ?', whereArgs: ['rollback-purchase'])),
        isEmpty);
    expect(
        (await db.query('activity_logs',
            where: 'event_key = ? AND details LIKE ?',
            whereArgs: ['purchaseCreated', '%rollback-purchase%'])),
        isEmpty);
  });

  test(
      'Multi-line purchase updates each product and records one total ledger entry',
      () async {
    await _seedPurchaseFixtures(products: 3);
    final db = PersistenceInitializer.persistenceManager!.sqliteManager;
    final result = await PurchaseRepositoryImpl().createPurchase(_purchase(
      'multi-purchase',
      [_line(1, 10, 2), _line(2, 20, 3), _line(3, 5, 4)],
    ));
    expect(result.isRight(), isTrue);
    expect(await db.query('purchases'), hasLength(1));
    expect(await db.query('purchase_items'), hasLength(3));
    for (var i = 1; i <= 3; i++) {
      expect(
          (await db.query('products',
                  where: 'id = ?', whereArgs: ['purchase-product-$i']))
              .single['stock'],
          20.0 + [10, 20, 5][i - 1]);
    }
    expect(
        await db.query('stock_movements',
            where: 'reference_id = ?', whereArgs: ['multi-purchase']),
        hasLength(3));
    final ledger = await db.query('supplier_ledger',
        where: 'reference_id = ?', whereArgs: ['multi-purchase']);
    expect(ledger, hasLength(1));
    expect(ledger.single['amount'], 100.0);
  });

  test('Invalid purchase inputs leave the database unchanged', () async {
    await _seedPurchaseFixtures();
    final db = PersistenceInitializer.persistenceManager!.sqliteManager;
    for (final purchase in [
      _purchase('zero-quantity', [_line(1, 0, 10)]),
      _purchase('negative-quantity', [_line(1, -1, 10)]),
      _purchase('missing-product', [_line(99, 1, 10)]),
      _purchase('missing-supplier', [_line(1, 1, 10)], supplierId: 'missing'),
    ]) {
      expect((await PurchaseRepositoryImpl().createPurchase(purchase)).isLeft(),
          isTrue);
    }
    expect(await db.query('purchases'), isEmpty);
    expect(await db.query('purchase_items'), isEmpty);
    expect((await db.query('products')).single['stock'], 20.0);
    expect(await db.query('stock_movements'), isEmpty);
    expect(await db.query('supplier_ledger'), isEmpty);
  });

  test('Purchase references are unique and history preserves purchase fields',
      () async {
    await _seedPurchaseFixtures();
    final repository = PurchaseRepositoryImpl();
    expect(
        (await repository
                .createPurchase(_purchase('first-purchase', [_line(1, 1, 10)])))
            .isRight(),
        isTrue);
    expect(
        (await repository.createPurchase(
                _purchase('second-purchase', [_line(1, 1, 10)])))
            .isRight(),
        isTrue);
    final history = (await repository.getPurchases()).getOrElse(() => []);
    expect(history, hasLength(2));
    expect(
        history[0]['reference_number'], isNot(history[1]['reference_number']));
    expect(
        history.every((row) =>
            row['purchase_date'] != null &&
            row['supplier_id'] == 'purchase-supplier' &&
            row['total'] != null &&
            row['status'] == 'confirmed'),
        isTrue);
  });

  test('Supplier payment reduces ledger balance and records audit', () async {
    await _seedPurchaseFixtures();
    final purchaseRepository = PurchaseRepositoryImpl();
    final paymentRepository = SupplierPaymentRepositoryImpl();
    await purchaseRepository
        .createPurchase(_purchase('payment-purchase', [_line(1, 1, 100)]));
    final result =
        await paymentRepository.createPayment(_payment('payment-1', 40));
    expect(result.isRight(), isTrue);
    final db = PersistenceInitializer.persistenceManager!.sqliteManager;
    expect(await db.query('supplier_payments'), hasLength(1));
    expect(
        (await db.query('supplier_ledger',
                where: 'reference_id = ?', whereArgs: ['payment-1']))
            .single['amount'],
        -40.0);
    expect(
        (await SupplierRepositoryImpl().getSupplierBalance('purchase-supplier'))
            .getOrElse(() => -1),
        60.0);
    expect(
        await db.query('activity_logs',
            where: 'event_key = ?', whereArgs: ['supplierPayment']),
        hasLength(1));
  });

  test('Full supplier payment reaches zero balance', () async {
    await _seedPurchaseFixtures();
    await PurchaseRepositoryImpl()
        .createPurchase(_purchase('full-payment-purchase', [_line(1, 1, 100)]));
    expect(
        (await SupplierPaymentRepositoryImpl()
                .createPayment(_payment('full-payment', 100)))
            .isRight(),
        isTrue);
    expect(
        (await SupplierRepositoryImpl().getSupplierBalance('purchase-supplier'))
            .getOrElse(() => -1),
        0.0);
  });

  test('Invalid supplier payments preserve all database state', () async {
    await _seedPurchaseFixtures();
    await PurchaseRepositoryImpl().createPurchase(
        _purchase('invalid-payment-purchase', [_line(1, 1, 100)]));
    final repository = SupplierPaymentRepositoryImpl();
    for (final payment in [
      _payment('zero-payment', 0),
      _payment('negative-payment', -1),
      _payment('over-payment', 101),
      _payment('missing-supplier', 1, supplierId: 'missing'),
    ]) {
      expect((await repository.createPayment(payment)).isLeft(), isTrue);
    }
    final db = PersistenceInitializer.persistenceManager!.sqliteManager;
    expect(await db.query('supplier_payments'), isEmpty);
    expect(
        await db.query('supplier_ledger',
            where: 'entry_type = ?', whereArgs: ['supplier_payment']),
        isEmpty);
    expect(
        (await SupplierRepositoryImpl().getSupplierBalance('purchase-supplier'))
            .getOrElse(() => -1),
        100.0);
    expect(
        await db.query('activity_logs',
            where: 'event_key = ?', whereArgs: ['supplierPayment']),
        isEmpty);
  });

  test('Supplier payment rolls back after downstream failure', () async {
    await _seedPurchaseFixtures();
    await PurchaseRepositoryImpl().createPurchase(
        _purchase('rollback-payment-purchase', [_line(1, 1, 100)]));
    final repository = SupplierPaymentRepositoryImpl(
      failureInjector: (_) async => throw StateError('forced payment failure'),
    );
    final result =
        await repository.createPayment(_payment('rollback-payment', 40));
    expect(result.isLeft(), isTrue);
    final db = PersistenceInitializer.persistenceManager!.sqliteManager;
    expect(await db.query('supplier_payments'), isEmpty);
    expect(
        await db.query('supplier_ledger',
            where: 'reference_id = ?', whereArgs: ['rollback-payment']),
        isEmpty);
    expect(
        (await SupplierRepositoryImpl().getSupplierBalance('purchase-supplier'))
            .getOrElse(() => -1),
        100.0);
    expect(
        await db.query('activity_logs',
            where: 'event_key = ?', whereArgs: ['supplierPayment']),
        isEmpty);
  });

  test(
      'Multiple supplier payments and payment history preserve references and methods',
      () async {
    await _seedPurchaseFixtures();
    await PurchaseRepositoryImpl().createPurchase(
        _purchase('multiple-payment-purchase', [_line(1, 1, 100)]));
    final repository = SupplierPaymentRepositoryImpl();
    expect(
        (await repository.createPayment(_payment('payment-a', 30))).isRight(),
        isTrue);
    expect(
        (await repository.createPayment(_payment('payment-b', 20))).isRight(),
        isTrue);
    final history =
        (await repository.getPaymentHistory(supplierId: 'purchase-supplier'))
            .getOrElse(() => []);
    expect(history, hasLength(2));
    expect(history.map((row) => row['reference']).toSet(), hasLength(2));
    expect(
        history.every((row) =>
            row['supplier_name'] == 'Purchase Supplier' &&
            row['payment_method'] == 'cash'),
        isTrue);
    expect(
        (await SupplierRepositoryImpl().getSupplierBalance('purchase-supplier'))
            .getOrElse(() => -1),
        50.0);
  });

  test('Cashier cannot create supplier payment at service boundary', () async {
    await _seedPurchaseFixtures();
    await PurchaseRepositoryImpl().createPurchase(
        _purchase('permission-payment-purchase', [_line(1, 1, 100)]));
    getIt<UserCubit>().currentUser = User(
      username: 'cashier',
      name: 'Cashier',
      phone: '011',
      userType: UserType.cashier,
      password: 'pass',
    );
    final result = await SupplierPaymentRepositoryImpl()
        .createPayment(_payment('denied-payment', 10));
    expect(result.isLeft(), isTrue);
    getIt<UserCubit>().currentUser = User(
      username: 'manager',
      name: 'Manager',
      phone: '010',
      userType: UserType.manager,
      password: 'pass',
    );
  });

  test('Supplier return decreases stock, liability, and records audit',
      () async {
    await _seedPurchaseFixtures();
    await PurchaseRepositoryImpl()
        .createPurchase(_purchase('return-purchase', [_line(1, 10, 100)]));
    final result = await SupplierReturnRepositoryImpl().createReturn(
      _returnValue('return-1', 'return-purchase', [
        const SupplierReturnLine(
            purchaseItemId: 'return-purchase_purchase-product-1',
            productId: 'purchase-product-1',
            quantity: 3)
      ]),
    );
    expect(result.isRight(), isTrue);
    final db = PersistenceInitializer.persistenceManager!.sqliteManager;
    expect(await db.query('supplier_returns'), hasLength(1));
    expect(await db.query('supplier_return_items'), hasLength(1));
    expect((await db.query('products')).single['stock'], 27.0);
    expect(
        (await db.query('stock_movements',
                where: 'movement_type = ?', whereArgs: ['supplier_return']))
            .single['quantity_change'],
        -3.0);
    expect(
        (await db.query('supplier_ledger',
                where: 'entry_type = ?', whereArgs: ['supplier_return']))
            .single['amount'],
        -300.0);
    expect(
        await db.query('activity_logs',
            where: 'event_key = ?', whereArgs: ['supplierReturn']),
        hasLength(1));
    expect(await db.query('cash_movements'), isEmpty);
  });

  test('Supplier return posting is confirmed-only and idempotent', () async {
    await _seedPurchaseFixtures();
    await PurchaseRepositoryImpl()
        .createPurchase(_purchase('return-gating-purchase', [_line(1, 4, 10)]));
    final repository = SupplierReturnRepositoryImpl();
    final line = const SupplierReturnLine(
        purchaseItemId: 'return-gating-purchase_purchase-product-1',
        productId: 'purchase-product-1',
        quantity: 1);
    expect(
        (await repository.createReturn(_returnValue(
          'draft-return',
          'return-gating-purchase',
          [line],
          status: 'draft',
        )))
            .isLeft(),
        isTrue);
    final value =
        _returnValue('idempotent-return', 'return-gating-purchase', [line]);
    expect((await repository.createReturn(value)).isRight(), isTrue);
    expect((await repository.createReturn(value)).isRight(), isTrue);
    final db = PersistenceInitializer.persistenceManager!.sqliteManager;
    expect(await db.query('supplier_returns'), hasLength(1));
    expect(await db.query('supplier_return_items'), hasLength(1));
    expect(
        await db.query('stock_movements',
            where: 'movement_type = ?', whereArgs: ['supplier_return']),
        hasLength(1));
    expect(
        await db.query('supplier_ledger',
            where: 'entry_type = ?', whereArgs: ['supplier_return']),
        hasLength(1));
  });

  test('Supplier returns support partial and full return limits', () async {
    await _seedPurchaseFixtures();
    await PurchaseRepositoryImpl().createPurchase(
        _purchase('partial-return-purchase', [_line(1, 10, 100)]));
    final repository = SupplierReturnRepositoryImpl();
    expect(
        (await repository.createReturn(_returnValue(
          'partial-return-1',
          'partial-return-purchase',
          [
            const SupplierReturnLine(
                purchaseItemId: 'partial-return-purchase_purchase-product-1',
                productId: 'purchase-product-1',
                quantity: 3)
          ],
        )))
            .isRight(),
        isTrue);
    expect(
        (await repository.createReturn(_returnValue(
          'partial-return-2',
          'partial-return-purchase',
          [
            const SupplierReturnLine(
                purchaseItemId: 'partial-return-purchase_purchase-product-1',
                productId: 'purchase-product-1',
                quantity: 7)
          ],
        )))
            .isRight(),
        isTrue);
    expect(
        await PersistenceInitializer.persistenceManager!.sqliteManager
            .query('supplier_return_items'),
        hasLength(2));
  });

  test(
      'Supplier return rejects over-return and stock shortage without mutation',
      () async {
    await _seedPurchaseFixtures();
    await PurchaseRepositoryImpl().createPurchase(
        _purchase('invalid-return-purchase', [_line(1, 10, 100)]));
    final repository = SupplierReturnRepositoryImpl();
    final item = const SupplierReturnLine(
      purchaseItemId: 'invalid-return-purchase_purchase-product-1',
      productId: 'purchase-product-1',
      quantity: 8,
    );
    expect(
        (await repository.createReturn(_returnValue(
                'return-three', 'invalid-return-purchase', [item])))
            .isRight(),
        isTrue);
    final db = PersistenceInitializer.persistenceManager!.sqliteManager;
    expect((await db.query('products')).single['stock'], 22.0);
    expect(
        (await repository.createReturn(_returnValue(
          'return-four',
          'invalid-return-purchase',
          [item.copyWith(quantity: 3)],
        )))
            .isLeft(),
        isTrue);
    expect(await db.query('supplier_returns'), hasLength(1));
    expect(await db.query('supplier_return_items'), hasLength(1));
    expect((await db.query('products')).single['stock'], 22.0);
  });

  test(
      'Supplier return rejects zero, negative, invalid supplier, purchase, and item',
      () async {
    await _seedPurchaseFixtures();
    await PurchaseRepositoryImpl().createPurchase(
        _purchase('validation-return-purchase', [_line(1, 10, 100)]));
    final repository = SupplierReturnRepositoryImpl();
    final validItem = const SupplierReturnLine(
      purchaseItemId: 'validation-return-purchase_purchase-product-1',
      productId: 'purchase-product-1',
      quantity: 1,
    );
    final cases = [
      _returnValue('return-zero', 'validation-return-purchase',
          [validItem.copyWith(quantity: 0)]),
      _returnValue('return-negative', 'validation-return-purchase',
          [validItem.copyWith(quantity: -1)]),
      _returnValue('return-purchase-missing', 'missing', [validItem]),
      _returnValue('return-item-missing', 'validation-return-purchase',
          [validItem.copyWith(purchaseItemId: 'missing')]),
    ];
    for (final value in cases) {
      expect((await repository.createReturn(value)).isLeft(), isTrue);
    }
    expect(
        await PersistenceInitializer.persistenceManager!.sqliteManager
            .query('supplier_returns'),
        isEmpty);
  });

  test(
      'Supplier return rollback restores stock and ledgers after downstream failure',
      () async {
    await _seedPurchaseFixtures();
    await PurchaseRepositoryImpl().createPurchase(
        _purchase('rollback-return-purchase', [_line(1, 10, 100)]));
    final repository = SupplierReturnRepositoryImpl(
      failureInjector: (_) async => throw StateError('forced return failure'),
    );
    final result = await repository.createReturn(_returnValue(
      'rollback-return',
      'rollback-return-purchase',
      [
        const SupplierReturnLine(
            purchaseItemId: 'rollback-return-purchase_purchase-product-1',
            productId: 'purchase-product-1',
            quantity: 3)
      ],
    ));
    expect(result.isLeft(), isTrue);
    final db = PersistenceInitializer.persistenceManager!.sqliteManager;
    expect(await db.query('supplier_returns'), isEmpty);
    expect(await db.query('supplier_return_items'), isEmpty);
    expect((await db.query('products')).single['stock'], 30.0);
    expect(
        await db.query('stock_movements',
            where: 'reference_id = ?', whereArgs: ['rollback-return']),
        isEmpty);
    expect(
        await db.query('supplier_ledger',
            where: 'reference_id = ?', whereArgs: ['rollback-return']),
        isEmpty);
    expect(
        await db.query('activity_logs',
            where: 'event_key = ?', whereArgs: ['supplierReturn']),
        isEmpty);
  });

  test(
      'Supplier return preserves purchase history and supports multi-line totals',
      () async {
    await _seedPurchaseFixtures(products: 2);
    await PurchaseRepositoryImpl().createPurchase(_purchase(
        'history-return-purchase', [_line(1, 10, 100), _line(2, 5, 300)]));
    final db = PersistenceInitializer.persistenceManager!.sqliteManager;
    final purchaseBefore = (await db.query('purchases')).single;
    final itemsBefore = await db.query('purchase_items', orderBy: 'id');
    expect(
        (await SupplierReturnRepositoryImpl().createReturn(_returnValue(
          'history-return',
          'history-return-purchase',
          [
            const SupplierReturnLine(
                purchaseItemId: 'history-return-purchase_purchase-product-1',
                productId: 'purchase-product-1',
                quantity: 2),
            const SupplierReturnLine(
                purchaseItemId: 'history-return-purchase_purchase-product-2',
                productId: 'purchase-product-2',
                quantity: 1)
          ],
        )))
            .isRight(),
        isTrue);
    final purchaseAfter = (await db.query('purchases')).single;
    final itemsAfter = await db.query('purchase_items', orderBy: 'id');
    expect(purchaseAfter, purchaseBefore);
    expect(itemsAfter, itemsBefore);
    expect((await db.query('supplier_returns')).single['total_amount'], 500.0);
    expect(
        await db.query('stock_movements',
            where: 'reference_id = ?', whereArgs: ['history-return']),
        hasLength(2));
  });

  test('Cashier cannot create supplier return at service boundary', () async {
    await _seedPurchaseFixtures();
    await PurchaseRepositoryImpl().createPurchase(
        _purchase('permission-return-purchase', [_line(1, 1, 100)]));
    getIt<UserCubit>().currentUser = User(
      username: 'cashier',
      name: 'Cashier',
      phone: '011',
      userType: UserType.cashier,
      password: 'pass',
    );
    final result =
        await SupplierReturnRepositoryImpl().createReturn(_returnValue(
      'denied-return',
      'permission-return-purchase',
      [
        const SupplierReturnLine(
            purchaseItemId: 'permission-return-purchase_purchase-product-1',
            productId: 'purchase-product-1',
            quantity: 1)
      ],
    ));
    expect(result.isLeft(), isTrue);
    getIt<UserCubit>().currentUser = User(
      username: 'manager',
      name: 'Manager',
      phone: '010',
      userType: UserType.manager,
      password: 'pass',
    );
  });

  test(
      'Customer return reuses the transactional refund flow for goods, stock, and ledger',
      () async {
    final db = PersistenceInitializer.persistenceManager!.sqliteManager;
    await db.insert('users', {
      'id': 'manager',
      'username': 'manager',
      'display_name': 'Manager',
      'password_hash': 'pass',
      'role': 'manager',
      'is_active': 1,
      'created_at': DateTime.now().toIso8601String(),
    });
    getIt<UserCubit>().currentUser = User(
      username: 'manager',
      name: 'Manager',
      phone: '010',
      userType: UserType.manager,
      password: 'pass',
    );
    await db.insert('customers', {
      'id': 'return-customer',
      'code': 'RET-C',
      'name': 'Return Customer',
      'is_active': 1,
      'created_at': DateTime.now().toIso8601String(),
      'updated_at': DateTime.now().toIso8601String(),
    });
    await db.insert('products', {
      'id': 'return-product',
      'barcode': 'RET-P',
      'name': 'Return Product',
      'price': 100.0,
      'min_price': 1.0,
      'wholesale_price': 60.0,
      'stock': 0.0,
      'min_stock': 1.0,
      'is_active': 1,
      'created_at': DateTime.now().toIso8601String(),
      'updated_at': DateTime.now().toIso8601String(),
    });
    await db.insert('sales', {
      'id': 'return-sale',
      'total': 1000.0,
      'items_count': 10,
      'created_at': DateTime.now().toIso8601String(),
      'customer_id': 'return-customer',
      'is_refund': 0,
      'payment_method': 'credit',
    });
    await db.insert('sale_items', {
      'id': 'return-sale-item',
      'sale_id': 'return-sale',
      'product_id': 'return-product',
      'product_barcode': 'RET-P',
      'product_name': 'Return Product',
      'quantity': 10.0,
      'price': 100.0,
      'wholesale_price': 60.0,
      'subtotal': 1000.0,
      'refunded_quantity': 0.0,
    });
    await db.insert('customer_ledger', {
      'id': 'return-sale-ledger',
      'customer_id': 'return-customer',
      'entry_type': 'sale',
      'amount': 1000.0,
      'balance_after': 1000.0,
      'reference_type': 'sale',
      'reference_id': 'return-sale',
      'created_at': DateTime.now().toIso8601String(),
    });

    final cubit = InvoiceCubit(SalesRepositoryImpl());
    await cubit.createPartialRefund(
      originalSale: Sale(
        id: 'return-sale',
        total: 1000,
        items: 10,
        date: DateTime.now(),
        cashierName: 'manager',
        customerId: 'return-customer',
        saleItems: [
          SaleItem(
            productId: 'return-product',
            name: 'Return Product',
            price: 100,
            quantity: 10,
            total: 1000,
            wholesalePrice: 60,
          ),
        ],
      ),
      itemsToRefund: [
        RefundItem(
          productId: 'return-product',
          productName: 'Return Product',
          quantity: 3,
          unitPrice: 100,
          wholesalePrice: 60,
        ),
      ],
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await cubit.close();
    expect((await db.query('products')).single['stock'], 3.0);
    expect(
        (await db.query('customer_ledger',
                where: 'entry_type = ?', whereArgs: ['refund']))
            .single['amount'],
        -300.0);
    expect(
        await db.query('stock_movements',
            where: 'movement_type = ?', whereArgs: ['customer_return']),
        hasLength(1));
  });

  test(
      'Customer return rolls back every mutation after an injected downstream failure',
      () async {
    final db = PersistenceInitializer.persistenceManager!.sqliteManager;
    await db.insert('users', {
      'id': 'rollback-manager',
      'username': 'rollback-manager',
      'display_name': 'Rollback Manager',
      'password_hash': 'pass',
      'role': 'manager',
      'is_active': 1,
      'created_at': DateTime.now().toIso8601String(),
    });
    getIt<UserCubit>().currentUser = User(
      username: 'manager',
      name: 'Manager',
      phone: '010',
      userType: UserType.manager,
      password: 'pass',
    );
    await db.insert('customers', {
      'id': 'rollback-customer',
      'code': 'ROLL-C',
      'name': 'Rollback Customer',
      'is_active': 1,
      'created_at': DateTime.now().toIso8601String(),
      'updated_at': DateTime.now().toIso8601String(),
    });
    await db.insert('products', {
      'id': 'rollback-product',
      'barcode': 'ROLL-P',
      'name': 'Rollback Product',
      'price': 100.0,
      'min_price': 1.0,
      'wholesale_price': 60.0,
      'stock': 7.0,
      'min_stock': 1.0,
      'is_active': 1,
      'created_at': DateTime.now().toIso8601String(),
      'updated_at': DateTime.now().toIso8601String(),
    });
    await db.insert('sales', {
      'id': 'rollback-sale',
      'total': 1000.0,
      'items_count': 10,
      'created_at': '2026-09-01T10:00:00.000',
      'user_id': 'rollback-manager',
      'cashier_name': 'Rollback Manager',
      'customer_id': 'rollback-customer',
      'is_refund': 0,
      'payment_method': 'credit',
    });
    await db.insert('sale_items', {
      'id': 'rollback-sale-item',
      'sale_id': 'rollback-sale',
      'product_id': 'rollback-product',
      'product_barcode': 'ROLL-P',
      'product_name': 'Rollback Product',
      'quantity': 10.0,
      'price': 100.0,
      'wholesale_price': 60.0,
      'subtotal': 1000.0,
      'refunded_quantity': 0.0,
    });
    await db.insert('customer_ledger', {
      'id': 'rollback-sale-ledger',
      'customer_id': 'rollback-customer',
      'entry_type': 'sale',
      'amount': 1000.0,
      'balance_after': 1000.0,
      'reference_type': 'sale',
      'reference_id': 'rollback-sale',
      'created_at': DateTime.now().toIso8601String(),
    });

    getIt<UserCubit>().currentUser = User(
      username: 'rollback-manager',
      name: 'Rollback Manager',
      phone: '010',
      userType: UserType.manager,
      password: 'pass',
    );
    final originalSale = Sale(
      id: 'rollback-sale',
      total: 1000,
      items: 10,
      date: DateTime(2026, 9, 1, 10),
      cashierName: 'Rollback Manager',
      cashierUsername: 'rollback-manager',
      customerId: 'rollback-customer',
      saleItems: [
        SaleItem(
          productId: 'rollback-product',
          name: 'Rollback Product',
          price: 100,
          quantity: 10,
          total: 1000,
          wholesalePrice: 60,
        ),
      ],
    );
    final originalSaleRows =
        await db.query('sales', where: 'id = ?', whereArgs: ['rollback-sale']);
    final originalItemRows = await db.query('sale_items',
        where: 'sale_id = ?', whereArgs: ['rollback-sale']);
    final repository = InvoiceCubit(
      SalesRepositoryImpl(),
      failureInjector: (_) async =>
          throw StateError('injected downstream failure'),
    );

    await expectLater(
      repository.createPartialRefund(
        originalSale: originalSale,
        itemsToRefund: [
          RefundItem(
            productId: 'rollback-product',
            productName: 'Rollback Product',
            quantity: 3,
            unitPrice: 100,
            wholesalePrice: 60,
          ),
        ],
      ),
      throwsA(isA<Exception>()),
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await repository.close();

    expect((await db.query('products')).single['stock'], 7.0);
    expect(
        await db.query('sales',
            where: 'is_refund = 1 AND original_sale_id = ?',
            whereArgs: ['rollback-sale']),
        isEmpty);
    expect(
        await db.query('sale_items',
            where: 'LOWER(sale_id) LIKE ?', whereArgs: ['%refund%']),
        isEmpty);
    expect(
        await db.query('stock_movements',
            where: 'movement_type = ? AND LOWER(reference_id) LIKE ?',
            whereArgs: ['customer_return', '%refund%']),
        isEmpty);
    expect(
        await db.query('customer_ledger',
            where: 'entry_type = ? AND reference_type = ?',
            whereArgs: ['refund', 'refund']),
        isEmpty);
    expect(
        await db
            .query('activity_logs', where: 'type = ?', whereArgs: ['refund']),
        isEmpty);
    expect(
        await db.query('sales', where: 'id = ?', whereArgs: ['rollback-sale']),
        originalSaleRows);
    expect(
        await db.query('sale_items',
            where: 'sale_id = ?', whereArgs: ['rollback-sale']),
        originalItemRows);
    expect(
        (await CustomerRepositoryImpl().getCustomerBalance('rollback-customer'))
            .getOrElse(() => -1),
        1000.0);
    getIt<UserCubit>().currentUser = User(
      username: 'manager',
      name: 'Manager',
      phone: '010',
      userType: UserType.manager,
      password: 'pass',
    );
  });

  test(
      'Successful sale writes sale, items, stock movement, and customer ledger',
      () async {
    final db = PersistenceInitializer.persistenceManager!.sqliteManager;
    await db.insert(
        'customers',
        Customer(
          id: 'cust-1',
          code: 'C-001',
          name: 'Ahmed Ali',
          phone: '01000000000',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ).toMap());
    await db.insert('users', {
      'id': 'cashier-1',
      'username': 'cashier-1',
      'display_name': 'Cashier',
      'phone': '01000000000',
      'password_hash': 'hash',
      'role': 'cashier',
      'is_active': 1,
      'created_at': DateTime.now().toIso8601String(),
      'created_by': null,
    });
    await db.insert('categories', {
      'id': 'cat-1',
      'name': 'General',
      'color': '#000000',
      'sort_order': 0,
    });

    await db.insert('products', {
      'id': 'prod-1',
      'barcode': '1001',
      'name': 'Rice 5kg',
      'price': 20.0,
      'min_price': 15.0,
      'wholesale_price': 12.0,
      'stock': 10.0,
      'min_stock': 2.0,
      'category_id': 'cat-1',
      'is_active': 1,
      'created_at': DateTime.now().toIso8601String(),
      'updated_at': DateTime.now().toIso8601String(),
    });

    final repo = SalesRepositoryImpl();
    final result = await repo.createSaleWithCashier(
      items: [
        CartItemModel(
          id: 'prod-1',
          name: 'Rice 5kg',
          originalPrice: 20.0,
          salePrice: 20.0,
          qty: 3,
          date: DateTime.now(),
          minPrice: 15.0,
          wholesalePrice: 12.0,
        ),
      ],
      total: 60.0,
      cashierName: 'Cashier',
      cashierUsername: 'cashier-1',
      customerId: 'cust-1',
      paymentMethod: 'credit',
    );

    expect(result.isRight(), isTrue);

    final sales = await db.query('sales');
    expect(sales, hasLength(1));
    expect(sales.first['customer_id'], 'cust-1');

    final saleItems = await db.query('sale_items');
    expect(saleItems, hasLength(1));
    expect((saleItems.first['quantity'] as num).toInt(), 3);

    final movements = await db.query('stock_movements');
    expect(movements, hasLength(1));
    expect((movements.first['quantity_change'] as num).toDouble(), -3.0);

    final productRow =
        (await db.query('products', where: 'id = ?', whereArgs: ['prod-1']))
            .first;
    expect((productRow['stock'] as num).toInt(), 7);

    final ledger = await db.query('customer_ledger',
        where: 'customer_id = ?', whereArgs: ['cust-1']);
    expect(ledger, hasLength(1));
    expect((ledger.first['amount'] as num).toDouble(), 60.0);
    expect(ledger.first['entry_type'], 'sale');
    expect(await db.query('cash_movements'), isEmpty);
  });

  test('Customer cash sale does not create debt', () async {
    await _seedSaleFixture();
    final result = await SalesRepositoryImpl().createSaleWithCashier(
      items: [_saleFixtureItem()],
      total: 450,
      cashierName: 'Cashier',
      cashierUsername: 'cashier-1',
      customerId: 'sale-customer',
      paymentMethod: 'cash',
    );
    final db = PersistenceInitializer.persistenceManager!.sqliteManager;
    expect(result.isRight(), isTrue);
    expect(await db.query('customer_ledger'), isEmpty);
  });

  test('Anonymous sale can be loaded and refunded', () async {
    await _seedSaleFixture(customer: false);
    await _seedRefundManager();
    final repository = SalesRepositoryImpl();
    final saleResult = await repository.createSaleWithCashier(
      items: [_saleFixtureItem()],
      total: 450,
      cashierName: 'Cashier',
      cashierUsername: 'cashier-1',
      paymentMethod: 'cash',
    );
    expect(saleResult.isRight(), isTrue);

    final loadedSales = await repository.getRecentSales(limit: 10);
    final originalSale = loadedSales.fold(
      (failure) => throw StateError(failure.message),
      (sales) => sales.single,
    );
    expect(originalSale.customerId, isNull);
    expect(originalSale.paymentMethod, 'cash');
    expect(originalSale.total, 450);
    final cubit = InvoiceCubit(repository);
    await cubit.createPartialRefund(
      originalSale: originalSale,
      itemsToRefund: [
        RefundItem(
          productId: 'sale-product',
          productName: 'Sale Product',
          quantity: 1,
          unitPrice: 450,
          wholesalePrice: 300,
        ),
      ],
    );

    final db = PersistenceInitializer.persistenceManager!.sqliteManager;
    expect(await db.query('sales', where: 'is_refund = 1'), hasLength(1));
    expect(await db.query('customer_ledger'), isEmpty);
    expect((await db.query('products')).single['stock'], 10.0);
    expect(
        await db.query('stock_movements',
            where: 'movement_type = ?', whereArgs: ['customer_return']),
        hasLength(1));
    final cashRefunds = await db.query('cash_movements',
        where: 'movement_type = ?', whereArgs: ['customer_refund_cash']);
    expect(cashRefunds, hasLength(1));
    expect(cashRefunds.single['amount'], -450.0);
    expect(cashRefunds.single['reference_type'], 'refund');
    expect(cashRefunds.single['reference_id'], isNotEmpty);
    expect(cashRefunds.single['idempotency_key'],
        startsWith('refund:${cashRefunds.single['reference_id']}:cash'));
  });

  test('Customer credit sale can be loaded and refunded with ledger reversal',
      () async {
    await _seedSaleFixture();
    await _seedRefundManager();
    final repository = SalesRepositoryImpl();
    final saleResult = await repository.createSaleWithCashier(
      items: [_saleFixtureItem()],
      total: 450,
      cashierName: 'Cashier',
      cashierUsername: 'cashier-1',
      customerId: 'sale-customer',
      paymentMethod: 'credit',
    );
    expect(saleResult.isRight(), isTrue);

    final loadedSales = await repository.getRecentSales(limit: 10);
    final originalSale = loadedSales.fold(
      (failure) => throw StateError(failure.message),
      (sales) => sales.single,
    );
    expect(originalSale.customerId, 'sale-customer');

    final cubit = InvoiceCubit(repository);
    await cubit.createPartialRefund(
      originalSale: originalSale,
      itemsToRefund: [
        RefundItem(
          productId: 'sale-product',
          productName: 'Sale Product',
          quantity: 1,
          unitPrice: 450,
          wholesalePrice: 300,
        ),
      ],
    );

    final db = PersistenceInitializer.persistenceManager!.sqliteManager;
    final ledger = await db.query('customer_ledger',
        where: 'customer_id = ?', whereArgs: ['sale-customer']);
    expect(ledger, hasLength(2));
    expect(ledger.map((row) => row['entry_type']),
        containsAll(['sale', 'refund']));
    expect(
        ledger.fold<double>(
            0, (sum, row) => sum + (row['amount'] as num).toDouble()),
        0);
    expect(await db.query('sales', where: 'is_refund = 1'), hasLength(1));
    expect(
        await db.query('stock_movements',
            where: 'movement_type = ?', whereArgs: ['customer_return']),
        hasLength(1));
  });

  test('Customer cash sale refund does not create customer debt', () async {
    await _seedSaleFixture();
    await _seedRefundManager();
    final repository = SalesRepositoryImpl();
    final saleResult = await repository.createSaleWithCashier(
      items: [_saleFixtureItem()],
      total: 450,
      cashierName: 'Cashier',
      cashierUsername: 'cashier-1',
      customerId: 'sale-customer',
      paymentMethod: 'cash',
    );
    expect(saleResult.isRight(), isTrue);

    final loadedSales = await repository.getRecentSales(limit: 10);
    final originalSale = loadedSales.fold(
      (failure) => throw StateError(failure.message),
      (sales) => sales.single,
    );
    expect(originalSale.customerId, 'sale-customer');

    final cubit = InvoiceCubit(repository);
    await cubit.createPartialRefund(
      originalSale: originalSale,
      itemsToRefund: [
        RefundItem(
          productId: 'sale-product',
          productName: 'Sale Product',
          quantity: 1,
          unitPrice: 450,
          wholesalePrice: 300,
        ),
      ],
    );

    final db = PersistenceInitializer.persistenceManager!.sqliteManager;
    expect(await db.query('customer_ledger'), isEmpty);
    expect(await db.query('sales', where: 'is_refund = 1'), hasLength(1));
    expect(
        await db.query('stock_movements',
            where: 'movement_type = ?', whereArgs: ['customer_return']),
        hasLength(1));
    final cashRefunds = await db.query('cash_movements',
        where: 'movement_type = ?', whereArgs: ['customer_refund_cash']);
    expect(cashRefunds, hasLength(1));
    expect(cashRefunds.single['amount'], -450.0);
    expect(cashRefunds.single['reference_type'], 'refund');
    expect(cashRefunds.single['reference_id'], isNotEmpty);
    expect(await db.query('cash_movements'), hasLength(2));
  });

  test('Cash refund duplicate and rollback retry are single-posting', () async {
    await _seedSaleFixture();
    await _seedRefundManager();
    final repository = SalesRepositoryImpl();
    expect(
      (await repository.createSaleWithCashier(
        items: [_saleFixtureItem()],
        total: 450,
        cashierName: 'Cashier',
        cashierUsername: 'cashier-1',
        customerId: 'sale-customer',
        paymentMethod: 'cash',
      ))
          .isRight(),
      isTrue,
    );
    final originalSale = (await repository.getRecentSales(limit: 10)).fold(
      (failure) => throw StateError(failure.message),
      (sales) => sales.single,
    );
    final refundItems = [
      RefundItem(
        productId: 'sale-product',
        productName: 'Sale Product',
        quantity: 1,
        unitPrice: 450,
        wholesalePrice: 300,
      ),
    ];
    var shouldFail = true;
    final failingCubit = InvoiceCubit(
      repository,
      failureInjector: (_) async {
        if (shouldFail) {
          shouldFail = false;
          throw StateError('forced refund rollback');
        }
      },
    );
    await expectLater(
      failingCubit.createPartialRefund(
        originalSale: originalSale,
        itemsToRefund: refundItems,
      ),
      throwsA(isA<Exception>()),
    );
    final db = PersistenceInitializer.persistenceManager!.sqliteManager;
    expect(await db.query('sales', where: 'is_refund = 1'), isEmpty);
    expect(
        await db.query('cash_movements',
            where: 'movement_type = ?', whereArgs: ['customer_refund_cash']),
        isEmpty);
    expect(
        await db.query('stock_movements',
            where: 'movement_type = ?', whereArgs: ['customer_return']),
        isEmpty);

    final cubit = InvoiceCubit(repository);
    await cubit.createPartialRefund(
      originalSale: originalSale,
      itemsToRefund: refundItems,
    );
    expect(
      await cubit.createPartialRefund(
        originalSale: originalSale,
        itemsToRefund: refundItems,
      ),
      RefundResult.alreadyProcessed,
    );
    expect(await db.query('sales', where: 'is_refund = 1'), hasLength(1));
    expect(
        await db.query('cash_movements',
            where: 'movement_type = ?', whereArgs: ['customer_refund_cash']),
        hasLength(1));
    expect(
        await db.query('stock_movements',
            where: 'movement_type = ?', whereArgs: ['customer_return']),
        hasLength(1));
  });

  test('Credit refund duplicate and concurrent attempts reverse once',
      () async {
    await _seedSaleFixture();
    await _seedRefundManager();
    final repository = SalesRepositoryImpl();
    expect(
      (await repository.createSaleWithCashier(
        items: [_saleFixtureItem()],
        total: 450,
        cashierName: 'Cashier',
        cashierUsername: 'cashier-1',
        customerId: 'sale-customer',
        paymentMethod: 'credit',
      ))
          .isRight(),
      isTrue,
    );
    final originalSale = (await repository.getRecentSales(limit: 10)).fold(
      (failure) => throw StateError(failure.message),
      (sales) => sales.single,
    );
    final items = [
      RefundItem(
        productId: 'sale-product',
        productName: 'Sale Product',
        quantity: 1,
        unitPrice: 450,
        wholesalePrice: 300,
      ),
    ];
    final cubit = InvoiceCubit(repository);
    final attempts = await Future.wait([
      cubit
          .createPartialRefund(originalSale: originalSale, itemsToRefund: items)
          .then((result) => result),
      cubit
          .createPartialRefund(originalSale: originalSale, itemsToRefund: items)
          .then((result) => result),
    ]);
    expect(
        attempts.where((value) => value == RefundResult.success), hasLength(1));
    expect(
      attempts.where((value) => value == RefundResult.alreadyProcessed),
      hasLength(1),
    );
    final db = PersistenceInitializer.persistenceManager!.sqliteManager;
    expect(await db.query('sales', where: 'is_refund = 1'), hasLength(1));
    expect(await db.query('cash_movements'), isEmpty);
    expect(
        await db.query('stock_movements',
            where: 'movement_type = ?', whereArgs: ['customer_return']),
        hasLength(1));
    expect(
        await db.query('customer_ledger',
            where: 'entry_type = ?', whereArgs: ['refund']),
        hasLength(1));
  });

  test('Customer wallet sale does not create debt', () async {
    await _seedSaleFixture();
    final result = await SalesRepositoryImpl().createSaleWithCashier(
      items: [_saleFixtureItem()],
      total: 450,
      cashierName: 'Cashier',
      cashierUsername: 'cashier-1',
      customerId: 'sale-customer',
      paymentMethod: 'wallet',
    );
    final db = PersistenceInitializer.persistenceManager!.sqliteManager;
    expect(result.isRight(), isTrue);
    expect(await db.query('customer_ledger'), isEmpty);
  });

  test('Anonymous credit sale is rejected without mutation', () async {
    await _seedSaleFixture(customer: false);
    final result = await SalesRepositoryImpl().createSaleWithCashier(
      items: [_saleFixtureItem()],
      total: 450,
      cashierName: 'Cashier',
      cashierUsername: 'cashier-1',
      paymentMethod: 'credit',
    );
    final db = PersistenceInitializer.persistenceManager!.sqliteManager;
    expect(result.isLeft(), isTrue);
    expect(await db.query('sales'), isEmpty);
    expect(await db.query('sale_items'), isEmpty);
    expect(await db.query('stock_movements'), isEmpty);
    expect(await db.query('customer_ledger'), isEmpty);
  });

  test('Insufficient stock rolls back without a partial sale', () async {
    final db = PersistenceInitializer.persistenceManager!.sqliteManager;
    await db.insert(
        'customers',
        Customer(
          id: 'cust-1',
          code: 'C-001',
          name: 'Ahmed Ali',
          phone: '01000000000',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ).toMap());
    await db.insert('users', {
      'id': 'cashier-1',
      'username': 'cashier-1',
      'display_name': 'Cashier',
      'phone': '01000000000',
      'password_hash': 'hash',
      'role': 'cashier',
      'is_active': 1,
      'created_at': DateTime.now().toIso8601String(),
      'created_by': null,
    });
    await db.insert('categories', {
      'id': 'cat-1',
      'name': 'General',
      'color': '#000000',
      'sort_order': 0,
    });

    await db.insert('products', {
      'id': 'prod-1',
      'barcode': '1001',
      'name': 'Rice 5kg',
      'price': 20.0,
      'min_price': 15.0,
      'wholesale_price': 12.0,
      'stock': 2.0,
      'min_stock': 2.0,
      'category_id': 'cat-1',
      'is_active': 1,
      'created_at': DateTime.now().toIso8601String(),
      'updated_at': DateTime.now().toIso8601String(),
    });

    final repo = SalesRepositoryImpl();
    final result = await repo.createSaleWithCashier(
      items: [
        CartItemModel(
          id: 'prod-1',
          name: 'Rice 5kg',
          originalPrice: 20.0,
          salePrice: 20.0,
          qty: 3,
          date: DateTime.now(),
          minPrice: 15.0,
          wholesalePrice: 12.0,
        ),
      ],
      total: 60.0,
      cashierName: 'Cashier',
      cashierUsername: 'cashier-1',
      customerId: 'cust-1',
    );

    expect(result.isLeft(), isTrue);
    expect((await db.query('sales')), isEmpty);
    expect((await db.query('sale_items')), isEmpty);
    expect((await db.query('stock_movements')), isEmpty);
    expect((await db.query('customer_ledger')), isEmpty);

    final productRow =
        (await db.query('products', where: 'id = ?', whereArgs: ['prod-1']))
            .first;
    expect((productRow['stock'] as num).toDouble(), 2.0);
  });

  test('Multi-item sale updates every product and movement correctly',
      () async {
    final db = PersistenceInitializer.persistenceManager!.sqliteManager;
    await db.insert('users', {
      'id': 'cashier-1',
      'username': 'cashier-1',
      'display_name': 'Cashier',
      'phone': '01000000000',
      'password_hash': 'hash',
      'role': 'cashier',
      'is_active': 1,
      'created_at': DateTime.now().toIso8601String(),
      'created_by': null,
    });
    await db.insert('categories', {
      'id': 'cat-1',
      'name': 'General',
      'color': '#000000',
      'sort_order': 0,
    });
    await db.insert('products', {
      'id': 'prod-1',
      'barcode': '1001',
      'name': 'Rice 5kg',
      'price': 20.0,
      'min_price': 15.0,
      'wholesale_price': 12.0,
      'stock': 10.0,
      'min_stock': 2.0,
      'category_id': 'cat-1',
      'is_active': 1,
      'created_at': DateTime.now().toIso8601String(),
      'updated_at': DateTime.now().toIso8601String(),
    });
    await db.insert('products', {
      'id': 'prod-2',
      'barcode': '1002',
      'name': 'Oil 1L',
      'price': 40.0,
      'min_price': 30.0,
      'wholesale_price': 26.0,
      'stock': 5.0,
      'min_stock': 1.0,
      'category_id': 'cat-1',
      'is_active': 1,
      'created_at': DateTime.now().toIso8601String(),
      'updated_at': DateTime.now().toIso8601String(),
    });

    final repo = SalesRepositoryImpl();
    final result = await repo.createSaleWithCashier(
      items: [
        CartItemModel(
          id: 'prod-1',
          name: 'Rice 5kg',
          originalPrice: 20.0,
          salePrice: 20.0,
          qty: 2,
          date: DateTime.now(),
          minPrice: 15.0,
          wholesalePrice: 12.0,
        ),
        CartItemModel(
          id: 'prod-2',
          name: 'Oil 1L',
          originalPrice: 40.0,
          salePrice: 40.0,
          qty: 1,
          date: DateTime.now(),
          minPrice: 30.0,
          wholesalePrice: 26.0,
        ),
      ],
      total: 80.0,
      cashierName: 'Cashier',
      cashierUsername: 'cashier-1',
    );

    expect(result.isRight(), isTrue);

    final productOne =
        (await db.query('products', where: 'id = ?', whereArgs: ['prod-1']))
            .first;
    final productTwo =
        (await db.query('products', where: 'id = ?', whereArgs: ['prod-2']))
            .first;
    expect((productOne['stock'] as num).toInt(), 8);
    expect((productTwo['stock'] as num).toInt(), 4);

    final movements = await db.query('stock_movements');
    expect(movements, hasLength(2));
    expect(
        movements.map((m) => (m['quantity_change'] as num).toDouble()).toList(),
        containsAll([-2.0, -1.0]));
  });

  test('Over-refund quantity is rejected before any mutation', () {
    final originalSale = Sale(
      id: 'sale-1',
      total: 100.0,
      items: 1,
      date: DateTime.now(),
      saleItems: [
        SaleItem(
          productId: 'prod-1',
          name: 'Rice 5kg',
          price: 10.0,
          quantity: 10,
          total: 100.0,
          wholesalePrice: 6.0,
        ),
      ],
      cashierName: 'Cashier',
      cashierUsername: 'cashier-1',
    );

    expect(
      () => InvoiceCubit.validateRefundAvailability(
        originalSale,
        [
          RefundItem(
            productId: 'prod-1',
            productName: 'Rice 5kg',
            quantity: 11,
            unitPrice: 10.0,
            wholesalePrice: 6.0,
          ),
        ],
      ),
      throwsA(isA<StateError>()),
    );
  });

  test('Refund availability enforces remaining quantity after prior refunds',
      () {
    final originalSale = Sale(
      id: 'sale-1',
      total: 100.0,
      items: 1,
      date: DateTime.now(),
      saleItems: [
        SaleItem(
          productId: 'prod-1',
          name: 'Rice 5kg',
          price: 10.0,
          quantity: 10,
          total: 100.0,
          wholesalePrice: 6.0,
          refundedQuantity: 6,
        ),
      ],
      cashierName: 'Cashier',
      cashierUsername: 'cashier-1',
    );

    expect(
      () => InvoiceCubit.validateRefundAvailability(
        originalSale,
        [
          RefundItem(
            productId: 'prod-1',
            productName: 'Rice 5kg',
            quantity: 5,
            unitPrice: 10.0,
            wholesalePrice: 6.0,
          ),
        ],
      ),
      throwsA(isA<StateError>()),
    );

    final allowed = InvoiceCubit.validateRefundAvailability(
      originalSale,
      [
        RefundItem(
          productId: 'prod-1',
          productName: 'Rice 5kg',
          quantity: 4,
          unitPrice: 10.0,
          wholesalePrice: 6.0,
        ),
      ],
    );

    expect(allowed, 40.0);
  });

  test(
      'Customer return lifecycle supports partial, full, and duplicate rejection',
      () async {
    final db = PersistenceInitializer.persistenceManager!.sqliteManager;
    await db.insert('users', {
      'id': 'lifecycle-manager',
      'username': 'lifecycle-manager',
      'display_name': 'Lifecycle Manager',
      'password_hash': 'pass',
      'role': 'manager',
      'is_active': 1,
      'created_at': DateTime.now().toIso8601String(),
    });
    getIt<UserCubit>().currentUser = User(
      username: 'lifecycle-manager',
      name: 'Lifecycle Manager',
      phone: '010',
      userType: UserType.manager,
      password: 'pass',
    );
    await db.insert('customers', {
      'id': 'lifecycle-customer',
      'code': 'LIFE-C',
      'name': 'Lifecycle Customer',
      'is_active': 1,
      'created_at': DateTime.now().toIso8601String(),
      'updated_at': DateTime.now().toIso8601String(),
    });
    await db.insert('products', {
      'id': 'lifecycle-product',
      'barcode': 'LIFE-P',
      'name': 'Lifecycle Product',
      'price': 450.0,
      'min_price': 1.0,
      'wholesale_price': 300.0,
      'stock': 8.0,
      'min_stock': 1.0,
      'is_active': 1,
      'created_at': DateTime.now().toIso8601String(),
      'updated_at': DateTime.now().toIso8601String(),
    });
    await db.insert('sales', {
      'id': 'lifecycle-sale',
      'reference_number': 'INV-2026-000001',
      'total': 900.0,
      'items_count': 2,
      'created_at': '2026-09-04T10:00:00.000',
      'customer_id': 'lifecycle-customer',
      'is_refund': 0,
      'payment_method': 'credit',
    });
    await db.insert('sale_items', {
      'id': 'lifecycle-sale-item',
      'sale_id': 'lifecycle-sale',
      'product_id': 'lifecycle-product',
      'product_barcode': 'LIFE-P',
      'product_name': 'Lifecycle Product',
      'quantity': 2.0,
      'price': 450.0,
      'subtotal': 900.0,
      'wholesale_price': 300.0,
      'refunded_quantity': 0.0,
    });
    await db.insert('customer_ledger', {
      'id': 'lifecycle-sale-ledger',
      'customer_id': 'lifecycle-customer',
      'entry_type': 'sale',
      'amount': 900.0,
      'balance_after': 900.0,
      'reference_type': 'sale',
      'reference_id': 'lifecycle-sale',
      'created_at': DateTime.now().toIso8601String(),
    });

    final original = Sale(
      id: 'lifecycle-sale',
      referenceNumber: 'INV-2026-000001',
      total: 900,
      items: 2,
      date: DateTime(2026, 9, 4, 10),
      cashierName: 'Lifecycle Manager',
      customerId: 'lifecycle-customer',
      paymentMethod: 'credit',
      saleItems: [
        SaleItem(
          productId: 'lifecycle-product',
          name: 'Lifecycle Product',
          price: 450,
          quantity: 2,
          total: 900,
          wholesalePrice: 300,
        ),
      ],
    );
    final cubit = InvoiceCubit(SalesRepositoryImpl());

    await cubit.createPartialRefund(
      originalSale: original,
      itemsToRefund: [
        RefundItem(
          productId: 'lifecycle-product',
          productName: 'Lifecycle Product',
          quantity: 1,
          unitPrice: 450,
          wholesalePrice: 300,
        ),
      ],
    );
    expect((await db.query('products')).single['stock'], 9.0);
    expect(
        (await db.query('sale_items',
                where: 'id = ?', whereArgs: ['lifecycle-sale-item']))
            .single['refunded_quantity'],
        1.0);
    expect(await db.query('sales', where: 'is_refund = 1'), hasLength(1));

    await cubit.createPartialRefund(
      originalSale: original,
      itemsToRefund: [
        RefundItem(
          productId: 'lifecycle-product',
          productName: 'Lifecycle Product',
          quantity: 1,
          unitPrice: 450,
          wholesalePrice: 300,
        ),
      ],
    );
    expect((await db.query('products')).single['stock'], 9.0);
    expect(
        (await db.query('sale_items',
                where: 'id = ?', whereArgs: ['lifecycle-sale-item']))
            .single['refunded_quantity'],
        1.0);
    expect(await db.query('sales', where: 'is_refund = 1'), hasLength(1));

    expect(
      await cubit.createPartialRefund(
        originalSale: original,
        itemsToRefund: [
          RefundItem(
            productId: 'lifecycle-product',
            productName: 'Lifecycle Product',
            quantity: 1,
            unitPrice: 450,
            wholesalePrice: 300,
          ),
        ],
      ),
      RefundResult.alreadyProcessed,
    );
    expect((await db.query('products')).single['stock'], 9.0);
    expect(await db.query('sales', where: 'is_refund = 1'), hasLength(1));
    expect(
        await db.query('stock_movements',
            where: 'movement_type = ?', whereArgs: ['customer_return']),
        hasLength(1));
  });

  test(
      'Customer Returns eligibility excludes refunded, anonymous, and exhausted sales',
      () {
    Sale item({
      required String id,
      String? customerId,
      double refunded = 0,
      bool refund = false,
    }) =>
        Sale(
          id: id,
          total: 100,
          items: 1,
          date: DateTime(2026, 9, 4),
          cashierName: 'Manager',
          customerId: customerId,
          invoiceTypeIndex: refund ? 1 : 0,
          saleItems: [
            SaleItem(
              productId: 'p',
              name: 'Product',
              price: 100,
              quantity: 1,
              total: 100,
              wholesalePrice: 50,
              refundedQuantity: refunded,
            ),
          ],
        );

    expect(
        CustomerReturnsScreen.isEligibleSale(
            item(id: 'eligible', customerId: 'customer')),
        isTrue);
    expect(
        CustomerReturnsScreen.isEligibleSale(
            item(id: 'exhausted', customerId: 'customer', refunded: 1)),
        isFalse);
    expect(
        CustomerReturnsScreen.isEligibleSale(item(id: 'anonymous')), isFalse);
    expect(
        CustomerReturnsScreen.isEligibleSale(
            item(id: 'refund', customerId: 'customer', refund: true)),
        isFalse);
  });

  test('Customer return submission gate allows one transaction only', () async {
    final db = PersistenceInitializer.persistenceManager!.sqliteManager;
    await _seedSaleFixture();
    await db.insert('users', {
      'id': 'manager',
      'username': 'manager',
      'display_name': 'Manager',
      'password_hash': 'pass',
      'role': 'manager',
      'is_active': 1,
      'created_at': DateTime.now().toIso8601String(),
    });
    getIt<UserCubit>().currentUser = User(
      username: 'manager',
      name: 'Manager',
      phone: '010',
      userType: UserType.manager,
      password: 'pass',
    );
    await db.insert('customers', {
      'id': 'dialog-customer',
      'code': 'DIALOG-C',
      'name': 'Dialog Customer',
      'is_active': 1,
      'created_at': DateTime.now().toIso8601String(),
      'updated_at': DateTime.now().toIso8601String(),
    });
    await db.insert('sales', {
      'id': 'dialog-sale',
      'reference_number': 'INV-2026-DIALOG',
      'total': 450.0,
      'items_count': 1,
      'created_at': '2026-09-04T10:00:00.000',
      'customer_id': 'dialog-customer',
      'is_refund': 0,
      'payment_method': 'credit',
    });
    await db.insert('sale_items', {
      'id': 'dialog-sale-item',
      'sale_id': 'dialog-sale',
      'product_id': 'sale-product',
      'product_barcode': 'SALE-P',
      'product_name': 'Sale Product',
      'quantity': 1.0,
      'price': 450.0,
      'subtotal': 450.0,
      'wholesale_price': 300.0,
      'refunded_quantity': 0.0,
    });
    final original = Sale(
      id: 'dialog-sale',
      referenceNumber: 'INV-2026-DIALOG',
      total: 450,
      items: 1,
      date: DateTime(2026, 9, 4, 10),
      cashierName: 'Manager',
      customerId: 'dialog-customer',
      paymentMethod: 'credit',
      saleItems: [
        SaleItem(
          productId: 'sale-product',
          name: 'Sale Product',
          price: 450,
          quantity: 1,
          total: 450,
          wholesalePrice: 300,
        ),
      ],
    );

    final gate = RefundSubmissionGate();
    expect(gate.tryStart(), isTrue);
    expect(gate.tryStart(), isFalse);
    final cubit = InvoiceCubit(SalesRepositoryImpl());
    await cubit.createPartialRefund(
      originalSale: original,
      itemsToRefund: [
        RefundItem(
          productId: 'sale-product',
          productName: 'Sale Product',
          quantity: 1,
          unitPrice: 450,
          wholesalePrice: 300,
        ),
      ],
    );
    expect(await db.query('sales', where: 'is_refund = 1'), hasLength(1));
    expect(
        await db.query('sale_items',
            where: 'sale_id = ?', whereArgs: ['dialog-sale']),
        hasLength(1));
    expect((await db.query('products')).single['stock'], 11.0);
    expect(
        await db.query('stock_movements',
            where: 'movement_type = ?', whereArgs: ['customer_return']),
        hasLength(1));
    expect(
        await db.query('customer_ledger',
            where: 'entry_type = ?', whereArgs: ['refund']),
        hasLength(1));
    expect(
        await db
            .query('activity_logs', where: 'type = ?', whereArgs: ['refund']),
        hasLength(1));
  });

  test(
      'Customer sale, payment, and refund preserve the combined ledger balance',
      () async {
    final db = PersistenceInitializer.persistenceManager!.sqliteManager;
    await _seedSaleFixture();
    await db.insert('users', {
      'id': 'manager',
      'username': 'manager',
      'display_name': 'Manager',
      'password_hash': 'pass',
      'role': 'manager',
      'is_active': 1,
      'created_at': DateTime.now().toIso8601String(),
    });
    getIt<UserCubit>().currentUser = User(
      username: 'manager',
      name: 'Manager',
      phone: '010',
      userType: UserType.manager,
      password: 'pass',
    );
    await db.insert('customers', {
      'id': 'balance-customer',
      'code': 'BALANCE-C',
      'name': 'Balance Customer',
      'is_active': 1,
      'created_at': DateTime.now().toIso8601String(),
      'updated_at': DateTime.now().toIso8601String(),
    });
    await db.insert('sales', {
      'id': 'balance-sale',
      'reference_number': 'INV-2026-BALANCE',
      'total': 900.0,
      'items_count': 2,
      'created_at': '2026-09-04T10:00:00.000',
      'customer_id': 'balance-customer',
      'is_refund': 0,
      'payment_method': 'credit',
    });
    await db.insert('sale_items', {
      'id': 'balance-sale-item',
      'sale_id': 'balance-sale',
      'product_id': 'sale-product',
      'product_barcode': 'SALE-P',
      'product_name': 'Sale Product',
      'quantity': 2.0,
      'price': 450.0,
      'subtotal': 900.0,
      'wholesale_price': 300.0,
      'refunded_quantity': 0.0,
    });
    await db.insert('customer_ledger', {
      'id': 'balance-sale-ledger',
      'customer_id': 'balance-customer',
      'entry_type': 'sale',
      'amount': 900.0,
      'balance_after': 900.0,
      'reference_type': 'sale',
      'reference_id': 'balance-sale',
      'created_at': DateTime.now().toIso8601String(),
    });
    final paymentResult = await CustomerPaymentRepositoryImpl().createPayment(
      _customerPayment('balance-payment', 500,
          customerId: 'balance-customer', reference: 'PAY-BALANCE-001'),
    );
    expect(paymentResult.isRight(), isTrue);
    final original = Sale(
      id: 'balance-sale',
      referenceNumber: 'INV-2026-BALANCE',
      total: 900,
      items: 2,
      date: DateTime(2026, 9, 4, 10),
      cashierName: 'Manager',
      customerId: 'balance-customer',
      paymentMethod: 'credit',
      saleItems: [
        SaleItem(
          productId: 'sale-product',
          name: 'Sale Product',
          price: 450,
          quantity: 2,
          total: 900,
          wholesalePrice: 300,
        ),
      ],
    );
    final cubit = InvoiceCubit(SalesRepositoryImpl());
    await cubit.createPartialRefund(
      originalSale: original,
      itemsToRefund: [
        RefundItem(
          productId: 'sale-product',
          productName: 'Sale Product',
          quantity: 1,
          unitPrice: 450,
          wholesalePrice: 300,
        ),
      ],
    );
    final ledger = await db.query('customer_ledger',
        where: 'customer_id = ?', whereArgs: ['balance-customer']);
    final amounts =
        ledger.map((row) => (row['amount'] as num).toDouble()).toList()..sort();
    expect(amounts, [-500.0, -450.0, 900.0]);
    expect(
        (await CustomerPaymentRepositoryImpl()
                .getCustomerBalance('balance-customer'))
            .getOrElse(() => 0),
        -50.0);
  });

  test('Customer Returns consumes only eligibility-filtered sales', () {
    Sale sale(String id,
        {String? customerId, double refunded = 0, bool isRefund = false}) {
      return Sale(
        id: id,
        total: 450,
        items: 1,
        date: DateTime(2026, 9, 4),
        cashierName: 'Manager',
        customerId: customerId,
        invoiceTypeIndex: isRefund ? 1 : 0,
        saleItems: [
          SaleItem(
            productId: 'p',
            name: 'Product',
            price: 450,
            quantity: 1,
            total: 450,
            wholesalePrice: 300,
            refundedQuantity: refunded,
          ),
        ],
      );
    }

    final visible = CustomerReturnsScreen.eligibleSales([
      sale('eligible', customerId: 'customer'),
      sale('exhausted', customerId: 'customer', refunded: 1),
      sale('anonymous'),
      sale('refund', customerId: 'customer', isRefund: true),
    ]);
    expect(visible.map((item) => item.id), ['eligible']);
  });

  test('Customer Returns filters update selection and search commercial fields',
      () {
    Sale sale(String id, {double refunded = 0, String? reference}) => Sale(
          id: id,
          referenceNumber: reference ?? 'INV-$id',
          total: 450,
          items: 1,
          date: DateTime(2026, 9, 4),
          cashierName: 'Manager',
          customerId: 'customer-1',
          customerName: 'Test Customer',
          customerCode: 'CUST-001',
          saleItems: [
            SaleItem(
              productId: 'p',
              name: 'Product',
              price: 450,
              quantity: 2,
              total: 900,
              wholesalePrice: 300,
              refundedQuantity: refunded,
            ),
          ],
        );

    final candidates = [sale('one'), sale('two', refunded: 1)];
    expect(
      CustomerReturnsScreen.filterCandidates(
        candidates,
        filter: CustomerReturnFilter.partiallyReturned,
      ).map((item) => item.id),
      ['two'],
    );
    expect(
      CustomerReturnsScreen.filterCandidates(
        candidates,
        query: 'INV-two',
      ).map((item) => item.id),
      ['two'],
    );
    expect(
      CustomerReturnsScreen.filterCandidates(
        candidates,
        query: 'CUST-001',
      ),
      hasLength(2),
    );
  });

  test(
      'Customer return candidates query includes customer cash and credit sales',
      () async {
    await _seedSaleFixture();
    final repository = SalesRepositoryImpl();

    expect(
        (await repository.createSaleWithCashier(
          items: [_saleFixtureItem()],
          total: 450,
          cashierName: 'Cashier',
          cashierUsername: 'cashier-1',
          customerId: 'sale-customer',
          paymentMethod: 'cash',
        ))
            .isRight(),
        isTrue);
    expect(
        (await repository.createSaleWithCashier(
          items: [_saleFixtureItem()],
          total: 450,
          cashierName: 'Cashier',
          cashierUsername: 'cashier-1',
          customerId: 'sale-customer',
          paymentMethod: 'credit',
        ))
            .isRight(),
        isTrue);
    expect(
        (await repository.createSaleWithCashier(
          items: [_saleFixtureItem()],
          total: 450,
          cashierName: 'Cashier',
          cashierUsername: 'cashier-1',
          paymentMethod: 'cash',
        ))
            .isRight(),
        isTrue);

    final sales = await repository.getRecentSales(limit: 10);
    final loadedSales = sales.fold(
      (failure) => throw StateError(failure.message),
      (value) => value,
    );
    final exhaustedSale =
        loadedSales.firstWhere((sale) => sale.customerId != null);
    final db = PersistenceInitializer.persistenceManager!.sqliteManager;
    await db.update(
      'sale_items',
      {'refunded_quantity': 1.0},
      where: 'sale_id = ?',
      whereArgs: [exhaustedSale.id],
    );
    await db.insert('sales', {
      'id': 'candidate-refund',
      'reference_number': 'CR-2026-CANDIDATE',
      'total': 450.0,
      'items_count': 1,
      'created_at': DateTime.now().toIso8601String(),
      'customer_id': 'sale-customer',
      'is_refund': 1,
      'original_sale_id': exhaustedSale.id,
      'payment_method': 'cash',
    });

    final candidates = await repository.getCustomerReturnCandidates();
    final eligible = candidates.fold(
      (failure) => throw StateError(failure.message),
      (value) => value,
    );
    expect(eligible, hasLength(1));
    expect(eligible.single.customerId, 'sale-customer');
    expect(eligible.single.isRefund, isFalse);
    expect(eligible.single.id, isNot(exhaustedSale.id));
  });

  testWidgets('Customer return PDF contains commercial metadata',
      (tester) async {
    final data = InvoiceData(
      invoiceId: 'CR-2026-000001',
      date: DateTime(2026, 9, 4),
      storeName: 'Bayaa POS',
      storeAddress: '',
      storePhone: '',
      cashierName: 'Test Cashier',
      lines: const [
        InvoiceLine(name: 'Test Product', price: 450, qty: 1),
      ],
      subtotal: 450,
      discount: 0,
      tax: 0,
      grandTotal: 450,
      paymentMethod: 'credit',
      originalInvoiceReference: 'INV-2026-000001',
      customerName: 'Test Customer',
      customerCode: 'CUST-001',
    );
    expect(data.invoiceId, 'CR-2026-000001');
    expect(data.invoiceId, isNot('INV-2026-000001'));
    await tester.runAsync(() async {
      final pdfBytes = await InvoicePdfService.buildReceipt80mm(
        data,
        locale: const Locale('en'),
        documentTitle: 'CUSTOMER RETURN',
      );
      final directory = await Directory.systemTemp.createTemp('bayaa-pdf-');
      final pdfPath = p.join(directory.path, 'customer-return.pdf');
      await File(pdfPath).writeAsBytes(pdfBytes);
      try {
        final result = await Process.run('pdftotext', [pdfPath, '-']);
        expect(result.exitCode, 0);
        final text = result.stdout as String;
        for (final value in [
          'CUSTOMER RETURN',
          'CR-2026-000001',
          'INV-2026-000001',
          'Test Customer',
          'CUST-001',
          'Test Cashier',
          'Test Product',
          '1',
          '450',
        ]) {
          expect(text, contains(value));
        }
        expect(text.indexOf('CR-2026-000001'),
            isNot(text.indexOf('INV-2026-000001')));
      } finally {
        await directory.delete(recursive: true);
      }
    });
  });

  test(
      'Customer CRUD, search, ledger balance, and opening balance use the repository',
      () async {
    final repository = CustomerRepositoryImpl();
    final now = DateTime.now();
    final customer = Customer(
      id: 'cust-crud',
      code: 'C-CRUD',
      name: 'Customer CRUD',
      phone: '010',
      openingBalance: 25,
      createdAt: now,
      updatedAt: now,
    );

    expect((await repository.createCustomer(customer)).isRight(), isTrue);
    expect(
        (await repository.searchCustomers('CRUD'))
            .getOrElse(() => [])
            .single
            .id,
        'cust-crud');
    expect(
        (await repository.getCustomerBalance('cust-crud')).getOrElse(() => 0),
        25);

    final updated = customer.copyWith(name: 'Updated Customer');
    expect((await repository.updateCustomer(updated)).isRight(), isTrue);
    expect(
        (await repository.getCustomerById('cust-crud'))
            .getOrElse(() => null)!
            .name,
        'Updated Customer');
    expect((await repository.deleteCustomer('cust-crud')).isRight(), isTrue);
    expect(
        (await repository.getCustomerById('cust-crud'))
            .getOrElse(() => null)!
            .isActive,
        isFalse);
  });

  test(
      'Supplier CRUD, search, ledger balance, and opening balance use the repository',
      () async {
    final repository = SupplierRepositoryImpl();
    final now = DateTime.now();
    final supplier = Supplier(
      id: 'sup-crud',
      code: 'S-CRUD',
      name: 'Supplier CRUD',
      phone: '011',
      openingBalance: 40,
      createdAt: now,
      updatedAt: now,
    );

    expect((await repository.createSupplier(supplier)).isRight(), isTrue);
    expect(
        (await repository.searchSuppliers('CRUD'))
            .getOrElse(() => [])
            .single
            .id,
        'sup-crud');
    expect((await repository.getSupplierBalance('sup-crud')).getOrElse(() => 0),
        40);

    final updated = Supplier(
      id: supplier.id,
      code: supplier.code,
      name: 'Updated Supplier',
      phone: supplier.phone,
      createdAt: supplier.createdAt,
      updatedAt: now,
    );
    expect((await repository.updateSupplier(updated)).isRight(), isTrue);
    expect(
        (await repository.getSupplierById('sup-crud'))
            .getOrElse(() => null)!
            .name,
        'Updated Supplier');
    expect((await repository.deleteSupplier('sup-crud')).isRight(), isTrue);
    expect(
        (await repository.getSupplierById('sup-crud'))
            .getOrElse(() => null)!
            .isActive,
        isFalse);
  });

  test('Customer and supplier codes are generated and immutable', () async {
    final now = DateTime.now();
    final customers = CustomerRepositoryImpl();
    final suppliers = SupplierRepositoryImpl();
    final customer = Customer(
      id: 'auto-customer',
      code: '',
      name: 'Auto Customer',
      phone: '012',
      createdAt: now,
      updatedAt: now,
    );
    final supplier = Supplier(
      id: 'auto-supplier',
      code: '',
      name: 'Auto Supplier',
      phone: '013',
      createdAt: now,
      updatedAt: now,
    );
    expect((await customers.createCustomer(customer)).isRight(), isTrue);
    expect((await suppliers.createSupplier(supplier)).isRight(), isTrue);
    final savedCustomer =
        (await customers.getCustomerById(customer.id)).getOrElse(() => null)!;
    final savedSupplier =
        (await suppliers.getSupplierById(supplier.id)).getOrElse(() => null)!;
    expect(savedCustomer.code, startsWith('CUS-'));
    expect(savedSupplier.code, startsWith('SUP-'));
    expect(
        (await customers.updateCustomer(
          savedCustomer.copyWith(name: 'Renamed'),
        ))
            .isRight(),
        isTrue);
    expect(
        (await customers.getCustomerById(customer.id))
            .getOrElse(() => null)!
            .code,
        savedCustomer.code);
  });

  test('Generated customer and supplier codes are not reused after retirement',
      () async {
    final db = PersistenceInitializer.persistenceManager!.sqliteManager;
    await db.delete('customers');
    await db.delete('suppliers');
    await db.delete('document_sequences');
    final now = DateTime.now();
    final customerRepository = CustomerRepositoryImpl();
    final supplierRepository = SupplierRepositoryImpl();

    Customer customer(String id) => Customer(
          id: id,
          code: '',
          name: id,
          phone: '010',
          createdAt: now,
          updatedAt: now,
        );
    Supplier supplier(String id) => Supplier(
          id: id,
          code: '',
          name: id,
          phone: '011',
          createdAt: now,
          updatedAt: now,
        );

    await customerRepository.createCustomer(customer('customer-1'));
    await customerRepository.createCustomer(customer('customer-2'));
    await supplierRepository.createSupplier(supplier('supplier-1'));
    await supplierRepository.createSupplier(supplier('supplier-2'));
    final c2 = (await customerRepository.getCustomerById('customer-2'))
        .getOrElse(() => null)!;
    final s2 = (await supplierRepository.getSupplierById('supplier-2'))
        .getOrElse(() => null)!;
    expect(c2.code, 'CUS-000002');
    expect(s2.code, 'SUP-000002');
    await customerRepository.deleteCustomer('customer-2');
    await supplierRepository.deleteSupplier('supplier-2');
    await customerRepository.createCustomer(customer('customer-3'));
    await supplierRepository.createSupplier(supplier('supplier-3'));
    expect(
        (await customerRepository.getCustomerById('customer-3'))
            .getOrElse(() => null)!
            .code,
        'CUS-000003');
    expect(
        (await supplierRepository.getSupplierById('supplier-3'))
            .getOrElse(() => null)!
            .code,
        'SUP-000003');
  });

  test(
      'Customer payment supports partial, full, and multiple payments from the ledger',
      () async {
    await _seedCustomerReceivable();
    final repository = CustomerPaymentRepositoryImpl();

    expect(
        (await repository.createPayment(_customerPayment('cp-1', 200)))
            .isRight(),
        isTrue);
    expect(
        (await repository.getCustomerBalance('payment-customer'))
            .getOrElse(() => -1),
        800);
    expect(
        (await repository.createPayment(_customerPayment('cp-2', 300)))
            .isRight(),
        isTrue);
    expect(
        (await repository.createPayment(_customerPayment('cp-3', 500)))
            .isRight(),
        isTrue);
    expect(
        (await repository.getCustomerBalance('payment-customer'))
            .getOrElse(() => -1),
        0);

    final db = PersistenceInitializer.persistenceManager!.sqliteManager;
    expect(await db.query('customer_payments'), hasLength(3));
    expect(
        await db.query('customer_ledger',
            where: 'entry_type = ?', whereArgs: ['customer_payment']),
        hasLength(3));
    final cashMovements = await db.query('cash_movements',
        where: 'reference_type = ? AND reference_id = ?',
        whereArgs: ['customer_payment', 'cp-1']);
    expect(cashMovements, hasLength(1));
    expect(cashMovements.single['movement_type'], 'customer_payment_cash');
    expect(cashMovements.single['amount'], 200.0);
    expect(cashMovements.single['reference_id'], 'cp-1');
    expect(cashMovements.single['user_id'], isNull);
    expect(
        await db.query('cash_movements',
            where: 'reference_type = ?', whereArgs: ['customer_payment']),
        hasLength(3));
    final history = (await repository.getPaymentHistory()).getOrElse(() => []);
    expect(
        history.singleWhere(
            (row) => row['reference'] == 'CP-cp-1')['customer_name'],
        'Payment Customer');
  });

  test(
      'Customer payment rejects invalid, overpaid, and duplicate references without mutation',
      () async {
    await _seedCustomerReceivable();
    final repository = CustomerPaymentRepositoryImpl();
    expect(
        (await repository.createPayment(_customerPayment('cp-valid', 940)))
            .isRight(),
        isTrue);
    final db = PersistenceInitializer.persistenceManager!.sqliteManager;
    final beforePayments = await db.query('customer_payments');
    final beforeLedger = await db.query('customer_ledger');
    final beforeAudit = await db.query('activity_logs');

    expect(
        (await repository.createPayment(_customerPayment('cp-over', 70)))
            .isLeft(),
        isTrue);
    expect(
        (await repository.createPayment(_customerPayment('cp-zero', 0)))
            .isLeft(),
        isTrue);
    expect(
        (await repository.createPayment(_customerPayment('cp-negative', -1)))
            .isLeft(),
        isTrue);
    expect(
        (await repository.createPayment(
                _customerPayment('cp-duplicate', 1, reference: 'CP-cp-valid')))
            .isLeft(),
        isTrue);
    expect(await db.query('customer_payments'), beforePayments);
    expect(await db.query('customer_ledger'), beforeLedger);
    expect(await db.query('activity_logs'), beforeAudit);
  });

  test('Customer payment generates empty references and preserves manual ones',
      () async {
    await _seedCustomerReceivable();
    final repository = CustomerPaymentRepositoryImpl();
    expect(
      (await repository
              .createPayment(_customerPayment('cp-empty', 10, reference: '')))
          .isRight(),
      isTrue,
    );
    expect(
      (await repository.createPayment(
              _customerPayment('cp-manual', 10, reference: 'PAY-TEST-001')))
          .isRight(),
      isTrue,
    );
    final db = PersistenceInitializer.persistenceManager!.sqliteManager;
    final payments = await db.query('customer_payments');
    expect(payments, hasLength(2));
    expect(payments.firstWhere((row) => row['id'] == 'cp-empty')['reference'],
        matches(RegExp(r'^CP-\d{4}-\d{6}$')));
    expect(payments.firstWhere((row) => row['id'] == 'cp-manual')['reference'],
        'PAY-TEST-001');
    expect((await db.query('activity_logs')).last['description'],
        contains('PAY-TEST-001'));
    expect(
        (await repository.getPaymentHistory())
            .getOrElse(() => [])
            .firstWhere((row) => row['id'] == 'cp-manual')['reference'],
        'PAY-TEST-001');
  });

  test('Customer payment 1450 outstanding minus 1200 leaves 250', () async {
    await _seedCustomerReceivable(amount: 1450);
    final repository = CustomerPaymentRepositoryImpl();
    final result = await repository.createPayment(
      _customerPayment('cp-1200', 1200, reference: 'PAY-2026-001'),
    );

    expect(result.isRight(), isTrue);
    expect(
      (await repository.getCustomerBalance('payment-customer'))
          .getOrElse(() => -1),
      250,
    );
    final db = PersistenceInitializer.persistenceManager!.sqliteManager;
    expect(await db.query('customer_payments'), hasLength(1));
    expect(
      await db.query('customer_ledger',
          where: 'entry_type = ?', whereArgs: ['customer_payment']),
      hasLength(1),
    );
    expect((await db.query('customer_payments')).single['reference'],
        'PAY-2026-001');
  });

  test('Customer payment generates a unique reference when empty', () async {
    await _seedCustomerReceivable(amount: 1000);
    final repository = CustomerPaymentRepositoryImpl();
    final result = await repository.createPayment(
      _customerPayment('cp-auto', 300, reference: ''),
    );

    expect(result.isRight(), isTrue);
    final db = PersistenceInitializer.persistenceManager!.sqliteManager;
    final payment = (await db.query('customer_payments')).single;
    expect(payment['reference'], matches(RegExp(r'^CP-\d{4}-\d{6}$')));
    expect(
      (await repository.getCustomerBalance('payment-customer'))
          .getOrElse(() => -1),
      700,
    );
  });

  testWidgets(
      'Payment receipt PDF contains payment semantics without item table',
      (tester) async {
    final data = InvoiceData(
      invoiceId: 'PAY-TEST-001',
      date: DateTime(2026, 9, 4),
      storeName: 'Bayaa POS',
      storeAddress: '',
      storePhone: '',
      cashierName: 'Test Cashier',
      lines: const [],
      subtotal: 500,
      discount: 0,
      tax: 0,
      grandTotal: 500,
      paymentMethod: 'cash',
      customerName: 'Test Customer',
      customerCode: 'CUST-001',
      previousBalance: 1000,
      remainingBalance: 500,
      footerNote: 'Test note',
    );
    await tester.runAsync(() async {
      final pdfBytes = await InvoicePdfService.buildReceipt80mm(
        data,
        locale: const Locale('en'),
        documentTitle: 'PAYMENT RECEIPT',
      );
      final directory = await Directory.systemTemp.createTemp('bayaa-payment-');
      final pdfPath = p.join(directory.path, 'payment.pdf');
      await File(pdfPath).writeAsBytes(pdfBytes);
      try {
        final result = await Process.run('pdftotext', [pdfPath, '-']);
        expect(result.exitCode, 0);
        final text = result.stdout as String;
        for (final value in [
          'PAYMENT RECEIPT',
          'Payment Reference:',
          'PAY-TEST-001',
          'Test Customer',
          'CUST-001',
          'Test Cashier',
          'Amount Paid:',
          'Previous Balance',
          'Remaining Balance',
          '500',
          '1 000',
          'Thank you for your payment.',
          'Test note',
          'Signature',
        ]) {
          expect(text, contains(value));
        }
        expect(text, isNot(contains('Invoice No:')));
        expect(text, isNot(contains('Grand Total:')));
        expect(text, isNot(contains('Thank you for shopping with us!')));
        expect(text, isNot(contains('Product')));
        expect(text, isNot(contains('Qty')));
      } finally {
        await directory.delete(recursive: true);
      }
    });
  });

  test(
      'Customer payment rejects an invalid customer and full payment reaches zero',
      () async {
    await _seedCustomerReceivable();
    final repository = CustomerPaymentRepositoryImpl();
    expect(
      (await repository.createPayment(
        _customerPayment('cp-invalid-customer', 10, customerId: 'missing'),
      ))
          .isLeft(),
      isTrue,
    );
    expect(
        (await repository.createPayment(_customerPayment('cp-full', 1000)))
            .isRight(),
        isTrue);
    expect(
        (await repository.getCustomerBalance('payment-customer'))
            .getOrElse(() => -1),
        0);
    expect(
      (await repository.createPayment(_customerPayment('cp-after-full', 1)))
          .isLeft(),
      isTrue,
    );
  });

  test('Customer payment leaves historical sale data unchanged', () async {
    await _seedCustomerReceivable();
    final db = PersistenceInitializer.persistenceManager!.sqliteManager;
    await db.insert('sales', {
      'id': 'payment-sale',
      'total': 1000.0,
      'created_at': '2026-09-01T10:00:00.000',
      'customer_id': 'payment-customer',
      'items_count': 1,
      'is_refund': 0,
      'payment_method': 'credit',
    });
    final before =
        await db.query('sales', where: 'id = ?', whereArgs: ['payment-sale']);
    await db.insert('products', {
      'id': 'payment-product',
      'barcode': 'PAY-P',
      'name': 'Payment Product',
      'price': 1200.0,
      'min_price': 1.0,
      'wholesale_price': 800.0,
      'stock': 5.0,
      'min_stock': 1.0,
      'is_active': 1,
      'created_at': DateTime.now().toIso8601String(),
      'updated_at': DateTime.now().toIso8601String(),
    });
    await db.insert('sale_items', {
      'id': 'payment-sale-item',
      'sale_id': 'payment-sale',
      'product_id': 'payment-product',
      'product_name': 'Payment Product',
      'quantity': 2.0,
      'price': 1200.0,
      'subtotal': 2400.0,
    });
    final beforeItems = await db
        .query('sale_items', where: 'sale_id = ?', whereArgs: ['payment-sale']);
    expect(
        (await CustomerPaymentRepositoryImpl()
                .createPayment(_customerPayment('cp-history', 100)))
            .isRight(),
        isTrue);
    expect(
        await db.query('sales', where: 'id = ?', whereArgs: ['payment-sale']),
        before);
    expect(
        await db.query('sale_items',
            where: 'sale_id = ?', whereArgs: ['payment-sale']),
        beforeItems);
  });

  test(
      'Customer payment rolls back payment, ledger, and audit after downstream failure',
      () async {
    await _seedCustomerReceivable();
    final db = PersistenceInitializer.persistenceManager!.sqliteManager;
    final repository = CustomerPaymentRepositoryImpl(
      failureInjector: (_) async => throw StateError('injected failure'),
    );
    expect(
        (await repository.createPayment(_customerPayment('cp-rollback', 400)))
            .isLeft(),
        isTrue);
    expect(
        (await repository.getCustomerBalance('payment-customer'))
            .getOrElse(() => -1),
        1000);
    expect(await db.query('customer_payments'), isEmpty);
    expect(
        await db.query('customer_ledger',
            where: 'entry_type = ?', whereArgs: ['customer_payment']),
        isEmpty);
    expect(await db.query('activity_logs'), isEmpty);
  });

  test('Cashier is rejected at the customer payment service boundary',
      () async {
    await _seedCustomerReceivable();
    getIt<UserCubit>().currentUser = User(
      username: 'cashier',
      name: 'Cashier',
      phone: '011',
      userType: UserType.cashier,
      password: 'pass',
    );
    final result = await CustomerPaymentRepositoryImpl()
        .createPayment(_customerPayment('cp-cashier', 10));
    expect(result.isLeft(), isTrue);
    getIt<UserCubit>().currentUser = User(
      username: 'manager',
      name: 'Manager',
      phone: '010',
      userType: UserType.manager,
      password: 'pass',
    );
  });

  test('Canonical stock posting records positive and negative movements',
      () async {
    final db = PersistenceInitializer.persistenceManager!.sqliteManager;
    await _seedCanonicalSupplier();
    await db.insert('products', {
      'id': 'canonical-product',
      'barcode': 'CANONICAL',
      'name': 'Canonical Product',
      'price': 10.0,
      'min_price': 1.0,
      'wholesale_price': 5.0,
      'stock': 0.0,
      'min_stock': 0.0,
      'is_active': 1,
      'created_at': DateTime.now().toIso8601String(),
      'updated_at': DateTime.now().toIso8601String(),
    });
    await db.insert('purchases', {
      'id': 'canonical-purchase',
      'supplier_id': 'canonical-supplier',
      'reference_number': 'PUR-CANONICAL',
      'purchase_date': DateTime.now().toIso8601String(),
      'subtotal': 0.0,
      'total': 0.0,
      'status': 'confirmed',
      'created_at': DateTime.now().toIso8601String(),
      'updated_at': DateTime.now().toIso8601String(),
    });
    await db.insert('customers', {
      'id': 'canonical-customer',
      'code': 'CUS-CANONICAL',
      'name': 'Canonical Customer',
      'is_active': 1,
      'created_at': DateTime.now().toIso8601String(),
      'updated_at': DateTime.now().toIso8601String(),
    });
    await db.insert('sales', {
      'id': 'canonical-sale',
      'customer_id': 'canonical-customer',
      'total': 0.0,
      'status': 'posted',
      'created_at': DateTime.now().toIso8601String(),
    });
    const posting = CanonicalStockPostingService();
    await db.transaction((txn) async {
      await posting.post(
        txn: txn,
        movementId: 'canonical-in',
        productId: 'canonical-product',
        quantityChange: 20,
        movementType: 'purchase',
        referenceType: 'purchase',
        referenceId: 'canonical-purchase',
      );
      await posting.post(
        txn: txn,
        movementId: 'canonical-out',
        productId: 'canonical-product',
        quantityChange: -5,
        movementType: 'sale',
        referenceType: 'sale',
        referenceId: 'canonical-sale',
      );
    });
    expect((await db.query('products')).single['stock'], 15.0);
    expect(await db.query('stock_movements'), hasLength(2));
    const reconciliationService = InventoryReconciliationService();
    final reconciliation = await reconciliationService.reconcile(db.database);
    await expectLater(
      db.transaction((txn) => posting.post(
            txn: txn,
            movementId: 'canonical-in',
            productId: 'canonical-product',
            quantityChange: 1,
            movementType: 'purchase',
            referenceType: 'purchase',
            referenceId: 'duplicate-purchase',
          )),
      throwsA(isA<StateError>()),
    );
    expect(reconciliation.single.isMatched, isTrue);
    expect(reconciliation.single.difference, 0);
  });

  test('Canonical stock posting rejects invalid and duplicate movements',
      () async {
    final db = PersistenceInitializer.persistenceManager!.sqliteManager;
    await _seedCanonicalSupplier();
    await db.insert('purchases', {
      'id': 'missing-product-purchase',
      'supplier_id': 'canonical-supplier',
      'reference_number': 'PUR-MISSING',
      'purchase_date': DateTime.now().toIso8601String(),
      'subtotal': 0.0,
      'total': 0.0,
      'status': 'confirmed',
      'created_at': DateTime.now().toIso8601String(),
      'updated_at': DateTime.now().toIso8601String(),
    });
    await db.insert('purchases', {
      'id': 'zero-purchase',
      'supplier_id': 'canonical-supplier',
      'reference_number': 'PUR-ZERO',
      'purchase_date': DateTime.now().toIso8601String(),
      'subtotal': 0.0,
      'total': 0.0,
      'status': 'confirmed',
      'created_at': DateTime.now().toIso8601String(),
      'updated_at': DateTime.now().toIso8601String(),
    });
    const posting = CanonicalStockPostingService();
    await expectLater(
      db.transaction((txn) => posting.post(
            txn: txn,
            movementId: 'missing-product-movement',
            productId: 'missing-product',
            quantityChange: 1,
            movementType: 'purchase',
            referenceType: 'purchase',
            referenceId: 'missing-product-purchase',
          )),
      throwsA(isA<StateError>()),
    );
    await expectLater(
      db.transaction((txn) => posting.post(
            txn: txn,
            movementId: 'zero-movement',
            productId: 'missing-product',
            quantityChange: 0,
            movementType: 'purchase',
            referenceType: 'purchase',
            referenceId: 'zero-purchase',
          )),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('Canonical stock posting rolls back stock and movement on failure',
      () async {
    final db = PersistenceInitializer.persistenceManager!.sqliteManager;
    await _seedCanonicalSupplier();
    await db.insert('products', {
      'id': 'rollback-product',
      'barcode': 'ROLLBACK',
      'name': 'Rollback Product',
      'price': 10.0,
      'min_price': 1.0,
      'wholesale_price': 5.0,
      'stock': 20.0,
      'min_stock': 0.0,
      'is_active': 1,
      'created_at': DateTime.now().toIso8601String(),
      'updated_at': DateTime.now().toIso8601String(),
    });
    await db.insert('purchases', {
      'id': 'rollback-purchase',
      'supplier_id': 'canonical-supplier',
      'reference_number': 'PUR-ROLLBACK',
      'purchase_date': DateTime.now().toIso8601String(),
      'subtotal': 0.0,
      'total': 0.0,
      'status': 'confirmed',
      'created_at': DateTime.now().toIso8601String(),
      'updated_at': DateTime.now().toIso8601String(),
    });
    const posting = CanonicalStockPostingService();
    await expectLater(
      db.transaction((txn) async {
        await posting.post(
          txn: txn,
          movementId: 'rollback-movement',
          productId: 'rollback-product',
          quantityChange: 5,
          movementType: 'purchase',
          referenceType: 'purchase',
          referenceId: 'rollback-purchase',
        );
        throw StateError('injected failure');
      }),
      throwsA(isA<StateError>()),
    );
    expect((await db.query('products')).single['stock'], 20.0);
    expect(await db.query('stock_movements'), isEmpty);
  });

  test('Cash integrations post only the expected business cash effects',
      () async {
    final db = PersistenceInitializer.persistenceManager!.sqliteManager;
    await _seedSaleFixture(customer: true);
    final salesRepository = SalesRepositoryImpl();
    final cashSaleResult = await salesRepository.createSaleWithCashier(
      items: [_saleFixtureItem()],
      total: 450,
      cashierName: 'Cashier',
      cashierUsername: 'cashier-1',
      customerId: 'sale-customer',
      paymentMethod: 'cash',
    );
    expect(cashSaleResult.isRight(), isTrue);
    cashSaleResult.fold(
      (failure) => throw StateError(failure.message),
      (_) => null,
    );
    final cashSale =
        (await db.query('sales', orderBy: 'rowid DESC', limit: 1)).single;
    expect(
      await db.query('cash_movements',
          where: 'reference_id = ?', whereArgs: [cashSale['id']]),
      hasLength(1),
    );
    expect(
      (await db.query('cash_movements',
              where: 'reference_id = ?', whereArgs: [cashSale['id']]))
          .single['amount'],
      450.0,
    );

    await _seedPurchaseFixtures();
    await PurchaseRepositoryImpl().createPurchase(
        _purchase('cash-integration-purchase', [_line(1, 1, 100)]));
    final supplierPayment = _payment('cash-integration-supplier-payment', 40);
    expect(
      (await SupplierPaymentRepositoryImpl().createPayment(supplierPayment))
          .isRight(),
      isTrue,
    );
    expect(
      (await db.query('cash_movements',
              where: 'reference_id = ?', whereArgs: [supplierPayment.id]))
          .single['amount'],
      -40.0,
    );

    final expenseRepository = ExpenseRepository();
    await expenseRepository.add(Expense(
      id: 'cash-integration-expense',
      title: 'Cash expense',
      amount: 25,
      category: 'operations',
      date: DateTime(2026, 9, 6),
      paymentMethod: 'cash',
    ));
    await expenseRepository.add(Expense(
      id: 'noncash-integration-expense',
      title: 'Non-cash expense',
      amount: 30,
      category: 'operations',
      date: DateTime(2026, 9, 6),
      paymentMethod: 'non_cash',
    ));
    expect(
      await db.query('cash_movements',
          where: 'reference_id = ?', whereArgs: ['cash-integration-expense']),
      hasLength(1),
    );
    expect(
      await db.query('cash_movements',
          where: 'reference_id = ?',
          whereArgs: ['noncash-integration-expense']),
      isEmpty,
    );
  });

  test(
      'Cash backup restore preserves business movements and lifecycle ordering',
      () async {
    final manager = PersistenceInitializer.persistenceManager!;
    final db = manager.sqliteManager;
    await _seedSaleFixture();
    await _seedRefundManager();
    await _seedCustomerReceivable();
    final saleResult = await SalesRepositoryImpl().createSaleWithCashier(
      items: [_saleFixtureItem()],
      total: 450,
      cashierName: 'Cashier',
      cashierUsername: 'cashier-1',
      customerId: 'sale-customer',
      paymentMethod: 'cash',
    );
    expect(saleResult.isRight(), isTrue);
    final sale = (await db.query('sales')).single;
    expect(
      (await CustomerPaymentRepositoryImpl()
              .createPayment(_customerPayment('backup-customer-payment', 100)))
          .isRight(),
      isTrue,
    );
    await _seedPurchaseFixtures();
    await PurchaseRepositoryImpl()
        .createPurchase(_purchase('backup-purchase', [_line(1, 1, 100)]));
    expect(
      (await SupplierPaymentRepositoryImpl()
              .createPayment(_payment('backup-supplier-payment', 40)))
          .isRight(),
      isTrue,
    );
    await ExpenseRepository().add(Expense(
      id: 'backup-expense',
      title: 'Backup expense',
      amount: 25,
      category: 'operations',
      date: DateTime(2026, 9, 6),
      paymentMethod: 'cash',
    ));
    final loadedSale = (await SalesRepositoryImpl().getRecentSales(limit: 10))
        .fold((failure) => throw StateError(failure.message),
            (sales) => sales.single);
    await InvoiceCubit(SalesRepositoryImpl()).createPartialRefund(
      originalSale: loadedSale,
      itemsToRefund: [
        RefundItem(
          productId: 'sale-product',
          productName: 'Sale Product',
          quantity: 1,
          unitPrice: 450,
          wholesalePrice: 300,
        ),
      ],
    );

    final before = await db.query('cash_movements', orderBy: 'id');
    final beforeBalance = before.fold<double>(
        0, (sum, row) => sum + (row['amount'] as num).toDouble());
    final registersBefore = await db.query('cash_registers');
    expect(registersBefore, hasLength(1));
    expect(before, hasLength(5));

    expect(
        await manager.backupManager.createBackup(
          actingUser: User(
            username: 'manager',
            name: 'Manager',
            phone: '010',
            userType: UserType.manager,
            password: 'pass',
          ),
        ),
        isTrue);
    final backup = await manager.backupManager.getLatestBackup();
    expect(backup, isNotNull);

    await CanonicalCashPostingService().post(
      movementType: 'cash_in',
      amount: 77,
      referenceType: 'test',
      referenceId: 'post-backup-mutation',
      idempotencyKey: 'post-backup-mutation',
      description: 'Post-backup mutation',
    );
    expect((await db.query('cash_movements')), hasLength(6));

    expect(
        await manager.backupManager.restoreFromBackup(
          backup!.path,
          actingUser: User(
            username: 'manager',
            name: 'Manager',
            phone: '010',
            userType: UserType.manager,
            password: 'pass',
          ),
        ),
        isTrue);

    final restoredDb = PersistenceInitializer.persistenceManager!.sqliteManager;
    final after = await restoredDb.query('cash_movements', orderBy: 'id');
    expect(after, hasLength(before.length));
    expect(after.map((row) => row['id']),
        orderedEquals(before.map((row) => row['id'])));
    expect(
      after.fold<double>(
          0, (sum, row) => sum + (row['amount'] as num).toDouble()),
      beforeBalance,
    );
    expect(await restoredDb.query('cash_registers'), hasLength(1));
    expect(
        await restoredDb.query('cash_movements',
            where: 'reference_id = ?', whereArgs: [sale['id']]),
        hasLength(1));
    expect(
      (await restoredDb.rawQuery('PRAGMA integrity_check'))
          .single['integrity_check'],
      'ok',
    );
    expect(
        await restoredDb.rawQuery(
            "SELECT name FROM sqlite_master WHERE type = 'index' AND name = 'idx_cash_movements_reference'"),
        hasLength(1));
    expect(
        await restoredDb.rawQuery(
            "SELECT name FROM sqlite_master WHERE type = 'trigger' AND name = 'cash_movements_no_update'"),
        hasLength(1));
    expect(
      () => restoredDb.execute(
          "UPDATE cash_movements SET amount = 1 WHERE id = '${after.single['id']}'"),
      throwsA(anything),
    );
    expect(
      () => restoredDb.delete('cash_movements',
          where: 'id = ?', whereArgs: [after.single['id']]),
      throwsA(anything),
    );

    final gate = DatabaseLifecycleCoordinator.instance;
    final queue = BackgroundWriteQueue(lifecycleCoordinator: gate)..start();
    addTearDown(queue.dispose);
    final activeStarted = Completer<void>();
    final releaseActive = Completer<void>();
    final active = gate.withWriteAccess(() async {
      activeStarted.complete();
      await releaseActive.future;
    });
    await activeStarted.future;
    final queued = queue.enqueue(() async {
      final queuedDb = PersistenceInitializer.persistenceManager!.sqliteManager;
      await queuedDb.database
          .transaction((txn) => CanonicalCashPostingService().postInTransaction(
                txn: txn,
                movementType: 'cash_in',
                amount: 11,
                referenceType: 'test',
                referenceId: 'queued-cash-write',
                idempotencyKey: 'queued-cash-write',
                description: 'Queued cash write',
              ));
    });
    final exclusive = gate.withExclusiveAccess(() async {});
    expect(gate.isExclusiveActive, isFalse);
    releaseActive.complete();
    await active;
    await exclusive;
    await queued;
    await Future<void>.delayed(const Duration(milliseconds: 25));
    final activeDb = PersistenceInitializer.persistenceManager!.sqliteManager;
    expect(
      await activeDb.query('cash_movements',
          where: 'reference_id = ?', whereArgs: ['queued-cash-write']),
      hasLength(1),
    );
  });

  test('Business cash requests reject duplicate postings', () async {
    await _seedSaleFixture();
    await _seedCustomerReceivable();
    await _seedPurchaseFixtures();
    final db = PersistenceInitializer.persistenceManager!.sqliteManager;
    await CanonicalCashPostingService().post(
      movementType: 'opening_balance',
      amount: 1000,
      referenceType: 'test',
      referenceId: 'business-idempotency-opening',
      idempotencyKey: 'business-idempotency-opening',
      description: 'Business idempotency opening',
    );

    final sales = SalesRepositoryImpl();
    final sale = Sale(
      id: 'business-idempotent-sale',
      total: 450,
      items: 1,
      date: DateTime(2026, 9, 6),
      cashierName: 'Cashier',
      cashierUsername: 'cashier-1',
      paymentMethod: 'cash',
      saleItems: [
        SaleItem(
          productId: 'sale-product',
          name: 'Sale Product',
          price: 450,
          quantity: 1,
          total: 450,
          wholesalePrice: 300,
        ),
      ],
    );
    expect((await sales.saveSale(sale)).isRight(), isTrue);
    expect((await sales.saveSale(sale)).isLeft(), isTrue);

    final payment = _customerPayment('business-idempotent-payment', 100);
    final paymentResults = await Future.wait([
      CustomerPaymentRepositoryImpl().createPayment(payment),
      CustomerPaymentRepositoryImpl().createPayment(payment),
    ]);
    expect(paymentResults.where((result) => result.isRight()), hasLength(1));

    await PurchaseRepositoryImpl().createPurchase(
        _purchase('business-idempotent-purchase', [_line(1, 1, 100)]));
    final supplierPayment =
        _payment('business-idempotent-supplier-payment', 40);
    final supplierResults = await Future.wait([
      SupplierPaymentRepositoryImpl().createPayment(supplierPayment),
      SupplierPaymentRepositoryImpl().createPayment(supplierPayment),
    ]);
    expect(supplierResults.where((result) => result.isRight()), hasLength(1));

    final expense = Expense(
      id: 'business-idempotent-expense',
      title: 'Business idempotent expense',
      amount: 50,
      category: 'operations',
      date: DateTime(2026, 9, 6),
      paymentMethod: 'cash',
    );
    await ExpenseRepository().add(expense);
    await expectLater(ExpenseRepository().add(expense), throwsA(anything));

    final movements = await db.query('cash_movements');
    expect(movements, hasLength(5));
    expect(
      movements.fold<double>(
          0, (sum, row) => sum + (row['amount'] as num).toDouble()),
      1460,
    );
    expect(
      await db.query('cash_movements',
          where: 'reference_id = ?',
          whereArgs: ['business-idempotent-payment']),
      hasLength(1),
    );
    expect(
      await db.query('cash_movements',
          where: 'reference_id = ?',
          whereArgs: ['business-idempotent-supplier-payment']),
      hasLength(1),
    );
    expect(
      await db.query('cash_movements',
          where: 'reference_id = ?',
          whereArgs: ['business-idempotent-expense']),
      hasLength(1),
    );
  });

  test('Exact cash invariant remains 1060 across production workflows',
      () async {
    final db = PersistenceInitializer.persistenceManager!.sqliteManager;
    final now = DateTime.now().toIso8601String();
    await db.insert('users', {
      'id': 'manager',
      'username': 'manager',
      'display_name': 'Manager',
      'password_hash': 'test',
      'role': 'manager',
      'is_active': 1,
      'created_at': now,
    });
    await db.insert('customers', {
      'id': 'invariant-customer',
      'code': 'INV-C',
      'name': 'Invariant Customer',
      'is_active': 1,
      'created_at': now,
      'updated_at': now,
    });
    await db.insert('suppliers', {
      'id': 'invariant-supplier',
      'code': 'INV-S',
      'name': 'Invariant Supplier',
      'is_active': 1,
      'created_at': now,
      'updated_at': now,
    });
    await db.insert('categories', {
      'id': 'invariant-category',
      'name': 'Invariant',
      'sort_order': 0,
    });

    Future<void> addProduct(String id, double price) async {
      await db.insert('products', {
        'id': id,
        'barcode': id,
        'name': id,
        'price': price,
        'min_price': 1.0,
        'wholesale_price': price / 2,
        'stock': 10.0,
        'min_stock': 1.0,
        'category_id': 'invariant-category',
        'is_active': 1,
        'created_at': now,
        'updated_at': now,
      });
    }

    await addProduct('invariant-cash-sale', 200);
    await addProduct('invariant-credit-sale', 300);
    await addProduct('invariant-cash-refund', 40);
    await addProduct('invariant-credit-refund', 30);
    await addProduct('invariant-purchase', 150);
    await CanonicalCashPostingService().post(
      movementType: 'opening_balance',
      amount: 1000,
      referenceType: 'test',
      referenceId: 'invariant-opening',
      idempotencyKey: 'invariant-opening',
      description: 'Invariant opening balance',
      userId: 'manager',
    );

    CartItemModel item(String id, double amount) => CartItemModel(
          id: id,
          name: id,
          originalPrice: amount,
          salePrice: amount,
          qty: 1,
          date: DateTime(2026, 9, 6),
          minPrice: 1,
          wholesalePrice: amount / 2,
        );
    final sales = SalesRepositoryImpl();
    final cashSale = await sales.createSaleWithCashier(
      items: [item('invariant-cash-sale', 200)],
      total: 200,
      cashierName: 'Manager',
      cashierUsername: 'manager',
      paymentMethod: 'cash',
    );
    expect(cashSale.isRight(), isTrue);
    final creditSale = await sales.createSaleWithCashier(
      items: [item('invariant-credit-sale', 300)],
      total: 300,
      cashierName: 'Manager',
      cashierUsername: 'manager',
      customerId: 'invariant-customer',
      paymentMethod: 'credit',
    );
    expect(creditSale.isRight(), isTrue);

    final customerPayment = _customerPayment(
      'invariant-payment',
      100,
      customerId: 'invariant-customer',
    );
    expect(
      (await CustomerPaymentRepositoryImpl().createPayment(customerPayment))
          .isRight(),
      isTrue,
    );

    final purchase = Purchase(
      id: 'invariant-purchase-document',
      referenceNumber: 'INV-PURCHASE',
      supplierId: 'invariant-supplier',
      purchaseDate: DateTime(2026, 9, 6),
      lines: const [
        PurchaseLine(
          productId: 'invariant-purchase',
          productName: 'invariant-purchase',
          productBarcode: 'invariant-purchase',
          quantity: 1,
          unitCost: 150,
        ),
      ],
      createdBy: 'manager',
    );
    expect((await PurchaseRepositoryImpl().createPurchase(purchase)).isRight(),
        isTrue);
    final supplierPayment = _payment(
      'invariant-supplier-payment',
      150,
      supplierId: 'invariant-supplier',
    );
    expect(
      (await SupplierPaymentRepositoryImpl().createPayment(supplierPayment))
          .isRight(),
      isTrue,
    );
    expect(
      (await SupplierReturnRepositoryImpl().createReturn(_returnValue(
        'invariant-supplier-return',
        purchase.id,
        [
          const SupplierReturnLine(
            purchaseItemId: 'invariant-purchase-document_invariant-purchase',
            productId: 'invariant-purchase',
            quantity: 1,
          ),
        ],
        supplierId: 'invariant-supplier',
      )))
          .isRight(),
      isTrue,
    );

    await ExpenseRepository().add(Expense(
      id: 'invariant-expense',
      title: 'Invariant expense',
      amount: 50,
      category: 'operations',
      date: DateTime(2026, 9, 6),
      paymentMethod: 'cash',
    ));

    final cashSaleModel = (await sales.getRecentSales(limit: 10)).fold(
      (failure) => throw StateError(failure.message),
      (values) => values.firstWhere((value) => value.total == 200),
    );
    final refundItems = [
      RefundItem(
        productId: 'invariant-cash-sale',
        productName: 'invariant-cash-sale',
        quantity: 1,
        unitPrice: 200,
        wholesalePrice: 100,
      ),
    ];
    final refundCubit = InvoiceCubit(sales);
    await refundCubit.createPartialRefund(
      originalSale: cashSaleModel,
      itemsToRefund: refundItems,
    );

    final creditSaleModel = (await sales.getRecentSales(limit: 10)).fold(
      (failure) => throw StateError(failure.message),
      (values) => values.firstWhere((value) => value.total == 300),
    );
    await InvoiceCubit(sales).createPartialRefund(
      originalSale: creditSaleModel,
      itemsToRefund: [
        RefundItem(
          productId: 'invariant-credit-sale',
          productName: 'invariant-credit-sale',
          quantity: 1,
          unitPrice: 30,
          wholesalePrice: 150,
        ),
      ],
    );

    final movements =
        await db.query('cash_movements', orderBy: 'created_at ASC, id ASC');
    final movementSummary = movements
        .map((row) => '${row['movement_type']}:${row['amount']}:'
            '${row['reference_id']}:${row['idempotency_key']}:'
            '${row['cash_register_id']}:${row['session_id']}')
        .toList();
    print('INVARIANT_MOVEMENTS $movementSummary');
    expect(
      movements
          .map((row) => '${row['movement_type']}:${row['amount']}')
          .toSet(),
      {
        'opening_balance:1000.0',
        'sale_cash:200.0',
        'customer_payment_cash:100.0',
        'supplier_payment_cash:-150.0',
        'expense_cash:-50.0',
        'customer_refund_cash:-200.0',
      },
    );
    expect(
      movements.fold<double>(
          0, (sum, row) => sum + (row['amount'] as num).toDouble()),
      900.0,
    );
    expect(await db.query('cash_movements'), hasLength(6));
    expect(
        await db.query('cash_movements',
            where: 'reference_id = ?', whereArgs: ['invariant-credit-sale']),
        isEmpty);
    expect(
        await db.query('cash_movements',
            where: 'reference_id = ?', whereArgs: [purchase.id]),
        isEmpty);
    expect(
        await db.query('cash_movements',
            where: 'reference_type = ? AND LOWER(reference_id) LIKE ?',
            whereArgs: ['refund', '%refund%']),
        hasLength(1));
  });
}
