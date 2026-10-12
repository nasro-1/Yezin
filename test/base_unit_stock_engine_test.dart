import 'dart:io';

import 'package:bayaa_pos/core/data/services/sqlite_manager.dart';
import 'package:bayaa_pos/features/stock/services/canonical_stock_posting_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  group('base-unit stock engine', () {
    late SQLiteManager manager;
    late CanonicalStockPostingService stockPosting;

    setUp(() async {
      manager = SQLiteManager(databasePath: 'stock_engine_${DateTime.now().microsecondsSinceEpoch}.sqlite');
      await manager.initialize();
      stockPosting = const CanonicalStockPostingService();
      await manager.insert('users', {
        'id': 'u-1',
        'username': 'unit-user',
        'display_name': 'Unit User',
        'password_hash': 'pw',
        'role': 'manager',
        'created_at': DateTime.now().toIso8601String(),
      });
    });

    tearDown(() async {
      await manager.close();
      for (final suffix in ['', '-wal', '-shm']) {
        final file = File('${manager.databasePath}$suffix');
        if (file.existsSync()) file.deleteSync();
      }
    });

    Future<void> insertProduct({
      required String id,
      required String name,
      required double stock,
      String barcode = '',
      String baseUnit = 'piece',
      int quantityPrecision = 3,
      String productType = 'STANDARD',
    }) async {
      await manager.insert('products', {
        'id': id,
        'barcode': barcode,
        'name': name,
        'product_type': productType,
        'base_unit': baseUnit,
        'quantity_precision': quantityPrecision,
        'allow_partial_package_sale': 0,
        'price': 0.0,
        'min_price': 0.0,
        'wholesale_price': 0.0,
        'stock': stock,
        'min_stock': 0.0,
        'is_active': 1,
        'created_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      });
    }

    Future<void> postBaseMovement({
      required String productId,
      required String movementId,
      required double quantityChange,
      required String movementType,
      required String referenceType,
      required String referenceId,
      double? sellingQuantity,
      double? conversionToBase,
      String? sellingUnitName,
    }) async {
      await manager.transaction((txn) async {
        await stockPosting.post(
          txn: txn,
          movementId: movementId,
          productId: productId,
          quantityChange: quantityChange,
          movementType: movementType,
          referenceType: referenceType,
          referenceId: referenceId,
          notes: 'test',
          userId: 'u-1',
          sellingQuantity: sellingQuantity,
          conversionToBase: conversionToBase,
          sellingUnitName: sellingUnitName,
        );
      });
    }

    test('legacy raw quantity callers still work', () async {
      await insertProduct(id: 'p-legacy', name: 'Legacy Product', stock: 10);
      await manager.insert('sales', {
        'id': 'sale-legacy',
        'total': 0.0,
        'created_at': DateTime.now().toIso8601String(),
        'user_id': 'u-1',
      });

      await postBaseMovement(
        productId: 'p-legacy',
        movementId: 'm-legacy',
        quantityChange: -3,
        movementType: 'sale',
        referenceType: 'sale',
        referenceId: 'sale-legacy',
      );

      final row = await manager.query('products', where: 'id = ?', whereArgs: ['p-legacy']);
      expect((row.single['stock'] as num).toDouble(), 7.0);
    });

    test('standard product: 3 pieces reduces stock by 3', () async {
      await insertProduct(id: 'p-standard', name: 'Notebook', stock: 10, baseUnit: 'piece');
      await manager.insert('sales', {
        'id': 'sale-standard',
        'total': 0.0,
        'created_at': DateTime.now().toIso8601String(),
        'user_id': 'u-1',
      });

      await postBaseMovement(
        productId: 'p-standard',
        movementId: 'm-standard',
        quantityChange: -3,
        movementType: 'sale',
        referenceType: 'sale',
        referenceId: 'sale-standard',
        sellingQuantity: 3,
        conversionToBase: 1,
        sellingUnitName: 'Piece',
      );

      final row = await manager.query('products', where: 'id = ?', whereArgs: ['p-standard']);
      expect((row.single['stock'] as num).toDouble(), 7.0);
    });

    test('weighted product supports decimal quantities without truncation', () async {
      await insertProduct(id: 'p-weighted', name: 'Potato', stock: 5.0, baseUnit: 'kg', productType: 'WEIGHTED', quantityPrecision: 3);
      await manager.insert('sales', {
        'id': 'sale-weighted',
        'total': 0.0,
        'created_at': DateTime.now().toIso8601String(),
        'user_id': 'u-1',
      });

      await postBaseMovement(
        productId: 'p-weighted',
        movementId: 'm-weighted-1',
        quantityChange: -0.300,
        movementType: 'sale',
        referenceType: 'sale',
        referenceId: 'sale-weighted',
        sellingQuantity: 0.300,
        conversionToBase: 1,
        sellingUnitName: 'kg',
      );
      final row1 = await manager.query('products', where: 'id = ?', whereArgs: ['p-weighted']);
      expect((row1.single['stock'] as num).toDouble(), 4.7);

      await postBaseMovement(
        productId: 'p-weighted',
        movementId: 'm-weighted-2',
        quantityChange: -1.250,
        movementType: 'sale',
        referenceType: 'sale',
        referenceId: 'sale-weighted',
        sellingQuantity: 1.250,
        conversionToBase: 1,
        sellingUnitName: 'kg',
      );
      final row2 = await manager.query('products', where: 'id = ?', whereArgs: ['p-weighted']);
      expect((row2.single['stock'] as num).toDouble(), 3.45);
    });

    test('packaged product conversion is applied in base units', () async {
      await insertProduct(id: 'p-pack', name: 'Bottle', stock: 30.0, baseUnit: 'bottle', productType: 'PACKAGED');
      await manager.insert('sales', {'id': 'sale-pack-1', 'total': 0.0, 'created_at': DateTime.now().toIso8601String(), 'user_id': 'u-1'});
      await manager.insert('sales', {'id': 'sale-pack-2', 'total': 0.0, 'created_at': DateTime.now().toIso8601String(), 'user_id': 'u-1'});

      await postBaseMovement(
        productId: 'p-pack',
        movementId: 'm-pack-1',
        quantityChange: -6,
        movementType: 'sale',
        referenceType: 'sale',
        referenceId: 'sale-pack-1',
        sellingQuantity: 1,
        conversionToBase: 6,
        sellingUnitName: 'Pack',
      );
      final afterPack = await manager.query('products', where: 'id = ?', whereArgs: ['p-pack']);
      expect((afterPack.single['stock'] as num).toDouble(), 24.0);

      await postBaseMovement(
        productId: 'p-pack',
        movementId: 'm-pack-2',
        quantityChange: -2,
        movementType: 'sale',
        referenceType: 'sale',
        referenceId: 'sale-pack-2',
        sellingQuantity: 2,
        conversionToBase: 1,
        sellingUnitName: 'Bottle',
      );
      final afterBottle = await manager.query('products', where: 'id = ?', whereArgs: ['p-pack']);
      expect((afterBottle.single['stock'] as num).toDouble(), 22.0);
    });

    test('insufficient stock is rejected with no partial posting', () async {
      await insertProduct(id: 'p-insufficient', name: 'Insufficient', stock: 29.0, baseUnit: 'bottle', productType: 'PACKAGED');
      await manager.insert('sales', {'id': 'sale-insufficient', 'total': 0.0, 'created_at': DateTime.now().toIso8601String(), 'user_id': 'u-1'});

      expect(
        () => manager.transaction((txn) => stockPosting.post(
          txn: txn,
          movementId: 'm-insufficient',
          productId: 'p-insufficient',
          quantityChange: -30,
          movementType: 'sale',
          referenceType: 'sale',
          referenceId: 'sale-insufficient',
          sellingQuantity: 5,
          conversionToBase: 6,
          sellingUnitName: 'Pack',
        )),
        throwsA(isA<StateError>()),
      );

      final row = await manager.query('products', where: 'id = ?', whereArgs: ['p-insufficient']);
      expect((row.single['stock'] as num).toDouble(), 29.0);
      expect(await manager.query('stock_movements'), isEmpty);
    });

    test('financial amount stays separate from base stock quantity', () async {
      await insertProduct(id: 'p-finance', name: 'Pack Product', stock: 30.0, productType: 'PACKAGED', baseUnit: 'bottle');
      await manager.insert('sales', {'id': 'sale-finance', 'total': 0.0, 'created_at': DateTime.now().toIso8601String(), 'user_id': 'u-1'});

      await postBaseMovement(
        productId: 'p-finance',
        movementId: 'm-finance',
        quantityChange: -6,
        movementType: 'sale',
        referenceType: 'sale',
        referenceId: 'sale-finance',
        sellingQuantity: 1,
        conversionToBase: 6,
        sellingUnitName: 'Pack',
      );

      final row = await manager.query('products', where: 'id = ?', whereArgs: ['p-finance']);
      expect((row.single['stock'] as num).toDouble(), 24.0);
      final movement = await manager.query('stock_movements', where: 'id = ?', whereArgs: ['m-finance']);
      expect((movement.single['quantity_change'] as num).toDouble(), -6.0);
    });
  });
}
