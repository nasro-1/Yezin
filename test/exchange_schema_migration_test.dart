import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:bayaa_pos/core/data/services/sqlite_manager.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late String dbPath;
  SQLiteManager? manager;

  Future<SQLiteManager> openLegacyV25Database({
    bool withLegacyExchangeSchema = false,
    bool forceSchema28Failure = false,
    int legacyVersion = 25,
  }) async {
    final path = dbPath;
    final db = await openDatabase(
      path,
      version: 25,
      onCreate: (database, version) async {
        await database.execute('''
          CREATE TABLE users (
            id TEXT PRIMARY KEY NOT NULL,
            username TEXT NOT NULL UNIQUE,
            display_name TEXT NOT NULL,
            password_hash TEXT NOT NULL,
            role TEXT NOT NULL DEFAULT 'cashier',
            created_at TEXT NOT NULL
          )
        ''');
        await database.execute('''
          CREATE TABLE customers (
            id TEXT PRIMARY KEY,
            code TEXT NOT NULL UNIQUE,
            name TEXT NOT NULL,
            opening_balance REAL NOT NULL DEFAULT 0.0,
            current_balance REAL NOT NULL DEFAULT 0.0,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
          )
        ''');
        await database.execute('''
          CREATE TABLE categories (
            id TEXT PRIMARY KEY NOT NULL,
            name TEXT NOT NULL UNIQUE,
            color TEXT,
            sort_order INTEGER DEFAULT 0
          )
        ''');
        await database.execute('''
          CREATE TABLE products (
            id TEXT PRIMARY KEY NOT NULL,
            barcode TEXT UNIQUE,
            name TEXT NOT NULL,
            price REAL NOT NULL,
            stock REAL NOT NULL DEFAULT 0.0,
            min_stock REAL NOT NULL DEFAULT 0.0,
            category_id TEXT,
            is_active INTEGER NOT NULL DEFAULT 1,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            FOREIGN KEY (category_id) REFERENCES categories(id)
          )
        ''');
        await database.execute('''
          CREATE TABLE sales (
            id TEXT PRIMARY KEY NOT NULL,
            total REAL NOT NULL DEFAULT 0.0,
            created_at TEXT NOT NULL,
            user_id TEXT,
            customer_id TEXT,
            payment_method TEXT DEFAULT 'cash',
            FOREIGN KEY (user_id) REFERENCES users(id),
            FOREIGN KEY (customer_id) REFERENCES customers(id)
          )
        ''');
        await database.execute('''
          CREATE TABLE sale_items (
            id TEXT PRIMARY KEY NOT NULL,
            sale_id TEXT NOT NULL,
            product_id TEXT NOT NULL,
            product_barcode TEXT,
            product_name TEXT NOT NULL,
            quantity REAL NOT NULL,
            price REAL NOT NULL,
            wholesale_price REAL DEFAULT 0.0,
            subtotal REAL NOT NULL,
            refunded_quantity REAL DEFAULT 0.0,
            FOREIGN KEY (sale_id) REFERENCES sales(id) ON DELETE CASCADE,
            CHECK (quantity > 0),
            CHECK (price >= 0),
            CHECK (refunded_quantity >= 0),
            CHECK (refunded_quantity <= quantity)
          )
        ''');
      },
    );

    await db.insert('users', {
      'id': 'u-1',
      'username': 'u-1',
      'display_name': 'User 1',
      'password_hash': 'pw',
      'role': 'manager',
      'created_at': DateTime.now().toIso8601String(),
    });
    await db.insert('customers', {
      'id': 'c-1',
      'code': 'C-001',
      'name': 'Customer 1',
      'opening_balance': 0.0,
      'current_balance': 0.0,
      'created_at': DateTime.now().toIso8601String(),
      'updated_at': DateTime.now().toIso8601String(),
    });
    await db.insert('products', {
      'id': 'p-1',
      'barcode': '1001',
      'name': 'Product 1',
      'price': 10.0,
      'created_at': DateTime.now().toIso8601String(),
      'updated_at': DateTime.now().toIso8601String(),
    });
    await db.insert('sales', {
      'id': 's-1',
      'total': 50.0,
      'created_at': DateTime.now().toIso8601String(),
      'user_id': 'u-1',
      'customer_id': 'c-1',
      'payment_method': 'credit',
    });
    await db.insert('sale_items', {
      'id': 'si-1',
      'sale_id': 's-1',
      'product_id': 'p-1',
      'product_barcode': '1001',
      'product_name': 'Product 1',
      'quantity': 5.0,
      'price': 10.0,
      'wholesale_price': 7.0,
      'subtotal': 50.0,
      'refunded_quantity': 1.0,
    });

    if (withLegacyExchangeSchema) {
      await db.execute('''
        CREATE TABLE exchange_documents (
          id TEXT PRIMARY KEY NOT NULL,
          original_sale_id TEXT NOT NULL,
          customer_id TEXT,
          payment_method TEXT NOT NULL CHECK (payment_method IN ('cash', 'credit')),
          difference_amount REAL NOT NULL,
          status TEXT NOT NULL DEFAULT 'posted'
            CHECK (status IN ('posted', 'voided', 'reversed')),
          idempotency_key TEXT NOT NULL UNIQUE,
          created_at TEXT NOT NULL,
          created_by TEXT NOT NULL,
          notes TEXT,
          replacement_sale_id TEXT,
          FOREIGN KEY (original_sale_id) REFERENCES sales(id),
          FOREIGN KEY (customer_id) REFERENCES customers(id),
          FOREIGN KEY (created_by) REFERENCES users(id),
          FOREIGN KEY (replacement_sale_id) REFERENCES sales(id)
        )
      ''');
      await db.execute('''
        CREATE TABLE exchange_items (
          id TEXT PRIMARY KEY NOT NULL,
          exchange_id TEXT NOT NULL,
          original_sale_item_id TEXT NOT NULL,
          original_product_id TEXT NOT NULL,
          returned_quantity REAL NOT NULL CHECK (returned_quantity > 0),
          replacement_product_id TEXT NOT NULL,
          replacement_quantity REAL NOT NULL CHECK (replacement_quantity > 0),
          old_unit_price REAL NOT NULL CHECK (old_unit_price >= 0),
          new_unit_price REAL NOT NULL CHECK (new_unit_price >= 0),
          old_total REAL NOT NULL CHECK (old_total >= 0),
          new_total REAL NOT NULL CHECK (new_total >= 0),
          difference_amount REAL NOT NULL,
          UNIQUE (exchange_id, original_sale_item_id),
          FOREIGN KEY (exchange_id) REFERENCES exchange_documents(id),
          FOREIGN KEY (original_sale_item_id) REFERENCES sale_items(id),
          FOREIGN KEY (original_product_id) REFERENCES products(id),
          FOREIGN KEY (replacement_product_id) REFERENCES products(id)
        )
      ''');
      await db.execute(
        'CREATE INDEX idx_exchange_items_exchange_id ON exchange_items(exchange_id)',
      );
      await db.execute(
        'CREATE INDEX idx_exchange_items_original_sale_item_id '
        'ON exchange_items(original_sale_item_id)',
      );
      await db.execute(
        'CREATE INDEX idx_exchange_items_original_product_id '
        'ON exchange_items(original_product_id)',
      );
      await db.execute(
        'CREATE INDEX idx_exchange_items_replacement_product_id '
        'ON exchange_items(replacement_product_id)',
      );
      await db.setVersion(
        forceSchema28Failure ? 27 : (legacyVersion == 25 ? 26 : legacyVersion),
      );
    }
    if (forceSchema28Failure) {
      await db
          .execute('ALTER TABLE products ADD COLUMN internal_reference TEXT');
      await db.execute(
        "UPDATE products SET internal_reference = 'duplicate-reference'",
      );
      await db.insert('products', {
        'id': 'p-2',
        'barcode': '1002',
        'name': 'Product 2',
        'price': 20.0,
        'internal_reference': 'duplicate-reference',
        'created_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      });
    }
    await db.close();

    final manager = SQLiteManager(databasePath: path);
    await manager.initialize();
    return manager;
  }

  setUp(() async {
    dbPath = 'exchange_schema_${DateTime.now().microsecondsSinceEpoch}.sqlite';
  });

  tearDown(() async {
    if (manager != null) {
      try {
        if (manager!.database.isOpen) {
          await manager!.close();
        }
      } catch (_) {}
    }
    for (final suffix in ['', '-wal', '-shm']) {
      final file = File('$dbPath$suffix');
      if (file.existsSync()) file.deleteSync();
    }
  });

  test(
      'v25 to v26 migration succeeds and adds exchange tables and default quantity',
      () async {
    manager = await openLegacyV25Database();

    expect(await manager!.database.getVersion(), 35);
    final saleItem = (await manager!.query('sale_items')).single;
    expect(saleItem['exchanged_quantity'], 0.0);
    final stockMovementColumns =
        await manager!.database.rawQuery('PRAGMA table_info(stock_movements)');
    expect(
      stockMovementColumns.any((column) => column['name'] == 'lineage_id'),
      isTrue,
    );
    expect(
      await manager!.query('sqlite_master',
          where: 'type = ? AND name = ?',
          whereArgs: ['table', 'exchange_documents']),
      isNotEmpty,
    );
    expect(
      await manager!.query('sqlite_master',
          where: 'type = ? AND name = ?',
          whereArgs: ['table', 'exchange_items']),
      isNotEmpty,
    );
  });

  test('legacy migration without supplier return items preserves exchange data',
      () async {
    manager = await openLegacyV25Database(
      withLegacyExchangeSchema: true,
      legacyVersion: 15,
    );

    expect(await manager!.database.getVersion(), 35);
    expect(
      await manager!.query(
        'sqlite_master',
        where: 'type = ? AND name = ?',
        whereArgs: ['trigger', 'products_no_delete_with_history'],
      ),
      hasLength(1),
    );
    expect(await manager!.rawQuery('PRAGMA foreign_key_check'), isEmpty);
    expect(await manager!.query('exchange_items'), hasLength(0));
  });

  test(
      'exchange schema contains required indexes, foreign keys, and unique idempotency key',
      () async {
    manager = await openLegacyV25Database();

    final tables = await manager!.database.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name IN (?, ?, ?, ?, ?, ?)",
      [
        'exchange_documents',
        'exchange_items',
        'sale_items',
        'products',
        'sales',
        'customers',
      ],
    );
    expect(
        tables.map((row) => row['name']),
        containsAll(<String>[
          'exchange_documents',
          'exchange_items',
          'sale_items',
        ]));

    final indices = await manager!.database.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'index' AND name IN (?, ?, ?, ?, ?, ?, ?, ?)",
      [
        'idx_exchange_documents_original_sale_id',
        'idx_exchange_documents_customer_id',
        'idx_exchange_documents_created_at',
        'idx_exchange_documents_status',
        'idx_exchange_items_exchange_id',
        'idx_exchange_items_original_sale_item_id',
        'idx_exchange_items_original_product_id',
        'idx_exchange_items_replacement_product_id',
      ],
    );
    expect(indices, hasLength(8));

    final fkDocs = await manager!.database
        .rawQuery('PRAGMA foreign_key_list(exchange_documents)');
    expect(fkDocs.map((row) => row['table']),
        containsAll(<String>['sales', 'customers', 'users']));

    final fkItems = await manager!.database
        .rawQuery('PRAGMA foreign_key_list(exchange_items)');
    expect(fkItems.map((row) => row['table']),
        containsAll(<String>['exchange_documents', 'sale_items', 'products']));

    final uniqueRows = await manager!.database.rawQuery(
      "PRAGMA index_list('exchange_documents')",
    );
    expect(
        uniqueRows.any(
            (row) => row['name'] == 'sqlite_autoindex_exchange_documents_1'),
        isTrue);

    final fkCheck =
        await manager!.database.rawQuery('PRAGMA foreign_key_check');
    expect(fkCheck, isEmpty);
  });

  test('insert and update triggers reject refunded + exchanged overflow',
      () async {
    manager = await openLegacyV25Database();

    expect(
      () => manager!.insert('sale_items', {
        'id': 'si-2',
        'sale_id': 's-1',
        'product_id': 'p-1',
        'product_barcode': '1001',
        'product_name': 'Product 1',
        'quantity': 5.0,
        'price': 10.0,
        'wholesale_price': 7.0,
        'subtotal': 50.0,
        'refunded_quantity': 4.0,
        'exchanged_quantity': 2.0,
      }),
      throwsA(isA<DatabaseException>()),
    );

    await manager!.update(
      'sale_items',
      {'refunded_quantity': 1.0, 'exchanged_quantity': 2.0},
      where: 'id = ?',
      whereArgs: ['si-1'],
    );

    expect(
      () => manager!.update(
        'sale_items',
        {'refunded_quantity': 3.0, 'exchanged_quantity': 3.0},
        where: 'id = ?',
        whereArgs: ['si-1'],
      ),
      throwsA(isA<DatabaseException>()),
    );
  });

  test(
      'valid refund+exchange combination is accepted and historical rows remain readable',
      () async {
    manager = await openLegacyV25Database();

    await manager!.update(
      'sale_items',
      {'refunded_quantity': 1.0, 'exchanged_quantity': 2.0},
      where: 'id = ?',
      whereArgs: ['si-1'],
    );

    final row = (await manager!
            .query('sale_items', where: 'id = ?', whereArgs: ['si-1']))
        .single;
    expect(row['refunded_quantity'], 1.0);
    expect(row['exchanged_quantity'], 2.0);
    expect((row['quantity'] as num).toDouble(), 5.0);

    final sales = await manager!.query('sales');
    final historical = await manager!
        .query('sale_items', where: 'sale_id = ?', whereArgs: ['s-1']);
    expect(sales, isNotEmpty);
    expect(historical, isNotEmpty);
  });

  test(
      'backup and restore preserve v26 schema, indexes, triggers, and integrity',
      () async {
    manager = await openLegacyV25Database();

    await manager!.insert('exchange_documents', {
      'id': 'ex-1',
      'original_sale_id': 's-1',
      'customer_id': 'c-1',
      'payment_method': 'credit',
      'difference_amount': -25.0,
      'status': 'posted',
      'idempotency_key': 'exchange:doc:1',
      'created_at': DateTime.now().toIso8601String(),
      'created_by': 'u-1',
      'notes': 'test',
      'replacement_sale_id': null,
    });

    final backupPath =
        'exchange_backup_${DateTime.now().microsecondsSinceEpoch}.sqlite';
    final sourcePath = manager!.database.path;
    await manager!.close();
    File(sourcePath).copySync(backupPath);

    final restored = SQLiteManager(databasePath: backupPath);
    await restored.initialize();

    final integrity =
        await restored.database.rawQuery('PRAGMA integrity_check');
    expect(integrity.single['integrity_check'], 'ok');

    final tables = await restored.database.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name IN ('exchange_documents', 'exchange_items')",
    );
    expect(tables.map((row) => row['name']),
        containsAll(<String>['exchange_documents', 'exchange_items']));

    final indexes = await restored.database.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'index' AND name LIKE 'idx_exchange_%'",
    );
    expect(indexes, isNotEmpty);

    final triggers = await restored.database.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'trigger' AND name LIKE 'sale_items_refund_exchange_guard_%'",
    );
    expect(triggers, hasLength(2));

    final fkCheck =
        await restored.database.rawQuery('PRAGMA foreign_key_check');
    expect(fkCheck, isEmpty);

    await restored.close();
    for (final suffix in ['', '-wal', '-shm']) {
      final file = File('$backupPath$suffix');
      if (file.existsSync()) file.deleteSync();
    }
  });

  test('Schema 27 replaces the legacy exchange item uniqueness safely',
      () async {
    manager = await openLegacyV25Database(withLegacyExchangeSchema: true);

    expect(await manager!.database.getVersion(), 35);
    final tableSql = await manager!.database.rawQuery(
      "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'exchange_items'",
    );
    expect(
        tableSql.single['sql'],
        contains(
          'UNIQUE (exchange_id, original_sale_item_id, replacement_product_id)',
        ));

    await manager!.insert('exchange_documents', {
      'id': 'ex-1',
      'original_sale_id': 's-1',
      'customer_id': 'c-1',
      'payment_method': 'cash',
      'difference_amount': 0.0,
      'status': 'posted',
      'idempotency_key': 'exchange:doc:27',
      'created_at': DateTime.now().toIso8601String(),
      'created_by': 'u-1',
      'replacement_sale_id': null,
    });
    await manager!.insert('products', {
      'id': 'p-2',
      'barcode': '1002',
      'name': 'Product 2',
      'price': 10.0,
      'created_at': DateTime.now().toIso8601String(),
      'updated_at': DateTime.now().toIso8601String(),
    });
    final baseItem = {
      'exchange_id': 'ex-1',
      'original_sale_item_id': 'si-1',
      'original_product_id': 'p-1',
      'returned_quantity': 1.0,
      'replacement_quantity': 1.0,
      'old_unit_price': 10.0,
      'new_unit_price': 10.0,
      'old_total': 10.0,
      'new_total': 10.0,
      'difference_amount': 0.0,
    };
    await manager!.insert('exchange_items', {
      ...baseItem,
      'id': 'exchange-item-b',
      'replacement_product_id': 'p-1',
    });
    await manager!.insert('exchange_items', {
      ...baseItem,
      'id': 'exchange-item-c',
      'replacement_product_id': 'p-2',
    });
    expect(
      () => manager!.insert('exchange_items', {
        ...baseItem,
        'id': 'exchange-item-b-duplicate',
        'replacement_product_id': 'p-1',
      }),
      throwsA(isA<DatabaseException>()),
    );
    expect(await manager!.query('exchange_items'), hasLength(2));
    expect(
        await manager!.database.rawQuery('PRAGMA foreign_key_check'), isEmpty);
  });

  test('Schema 28 preserves legacy data and creates unit metadata', () async {
    manager = await openLegacyV25Database();

    expect(await manager!.database.getVersion(), 35);
    final product = (await manager!.query(
      'products',
      where: 'id = ?',
      whereArgs: ['p-1'],
    ))
        .single;
    expect(product['barcode'], '1001');
    expect(product['name'], 'Product 1');
    expect((product['price'] as num).toDouble(), 10.0);
    expect(product['product_type'], 'STANDARD');
    expect(product['base_unit'], 'piece');
    expect(product['quantity_precision'], 3);
    expect(product['allow_partial_package_sale'], 0);
    expect(product['internal_reference'], isA<String>());

    final saleItem = (await manager!.query(
      'sale_items',
      where: 'id = ?',
      whereArgs: ['si-1'],
    ))
        .single;
    expect((saleItem['quantity'] as num).toDouble(), 5.0);
    expect((saleItem['price'] as num).toDouble(), 10.0);
    expect(saleItem['selling_unit_id'], isNull);
    expect(saleItem['selling_quantity'], isNull);
    expect(saleItem['base_quantity'], isNull);
    expect(saleItem['conversion_factor_snapshot'], isNull);

    final units = await manager!.query(
      'product_selling_units',
      where: 'product_id = ?',
      whereArgs: ['p-1'],
    );
    expect(units, hasLength(1));
    expect(units.single['name'], 'piece');
    expect((units.single['conversion_to_base'] as num).toDouble(), 1.0);
    expect((units.single['selling_price'] as num).toDouble(), 10.0);
    expect((units.single['cost_price'] as num).toDouble(), 0.0);
    expect(units.single['is_default'], 1);
  });

  test('Schema 28 enforces unit integrity and foreign keys', () async {
    manager = await openLegacyV25Database();

    expect(
      () => manager!.insert('product_selling_units', {
        'id': 'unit-invalid',
        'product_id': 'p-1',
        'name': 'invalid',
        'conversion_to_base': 0.0,
        'selling_price': 1.0,
        'is_default': 0,
        'is_active': 1,
        'created_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      }),
      throwsA(isA<DatabaseException>()),
    );

    expect(
      () => manager!.insert('product_selling_units', {
        'id': 'unit-orphan',
        'product_id': 'missing-product',
        'name': 'orphan',
        'conversion_to_base': 1.0,
        'selling_price': 1.0,
        'is_default': 0,
        'is_active': 1,
        'created_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      }),
      throwsA(isA<DatabaseException>()),
    );

    expect(await manager!.rawQuery('PRAGMA foreign_key_check'), isEmpty);
    final integrity = await manager!.rawQuery('PRAGMA integrity_check');
    expect(integrity.single['integrity_check'], 'ok');
  });

  test('Schema 28 migration is idempotent when reopening an upgraded database',
      () async {
    manager = await openLegacyV25Database();
    await manager!.close();

    final reopened = SQLiteManager(databasePath: dbPath);
    manager = reopened;
    await reopened.initialize();

    expect(await reopened.database.getVersion(), 35);
    expect(await reopened.query('products'), hasLength(1));
    expect(await reopened.query('product_selling_units'), hasLength(1));
    expect(await reopened.rawQuery('PRAGMA foreign_key_check'), isEmpty);
  });

  test('Schema 28 migration rolls back atomically on constraint failure',
      () async {
    final path = dbPath;
    await expectLater(
      openLegacyV25Database(forceSchema28Failure: true),
      throwsA(isA<DatabaseException>()),
    );

    final legacy = await openDatabase(path, version: 28);
    expect(await legacy.getVersion(), 28);
    final units = await legacy.query(
      'sqlite_master',
      where: 'type = ? AND name = ?',
      whereArgs: ['table', 'product_selling_units'],
    );
    expect(units, isEmpty);
    final products = await legacy.query('products');
    expect(products, hasLength(2));
    expect(
        products
            .every((row) => row['internal_reference'] == 'duplicate-reference'),
        isTrue);
    await legacy.close();
  });
}
