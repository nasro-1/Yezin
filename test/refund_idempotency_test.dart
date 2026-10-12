import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:bayaa_pos/core/data/services/persistence_initializer.dart';
import 'package:bayaa_pos/core/di/dependency_injection.dart';
import 'package:bayaa_pos/core/session/session_manager.dart';
import 'package:bayaa_pos/features/auth/data/models/user_model.dart';
import 'package:bayaa_pos/features/auth/presentation/cubit/user_cubit.dart';
import 'package:bayaa_pos/features/invoice/presentation/cubit/invoice_cubit.dart';
import 'package:bayaa_pos/features/invoice/presentation/widgets/partial_refund_dialog.dart';
import 'package:bayaa_pos/features/sales/data/models/sale_model.dart';
import 'package:bayaa_pos/features/sales/data/repository/sales_repository_impl.dart';
import 'package:path/path.dart' as p;

Future<void> _initializeIsolatedPersistence() async {
  if (getIt.isRegistered<SessionManager>()) {
    getIt<SessionManager>().clearCurrentSession();
  }
  final existing = PersistenceInitializer.persistenceManager;
  if (existing != null) {
    await existing.shutdown();
  }

  final appData = Platform.environment['APPDATA'] ??
      p.join(
          Platform.environment['USERPROFILE'] ?? 'C:/', 'AppData', 'Roaming');
  final bayaaDir = Directory(p.join(appData, 'Bayaa'));
  await bayaaDir.create(recursive: true);

  final testDirectory = Directory(
    p.join(
      bayaaDir.path,
      'BayaaData',
      'refund_test_${DateTime.now().microsecondsSinceEpoch}',
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

  final configFile = File(p.join(testDirectory.path, 'system_config.json'));
  await configFile.writeAsString(
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
  await PersistenceInitializer.initialize(systemConfigFile: configFile);
}

Future<void> _seedSaleForRefunds({
  required bool cashSale,
  required double quantity,
}) async {
  final db = PersistenceInitializer.persistenceManager!.sqliteManager;
  await db.insert('users', {
    'id': 'manager',
    'username': 'manager',
    'display_name': 'Manager',
    'password_hash': 'test',
    'role': 'manager',
    'is_active': 1,
    'created_at': DateTime.now().toIso8601String(),
    'created_by': null,
  }, conflictAlgorithm: ConflictAlgorithm.replace);
  await db.insert('users', {
    'id': 'cashier-1',
    'username': 'cashier-1',
    'display_name': 'Cashier',
    'password_hash': 'test',
    'role': 'cashier',
    'is_active': 1,
    'created_at': DateTime.now().toIso8601String(),
    'created_by': null,
  }, conflictAlgorithm: ConflictAlgorithm.replace);
  await db.insert('categories', {
    'id': 'refund-category',
    'name': 'Refund Category',
    'color': '#000000',
    'sort_order': 0,
  }, conflictAlgorithm: ConflictAlgorithm.replace);
  await db.insert('customers', {
    'id': 'refund-customer',
    'code': 'REF-CUST',
    'name': 'Refund Customer',
    'is_active': 1,
    'created_at': DateTime.now().toIso8601String(),
    'updated_at': DateTime.now().toIso8601String(),
  }, conflictAlgorithm: ConflictAlgorithm.replace);
  await db.insert('products', {
    'id': 'refund-product',
    'barcode': 'REF-P',
    'name': 'Refund Product',
    'price': 450.0,
    'min_price': 50.0,
    'wholesale_price': 300.0,
    'stock': 20.0,
    'min_stock': 1.0,
    'category_id': 'refund-category',
    'is_active': 1,
    'created_at': DateTime.now().toIso8601String(),
    'updated_at': DateTime.now().toIso8601String(),
  }, conflictAlgorithm: ConflictAlgorithm.replace);

  final sale = Sale(
    id: 'refund-sale-$quantity-${cashSale ? 'cash' : 'credit'}',
    total: 450.0 * quantity,
    items: quantity.toInt(),
    date: DateTime(2026, 9, 3),
    cashierName: 'Cashier',
    cashierUsername: 'cashier-1',
    customerId: 'refund-customer',
    paymentMethod: cashSale ? 'cash' : 'credit',
    saleItems: [
      SaleItem(
        productId: 'refund-product',
        name: 'Refund Product',
        price: 450.0,
        quantity: quantity,
        total: 450.0 * quantity,
        wholesalePrice: 300.0,
      )
    ],
  );

  await SalesRepositoryImpl().saveSale(sale);
}

void main() {
  setUp(() async {
    await _initializeIsolatedPersistence();
    if (!getIt.isRegistered<UserCubit>()) {
      setup();
    }
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

  test('cash refund duplicate is idempotent and creates one refund document', () async {
    await _seedSaleForRefunds(cashSale: true, quantity: 3);
    final cubit = InvoiceCubit(SalesRepositoryImpl());
    final originalSale = (await SalesRepositoryImpl().getRecentSales(limit: 10))
        .getOrElse(() => [])
        .firstWhere((sale) => sale.paymentMethod == 'cash');
    final refundItem = RefundItem(
      productId: 'refund-product',
      productName: 'Refund Product',
      quantity: 1,
      unitPrice: 450.0,
      wholesalePrice: 300.0,
    );

    await cubit.createPartialRefund(originalSale: originalSale, itemsToRefund: [refundItem]);
    await cubit.createPartialRefund(originalSale: originalSale, itemsToRefund: [refundItem]);

    final db = PersistenceInitializer.persistenceManager!.sqliteManager;
    expect(await db.query('sales', where: 'is_refund = 1'), hasLength(1));
    expect(await db.query('cash_movements', where: 'movement_type = ?', whereArgs: ['customer_refund_cash']), hasLength(1));
    expect(await db.query('customer_ledger', where: 'entry_type = ?', whereArgs: ['refund']), isEmpty);
  });

  test('credit refund duplicate is idempotent and reverses once', () async {
    await _seedSaleForRefunds(cashSale: false, quantity: 2);
    final cubit = InvoiceCubit(SalesRepositoryImpl());
    final originalSale = (await SalesRepositoryImpl().getRecentSales(limit: 10))
        .getOrElse(() => [])
        .firstWhere((sale) => sale.paymentMethod == 'credit');
    final refundItem = RefundItem(
      productId: 'refund-product',
      productName: 'Refund Product',
      quantity: 1,
      unitPrice: 450.0,
      wholesalePrice: 300.0,
    );

    await cubit.createPartialRefund(originalSale: originalSale, itemsToRefund: [refundItem]);
    await cubit.createPartialRefund(originalSale: originalSale, itemsToRefund: [refundItem]);

    final db = PersistenceInitializer.persistenceManager!.sqliteManager;
    expect(await db.query('sales', where: 'is_refund = 1'), hasLength(1));
    expect(await db.query('customer_ledger', where: 'entry_type = ?', whereArgs: ['refund']), hasLength(1));
    expect(await db.query('cash_movements', where: 'movement_type = ?', whereArgs: ['customer_refund_cash']), isEmpty);
  });

  test('concurrent identical refund creates only one refund document', () async {
    await _seedSaleForRefunds(cashSale: true, quantity: 3);
    final cubit = InvoiceCubit(SalesRepositoryImpl());
    final originalSale = (await SalesRepositoryImpl().getRecentSales(limit: 10))
        .getOrElse(() => [])
        .firstWhere((sale) => sale.paymentMethod == 'cash');
    final item = RefundItem(
      productId: 'refund-product',
      productName: 'Refund Product',
      quantity: 1,
      unitPrice: 450.0,
      wholesalePrice: 300.0,
    );

    final results = await Future.wait([
      cubit.createPartialRefund(originalSale: originalSale, itemsToRefund: [item]),
      cubit.createPartialRefund(originalSale: originalSale, itemsToRefund: [item]),
    ]);
    expect(results.where((result) => result == RefundResult.success), hasLength(1));
    expect(
      results.where((result) => result == RefundResult.alreadyProcessed),
      hasLength(1),
    );

    final db = PersistenceInitializer.persistenceManager!.sqliteManager;
    expect(await db.query('sales', where: 'is_refund = 1'), hasLength(1));
    expect(await db.query('cash_movements', where: 'movement_type = ?', whereArgs: ['customer_refund_cash']), hasLength(1));
  });

  test('two legitimate partial refunds remain distinct while retries stay no-op', () async {
    await _seedSaleForRefunds(cashSale: true, quantity: 5);
    final cubit = InvoiceCubit(SalesRepositoryImpl());
    final originalSale = (await SalesRepositoryImpl().getRecentSales(limit: 10))
        .getOrElse(() => [])
        .firstWhere((sale) => sale.paymentMethod == 'cash');
    final refundA = RefundItem(
      productId: 'refund-product',
      productName: 'Refund Product',
      quantity: 2,
      unitPrice: 450.0,
      wholesalePrice: 300.0,
    );
    final refundB = RefundItem(
      productId: 'refund-product',
      productName: 'Refund Product',
      quantity: 1,
      unitPrice: 450.0,
      wholesalePrice: 300.0,
    );

    await cubit.createPartialRefund(originalSale: originalSale, itemsToRefund: [refundA]);
    await cubit.createPartialRefund(originalSale: originalSale, itemsToRefund: [refundB]);
    await cubit.createPartialRefund(originalSale: originalSale, itemsToRefund: [refundA]);

    final db = PersistenceInitializer.persistenceManager!.sqliteManager;
    expect(await db.query('sales', where: 'is_refund = 1'), hasLength(2));
    final saleRows = await db.query('sales', where: 'is_refund = 1');
    final refundTotals = saleRows.map((row) => (row['total'] as num).toDouble()).toList();
    expect(refundTotals.fold<double>(0, (sum, value) => sum + value), 1350.0);
  });
}
