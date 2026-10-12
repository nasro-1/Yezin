import 'dart:convert';
import 'dart:io';

import 'package:bayaa_pos/core/data/services/persistence_initializer.dart';
import 'package:bayaa_pos/features/analytics/data/local_fifo_analytics_costing.dart';
import 'package:bayaa_pos/features/sales/data/models/sale_model.dart';
import 'package:bayaa_pos/features/sessions/data/repositories/session_repository_impl.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

Sale _sale({
  required String id,
  required double historicalCost,
  bool isRefund = false,
}) =>
    Sale(
      id: id,
      total: 60,
      items: 2,
      date: DateTime.utc(2026, 10, 1),
      cashierName: 'Cashier',
      invoiceTypeIndex: isRefund ? 1 : 0,
      saleItems: [
        SaleItem(
          productId: 'product-1',
          name: 'Product',
          price: 30,
          quantity: 2,
          total: 60,
          wholesalePrice: 80,
          historicalCost: historicalCost,
        ),
      ],
    );

Future<void> _initializeIsolatedPersistence() async {
  final existing = PersistenceInitializer.persistenceManager;
  if (existing != null) {
    await existing.shutdown();
  }

  final testDirectory = Directory(
    p.join(
      Directory.systemTemp.path,
      'bayaa_session_fifo_${DateTime.now().microsecondsSinceEpoch}',
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

Future<void> _seedDailyReportFixture({required bool completeHistory}) async {
  final db = PersistenceInitializer.persistenceManager!.sqliteManager;
  final sessionId = 'session-fifo-report';
  final saleId = 'sale-fifo-report';
  final saleItemId = 'sale-item-fifo-report';

  await db.insert('users', {
    'id': 'cashier',
    'username': 'cashier',
    'display_name': 'Cashier',
    'phone': '0000000000',
    'password_hash': 'test',
    'role': 'cashier',
    'is_active': 1,
    'created_at': DateTime.utc(2026, 10, 1, 8).toIso8601String(),
  });

  await db.insert('products', {
    'id': 'product-1',
    'name': 'Product',
    'price': 30.0,
    'min_price': 20.0,
    'wholesale_price': 80.0,
    'cost': 10.0,
    'stock': 10.0,
    'created_at': DateTime.utc(2026, 10, 1, 8).toIso8601String(),
    'updated_at': DateTime.utc(2026, 10, 1, 8).toIso8601String(),
    'is_active': 1,
    'base_unit': 'piece',
    'product_type': 'STANDARD',
    'quantity_precision': 3,
    'allow_partial_package_sale': 0,
  });

  await db.insert('shifts', {
    'id': sessionId,
    'user_id': 'cashier',
    'open_time': DateTime.utc(2026, 10, 1, 8).toIso8601String(),
    'close_time': DateTime.utc(2026, 10, 1, 18).toIso8601String(),
    'is_open': 0,
  });

  await db.insert('sales', {
    'id': saleId,
    'total': 60.0,
    'created_at': DateTime.utc(2026, 10, 1, 12).toIso8601String(),
    'user_id': 'cashier',
    'cashier_name': 'Cashier',
    'items_count': 1,
    'is_refund': 0,
    'shift_id': sessionId,
  });

  await db.insert('sale_items', {
    'id': saleItemId,
    'sale_id': saleId,
    'product_id': 'product-1',
    'product_name': 'Product',
    'quantity': 2.0,
    'price': 30.0,
    'wholesale_price': 80.0,
    'subtotal': 60.0,
    'refunded_quantity': 0.0,
    'exchanged_quantity': 0.0,
  });

  if (completeHistory) {
    await db.insert('stock_movements', {
      'id': 'purchase-1',
      'product_id': 'product-1',
      'product_barcode': 'P-001',
      'product_name': 'Product',
      'movement_type': 'purchase',
      'quantity_change': 10.0,
      'unit_cost': 10.0,
      'running_stock': 10.0,
      'reference_type': 'purchase',
      'reference_id': 'purchase-1',
      'lineage_id': 'purchase-lineage-1',
      'created_at': DateTime.utc(2026, 10, 1, 9).toIso8601String(),
      'user_id': 'cashier',
    });
    await db.insert('stock_movements', {
      'id': 'sale-movement-1',
      'product_id': 'product-1',
      'product_barcode': 'P-001',
      'product_name': 'Product',
      'movement_type': 'sale',
      'quantity_change': -2.0,
      'unit_cost': 0.0,
      'running_stock': 8.0,
      'reference_type': 'sale',
      'reference_id': saleId,
      'lineage_id': saleItemId,
      'created_at': DateTime.utc(2026, 10, 1, 12).toIso8601String(),
      'user_id': 'cashier',
    });
  }
}

void main() {
  test('server session COGS uses historical FIFO costs, not wholesale price',
      () async {
    final repository = SessionRepositoryImpl(serverMode: true);

    final costs = await repository.historicalCogsBySaleProduct([
      _sale(id: 'sale-1', historicalCost: 20),
      _sale(id: 'refund-1', historicalCost: 4, isRefund: true),
    ]);

    expect(costs['sale-1::product-1'], 20);
    expect(costs['refund-1::product-1'], -4);
  });

  test('server session COGS remains unavailable for incomplete FIFO history',
      () async {
    final repository = SessionRepositoryImpl(serverMode: true);

    final costs = await repository.historicalCogsBySaleProduct([
      _sale(id: 'sale-legacy', historicalCost: 20),
      Sale(
        id: 'sale-incomplete',
        total: 60,
        items: 2,
        date: DateTime.utc(2026, 10, 1),
        cashierName: 'Cashier',
        saleItems: [
          SaleItem(
            productId: 'product-1',
            name: 'Product',
            price: 30,
            quantity: 2,
            total: 60,
            wholesalePrice: 80,
          ),
        ],
      ),
    ]);

    expect(costs['sale-legacy::product-1'], 20);
    expect(costs['sale-incomplete::product-1'], isNull);
  });

  test('local FIFO replays multiple lots in order and ignores current cost changes',
      () {
    final result = const LocalFifoAnalyticsCosting().calculate(
      movements: [
        {
          'id': 'purchase-1',
          'product_id': 'product-1',
          'movement_type': 'purchase',
          'quantity_change': 1.0,
          'unit_cost': 10.0,
          'reference_type': 'purchase',
          'reference_id': 'purchase-1',
          'lineage_id': 'lot-1',
          'created_at': DateTime.utc(2026, 10, 1, 8).toIso8601String(),
        },
        {
          'id': 'purchase-2',
          'product_id': 'product-1',
          'movement_type': 'purchase',
          'quantity_change': 2.0,
          'unit_cost': 20.0,
          'reference_type': 'purchase',
          'reference_id': 'purchase-2',
          'lineage_id': 'lot-2',
          'created_at': DateTime.utc(2026, 10, 1, 9).toIso8601String(),
        },
        {
          'id': 'sale-1',
          'product_id': 'product-1',
          'movement_type': 'sale',
          'quantity_change': -3.0,
          'unit_cost': 0.0,
          'reference_type': 'sale',
          'reference_id': 'sale-1',
          'lineage_id': 'sale-item-1',
          'created_at': DateTime.utc(2026, 10, 1, 12).toIso8601String(),
        },
      ],
      start: DateTime.utc(2026, 10, 1),
      endExclusive: DateTime.utc(2026, 10, 2),
    );

    expect(result.costByReferenceProduct['sale-1::product-1'], 50.0);
  });

  test('daily report keeps historical FIFO COGS and gross profit when current cost changes',
      () async {
    await _initializeIsolatedPersistence();
    await _seedDailyReportFixture(completeHistory: true);

    final report = await SessionRepositoryImpl(serverMode: false)
        .generateDailyReport('session-fifo-report');

    expect(report, isNotNull);
    expect(report!.historicalCogsAvailable, isTrue);
    expect(report.historicalCogs, 20.0);
    expect(report.grossProfit, 40.0);
  });

  test('daily report marks historical COGS unavailable when FIFO history is incomplete',
      () async {
    await _initializeIsolatedPersistence();
    await _seedDailyReportFixture(completeHistory: false);

    final report = await SessionRepositoryImpl(serverMode: false)
        .generateDailyReport('session-fifo-report');

    expect(report, isNotNull);
    expect(report!.historicalCogsAvailable, isFalse);
    expect(report.historicalCogs, isNull);
    expect(report.grossProfit, isNull);
  });
}
