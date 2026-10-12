import 'dart:io';

import 'package:bayaa_pos/core/data/services/sqlite_manager.dart';
import 'package:bayaa_pos/features/products/data/repository/product_repository_imp.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  late SQLiteManager manager;

  setUp(() async {
    manager = SQLiteManager(databasePath: ':memory:');
    await manager.initialize();
  });

  tearDown(() => manager.close());

  Future<void> insertProduct(String id, String? barcode) {
    return manager.insert('products', {
      'id': id,
      'barcode': barcode,
      'name': 'Delete test product',
      'price': 10.0,
      'created_at': DateTime.now().toIso8601String(),
      'updated_at': DateTime.now().toIso8601String(),
    });
  }

  test('deleting by barcode removes the product from persistence', () async {
    await insertProduct('product-delete-1', 'DELETE-001');

    await deleteProductRecord(manager.database, 'product-delete-1');

    expect(
      await manager.query(
        'products',
        where: 'id = ?',
        whereArgs: ['product-delete-1'],
      ),
      isEmpty,
    );
  });

  test('historical products become inactive without rewriting history',
      () async {
    await insertProduct('product-history-1', 'HISTORY-001');
    await manager.insert('sales', {
      'id': 'sale-history-1',
      'total': 10.0,
      'created_at': DateTime.now().toIso8601String(),
      'status': 'posted',
    });
    await manager.insert('sale_items', {
      'id': 'sale-item-history-1',
      'sale_id': 'sale-history-1',
      'product_id': 'product-history-1',
      'product_name': 'Delete test product',
      'quantity': 1.0,
      'price': 10.0,
      'subtotal': 10.0,
    });

    await deleteProductRecord(manager.database, 'product-history-1');

    final product = await manager.query(
      'products',
      where: 'id = ?',
      whereArgs: ['product-history-1'],
    );
    expect(product.single['is_active'], 0);
    expect(await manager.query('sale_items'), hasLength(1));
    expect(await manager.query('sales'), hasLength(1));
  });

  test('NULL barcode products delete by canonical id and preserve history',
      () async {
    await insertProduct('product-packaged-null-barcode', null);
    await manager.insert('stock_movements', {
      'id': 'movement-null-barcode-1',
      'product_id': 'product-packaged-null-barcode',
      'product_name': 'Delete test product',
      'movement_type': 'opening',
      'quantity_change': 10.0,
      'unit_cost': 5.0,
      'running_stock': 10.0,
      'created_at': DateTime.now().toIso8601String(),
    });

    await deleteProductRecord(
      manager.database,
      'product-packaged-null-barcode',
    );

    final product = await manager.query(
      'products',
      where: 'id = ?',
      whereArgs: ['product-packaged-null-barcode'],
    );
    expect(product.single['is_active'], 0);
    expect(
      await manager.query(
        'stock_movements',
        where: 'product_id = ?',
        whereArgs: ['product-packaged-null-barcode'],
      ),
      hasLength(1),
    );
  });

  test(
      'schema upgrade allows active barcode reuse and preserves deleted product history',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('bayaa_product_barcode_v35_');
    final databasePath = '${directory.path}${Platform.pathSeparator}legacy.db';
    final legacyDatabase = await openDatabase(
      databasePath,
      version: 34,
      onCreate: (db, _) async {
        await db.execute(
          'CREATE TABLE categories (id TEXT PRIMARY KEY NOT NULL)',
        );
        await db.execute('''
          CREATE TABLE products (
            id TEXT PRIMARY KEY NOT NULL,
            barcode TEXT UNIQUE,
            name TEXT NOT NULL,
            internal_reference TEXT UNIQUE,
            product_type TEXT NOT NULL DEFAULT 'STANDARD'
              CHECK (product_type IN ('STANDARD', 'WEIGHTED', 'PACKAGED')),
            base_unit TEXT NOT NULL DEFAULT 'piece',
            quantity_precision INTEGER NOT NULL DEFAULT 3
              CHECK (quantity_precision > 0),
            allow_partial_package_sale INTEGER NOT NULL DEFAULT 0
              CHECK (allow_partial_package_sale IN (0, 1)),
            price REAL NOT NULL,
            min_price REAL DEFAULT 0.0,
            wholesale_price REAL DEFAULT 0.0,
            cost REAL DEFAULT 0.0,
            stock REAL DEFAULT 0.0,
            min_stock REAL DEFAULT 0.0,
            category_id TEXT,
            image_path TEXT,
            is_active INTEGER NOT NULL DEFAULT 1,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            FOREIGN KEY (category_id) REFERENCES categories(id)
          )
        ''');
        await db.execute('''
          CREATE TABLE product_history (
            product_id TEXT NOT NULL REFERENCES products(id)
          )
        ''');
        await db.insert('products', {
          'id': 'deleted-product',
          'barcode': '100000000001',
          'name': 'Deleted product',
          'price': 10,
          'is_active': 0,
          'created_at': DateTime.now().toIso8601String(),
          'updated_at': DateTime.now().toIso8601String(),
        });
        await db.insert('product_history', {'product_id': 'deleted-product'});
      },
    );
    await legacyDatabase.close();

    final upgradedManager = SQLiteManager(databasePath: databasePath);
    var initialized = false;
    try {
      await upgradedManager.initialize();
      initialized = true;
      final db = upgradedManager.database;

      expect(
        await db
            .query('products', where: 'id = ?', whereArgs: ['deleted-product']),
        hasLength(1),
      );
      expect(
        await db.query('product_history',
            where: 'product_id = ?', whereArgs: ['deleted-product']),
        hasLength(1),
      );
      expect(await db.rawQuery('PRAGMA foreign_key_check'), isEmpty);
      expect(
        (await db.query(
          'products',
          columns: ['is_active'],
          where: 'id = ?',
          whereArgs: ['deleted-product'],
        ))
            .single['is_active'],
        0,
      );

      await db.insert('products', {
        'id': 'replacement-product',
        'barcode': '100000000001',
        'name': 'Replacement product',
        'price': 10,
        'created_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      });

      await expectLater(
        db.insert('products', {
          'id': 'active-duplicate',
          'barcode': ' 100000000001 ',
          'name': 'Duplicate active product',
          'price': 10,
          'created_at': DateTime.now().toIso8601String(),
          'updated_at': DateTime.now().toIso8601String(),
        }),
        throwsA(isA<DatabaseException>()),
      );
    } finally {
      if (initialized) {
        await upgradedManager.close();
      }
      await directory.delete(recursive: true);
    }
  });
}
