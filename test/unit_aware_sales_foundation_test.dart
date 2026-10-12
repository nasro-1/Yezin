import 'dart:convert';
import 'dart:io';

import 'package:bayaa_pos/core/data/services/persistence_initializer.dart';
import 'package:bayaa_pos/core/di/dependency_injection.dart';
import 'package:bayaa_pos/core/session/session_manager.dart';
import 'package:bayaa_pos/features/auth/data/models/user_model.dart';
import 'package:bayaa_pos/features/sales/data/models/sale_model.dart';
import 'package:bayaa_pos/features/sales/data/repository/sales_repository_impl.dart';
import 'package:bayaa_pos/features/products/data/models/product_model.dart';
import 'package:bayaa_pos/features/products/data/models/selling_unit_model.dart';
import 'package:bayaa_pos/features/products/data/repository/product_repository_imp.dart';
import 'package:bayaa_pos/features/products/domain/product_catalog_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

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
      'sales_unit_test_${DateTime.now().microsecondsSinceEpoch}',
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
    'assets',
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

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  group('unit-aware sales foundation', () {
    setUp(() async {
      await _initializeIsolatedPersistence();
      final db = PersistenceInitializer.persistenceManager!.sqliteManager;
      await db.insert(
          'users',
          {
            'id': 'cashier-1',
            'username': 'cashier-1',
            'display_name': 'Cashier',
            'password_hash': 'pw',
            'role': 'cashier',
            'is_active': 1,
            'created_at': DateTime.now().toIso8601String(),
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
      await db.insert(
          'categories',
          {
            'id': 'sales-category',
            'name': 'Sales',
            'color': '#000000',
            'sort_order': 0,
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
      await db.insert(
          'shifts',
          {
            'id': 'shift-1',
            'user_id': 'cashier-1',
            'open_time': DateTime.now().toIso8601String(),
            'is_open': 1,
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
    });

    tearDown(() async {
      await PersistenceInitializer.persistenceManager?.shutdown();
    });

    tearDownAll(() async {
      await PersistenceInitializer.persistenceManager?.shutdown();
    });

    test('sale row stores selling-unit snapshot and posts base quantity',
        () async {
      final db = PersistenceInitializer.persistenceManager!.sqliteManager;
      await db.insert(
          'products',
          {
            'id': 'prod-unit-aware',
            'barcode': 'CC-UNIT',
            'name': 'Coca-Cola',
            'product_type': 'PACKAGED',
            'base_unit': 'bottle',
            'quantity_precision': 3,
            'allow_partial_package_sale': 1,
            'price': 500.0,
            'min_price': 0.0,
            'wholesale_price': 300.0,
            'stock': 30.0,
            'min_stock': 0.0,
            'category_id': 'sales-category',
            'is_active': 1,
            'created_at': DateTime.now().toIso8601String(),
            'updated_at': DateTime.now().toIso8601String(),
          },
          conflictAlgorithm: ConflictAlgorithm.replace);

      final salesRepository = SalesRepositoryImpl();
      final sale = Sale(
        id: 'sale-unit-aware',
        total: 2400,
        items: 1,
        date: DateTime.now(),
        cashierName: 'Cashier',
        cashierUsername: 'cashier-1',
        sessionId: 'shift-1',
        saleItems: [
          SaleItem(
            productId: 'prod-unit-aware',
            name: 'Coca-Cola',
            price: 2400,
            quantity: 1,
            total: 2400,
            wholesalePrice: 1200,
            sellingUnitId: 'unit-pack',
            sellingQuantity: 1,
            baseQuantity: 6,
            conversionFactorSnapshot: 6,
            sellingUnitNameSnapshot: 'Pack',
            baseUnitSnapshot: 'bottle',
          ),
        ],
      );

      final saveResult = await salesRepository.saveSale(sale);
      expect(saveResult.isRight(), isTrue);

      final saleItemRows = await db.query(
        'sale_items',
        where: 'sale_id = ?',
        whereArgs: ['sale-unit-aware'],
      );
      expect(saleItemRows, hasLength(1));
      expect((saleItemRows.single['selling_unit_id'] as String?), 'unit-pack');
      expect((saleItemRows.single['selling_quantity'] as num).toDouble(), 1.0);
      expect((saleItemRows.single['base_quantity'] as num).toDouble(), 6.0);
      expect(
        (saleItemRows.single['conversion_factor_snapshot'] as num).toDouble(),
        6.0,
      );
      expect(saleItemRows.single['selling_unit_name_snapshot'], 'Pack');
      expect(saleItemRows.single['base_unit_snapshot'], 'bottle');

      final productRow = await db.query(
        'products',
        where: 'id = ?',
        whereArgs: ['prod-unit-aware'],
      );
      expect((productRow.single['stock'] as num).toDouble(), 24.0);
    });

    test(
        'packaged piece and pack persist through save/reload/edit and sales never delete units',
        () async {
      final db = PersistenceInitializer.persistenceManager!.sqliteManager;
      final productId = 'prod-water-packaged';
      final piece = SellingUnit(
        id: 'unit-water-piece',
        productId: productId,
        name: 'Piece',
        conversionToBase: 1,
        cost: 200 / 30,
        sellingPrice: 8,
        wholesalePrice: 7.33,
        isDefault: true,
      );
      final pack = SellingUnit(
        id: 'unit-water-pack',
        productId: productId,
        name: 'Pack',
        conversionToBase: 30,
        cost: 200,
        sellingPrice: 240,
        wholesalePrice: 220,
      );
      final productRepository = ProductRepositoryImp();
      final product = Product(
        id: productId,
        name: 'Water',
        barcode: 'WATER-PACKAGED',
        productType: ProductType.packaged,
        baseUnit: 'piece',
        allowPartialPackageSale: true,
        price: 0,
        minPrice: 0,
        wholesalePrice: 0,
        category: 'sales-category',
        quantity: 300,
        minQuantity: 0,
      );
      final saveResult = await productRepository.saveProduct(
        product,
        packagedSellingUnits: [piece, pack],
      );
      expect(saveResult.isRight, isTrue);

      final unitRepository = SellingUnitRepository(
        PersistenceInitializer.persistenceManager!.sqliteManager,
      );
      var units = await unitRepository.listByProduct(productId);
      expect(units.map((unit) => unit.name),
          containsAll(<String>['Piece', 'Pack']));
      expect(units.singleWhere((unit) => unit.name == 'Piece').conversionToBase,
          1);
      expect(units.singleWhere((unit) => unit.name == 'Pack').conversionToBase,
          30);

      final editResult = await productRepository.saveProduct(
        product.copyWith(name: 'Water edited'),
        packagedSellingUnits: [
          units.singleWhere((unit) => unit.name == 'Piece'),
          units
              .singleWhere((unit) => unit.name == 'Pack')
              .copyWith(sellingPrice: 250),
        ],
      );
      expect(editResult.isRight, isTrue);
      units = await unitRepository.listByProduct(productId);
      expect(units.map((unit) => unit.name),
          containsAll(<String>['Piece', 'Pack']));
      final persistedPiece = units.singleWhere((unit) => unit.name == 'Piece');
      final persistedPack = units.singleWhere((unit) => unit.name == 'Pack');
      expect(persistedPiece.conversionToBase, 1);
      expect(persistedPiece.cost, closeTo(200 / 30, 1e-9));
      expect(persistedPiece.sellingPrice, 8);
      expect(persistedPiece.wholesalePrice, closeTo(7.33, 1e-9));
      expect(persistedPack.conversionToBase, 30);
      expect(persistedPack.cost, 200);
      expect(persistedPack.sellingPrice, 250);
      expect(persistedPack.wholesalePrice, 220);

      final sale = Sale(
        id: 'sale-water-piece',
        total: 8,
        items: 1,
        date: DateTime.now(),
        cashierName: 'Cashier',
        cashierUsername: 'cashier-1',
        sessionId: 'shift-1',
        saleItems: [
          SaleItem(
            productId: productId,
            name: 'Water',
            price: 8,
            quantity: 1,
            total: 8,
            wholesalePrice: 7.33,
            sellingUnitId: piece.id,
            sellingQuantity: 1,
            baseQuantity: 1,
            conversionFactorSnapshot: 1,
            sellingUnitNameSnapshot: 'Piece',
            baseUnitSnapshot: 'piece',
          ),
        ],
      );
      final saleResult = await SalesRepositoryImpl().saveSale(sale);
      expect(saleResult.isRight(), isTrue);

      final packSale = Sale(
        id: 'sale-water-pack',
        total: 240,
        items: 1,
        date: DateTime.now(),
        cashierName: 'Cashier',
        cashierUsername: 'cashier-1',
        sessionId: 'shift-1',
        saleItems: [
          SaleItem(
            productId: productId,
            name: 'Water',
            price: 240,
            quantity: 1,
            total: 240,
            wholesalePrice: 220,
            sellingUnitId: pack.id,
            sellingQuantity: 1,
            baseQuantity: 30,
            conversionFactorSnapshot: 30,
            sellingUnitNameSnapshot: 'Pack',
            baseUnitSnapshot: 'piece',
          ),
        ],
      );
      final packSaleResult = await SalesRepositoryImpl().saveSale(packSale);
      expect(packSaleResult.isRight(), isTrue);

      final productRow = (await db.query(
        'products',
        where: 'id = ?',
        whereArgs: [productId],
      ))
          .single;
      expect((productRow['stock'] as num).toDouble(), 269.0);

      final rows = await db.query(
        'product_selling_units',
        where: 'product_id = ?',
        whereArgs: [productId],
      );
      expect(rows, hasLength(2));
      expect(
        rows.map((row) => row['name']),
        containsAll(<String>['Piece', 'Pack']),
      );
      expect(
        (rows.singleWhere(
            (row) => row['name'] == 'Piece'))['conversion_to_base'],
        1.0,
      );
      expect(
        (rows
            .singleWhere((row) => row['name'] == 'Pack'))['conversion_to_base'],
        30.0,
      );
    });

    test(
        'packaged save preserves Pack default and repairs legacy zero-default units',
        () async {
      final repository = ProductRepositoryImp();
      final units = SellingUnitRepository(
        PersistenceInitializer.persistenceManager!.sqliteManager,
      );
      final product = Product(
        id: 'prod-packaged-default',
        name: 'Water',
        barcode: 'WATER-DEFAULT',
        productType: ProductType.packaged,
        baseUnit: 'piece',
        price: 0,
        minPrice: 0,
        wholesalePrice: 0,
        quantity: 0,
        minQuantity: 0,
        category: 'sales-category',
      );

      final pack = SellingUnit(
        id: 'unit-default-pack',
        productId: product.id,
        name: 'Pack',
        conversionToBase: 30,
        cost: 200,
        sellingPrice: 240,
        wholesalePrice: 220,
        isDefault: true,
      );
      final piece = SellingUnit(
        id: 'unit-default-piece',
        productId: product.id,
        name: 'Piece',
        conversionToBase: 1,
        cost: 30,
        sellingPrice: 50,
        wholesalePrice: 40,
        isDefault: false,
      );

      final saveResult = await repository.saveProduct(
        product,
        packagedSellingUnits: [pack, piece],
      );
      expect(saveResult.isRight, isTrue);

      var persisted = await units.listByProduct(product.id);
      expect(persisted.where((unit) => unit.isDefault), hasLength(1));
      expect(persisted.singleWhere((unit) => unit.name == 'Pack').isDefault,
          isTrue);
      expect(persisted.singleWhere((unit) => unit.name == 'Piece').isDefault,
          isFalse);

      final legacyResult = await repository.saveProduct(
        product,
        packagedSellingUnits: [
          pack.copyWith(isDefault: false),
          piece.copyWith(isDefault: false),
        ],
      );
      expect(legacyResult.isRight, isTrue);

      persisted = await units.listByProduct(product.id);
      expect(persisted.where((unit) => unit.isActive && unit.isDefault),
          hasLength(1));
      expect(persisted.singleWhere((unit) => unit.name == 'Pack').isDefault,
          isTrue);
      final persistedPiece =
          persisted.singleWhere((unit) => unit.name == 'Piece');
      expect(persistedPiece.isActive, isTrue);
      expect(persistedPiece.conversionToBase, 1);
      expect(persistedPiece.cost, 30);
      expect(persistedPiece.sellingPrice, 50);
      expect(persistedPiece.wholesalePrice, 40);
      final persistedPack =
          persisted.singleWhere((unit) => unit.name == 'Pack');
      expect(persistedPack.conversionToBase, 30);
      expect(persistedPack.cost, 200);
      expect(persistedPack.sellingPrice, 240);
      expect(persistedPack.wholesalePrice, 220);
    });

    test('new packaged product creation persists Piece and Pack', () async {
      final repository = ProductRepositoryImp();
      final productId = 'prod-packaged-creation';
      final product = Product(
        id: productId,
        name: 'Water',
        barcode: 'WATER-CREATION',
        productType: ProductType.packaged,
        baseUnit: 'piece',
        price: 0,
        minPrice: 0,
        wholesalePrice: 0,
        quantity: 0,
        minQuantity: 0,
        category: 'sales-category',
      );
      final saveResult = await repository.saveProductWithOpeningStock(
        product,
        openingQuantity: 0,
        openingUnitCost: 0,
        openingReason: 'Initial inventory',
        user: User(
          username: 'cashier-creation',
          name: 'Cashier',
          phone: '',
          userType: UserType.cashier,
          password: 'pw',
        ),
        packagedSellingUnits: [
          SellingUnit(
            id: 'unit-packaged-creation-piece',
            productId: productId,
            name: 'Piece',
            conversionToBase: 1,
            cost: 30,
            sellingPrice: 50,
            wholesalePrice: 40,
            isDefault: true,
          ),
          SellingUnit(
            id: 'unit-packaged-creation-pack',
            productId: productId,
            name: 'Pack',
            conversionToBase: 30,
            cost: 200,
            sellingPrice: 240,
            wholesalePrice: 220,
            isDefault: false,
          ),
        ],
      );

      expect(saveResult.isRight, isTrue);
      final persisted = await SellingUnitRepository(
        PersistenceInitializer.persistenceManager!.sqliteManager,
      ).listByProduct(productId, activeOnly: false);
      expect(persisted.map((unit) => unit.name),
          containsAll(<String>['Piece', 'Pack']));
      expect(persisted, hasLength(2));
      expect(persisted.singleWhere((unit) => unit.name == 'Piece').cost, 30);
      expect(persisted.singleWhere((unit) => unit.name == 'Piece').sellingPrice,
          50);
      expect(
          persisted.singleWhere((unit) => unit.name == 'Piece').wholesalePrice,
          40);
      expect(
          persisted.singleWhere((unit) => unit.name == 'Pack').conversionToBase,
          30);
    });

    test('legacy sale rows without selling-unit data remain compatible',
        () async {
      final db = PersistenceInitializer.persistenceManager!.sqliteManager;
      await db.insert(
          'products',
          {
            'id': 'prod-legacy',
            'barcode': 'LEGACY-SALE',
            'name': 'Notebook',
            'product_type': 'STANDARD',
            'base_unit': 'piece',
            'quantity_precision': 3,
            'allow_partial_package_sale': 0,
            'price': 25.0,
            'min_price': 0.0,
            'wholesale_price': 20.0,
            'stock': 10.0,
            'min_stock': 0.0,
            'category_id': 'sales-category',
            'is_active': 1,
            'created_at': DateTime.now().toIso8601String(),
            'updated_at': DateTime.now().toIso8601String(),
          },
          conflictAlgorithm: ConflictAlgorithm.replace);

      final repository = SalesRepositoryImpl();
      final sale = Sale(
        id: 'sale-legacy',
        total: 50,
        items: 1,
        date: DateTime.now(),
        cashierName: 'Cashier',
        cashierUsername: 'cashier-1',
        sessionId: 'shift-1',
        saleItems: [
          SaleItem(
            productId: 'prod-legacy',
            name: 'Notebook',
            price: 25,
            quantity: 2,
            total: 50,
            wholesalePrice: 20,
          ),
        ],
      );

      final saveResult = await repository.saveSale(sale);
      expect(saveResult.isRight(), isTrue);

      final itemRow = (await db.query(
        'sale_items',
        where: 'sale_id = ?',
        whereArgs: ['sale-legacy'],
      ))
          .single;
      expect(itemRow['selling_unit_id'], isNull);
      expect((itemRow['selling_quantity'] as num).toDouble(), 2.0);
      expect((itemRow['base_quantity'] as num).toDouble(), 2.0);
      expect(itemRow['conversion_factor_snapshot'], isNull);

      final productRow = await db.query(
        'products',
        where: 'id = ?',
        whereArgs: ['prod-legacy'],
      );
      expect((productRow.single['stock'] as num).toDouble(), 8.0);
    });
  });
}
