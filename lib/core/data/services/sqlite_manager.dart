// lib/core/data/services/sqlite_manager.dart

// ignore_for_file: avoid_print

import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:bayaa_pos/core/constants/app_brand.dart';
import '../../logging/file_logger.dart';

/// SQLite database manager with WAL mode and optimizations.
class SQLiteManager {
  static const int databaseSchemaVersion = 35;

  final String databasePath;
  Database? _database;

  SQLiteManager({required this.databasePath});

  Future<void> initialize() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;

    FileLogger.info('Initializing SQLite database at: $databasePath',
        source: 'SQLite');

    _database = await openDatabase(
      databasePath,
      version: databaseSchemaVersion,
      onCreate: _onCreate,
      onConfigure: _onConfigure,
      onUpgrade: _onUpgrade,
      onOpen: _onOpen,
    );

    FileLogger.info('SQLite database initialized successfully',
        source: 'SQLite');
  }

  Future<void> _onConfigure(Database db) async {
    await db.execute('PRAGMA foreign_keys = ON');
  }

  Future<void> _onOpen(Database db) async {
    await db.execute('PRAGMA journal_mode = WAL');
    await db.execute('PRAGMA synchronous = NORMAL');
    await db.execute('PRAGMA cache_size = -64000');
    await db.execute('PRAGMA temp_store = MEMORY');
    await db.execute('PRAGMA mmap_size = 30000000000');
    await db.execute('PRAGMA wal_autocheckpoint = 1000');

    FileLogger.debug('SQLite PRAGMAs configured: WAL mode, synchronous=NORMAL',
        source: 'SQLite');
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    print('🔄 Migrating database from version $oldVersion to $newVersion');
    if (oldVersion < 17) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS document_sequences (
          sequence_key TEXT PRIMARY KEY NOT NULL,
          next_value INTEGER NOT NULL CHECK(next_value > 0)
        )
      ''');
      await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_document_sequences_key ON document_sequences(sequence_key)');
      try {
        await db.execute('ALTER TABLE sales ADD COLUMN reference_number TEXT');
      } catch (e) {
        if (!e.toString().contains('duplicate column name')) rethrow;
      }

      await db.execute(
          'CREATE UNIQUE INDEX IF NOT EXISTS idx_sales_reference_number ON sales(reference_number)');
    }

    if (oldVersion < 2) {
      print('  ➕ Adding missing columns to sales table...');

      // Add items_count column to sales table
      try {
        await db.execute(
            'ALTER TABLE sales ADD COLUMN items_count INTEGER DEFAULT 0');
        print('    ✅ Added items_count column');
      } catch (e) {
        if (!e.toString().contains('duplicate column name')) {
          print('    ⚠️ Error adding items_count: $e');
        }
      }

      // Add cashier_name column to sales table
      try {
        await db.execute('ALTER TABLE sales ADD COLUMN cashier_name TEXT');
        print('    ✅ Added cashier_name column');
      } catch (e) {
        if (!e.toString().contains('duplicate column name')) {
          print('    ⚠️ Error adding cashier_name: $e');
        }
      }

      print('  ➕ Adding missing columns to shifts table...');

      // Add close_time column to shifts table
      try {
        await db.execute('ALTER TABLE shifts ADD COLUMN close_time TEXT');
        print('    ✅ Added close_time column');
      } catch (e) {
        if (!e.toString().contains('duplicate column name')) {
          print('    ⚠️ Error adding close_time: $e');
        }
      }

      // Add closed_by column to shifts table
      try {
        await db.execute('ALTER TABLE shifts ADD COLUMN closed_by TEXT');
        print('    ✅ Added closed_by column');
      } catch (e) {
        if (!e.toString().contains('duplicate column name')) {
          print('    ⚠️ Error adding closed_by: $e');
        }
      }

      print('  ✅ Migration complete');
    }

    if (oldVersion < 3) {
      print('  ➕ Adding missing columns to store_settings table...');

      // List of new columns to ensure exist in store_settings
      // store_address, store_phone, store_email, logo_path, tax_number, tax_rate, currency, invoice_prefix
      final newColumns = {
        'store_address': 'TEXT',
        'store_phone': 'TEXT',
        'store_email': 'TEXT',
        'logo_path': 'TEXT',
        'tax_number': 'TEXT',
        'tax_rate': 'REAL DEFAULT 0.0',
        'currency': "TEXT DEFAULT 'DZD'",
        'invoice_prefix': "TEXT DEFAULT 'INV'",
      };

      for (final entry in newColumns.entries) {
        try {
          await db.execute(
              'ALTER TABLE store_settings ADD COLUMN ${entry.key} ${entry.value}');
          print('    ✅ Added ${entry.key} column');
        } catch (e) {
          if (!e.toString().contains('duplicate column name')) {
            print('    ⚠️ Error adding ${entry.key}: $e');
          }
        }
      }

      print('  ✅ Migration to v3 complete');
    }

    if (oldVersion < 4) {
      print('  ➕ Adding activity_logs table...');
      await db.execute('''
        CREATE TABLE IF NOT EXISTS activity_logs (
          id TEXT PRIMARY KEY NOT NULL,
          timestamp TEXT NOT NULL,
          type TEXT NOT NULL,
          description TEXT NOT NULL,
          user_name TEXT NOT NULL,
          details TEXT
        )
      ''');
      await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_activity_logs_timestamp ON activity_logs(timestamp DESC)');
      print('  ✅ Migration to v4 complete');
    }

    if (oldVersion < 5) {
      print('  ➕ Adding session_id to activity_logs...');
      try {
        await db
            .execute('ALTER TABLE activity_logs ADD COLUMN session_id TEXT');
        print('    ✅ Added session_id column');
      } catch (e) {
        if (!e.toString().contains('duplicate column name')) {
          print('    ⚠️ Error adding session_id: $e');
        }
      }
      await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_activity_logs_session ON activity_logs(session_id)');
      await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_activity_logs_type ON activity_logs(type)');
      print('  ✅ Migration to v5 complete');
    }

    if (oldVersion < 6) {
      print('  ➕ Adding event_key and parameters to activity_logs...');
      try {
        await db.execute('ALTER TABLE activity_logs ADD COLUMN event_key TEXT');
        await db
            .execute('ALTER TABLE activity_logs ADD COLUMN parameters TEXT');
        print('    ✅ Added event_key and parameters columns');
      } catch (e) {
        if (!e.toString().contains('duplicate column name')) {
          print('    ⚠️ Error adding event_key/parameters: $e');
        }
      }
      print('  ✅ Migration to v6 complete');
    }

    if (oldVersion < 7) {
      print('  ➕ Adding payment_method to sales table...');
      try {
        await db.execute(
            "ALTER TABLE sales ADD COLUMN payment_method TEXT DEFAULT 'cash'");
        print('    ✅ Added payment_method column');
      } catch (e) {
        if (!e.toString().contains('duplicate column name')) {
          print('    ⚠️ Error adding payment_method: $e');
        }
      }
      print('  ✅ Migration to v7 complete');
    }

    if (oldVersion < 8) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS expenses (
          id TEXT PRIMARY KEY NOT NULL,
          title TEXT NOT NULL,
          amount REAL NOT NULL,
          category TEXT NOT NULL DEFAULT 'General',
          notes TEXT,
          created_at TEXT NOT NULL,
          user_id TEXT,
          shift_id TEXT,
          payment_method TEXT NOT NULL DEFAULT 'unknown'
        )
      ''');
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_expenses_created_at '
        'ON expenses(created_at DESC)',
      );
    }

    if (oldVersion < 9) {
      print('  ➕ Adding optional user and product images...');
      final columns = <String, List<String>>{
        'users': ['phone TEXT', 'image_path TEXT'],
        'products': ['image_path TEXT'],
      };
      for (final table in columns.entries) {
        for (final definition in table.value) {
          try {
            await db.execute(
              'ALTER TABLE ${table.key} ADD COLUMN $definition',
            );
          } catch (e) {
            if (!e.toString().contains('duplicate column name')) rethrow;
          }
        }
      }
      print('  ✅ Migration to v9 complete');
    }

    if (oldVersion < 10) {
      await _createProductIndexes(db);
      print('  ✅ Migration to v10 complete');
    }

    if (oldVersion < 11) {
      await _createErpTables(db);
      await _ensureErpLegacyColumns(db);
      try {
        await db.execute('ALTER TABLE sales ADD COLUMN customer_id TEXT');
      } catch (e) {
        if (!e.toString().contains('duplicate column name')) {
          print('  ⚠️ Error adding customer_id to sales: $e');
        }
      }
      try {
        await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_sales_customer_id ON sales(customer_id, created_at DESC)',
        );
      } catch (_) {}
      print('  ✅ Migration to v11 complete');
    }
    if (oldVersion < 12) {
      await _createPurchaseTables(db);
    }
    if (oldVersion < 13) {
      await _createSupplierPaymentTables(db);
    }
    if (oldVersion < 14) {
      await _createSupplierReturnTables(db);
    }
    if (oldVersion < 15) {
      await _createCustomerPaymentTables(db);
    }
    if (oldVersion < 16) {
      await _createOrdersAndProformasTables(db);
      print('  ✅ Migration to v16 complete');
    }
    if (oldVersion < 18) {
      await _createOpeningStockTables(db);
      print('  ✅ Migration to v18 complete');
    }
    if (oldVersion < 19) {
      await _createStockAdjustmentTables(db);
      print('  ✅ Migration to v19 complete');
    }
    if (oldVersion < 20) {
      await _addColumnIfMissing(
        db,
        'stock_adjustment_items',
        'unit_cost REAL NOT NULL DEFAULT 0 CHECK(unit_cost >= 0)',
      );
      await _addColumnIfMissing(
        db,
        'stock_adjustment_items',
        'line_total REAL NOT NULL DEFAULT 0 CHECK(line_total >= 0)',
      );
      print('  ✅ Migration to v20 complete');
    }
    if (oldVersion < 21) {
      await _addColumnIfMissing(
        db,
        'stock_adjustment_documents',
        'idempotency_key TEXT',
      );
      await db.execute(
        'CREATE UNIQUE INDEX IF NOT EXISTS '
        'idx_stock_adjustment_documents_idempotency '
        'ON stock_adjustment_documents(idempotency_key) '
        'WHERE idempotency_key IS NOT NULL',
      );
      print('  ✅ Migration to v21 complete');
    }
    if (oldVersion < 24) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS expenses (
          id TEXT PRIMARY KEY NOT NULL,
          title TEXT NOT NULL,
          amount REAL NOT NULL,
          category TEXT NOT NULL DEFAULT 'General',
          notes TEXT,
          created_at TEXT NOT NULL,
          user_id TEXT,
          shift_id TEXT
        )
      ''');
      await _addColumnIfMissing(
        db,
        'expenses',
        "payment_method TEXT NOT NULL DEFAULT 'unknown'",
      );
      await _createCashTables(db);
      print('  ✅ Migration to v24 complete');
    }
    if (oldVersion < 26) {
      await _addColumnIfMissing(
        db,
        'sale_items',
        'refunded_quantity REAL NOT NULL DEFAULT 0.0',
      );
      await _addColumnIfMissing(
        db,
        'sale_items',
        'exchanged_quantity REAL NOT NULL DEFAULT 0.0',
      );
      await db.execute(
        'UPDATE sale_items SET exchanged_quantity = 0.0 WHERE exchanged_quantity IS NULL',
      );
      await _createExchangeSchema(db);
      print('  ✅ Migration to v26 complete');
    }
    if (oldVersion < 27) {
      await _migrateExchangeItemsToSchema27(db);
      print('  ✅ Migration to v27 complete');
    }
    if (oldVersion < 28) {
      await _migrateToSchema28(db);
      print('  ✅ Migration to v28 complete');
    }
    if (oldVersion < 29) {
      await _addColumnIfMissing(
        db,
        'product_selling_units',
        'cost_price REAL NOT NULL DEFAULT 0 CHECK (cost_price >= 0)',
      );
      print('  ✅ Migration to v29 complete');
    }
    if (oldVersion < 30) {
      await _addColumnIfMissing(
        db,
        'product_selling_units',
        'icon_key TEXT',
      );
      await db.execute('''
        UPDATE product_selling_units
        SET icon_key = CASE lower(trim(name))
          WHEN 'piece' THEN 'package'
          WHEN 'box' THEN 'box'
          WHEN 'bottle' THEN 'bottle'
          WHEN 'can' THEN 'can'
          WHEN 'pack' THEN 'pack'
          WHEN 'carton' THEN 'carton'
          ELSE 'package'
        END
        WHERE icon_key IS NULL OR trim(icon_key) = ''
      ''');
      print('  ✅ Migration to v30 complete');
    }
    if (oldVersion < 31) {
      final storeSettingsTable = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'store_settings'",
      );
      if (storeSettingsTable.isNotEmpty) {
        await _addColumnIfMissing(
          db,
          'store_settings',
          'show_logo INTEGER NOT NULL DEFAULT 1',
        );
        await _addColumnIfMissing(
          db,
          'store_settings',
          'show_vat INTEGER NOT NULL DEFAULT 1',
        );
        await _addColumnIfMissing(
          db,
          'store_settings',
          'show_amount_in_words INTEGER NOT NULL DEFAULT 1',
        );
        await _addColumnIfMissing(
          db,
          'store_settings',
          'show_barcode INTEGER NOT NULL DEFAULT 1',
        );
      }
    }
    if (oldVersion < 32) {
      await _ensureMasterDataColumns(db);
    }
    if (oldVersion < 33) {
      await _addColumnIfMissing(
        db,
        'product_selling_units',
        'minimum_stock REAL NOT NULL DEFAULT 0 CHECK (minimum_stock >= 0)',
      );
    }
    if (oldVersion < 34) {
      final stockMovementTable = await db.rawQuery(
        "SELECT name FROM sqlite_master "
        "WHERE type = 'table' AND name = 'stock_movements'",
      );
      if (stockMovementTable.isNotEmpty) {
        await _addColumnIfMissing(db, 'stock_movements', 'lineage_id TEXT');
        await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_stock_movements_lineage_id '
          'ON stock_movements(lineage_id)',
        );
      }
    }
    if (oldVersion < 35) {
      await _migrateProductBarcodeUniqueness(db);
      print('  ✅ Migration to v35 complete');
    }
    // Historical deletion triggers reference tables introduced by older
    // migrations. Ensure those tables exist before recreating the triggers.
    final customerTable = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'customers'",
    );
    final supplierTable = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'suppliers'",
    );
    if (customerTable.isNotEmpty || supplierTable.isNotEmpty) {
      await _ensureErpLegacyColumns(db);
    }
    const legacyColumns = <String, List<String>>{
      'customer_ledger': ["created_at TEXT NOT NULL DEFAULT ''"],
      'supplier_ledger': ["created_at TEXT NOT NULL DEFAULT ''"],
      'stock_movements': ["created_at TEXT NOT NULL DEFAULT ''"],
      'purchases': [
        "purchase_date TEXT NOT NULL DEFAULT ''",
        "reference_number TEXT NOT NULL DEFAULT ''",
      ],
      'customer_payments': [
        "payment_date TEXT NOT NULL DEFAULT ''",
        "reference TEXT NOT NULL DEFAULT ''",
      ],
      'supplier_payments': [
        "payment_date TEXT NOT NULL DEFAULT ''",
        "reference TEXT NOT NULL DEFAULT ''",
      ],
    };
    for (final entry in legacyColumns.entries) {
      final table = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
        [entry.key],
      );
      if (table.isNotEmpty) {
        for (final definition in entry.value) {
          await _addColumnIfMissing(db, entry.key, definition);
        }
      }
    }
    await _createErpTables(db);
    await _createPurchaseTables(db);
    await _createSupplierPaymentTables(db);
    await _createSupplierReturnTables(db);
    await _createCustomerPaymentTables(db);
    await _createOrdersAndProformasTables(db);
    if (oldVersion < 23) {
      await _createHistoricalDeletionProtection(db);
      print('  ✅ Migration to v23 complete');
    }
    if (oldVersion < 25) {
      await _createLedgerImmutabilityTriggers(db);
    }
    if (oldVersion < 23) {
      await _createStockMovementIntegrityTriggers(db);
    }
  }

  Future<void> _migrateExchangeItemsToSchema27(Database db) async {
    final duplicateRows = await db.rawQuery('''
      SELECT exchange_id, original_sale_item_id, replacement_product_id,
             COUNT(*) AS duplicate_count
      FROM exchange_items
      GROUP BY exchange_id, original_sale_item_id, replacement_product_id
      HAVING COUNT(*) > 1
    ''');
    if (duplicateRows.isNotEmpty) {
      throw StateError(
        'Schema 27 migration aborted: duplicate exchange_items rows exist '
        'for the new unique key: $duplicateRows',
      );
    }

    await db.execute('''
      CREATE TABLE exchange_items_new (
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
        original_selling_unit_id TEXT,
        original_selling_quantity REAL,
        original_base_quantity REAL,
        original_conversion_factor_snapshot REAL,
        original_selling_unit_name_snapshot TEXT,
        original_base_unit_snapshot TEXT,
        replacement_selling_unit_id TEXT,
        replacement_selling_quantity REAL,
        replacement_base_quantity REAL,
        replacement_conversion_factor_snapshot REAL,
        replacement_selling_unit_name_snapshot TEXT,
        replacement_base_unit_snapshot TEXT,
        UNIQUE (exchange_id, original_sale_item_id, replacement_product_id),
        FOREIGN KEY (exchange_id) REFERENCES exchange_documents(id),
        FOREIGN KEY (original_sale_item_id) REFERENCES sale_items(id),
        FOREIGN KEY (original_product_id) REFERENCES products(id),
        FOREIGN KEY (replacement_product_id) REFERENCES products(id)
      )
    ''');

    await db.execute('''
      INSERT INTO exchange_items_new (
        id,
        exchange_id,
        original_sale_item_id,
        original_product_id,
        returned_quantity,
        replacement_product_id,
        replacement_quantity,
        old_unit_price,
        new_unit_price,
        old_total,
        new_total,
        difference_amount
      )
      SELECT
        id,
        exchange_id,
        original_sale_item_id,
        original_product_id,
        returned_quantity,
        replacement_product_id,
        replacement_quantity,
        old_unit_price,
        new_unit_price,
        old_total,
        new_total,
        difference_amount
      FROM exchange_items
    ''');

    final oldCountRow =
        await db.rawQuery('SELECT COUNT(*) AS count FROM exchange_items');
    final newCountRow =
        await db.rawQuery('SELECT COUNT(*) AS count FROM exchange_items_new');
    final oldRowCount = (oldCountRow.single['count'] as num?)?.toInt() ?? 0;
    final newRowCount = (newCountRow.single['count'] as num?)?.toInt() ?? 0;
    if (oldRowCount != newRowCount) {
      throw StateError(
        'Schema 27 migration aborted: exchange_items row count changed '
        'from $oldRowCount to $newRowCount',
      );
    }

    for (final indexName in [
      'idx_exchange_items_exchange_id',
      'idx_exchange_items_original_sale_item_id',
      'idx_exchange_items_original_product_id',
      'idx_exchange_items_replacement_product_id',
    ]) {
      await db.execute('DROP INDEX IF EXISTS $indexName');
    }
    await db.execute('DROP TABLE exchange_items');
    await db.execute('ALTER TABLE exchange_items_new RENAME TO exchange_items');

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

    final foreignKeyErrors = await db.rawQuery('PRAGMA foreign_key_check');
    if (foreignKeyErrors.isNotEmpty) {
      throw StateError(
        'Schema 27 migration failed foreign key validation: $foreignKeyErrors',
      );
    }
  }

  Future<void> _createExchangeSchema(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS exchange_documents (
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
      CREATE TABLE IF NOT EXISTS exchange_items (
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
        original_selling_unit_id TEXT,
        original_selling_quantity REAL,
        original_base_quantity REAL,
        original_conversion_factor_snapshot REAL,
        original_selling_unit_name_snapshot TEXT,
        original_base_unit_snapshot TEXT,
        replacement_selling_unit_id TEXT,
        replacement_selling_quantity REAL,
        replacement_base_quantity REAL,
        replacement_conversion_factor_snapshot REAL,
        replacement_selling_unit_name_snapshot TEXT,
        replacement_base_unit_snapshot TEXT,
        UNIQUE (exchange_id, original_sale_item_id, replacement_product_id),
        FOREIGN KEY (exchange_id) REFERENCES exchange_documents(id),
        FOREIGN KEY (original_sale_item_id) REFERENCES sale_items(id),
        FOREIGN KEY (original_product_id) REFERENCES products(id),
        FOREIGN KEY (replacement_product_id) REFERENCES products(id)
      )
    ''');

    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_exchange_documents_original_sale_id ON exchange_documents(original_sale_id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_exchange_documents_customer_id ON exchange_documents(customer_id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_exchange_documents_created_at ON exchange_documents(created_at DESC)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_exchange_documents_status ON exchange_documents(status)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_exchange_items_exchange_id ON exchange_items(exchange_id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_exchange_items_original_sale_item_id ON exchange_items(original_sale_item_id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_exchange_items_original_product_id ON exchange_items(original_product_id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_exchange_items_replacement_product_id ON exchange_items(replacement_product_id)',
    );

    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS sale_items_refund_exchange_guard_insert
      BEFORE INSERT ON sale_items
      BEGIN
        SELECT CASE
          WHEN NEW.refunded_quantity + NEW.exchanged_quantity > NEW.quantity
            THEN RAISE(ABORT, 'refunded_quantity + exchanged_quantity cannot exceed quantity')
        END;
      END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS sale_items_refund_exchange_guard_update
      BEFORE UPDATE ON sale_items
      BEGIN
        SELECT CASE
          WHEN NEW.refunded_quantity + NEW.exchanged_quantity > NEW.quantity
            THEN RAISE(ABORT, 'refunded_quantity + exchanged_quantity cannot exceed quantity')
        END;
      END
    ''');
  }

  Future<void> _migrateToSchema28(Database db) async {
    await _addColumnIfMissing(db, 'products', 'internal_reference TEXT');
    await _addColumnIfMissing(
      db,
      'products',
      "product_type TEXT NOT NULL DEFAULT 'STANDARD'",
    );
    await _addColumnIfMissing(
      db,
      'products',
      "base_unit TEXT NOT NULL DEFAULT 'piece'",
    );
    await _addColumnIfMissing(
      db,
      'products',
      'quantity_precision INTEGER NOT NULL DEFAULT 3',
    );
    await _addColumnIfMissing(
      db,
      'products',
      'allow_partial_package_sale INTEGER NOT NULL DEFAULT 0',
    );

    final productColumns = await db.rawQuery('PRAGMA table_info(products)');
    final hasWholesalePrice =
        productColumns.any((column) => column['name'] == 'wholesale_price');
    final products = await db.query(
      'products',
      columns: [
        'id',
        'internal_reference',
        'price',
        if (hasWholesalePrice) 'wholesale_price',
      ],
    );
    for (final product in products) {
      final id = product['id'] as String;
      final reference = product['internal_reference'] as String?;
      if (reference == null || reference.trim().isEmpty) {
        await db.update(
          'products',
          {'internal_reference': 'PRD-$id'},
          where: 'id = ?',
          whereArgs: [id],
        );
      }
    }
    await db.execute(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_products_internal_reference '
      'ON products(internal_reference)',
    );
    await db.execute(
      "CREATE INDEX IF NOT EXISTS idx_products_type_active "
      "ON products(product_type)",
    );
    await _createProductSellingUnitsSchema(db);
    final now = DateTime.now().toIso8601String();
    for (final product in await db.query(
      'products',
      columns: [
        'id',
        'price',
        if (hasWholesalePrice) 'wholesale_price',
      ],
    )) {
      final productId = product['id'] as String;
      final existingUnit = await db.query(
        'product_selling_units',
        columns: ['id'],
        where: 'product_id = ?',
        whereArgs: [productId],
        limit: 1,
      );
      if (existingUnit.isNotEmpty) continue;
      await db.insert('product_selling_units', {
        'id': 'unit_${productId}_piece',
        'product_id': productId,
        'name': 'piece',
        'conversion_to_base': 1.0,
        'selling_price': (product['price'] as num?)?.toDouble() ?? 0.0,
        'wholesale_price': (product['wholesale_price'] as num?)?.toDouble(),
        'is_default': 1,
        'is_active': 1,
        'created_at': now,
        'updated_at': now,
      });
    }

    for (final entry in <String, List<String>>{
      'sale_items': [
        'selling_unit_id TEXT',
        'selling_quantity REAL',
        'base_quantity REAL',
        'conversion_factor_snapshot REAL',
        'selling_unit_name_snapshot TEXT',
        'base_unit_snapshot TEXT',
      ],
      'purchase_items': [
        'selling_unit_id TEXT',
        'selling_quantity REAL',
        'base_quantity REAL',
        'conversion_factor_snapshot REAL',
        'selling_unit_name_snapshot TEXT',
        'base_unit_snapshot TEXT',
      ],
      'exchange_items': [
        'original_selling_unit_id TEXT',
        'original_selling_quantity REAL',
        'original_base_quantity REAL',
        'original_conversion_factor_snapshot REAL',
        'original_selling_unit_name_snapshot TEXT',
        'original_base_unit_snapshot TEXT',
        'replacement_selling_unit_id TEXT',
        'replacement_selling_quantity REAL',
        'replacement_base_quantity REAL',
        'replacement_conversion_factor_snapshot REAL',
        'replacement_selling_unit_name_snapshot TEXT',
        'replacement_base_unit_snapshot TEXT',
      ],
    }.entries) {
      final table = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
        [entry.key],
      );
      if (table.isEmpty) continue;
      for (final definition in entry.value) {
        await _addColumnIfMissing(db, entry.key, definition);
      }
    }

    for (final entry in <({String table, String column, String suffix})>[
      (table: 'sale_items', column: 'selling_unit_id', suffix: 'selling_unit'),
      (
        table: 'purchase_items',
        column: 'selling_unit_id',
        suffix: 'selling_unit'
      ),
      (
        table: 'exchange_items',
        column: 'original_selling_unit_id',
        suffix: 'original_unit'
      ),
      (
        table: 'exchange_items',
        column: 'replacement_selling_unit_id',
        suffix: 'replacement_unit'
      ),
    ]) {
      final table = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
        [entry.table],
      );
      if (table.isEmpty) continue;
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_${entry.table}_${entry.suffix} '
        'ON ${entry.table}(${entry.column})',
      );
    }
  }

  Future<void> _createProductSellingUnitsSchema(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS product_selling_units (
        id TEXT PRIMARY KEY NOT NULL,
        product_id TEXT NOT NULL,
        name TEXT NOT NULL,
        icon_key TEXT,
        conversion_to_base REAL NOT NULL CHECK (conversion_to_base > 0),
        selling_price REAL NOT NULL CHECK (selling_price >= 0),
        cost_price REAL NOT NULL DEFAULT 0 CHECK (cost_price >= 0),
        wholesale_price REAL CHECK (wholesale_price IS NULL OR wholesale_price >= 0),
        minimum_stock REAL NOT NULL DEFAULT 0 CHECK (minimum_stock >= 0),
        barcode TEXT,
        is_default INTEGER NOT NULL DEFAULT 0 CHECK (is_default IN (0, 1)),
        is_active INTEGER NOT NULL DEFAULT 1 CHECK (is_active IN (0, 1)),
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        FOREIGN KEY (product_id) REFERENCES products(id) ON DELETE RESTRICT,
        CHECK (length(trim(name)) > 0)
      )
    ''');
    await db.execute(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_product_units_name '
      'ON product_selling_units(product_id, name)',
    );
    await db.execute(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_product_units_barcode '
      'ON product_selling_units(barcode) WHERE barcode IS NOT NULL',
    );
    await db.execute(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_product_units_default '
      'ON product_selling_units(product_id) '
      'WHERE is_default = 1 AND is_active = 1',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_product_units_product_active '
      'ON product_selling_units(product_id, is_active)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_product_units_barcode_lookup '
      'ON product_selling_units(barcode)',
    );
    await _createProductUnitBarcodeCollisionTriggers(db);
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS product_units_default_required
      BEFORE UPDATE OF is_active, is_default ON product_selling_units
      WHEN OLD.is_active = 1 AND OLD.is_default = 1
        AND (NEW.is_active = 0 OR NEW.is_default = 0)
        AND NOT EXISTS (
          SELECT 1 FROM product_selling_units
          WHERE product_id = OLD.product_id
            AND id <> OLD.id
            AND is_active = 1
            AND is_default = 1
        )
      BEGIN
        SELECT RAISE(ABORT, 'Each product requires an active default selling unit');
      END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS product_units_default_required_delete
      BEFORE DELETE ON product_selling_units
      WHEN OLD.is_active = 1 AND OLD.is_default = 1
        AND NOT EXISTS (
          SELECT 1 FROM product_selling_units
          WHERE product_id = OLD.product_id
            AND id <> OLD.id
            AND is_active = 1
        )
      BEGIN
        SELECT RAISE(ABORT, 'Each product requires an active selling unit');
      END
    ''');
  }

  Future<void> _createProductUnitBarcodeCollisionTriggers(Database db) async {
    final unitTable = await db.rawQuery(
      "SELECT name FROM sqlite_master "
      "WHERE type = 'table' AND name = 'product_selling_units'",
    );
    if (unitTable.isEmpty) return;

    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS product_units_barcode_legacy_collision_insert
      BEFORE INSERT ON product_selling_units
      WHEN NEW.barcode IS NOT NULL
        AND EXISTS (SELECT 1 FROM products WHERE barcode = NEW.barcode)
      BEGIN
        SELECT RAISE(ABORT, 'Selling-unit barcode collides with product barcode');
      END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS product_units_barcode_legacy_collision_update
      BEFORE UPDATE OF barcode ON product_selling_units
      WHEN NEW.barcode IS NOT NULL
        AND EXISTS (SELECT 1 FROM products WHERE barcode = NEW.barcode)
      BEGIN
        SELECT RAISE(ABORT, 'Selling-unit barcode collides with product barcode');
      END
    ''');
  }

  Future<void> _createStockMovementIntegrityTriggers(Database db) async {
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS prevent_stock_movement_update
      BEFORE UPDATE ON stock_movements
      BEGIN
        SELECT RAISE(ABORT, 'stock_movements are immutable');
      END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS prevent_stock_movement_delete
      BEFORE DELETE ON stock_movements
      BEGIN
        SELECT RAISE(ABORT, 'stock_movements are immutable');
      END
    ''');
  }

  Future<void> _addColumnIfMissing(
    Database db,
    String table,
    String definition,
  ) async {
    final columnName = definition.split(' ').first;
    final columns = await db.rawQuery('PRAGMA table_info($table)');
    if (columns.any((column) => column['name'] == columnName)) return;
    await db.execute('ALTER TABLE $table ADD COLUMN $definition');
  }

  Future<void> _onCreate(Database db, int version) async {
    // Store settings table
    await db.execute('''
      CREATE TABLE IF NOT EXISTS store_settings (
        id TEXT PRIMARY KEY NOT NULL,
        store_name TEXT NOT NULL,
        store_address TEXT,
        store_phone TEXT,
        store_email TEXT,
        logo_path TEXT,
        tax_number TEXT,
        tax_rate REAL DEFAULT 0.0,
        currency TEXT DEFAULT 'DZD',
        invoice_prefix TEXT DEFAULT 'INV',
        last_invoice_number INTEGER DEFAULT 0,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        CHECK (tax_rate >= 0 AND tax_rate <= 100)
      )
    ''');

    // Activity Logs table
    await db.execute('''
      CREATE TABLE IF NOT EXISTS activity_logs (
        id TEXT PRIMARY KEY NOT NULL,
        session_id TEXT,
        timestamp TEXT NOT NULL,
        type TEXT NOT NULL,
        description TEXT NOT NULL,
        user_name TEXT NOT NULL,
        details TEXT,
        event_key TEXT,
        parameters TEXT
      )
    ''');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_activity_logs_timestamp ON activity_logs(timestamp DESC)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_activity_logs_session ON activity_logs(session_id)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_activity_logs_type ON activity_logs(type)');

    // Categories table
    await db.execute('''
      CREATE TABLE IF NOT EXISTS categories (
        id TEXT PRIMARY KEY NOT NULL,
        name TEXT NOT NULL UNIQUE,
        color TEXT,
        sort_order INTEGER DEFAULT 0
      )
    ''');

    // Products table
    await db.execute('''
      CREATE TABLE IF NOT EXISTS products (
        id TEXT PRIMARY KEY NOT NULL,
        barcode TEXT,
        name TEXT NOT NULL,
        internal_reference TEXT UNIQUE,
        product_type TEXT NOT NULL DEFAULT 'STANDARD'
          CHECK (product_type IN ('STANDARD', 'WEIGHTED', 'PACKAGED')),
        base_unit TEXT NOT NULL DEFAULT 'piece',
        quantity_precision INTEGER NOT NULL DEFAULT 3 CHECK (quantity_precision > 0),
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
    await _createProductIndexes(db);
    await _createProductSellingUnitsSchema(db);

    // Users table
    await db.execute('''
      CREATE TABLE IF NOT EXISTS document_sequences (
        sequence_key TEXT PRIMARY KEY NOT NULL,
        next_value INTEGER NOT NULL CHECK(next_value > 0)
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS users (
        id TEXT PRIMARY KEY NOT NULL,
        username TEXT NOT NULL UNIQUE,
        display_name TEXT NOT NULL,
        phone TEXT,
        image_path TEXT,
        password_hash TEXT NOT NULL,
        role TEXT NOT NULL DEFAULT 'cashier',
        is_active INTEGER NOT NULL DEFAULT 1,
        created_at TEXT NOT NULL,
        created_by TEXT,
        last_login TEXT,
        CHECK (role IN ('admin', 'manager', 'cashier')),
        FOREIGN KEY (created_by) REFERENCES users(id)
      )
    ''');

    // Shifts table
    await db.execute('''
      CREATE TABLE IF NOT EXISTS shifts (
        id TEXT PRIMARY KEY NOT NULL,
        user_id TEXT NOT NULL,
        open_time TEXT NOT NULL,
        close_time TEXT,
        closed_by TEXT,
        opening_cash REAL DEFAULT 0.0,
        closing_cash REAL DEFAULT 0.0,
        is_open INTEGER NOT NULL DEFAULT 1
      )
    ''');

    // Sales table
    await db.execute('''
      CREATE TABLE IF NOT EXISTS sales (
        id TEXT PRIMARY KEY NOT NULL,
        reference_number TEXT UNIQUE,
        total REAL NOT NULL DEFAULT 0.0,
        created_at TEXT NOT NULL,
        user_id TEXT,
        cashier_name TEXT,
        customer_id TEXT,
        items_count INTEGER DEFAULT 0,
        is_refund INTEGER NOT NULL DEFAULT 0,
        original_sale_id TEXT,
        shift_id TEXT,
        discount REAL DEFAULT 0.0,
        tax REAL DEFAULT 0.0,
        payment_method TEXT DEFAULT 'cash',
        notes TEXT,
        FOREIGN KEY (user_id) REFERENCES users(id),
        FOREIGN KEY (customer_id) REFERENCES customers(id),
        FOREIGN KEY (original_sale_id) REFERENCES sales(id),
        FOREIGN KEY (shift_id) REFERENCES shifts(id)
      )
    ''');

    // Sale items table
    await db.execute('''
      CREATE TABLE IF NOT EXISTS sale_items (
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
        exchanged_quantity REAL NOT NULL DEFAULT 0.0,
        selling_unit_id TEXT,
        selling_quantity REAL,
        base_quantity REAL,
        conversion_factor_snapshot REAL,
        selling_unit_name_snapshot TEXT,
        base_unit_snapshot TEXT,
        FOREIGN KEY (sale_id) REFERENCES sales(id) ON DELETE CASCADE,
        CHECK (quantity > 0),
        CHECK (price >= 0),
        CHECK (refunded_quantity >= 0),
        CHECK (refunded_quantity <= quantity),
        CHECK (exchanged_quantity >= 0),
        CHECK (exchanged_quantity <= quantity)
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS expenses (
        id TEXT PRIMARY KEY NOT NULL,
        title TEXT NOT NULL,
        amount REAL NOT NULL,
        category TEXT NOT NULL DEFAULT 'General',
        notes TEXT,
        created_at TEXT NOT NULL,
        user_id TEXT,
        shift_id TEXT,
        payment_method TEXT NOT NULL DEFAULT 'unknown'
      )
    ''');

    // Create indexes
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_sales_created_at ON sales(created_at DESC)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_sales_user_id ON sales(user_id)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_sale_items_sale_id ON sale_items(sale_id)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_users_username ON users(username)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_shifts_user_id ON shifts(user_id)');

    // Additional performance indexes
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_sales_shift_date ON sales(shift_id, created_at DESC)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_sales_is_refund ON sales(is_refund, created_at DESC)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_sale_items_product ON sale_items(product_id)');
    FileLogger.info('Database indexes created', source: 'SQLite');

    await _createErpTables(db);
    await _createLedgerImmutabilityTriggers(db);
    await _createCashTables(db);
    await _ensureErpLegacyColumns(db);
    await _createExchangeSchema(db);
    await _createPurchaseTables(db);
    await _createSupplierPaymentTables(db);
    await _createSupplierReturnTables(db);
    await _createCustomerPaymentTables(db);
    await _createOrdersAndProformasTables(db);
    await _createOpeningStockTables(db);
    await _createStockAdjustmentTables(db);
    await _createHistoricalDeletionProtection(db);

    // Insert default settings
    await db.execute('''
      INSERT INTO store_settings (
        id, store_name, store_address, store_phone,
        currency, invoice_prefix, last_invoice_number,
        created_at, updated_at
      ) VALUES (
        'store_settings_singleton', '${AppBrand.name}', '', '',
        'DZD', 'INV', 0,
        '${DateTime.now().toIso8601String()}',
        '${DateTime.now().toIso8601String()}'
      )
    ''');
  }

  Future<void> _createLedgerImmutabilityTriggers(Database db) async {
    final triggers = <String, String>{
      'customer_ledger_no_update':
          "CREATE TRIGGER IF NOT EXISTS customer_ledger_no_update BEFORE UPDATE ON customer_ledger BEGIN SELECT RAISE(ABORT, 'customer_ledger is immutable'); END",
      'customer_ledger_no_delete':
          "CREATE TRIGGER IF NOT EXISTS customer_ledger_no_delete BEFORE DELETE ON customer_ledger BEGIN SELECT RAISE(ABORT, 'customer_ledger is immutable'); END",
      'supplier_ledger_no_update':
          "CREATE TRIGGER IF NOT EXISTS supplier_ledger_no_update BEFORE UPDATE ON supplier_ledger BEGIN SELECT RAISE(ABORT, 'supplier_ledger is immutable'); END",
      'supplier_ledger_no_delete':
          "CREATE TRIGGER IF NOT EXISTS supplier_ledger_no_delete BEFORE DELETE ON supplier_ledger BEGIN SELECT RAISE(ABORT, 'supplier_ledger is immutable'); END",
    };

    for (final entry in triggers.entries) {
      await db.execute(entry.value);
    }
  }

  Future<void> _createCashTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS cash_registers (
        id TEXT PRIMARY KEY NOT NULL,
        name TEXT NOT NULL,
        code TEXT NOT NULL UNIQUE,
        is_active INTEGER NOT NULL DEFAULT 1,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        created_by TEXT,
        FOREIGN KEY (created_by) REFERENCES users(id)
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS cash_movements (
        id TEXT PRIMARY KEY NOT NULL,
        cash_register_id TEXT NOT NULL,
        movement_type TEXT NOT NULL CHECK (movement_type IN (
          'opening_balance',
          'sale_cash',
          'customer_payment_cash',
          'supplier_payment_cash',
          'expense_cash',
          'customer_refund_cash',
          'cash_in',
          'cash_out'
        )),
        amount REAL NOT NULL CHECK (amount <> 0),
        reference_type TEXT,
        reference_id TEXT,
        session_id TEXT,
        user_id TEXT,
        idempotency_key TEXT UNIQUE,
        description TEXT NOT NULL,
        created_at TEXT NOT NULL,
        FOREIGN KEY (cash_register_id) REFERENCES cash_registers(id),
        FOREIGN KEY (session_id) REFERENCES shifts(id),
        FOREIGN KEY (user_id) REFERENCES users(id)
      )
    ''');
    await db
        .execute('CREATE INDEX IF NOT EXISTS idx_cash_movements_register_date '
            'ON cash_movements(cash_register_id, created_at DESC)');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_cash_movements_reference '
        'ON cash_movements(reference_type, reference_id)');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS cash_movements_no_update
      BEFORE UPDATE ON cash_movements
      BEGIN
        SELECT RAISE(ABORT, 'cash_movements are immutable');
      END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS cash_movements_no_delete
      BEFORE DELETE ON cash_movements
      BEGIN
        SELECT RAISE(ABORT, 'cash_movements are immutable');
      END
    ''');
    final now = DateTime.now().toIso8601String();
    final usersTable = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'users'",
    );
    if (usersTable.isNotEmpty) {
      await db.insert(
        'cash_registers',
        {
          'id': 'main-register',
          'name': 'Main Register',
          'code': 'MAIN',
          'is_active': 1,
          'created_at': now,
          'updated_at': now,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }
  }

  Future<void> _createHistoricalDeletionProtection(Database db) async {
    await _addColumnIfMissing(
      db,
      'sales',
      "status TEXT NOT NULL DEFAULT 'posted'",
    );
    await db.execute(
      "UPDATE sales SET status = 'posted' WHERE status IS NULL OR status = ''",
    );

    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS sales_no_delete_posted
      BEFORE DELETE ON sales
      WHEN OLD.status IN ('posted', 'completed')
      BEGIN
        SELECT RAISE(ABORT, 'Posted or completed sales are immutable');
      END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS sale_items_no_delete_posted
      BEFORE DELETE ON sale_items
      WHEN (SELECT status FROM sales WHERE id = OLD.sale_id)
        IN ('posted', 'completed')
      BEGIN
        SELECT RAISE(ABORT, 'Posted or completed sale items are immutable');
      END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS products_no_delete_with_history
      BEFORE DELETE ON products
      WHEN EXISTS (SELECT 1 FROM sale_items WHERE product_id = OLD.id)
        OR EXISTS (SELECT 1 FROM purchase_items WHERE product_id = OLD.id)
        OR EXISTS (SELECT 1 FROM order_items WHERE product_id = OLD.id)
        OR EXISTS (SELECT 1 FROM proforma_items WHERE product_id = OLD.id)
        OR EXISTS (SELECT 1 FROM supplier_return_items WHERE product_id = OLD.id)
        OR EXISTS (SELECT 1 FROM stock_movements WHERE product_id = OLD.id)
        OR EXISTS (SELECT 1 FROM opening_stock_lines WHERE product_id = OLD.id)
        OR EXISTS (SELECT 1 FROM stock_adjustment_items WHERE product_id = OLD.id)
      BEGIN
        SELECT RAISE(ABORT, 'Products with historical references are immutable');
      END
    ''');
  }

  Future<void> _createPurchaseTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS purchases (
        id TEXT PRIMARY KEY NOT NULL,
        reference_number TEXT NOT NULL UNIQUE,
        supplier_id TEXT NOT NULL,
        purchase_date TEXT NOT NULL,
        subtotal REAL NOT NULL,
        total REAL NOT NULL,
        notes TEXT,
        status TEXT NOT NULL DEFAULT 'confirmed',
        created_by TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        FOREIGN KEY (supplier_id) REFERENCES suppliers(id)
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS purchase_items (
        id TEXT PRIMARY KEY NOT NULL,
        purchase_id TEXT NOT NULL,
        product_id TEXT NOT NULL,
        quantity REAL NOT NULL CHECK(quantity > 0),
        unit_cost REAL NOT NULL CHECK(unit_cost >= 0),
        line_total REAL NOT NULL,
        selling_unit_id TEXT,
        selling_quantity REAL,
        base_quantity REAL,
        conversion_factor_snapshot REAL,
        selling_unit_name_snapshot TEXT,
        base_unit_snapshot TEXT,
        FOREIGN KEY (purchase_id) REFERENCES purchases(id) ON DELETE CASCADE,
        FOREIGN KEY (product_id) REFERENCES products(id)
      )
    ''');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_purchases_supplier_id ON purchases(supplier_id)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_purchases_date ON purchases(purchase_date DESC)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_purchases_reference ON purchases(reference_number)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_purchase_items_purchase_id ON purchase_items(purchase_id)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_purchase_items_product_id ON purchase_items(product_id)');
  }

  Future<void> _createSupplierPaymentTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS supplier_payments (
        id TEXT PRIMARY KEY NOT NULL,
        supplier_id TEXT NOT NULL,
        amount REAL NOT NULL CHECK(amount > 0),
        payment_date TEXT NOT NULL,
        payment_method TEXT NOT NULL DEFAULT 'cash',
        reference TEXT NOT NULL UNIQUE,
        notes TEXT,
        created_by TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'confirmed',
        created_at TEXT NOT NULL,
        FOREIGN KEY (supplier_id) REFERENCES suppliers(id)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_supplier_payments_supplier '
      'ON supplier_payments(supplier_id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_supplier_payments_date '
      'ON supplier_payments(payment_date DESC)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_supplier_payments_reference '
      'ON supplier_payments(reference)',
    );
  }

  Future<void> _createCustomerPaymentTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS customer_payments (
        id TEXT PRIMARY KEY NOT NULL,
        customer_id TEXT NOT NULL,
        amount REAL NOT NULL CHECK(amount > 0),
        payment_date TEXT NOT NULL,
        payment_method TEXT NOT NULL DEFAULT 'cash',
        reference TEXT NOT NULL UNIQUE,
        notes TEXT,
        created_by TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'confirmed',
        created_at TEXT NOT NULL,
        FOREIGN KEY (customer_id) REFERENCES customers(id)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_customer_payments_customer '
      'ON customer_payments(customer_id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_customer_payments_date '
      'ON customer_payments(payment_date DESC)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_customer_payments_reference '
      'ON customer_payments(reference)',
    );
  }

  Future<void> _createOrdersAndProformasTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS orders (
        id TEXT PRIMARY KEY NOT NULL,
        reference_number TEXT NOT NULL UNIQUE,
        customer_id TEXT,
        order_date TEXT NOT NULL,
        subtotal REAL NOT NULL CHECK(subtotal >= 0),
        total REAL NOT NULL CHECK(total >= 0),
        status TEXT NOT NULL DEFAULT 'draft'
          CHECK(status IN ('draft', 'confirmed', 'cancelled', 'converted')),
        notes TEXT,
        created_by TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        converted_sale_id TEXT UNIQUE,
        FOREIGN KEY (customer_id) REFERENCES customers(id)
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS order_items (
        id TEXT PRIMARY KEY NOT NULL,
        order_id TEXT NOT NULL,
        product_id TEXT NOT NULL,
        product_barcode TEXT,
        product_name TEXT NOT NULL,
        quantity REAL NOT NULL CHECK(quantity > 0),
        unit_price REAL NOT NULL CHECK(unit_price >= 0),
        wholesale_price REAL NOT NULL DEFAULT 0 CHECK(wholesale_price >= 0),
        line_total REAL NOT NULL CHECK(line_total >= 0),
        FOREIGN KEY (order_id) REFERENCES orders(id) ON DELETE CASCADE,
        FOREIGN KEY (product_id) REFERENCES products(id)
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS proformas (
        id TEXT PRIMARY KEY NOT NULL,
        reference_number TEXT NOT NULL UNIQUE,
        customer_id TEXT,
        proforma_date TEXT NOT NULL,
        subtotal REAL NOT NULL CHECK(subtotal >= 0),
        total REAL NOT NULL CHECK(total >= 0),
        status TEXT NOT NULL DEFAULT 'draft'
          CHECK(status IN ('draft', 'confirmed', 'cancelled', 'converted')),
        notes TEXT,
        created_by TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        converted_sale_id TEXT UNIQUE,
        FOREIGN KEY (customer_id) REFERENCES customers(id)
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS proforma_items (
        id TEXT PRIMARY KEY NOT NULL,
        proforma_id TEXT NOT NULL,
        product_id TEXT NOT NULL,
        product_barcode TEXT,
        product_name TEXT NOT NULL,
        quantity REAL NOT NULL CHECK(quantity > 0),
        unit_price REAL NOT NULL CHECK(unit_price >= 0),
        wholesale_price REAL NOT NULL DEFAULT 0 CHECK(wholesale_price >= 0),
        line_total REAL NOT NULL CHECK(line_total >= 0),
        FOREIGN KEY (proforma_id) REFERENCES proformas(id) ON DELETE CASCADE,
        FOREIGN KEY (product_id) REFERENCES products(id)
      )
    ''');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_orders_status_date ON orders(status, order_date DESC)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_order_items_order ON order_items(order_id)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_proformas_status_date ON proformas(status, proforma_date DESC)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_proforma_items_parent ON proforma_items(proforma_id)');

    // Once a document is confirmed, its historical lines and business fields
    // are immutable. Status and conversion linkage remain transition fields.
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS orders_immutable_after_confirmation
      BEFORE UPDATE ON orders
      WHEN OLD.status <> 'draft' AND (
        NEW.reference_number <> OLD.reference_number OR
        COALESCE(NEW.customer_id, '') <> COALESCE(OLD.customer_id, '') OR
        NEW.order_date <> OLD.order_date OR NEW.subtotal <> OLD.subtotal OR
        NEW.total <> OLD.total OR COALESCE(NEW.notes, '') <> COALESCE(OLD.notes, '') OR
        COALESCE(NEW.created_by, '') <> COALESCE(OLD.created_by, '')
      )
      BEGIN SELECT RAISE(ABORT, 'Historical orders are immutable'); END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS proformas_immutable_after_confirmation
      BEFORE UPDATE ON proformas
      WHEN OLD.status <> 'draft' AND (
        NEW.reference_number <> OLD.reference_number OR
        COALESCE(NEW.customer_id, '') <> COALESCE(OLD.customer_id, '') OR
        NEW.proforma_date <> OLD.proforma_date OR NEW.subtotal <> OLD.subtotal OR
        NEW.total <> OLD.total OR COALESCE(NEW.notes, '') <> COALESCE(OLD.notes, '') OR
        COALESCE(NEW.created_by, '') <> COALESCE(OLD.created_by, '')
      )
      BEGIN SELECT RAISE(ABORT, 'Historical proformas are immutable'); END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS order_items_immutable_after_confirmation
      BEFORE UPDATE ON order_items
      WHEN (SELECT status FROM orders WHERE id = OLD.order_id) <> 'draft'
      BEGIN SELECT RAISE(ABORT, 'Historical order lines are immutable'); END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS order_items_no_insert_after_confirmation
      BEFORE INSERT ON order_items
      WHEN (SELECT status FROM orders WHERE id = NEW.order_id) <> 'draft'
      BEGIN SELECT RAISE(ABORT, 'Historical order lines are immutable'); END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS proforma_items_immutable_after_confirmation
      BEFORE UPDATE ON proforma_items
      WHEN (SELECT status FROM proformas WHERE id = OLD.proforma_id) <> 'draft'
      BEGIN SELECT RAISE(ABORT, 'Historical proforma lines are immutable'); END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS proforma_items_no_insert_after_confirmation
      BEFORE INSERT ON proforma_items
      WHEN (SELECT status FROM proformas WHERE id = NEW.proforma_id) <> 'draft'
      BEGIN SELECT RAISE(ABORT, 'Historical proforma lines are immutable'); END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS order_items_no_delete_after_confirmation
      BEFORE DELETE ON order_items
      WHEN (SELECT status FROM orders WHERE id = OLD.order_id) <> 'draft'
      BEGIN SELECT RAISE(ABORT, 'Historical order lines are immutable'); END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS proforma_items_no_delete_after_confirmation
      BEFORE DELETE ON proforma_items
      WHEN (SELECT status FROM proformas WHERE id = OLD.proforma_id) <> 'draft'
      BEGIN SELECT RAISE(ABORT, 'Historical proforma lines are immutable'); END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS orders_no_delete_after_confirmation
      BEFORE DELETE ON orders
      WHEN OLD.status <> 'draft'
      BEGIN SELECT RAISE(ABORT, 'Historical orders are immutable'); END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS proformas_no_delete_after_confirmation
      BEFORE DELETE ON proformas
      WHEN OLD.status <> 'draft'
      BEGIN SELECT RAISE(ABORT, 'Historical proformas are immutable'); END
    ''');
  }

  Future<void> _createSupplierReturnTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS supplier_returns (
        id TEXT PRIMARY KEY NOT NULL,
        reference TEXT NOT NULL UNIQUE,
        supplier_id TEXT NOT NULL,
        purchase_id TEXT NOT NULL,
        return_date TEXT NOT NULL,
        total_amount REAL NOT NULL CHECK(total_amount > 0),
        status TEXT NOT NULL DEFAULT 'confirmed',
        notes TEXT,
        created_by TEXT NOT NULL,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        FOREIGN KEY (supplier_id) REFERENCES suppliers(id),
        FOREIGN KEY (purchase_id) REFERENCES purchases(id)
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS supplier_return_items (
        id TEXT PRIMARY KEY NOT NULL,
        return_id TEXT NOT NULL,
        purchase_item_id TEXT NOT NULL,
        product_id TEXT NOT NULL,
        quantity REAL NOT NULL CHECK(quantity > 0),
        unit_price REAL NOT NULL CHECK(unit_price >= 0),
        line_total REAL NOT NULL,
        created_at TEXT NOT NULL,
        FOREIGN KEY (return_id) REFERENCES supplier_returns(id) ON DELETE CASCADE,
        FOREIGN KEY (purchase_item_id) REFERENCES purchase_items(id),
        FOREIGN KEY (product_id) REFERENCES products(id)
      )
    ''');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_supplier_returns_supplier ON supplier_returns(supplier_id)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_supplier_returns_date ON supplier_returns(return_date DESC)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_supplier_returns_purchase ON supplier_returns(purchase_id)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_supplier_returns_reference ON supplier_returns(reference)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_supplier_return_items_purchase_item ON supplier_return_items(purchase_item_id)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_supplier_return_items_product ON supplier_return_items(product_id)');
  }

  Future<void> _createErpTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS customers (
        id TEXT PRIMARY KEY,
        code TEXT NOT NULL UNIQUE,
        name TEXT NOT NULL,
        registration_name TEXT,
        activity TEXT DEFAULT 'Retail',
        category TEXT DEFAULT 'General',
        address TEXT,
        phone TEXT,
        mobile TEXT,
        email TEXT,
        tax_number TEXT,
        registration_number TEXT,
        customer_reference TEXT,
        commercial_register TEXT,
        tax_id TEXT,
        nis TEXT,
        ai TEXT,
        credit_limit REAL NOT NULL DEFAULT 0.0,
        opening_balance REAL NOT NULL DEFAULT 0.0,
        notes TEXT,
        current_balance REAL NOT NULL DEFAULT 0.0,
        is_active INTEGER NOT NULL DEFAULT 1,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS suppliers (
        id TEXT PRIMARY KEY,
        code TEXT NOT NULL UNIQUE,
        name TEXT NOT NULL,
        registration_name TEXT,
        activity TEXT DEFAULT 'Retail',
        address TEXT,
        phone TEXT,
        mobile TEXT,
        email TEXT,
        tax_number TEXT,
        registration_number TEXT,
        supplier_reference TEXT,
        contact_person TEXT,
        commercial_register TEXT,
        tax_id TEXT,
        nis TEXT,
        ai TEXT,
        bank_name TEXT,
        bank_account TEXT,
        currency TEXT DEFAULT 'DZD',
        credit_limit REAL NOT NULL DEFAULT 0.0,
        opening_balance REAL NOT NULL DEFAULT 0.0,
        notes TEXT,
        current_balance REAL NOT NULL DEFAULT 0.0,
        is_active INTEGER NOT NULL DEFAULT 1,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS customer_ledger (
        id TEXT PRIMARY KEY,
        customer_id TEXT NOT NULL,
        entry_type TEXT NOT NULL,
        amount REAL NOT NULL,
        balance_after REAL NOT NULL,
        reference_type TEXT,
        reference_id TEXT,
        notes TEXT,
        created_at TEXT NOT NULL,
        FOREIGN KEY (customer_id) REFERENCES customers(id)
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS supplier_ledger (
        id TEXT PRIMARY KEY,
        supplier_id TEXT NOT NULL,
        entry_type TEXT NOT NULL,
        amount REAL NOT NULL,
        balance_after REAL NOT NULL,
        reference_type TEXT,
        reference_id TEXT,
        notes TEXT,
        created_at TEXT NOT NULL,
        FOREIGN KEY (supplier_id) REFERENCES suppliers(id)
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS stock_movements (
        id TEXT PRIMARY KEY,
        product_id TEXT NOT NULL,
        product_barcode TEXT,
        product_name TEXT NOT NULL,
        movement_type TEXT NOT NULL,
        quantity_change REAL NOT NULL,
        unit_cost REAL DEFAULT 0.0,
        running_stock REAL NOT NULL,
        reference_type TEXT,
        reference_id TEXT,
        lineage_id TEXT,
        notes TEXT,
        user_id TEXT,
        created_at TEXT NOT NULL,
        FOREIGN KEY (product_id) REFERENCES products(id)
        ,CHECK (quantity_change <> 0)
        ,CHECK (unit_cost >= 0)
      )
    ''');
    await _createStockMovementIntegrityTriggers(db);

    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_customers_name ON customers(name COLLATE NOCASE)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_suppliers_name ON suppliers(name COLLATE NOCASE)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_customer_ledger_customer_id ON customer_ledger(customer_id, created_at DESC)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_supplier_ledger_supplier_id ON supplier_ledger(supplier_id, created_at DESC)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_stock_movements_product_id ON stock_movements(product_id, created_at DESC)');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_stock_movements_lineage_id '
      'ON stock_movements(lineage_id)',
    );
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_customers_code ON customers(code)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_suppliers_code ON suppliers(code)');
  }

  Future<void> _ensureErpLegacyColumns(Database db) async {
    final customerAdds = <String, String>{
      'code': 'TEXT',
      'registration_name': 'TEXT',
      'activity': "TEXT DEFAULT 'Retail'",
      'category': "TEXT DEFAULT 'General'",
      'mobile': 'TEXT',
      'tax_number': 'TEXT',
      'registration_number': 'TEXT',
      'credit_limit': 'REAL DEFAULT 0.0',
      'opening_balance': 'REAL DEFAULT 0.0',
      'notes': 'TEXT',
      'customer_reference': 'TEXT',
      'commercial_register': 'TEXT',
      'tax_id': 'TEXT',
      'nis': 'TEXT',
      'ai': 'TEXT',
    };
    for (final entry in customerAdds.entries) {
      try {
        await db.execute(
            'ALTER TABLE customers ADD COLUMN ${entry.key} ${entry.value}');
      } catch (e) {
        if (!e.toString().contains('duplicate column name')) {
          print('Customer legacy column issue ${entry.key}: $e');
        }
      }
    }

    final supplierAdds = <String, String>{
      'code': 'TEXT',
      'registration_name': 'TEXT',
      'activity': "TEXT DEFAULT 'Retail'",
      'mobile': 'TEXT',
      'tax_number': 'TEXT',
      'registration_number': 'TEXT',
      'currency': "TEXT DEFAULT 'DZD'",
      'credit_limit': 'REAL DEFAULT 0.0',
      'opening_balance': 'REAL DEFAULT 0.0',
      'notes': 'TEXT',
      'supplier_reference': 'TEXT',
      'contact_person': 'TEXT',
      'commercial_register': 'TEXT',
      'tax_id': 'TEXT',
      'nis': 'TEXT',
      'ai': 'TEXT',
      'bank_name': 'TEXT',
      'bank_account': 'TEXT',
    };
    for (final entry in supplierAdds.entries) {
      try {
        await db.execute(
            'ALTER TABLE suppliers ADD COLUMN ${entry.key} ${entry.value}');
      } catch (e) {
        if (!e.toString().contains('duplicate column name')) {
          print('Supplier legacy column issue ${entry.key}: $e');
        }
      }
    }
  }

  Future<void> _ensureMasterDataColumns(Database db) async {
    await _ensureErpLegacyColumns(db);
  }

  Future<void> _createProductIndexes(Database db) async {
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_products_barcode ON products(barcode)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_products_category_id '
      'ON products(category_id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_products_active '
      'ON products(is_active, category_id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_products_low_stock '
      'ON products(stock, min_stock) WHERE stock <= min_stock',
    );
    await db.execute(
      'CREATE UNIQUE INDEX IF NOT EXISTS '
      'idx_products_active_normalized_barcode '
      'ON products(trim(barcode)) '
      "WHERE is_active = 1 AND barcode IS NOT NULL AND trim(barcode) <> ''",
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_products_active_name '
      'ON products(is_active, name COLLATE NOCASE, id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_products_category_active_name '
      'ON products(category_id, is_active, name COLLATE NOCASE, id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_products_stock '
      'ON products(is_active, stock, min_stock)',
    );
  }

  Future<void> _migrateProductBarcodeUniqueness(Database db) async {
    final tableRows = await db.rawQuery(
      "SELECT sql FROM sqlite_master "
      "WHERE type = 'table' AND name = 'products'",
    );
    if (tableRows.isEmpty) return;

    final createSql = tableRows.single['sql'] as String?;
    if (createSql == null) {
      throw StateError('Unable to read the products table definition');
    }

    final temporaryTable = 'products_barcode_migration_v35';
    final temporaryTableRows = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
      [temporaryTable],
    );
    if (temporaryTableRows.isNotEmpty) {
      throw StateError('Temporary product migration table already exists');
    }

    final renamedCreateSql = createSql.replaceFirst(
      RegExp(
        r'CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?products\b',
        caseSensitive: false,
      ),
      'CREATE TABLE $temporaryTable',
    );
    if (renamedCreateSql == createSql) {
      throw StateError('Unable to prepare the products table migration');
    }
    final migratedCreateSql = renamedCreateSql.replaceFirstMapped(
      RegExp(r'(\bbarcode\s+TEXT)\s+UNIQUE\b', caseSensitive: false),
      (match) => match.group(1)!,
    );
    final rebuildTable = migratedCreateSql != renamedCreateSql;
    if (rebuildTable) {
      final columns = await db.rawQuery('PRAGMA table_info(products)');
      if (columns.isEmpty) {
        throw StateError('Unable to read the products table columns');
      }
      final columnList =
          columns.map((column) => '"${column['name']}"').join(', ');

      // Keep product foreign keys deferred while replacing the parent table.
      await db.execute('PRAGMA defer_foreign_keys = ON');
      await db.execute(
        'DROP TRIGGER IF EXISTS product_units_barcode_legacy_collision_insert',
      );
      await db.execute(
        'DROP TRIGGER IF EXISTS product_units_barcode_legacy_collision_update',
      );
      await db.execute(migratedCreateSql);
      await db.execute(
        'INSERT INTO $temporaryTable ($columnList) '
        'SELECT $columnList FROM products',
      );
      await db.execute('DROP TABLE products');
      await db.execute('ALTER TABLE $temporaryTable RENAME TO products');

      final foreignKeyViolations = await db.rawQuery(
        'PRAGMA foreign_key_check',
      );
      if (foreignKeyViolations.isNotEmpty) {
        throw StateError(
          'Product barcode migration found invalid foreign key references',
        );
      }
      await db.execute('PRAGMA defer_foreign_keys = OFF');
      await _createProductUnitBarcodeCollisionTriggers(db);
    }

    final indexes = await db.rawQuery('PRAGMA index_list(products)');
    for (final index in indexes.where((row) => row['unique'] == 1)) {
      final indexName = index['name'] as String;
      final indexColumns = await db.rawQuery(
        'PRAGMA index_info("$indexName")',
      );
      if (indexColumns.length == 1 &&
          indexColumns.single['name'] == 'barcode' &&
          index['origin'] != 'u') {
        await db.execute('DROP INDEX "$indexName"');
      }
    }

    final remainingBarcodeConstraints = await db.rawQuery(
      'PRAGMA index_list(products)',
    );
    for (final index
        in remainingBarcodeConstraints.where((row) => row['unique'] == 1)) {
      final indexColumns = await db.rawQuery(
        'PRAGMA index_info("${index['name']}")',
      );
      if (indexColumns.length == 1 &&
          indexColumns.single['name'] == 'barcode') {
        throw StateError(
          'Unable to remove the legacy unique product barcode constraint',
        );
      }
    }

    await _createProductIndexes(db);
    await db.execute(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_products_internal_reference '
      'ON products(internal_reference)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_products_type_active '
      'ON products(product_type)',
    );
  }

  Future<void> _createOpeningStockTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS opening_stock_documents (
        id TEXT PRIMARY KEY NOT NULL,
        reference_number TEXT NOT NULL UNIQUE,
        status TEXT NOT NULL DEFAULT 'posted' CHECK(status = 'posted'),
        opening_date TEXT NOT NULL,
        reason TEXT NOT NULL,
        notes TEXT,
        posted_at TEXT NOT NULL,
        posted_by TEXT NOT NULL,
        created_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS opening_stock_lines (
        id TEXT PRIMARY KEY NOT NULL,
        document_id TEXT NOT NULL,
        product_id TEXT NOT NULL,
        product_barcode TEXT,
        product_name TEXT NOT NULL,
        quantity REAL NOT NULL CHECK(quantity > 0),
        unit_cost REAL NOT NULL DEFAULT 0 CHECK(unit_cost >= 0),
        line_total REAL NOT NULL DEFAULT 0 CHECK(line_total >= 0),
        created_at TEXT NOT NULL,
        FOREIGN KEY (document_id) REFERENCES opening_stock_documents(id)
          ON DELETE CASCADE,
        FOREIGN KEY (product_id) REFERENCES products(id),
        UNIQUE (document_id, product_id)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_opening_stock_documents_posted_at '
      'ON opening_stock_documents(posted_at DESC)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_opening_stock_lines_document '
      'ON opening_stock_lines(document_id, created_at ASC)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_opening_stock_lines_product '
      'ON opening_stock_lines(product_id, created_at DESC)',
    );
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS opening_stock_documents_no_update
      BEFORE UPDATE ON opening_stock_documents
      BEGIN SELECT RAISE(ABORT, 'Posted opening stock is immutable'); END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS opening_stock_documents_no_delete
      BEFORE DELETE ON opening_stock_documents
      BEGIN SELECT RAISE(ABORT, 'Posted opening stock cannot be deleted'); END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS opening_stock_lines_no_update
      BEFORE UPDATE ON opening_stock_lines
      BEGIN SELECT RAISE(ABORT, 'Posted opening stock lines are immutable'); END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS opening_stock_lines_no_delete
      BEFORE DELETE ON opening_stock_lines
      BEGIN SELECT RAISE(ABORT, 'Posted opening stock lines cannot be deleted'); END
    ''');
  }

  Future<void> _createStockAdjustmentTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS stock_adjustment_documents (
        id TEXT PRIMARY KEY NOT NULL,
        reference_number TEXT NOT NULL UNIQUE,
        idempotency_key TEXT NOT NULL UNIQUE,
        status TEXT NOT NULL DEFAULT 'posted' CHECK(status = 'posted'),
        adjustment_date TEXT NOT NULL,
        reason TEXT NOT NULL,
        notes TEXT,
        posted_at TEXT NOT NULL,
        posted_by TEXT NOT NULL,
        created_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS stock_adjustment_items (
        id TEXT PRIMARY KEY NOT NULL,
        document_id TEXT NOT NULL,
        product_id TEXT NOT NULL,
        product_barcode TEXT,
        product_name TEXT NOT NULL,
        current_quantity REAL NOT NULL CHECK(current_quantity >= 0),
        counted_quantity REAL NOT NULL CHECK(counted_quantity >= 0),
        delta REAL NOT NULL CHECK(delta <> 0),
        quantity_change REAL NOT NULL CHECK(quantity_change <> 0),
        unit_cost REAL NOT NULL DEFAULT 0 CHECK(unit_cost >= 0),
        line_total REAL NOT NULL DEFAULT 0 CHECK(line_total >= 0),
        created_at TEXT NOT NULL,
        FOREIGN KEY (document_id) REFERENCES stock_adjustment_documents(id)
          ON DELETE CASCADE,
        FOREIGN KEY (product_id) REFERENCES products(id),
        UNIQUE (document_id, product_id)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_stock_adjustment_documents_posted_at '
      'ON stock_adjustment_documents(posted_at DESC)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_stock_adjustment_items_document '
      'ON stock_adjustment_items(document_id, created_at ASC)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_stock_adjustment_items_product '
      'ON stock_adjustment_items(product_id, created_at DESC)',
    );
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS stock_adjustment_documents_no_update
      BEFORE UPDATE ON stock_adjustment_documents
      BEGIN SELECT RAISE(ABORT, 'Posted stock adjustments are immutable'); END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS stock_adjustment_documents_no_delete
      BEFORE DELETE ON stock_adjustment_documents
      BEGIN SELECT RAISE(ABORT, 'Posted stock adjustments cannot be deleted'); END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS stock_adjustment_items_no_update
      BEFORE UPDATE ON stock_adjustment_items
      BEGIN SELECT RAISE(ABORT, 'Posted stock adjustment items are immutable'); END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS stock_adjustment_items_no_delete
      BEFORE DELETE ON stock_adjustment_items
      BEGIN SELECT RAISE(ABORT, 'Posted stock adjustment items cannot be deleted'); END
    ''');
  }

  Database get database {
    if (_database == null) {
      throw StateError('Database not initialized');
    }
    return _database!;
  }

  Future<List<Map<String, dynamic>>> query(
    String table, {
    bool? distinct,
    List<String>? columns,
    String? where,
    List<Object?>? whereArgs,
    String? groupBy,
    String? having,
    String? orderBy,
    int? limit,
    int? offset,
  }) async {
    final stopwatch = Stopwatch()..start();
    final effectiveOrderBy = orderBy ??
        (table == 'stock_movements' ? 'created_at ASC, rowid ASC' : null);
    final results = await database.query(
      table,
      distinct: distinct,
      columns: columns,
      where: where,
      whereArgs: whereArgs,
      groupBy: groupBy,
      having: having,
      orderBy: effectiveOrderBy,
      limit: limit,
      offset: offset,
    );
    print(
        '🔍 SQL SELECT from $table | Count: ${results.length} | Time: ${stopwatch.elapsedMilliseconds}ms');
    // Optional: verbose log for small results?
    // if (results.length < 5) print('   Results: $results');
    return results;
  }

  Future<int> insert(
    String table,
    Map<String, dynamic> values, {
    ConflictAlgorithm? conflictAlgorithm,
  }) async {
    print('📝 SQL INSERT into $table | Data: $values');
    return database.insert(
      table,
      values,
      conflictAlgorithm: conflictAlgorithm,
    );
  }

  Future<int> update(
    String table,
    Map<String, dynamic> values, {
    String? where,
    List<Object?>? whereArgs,
  }) async {
    print(
        '📝 SQL UPDATE $table | Where: $where | Args: $whereArgs | Data: $values');
    return database.update(
      table,
      values,
      where: where,
      whereArgs: whereArgs,
    );
  }

  Future<int> delete(
    String table, {
    String? where,
    List<Object?>? whereArgs,
  }) async {
    print('🗑️ SQL DELETE from $table | Where: $where | Args: $whereArgs');
    return database.delete(
      table,
      where: where,
      whereArgs: whereArgs,
    );
  }

  Future<void> execute(String sql, [List<Object?>? arguments]) async {
    print('⚙️ SQL EXECUTE: $sql | Args: $arguments');
    await database.execute(sql, arguments);
  }

  Future<List<Map<String, dynamic>>> rawQuery(
    String sql, [
    List<Object?>? arguments,
  ]) async {
    return database.rawQuery(sql, arguments);
  }

  Future<T> transaction<T>(Future<T> Function(Transaction txn) action) async {
    print('🔄 SQL TRANSACTION START');
    try {
      final result = await database.transaction(action);
      print('✅ SQL TRANSACTION COMMIT');
      return result;
    } catch (e) {
      print('❌ SQL TRANSACTION ROLLBACK: $e');
      rethrow;
    }
  }

  Future<bool> checkIntegrity() async {
    final result = await database.rawQuery('PRAGMA integrity_check');
    return result.isNotEmpty && result.first.values.first == 'ok';
  }

  Future<void> checkpoint() async {
    await database.execute('PRAGMA wal_checkpoint(FULL)');
  }

  Future<void> close() async {
    await checkpoint();
    await _database?.close();
    _database = null;
  }
}
