import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:bayaa_pos/core/data/services/sqlite_manager.dart';
import 'package:bayaa_pos/features/stock/services/canonical_stock_posting_service.dart';

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
      'created_at': DateTime.now().toIso8601String(),
      'updated_at': DateTime.now().toIso8601String(),
    });
  });
  tearDown(() => manager.close());

  test('stock movement rows are immutable at the database boundary', () async {
    await manager.insert('stock_movements', {
      'id': 'movement-1',
      'product_id': 'p-1',
      'product_name': 'Test product',
      'movement_type': 'historical',
      'quantity_change': 1.0,
      'running_stock': 1.0,
      'reference_type': 'historical',
      'reference_id': 'legacy-1',
      'created_at': DateTime.now().toIso8601String(),
    });

    expect(
      () => manager.update('stock_movements', {'notes': 'tampered'},
          where: 'id = ?', whereArgs: ['movement-1']),
      throwsA(isA<DatabaseException>()),
    );
    expect(
      () => manager.delete('stock_movements',
          where: 'id = ?', whereArgs: ['movement-1']),
      throwsA(isA<DatabaseException>()),
    );
  });

  test('canonical posting rejects an untraceable source atomically', () async {
    final service = const CanonicalStockPostingService();

    expect(
      () => manager.transaction((txn) => service.post(
            txn: txn,
            movementId: 'movement-2',
            productId: 'p-1',
            quantityChange: 2,
            movementType: 'purchase',
            referenceType: 'purchase',
            referenceId: 'missing-purchase',
          )),
      throwsA(isA<StateError>()),
    );
    expect(
      (await manager.query('products', where: 'id = ?', whereArgs: ['p-1']))
          .single['stock'],
      0.0,
    );
    expect(await manager.query('stock_movements'), isEmpty);
  });
}
