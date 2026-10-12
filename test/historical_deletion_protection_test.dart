import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:bayaa_pos/core/data/services/sqlite_manager.dart';

void main() {
  late SQLiteManager manager;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    manager = SQLiteManager(databasePath: ':memory:');
    await manager.initialize();
    await manager.insert('products', {
      'id': 'p-1',
      'barcode': '1001',
      'name': 'Historical product',
      'price': 10.0,
      'created_at': DateTime.now().toIso8601String(),
      'updated_at': DateTime.now().toIso8601String(),
    });
  });

  tearDown(() => manager.close());

  test('posted sales cannot be physically deleted', () async {
    await manager.insert('sales', {
      'id': 'sale-1',
      'total': 10.0,
      'created_at': DateTime.now().toIso8601String(),
      'status': 'posted',
    });

    expect(
      () => manager.delete('sales', where: 'id = ?', whereArgs: ['sale-1']),
      throwsA(isA<DatabaseException>()),
    );
    expect(await manager.query('sales'), hasLength(1));
  });

  test('products with historical references cannot be physically deleted',
      () async {
    await manager.insert('sales', {
      'id': 'sale-1',
      'total': 10.0,
      'created_at': DateTime.now().toIso8601String(),
      'status': 'posted',
    });
    await manager.insert('sale_items', {
      'id': 'item-1',
      'sale_id': 'sale-1',
      'product_id': 'p-1',
      'product_name': 'Historical product',
      'quantity': 1.0,
      'price': 10.0,
      'subtotal': 10.0,
    });

    expect(
      () => manager.delete('products', where: 'id = ?', whereArgs: ['p-1']),
      throwsA(isA<DatabaseException>()),
    );
    expect(await manager.query('products'), hasLength(1));
  });
}
