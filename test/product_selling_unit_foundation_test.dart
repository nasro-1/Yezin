import 'dart:io';

import 'package:bayaa_pos/core/data/services/sqlite_manager.dart';
import 'package:bayaa_pos/features/products/data/models/product_model.dart';
import 'package:bayaa_pos/features/products/data/models/selling_unit_model.dart';
import 'package:bayaa_pos/features/products/domain/product_catalog_service.dart';
import 'package:bayaa_pos/features/stock/data/models/stock_movement_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _SellingUnitInput {
  const _SellingUnitInput({
    required this.name,
    required this.conversionToBase,
    required this.cost,
    required this.sellingPrice,
    required this.wholesale,
    required this.barcode,
    required this.isDefault,
  });

  final String name;
  final double conversionToBase;
  final double cost;
  final double sellingPrice;
  final double wholesale;
  final String barcode;
  final bool isDefault;
}

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  group('Product domain and selling-unit foundation', () {
    late SQLiteManager manager;
    late ProductCatalogRepository productRepository;
    late SellingUnitRepository sellingUnitRepository;
    late BarcodeLookupService barcodeLookupService;

    test('maps server selling units without losing persisted fields', () {
      final product = Product.fromMap({
        'id': 'product-1',
        'name': 'Packaged product',
        'product_type': 'PACKAGED',
        'price': 30,
        'min_price': 20,
        'wholesale_price': 25,
        'stock': 90,
        'min_stock': 1,
        'category_id': 'category-1',
        'selling_units': [
          {
            'id': 'unit-piece',
            'product_id': 'product-1',
            'name': 'piece',
            'conversion_to_base': 1,
            'cost_price': 10,
            'selling_price': 30,
            'wholesale_price': 25,
            'barcode': 'piece-001',
            'icon_key': 'package',
            'is_default': true,
            'is_active': true,
          },
          {
            'id': 'unit-pack',
            'product_id': 'product-1',
            'name': 'pack',
            'conversion_to_base': 30,
            'cost_price': 200,
            'selling_price': 240,
            'wholesale_price': 220,
            'barcode': 'pack-001',
            'icon_key': 'pack',
            'is_default': false,
            'is_active': true,
          },
        ],
      });

      expect(product.sellingUnits.map((unit) => unit.id), [
        'unit-piece',
        'unit-pack',
      ]);
      expect(product.sellingUnits[1].conversionToBase, 30);
      expect(product.sellingUnits[1].cost, 200);
      expect(product.sellingUnits[1].sellingPrice, 240);
      expect(product.sellingUnits[1].wholesalePrice, 220);
      expect(product.sellingUnits[1].iconKey, 'pack');
    });

    test('converts selling-unit minimum stock thresholds to base units', () {
      final product = Product.fromMap({
        'id': 'product-thresholds',
        'name': 'Threshold product',
        'product_type': 'PACKAGED',
        'stock': 29,
        'min_stock': 0,
        'selling_units': [
          {
            'id': 'unit-pack',
            'product_id': 'product-thresholds',
            'name': 'pack',
            'conversion_to_base': 6,
            'minimum_stock': 5,
            'is_active': true,
          },
          {
            'id': 'unit-box',
            'product_id': 'product-thresholds',
            'name': 'box',
            'conversion_to_base': 24,
            'minimum_stock': 2,
            'is_active': true,
          },
        ],
      });

      expect(product.effectiveMinimumStock, 48);
      expect(product.status, 'lowStock');
    });

    test('uses the highest converted threshold as one product low-stock rule',
        () {
      final product = Product.fromMap({
        'id': 'product-max-threshold',
        'name': 'Max threshold product',
        'product_type': 'PACKAGED',
        'stock': 40,
        'min_stock': 10,
        'selling_units': [
          {
            'id': 'unit-piece',
            'product_id': 'product-max-threshold',
            'name': 'piece',
            'conversion_to_base': 1,
            'minimum_stock': 10,
            'is_active': true,
          },
          {
            'id': 'unit-pack',
            'product_id': 'product-max-threshold',
            'name': 'pack',
            'conversion_to_base': 6,
            'minimum_stock': 5,
            'is_active': true,
          },
          {
            'id': 'unit-box',
            'product_id': 'product-max-threshold',
            'name': 'box',
            'conversion_to_base': 24,
            'minimum_stock': 2,
            'is_active': true,
          },
        ],
      });

      expect(product.effectiveMinimumStock, 48);
      expect(product.status, 'lowStock');
      expect(product.quantityWithBaseUnit, '40 piece');
    });

    test('missing selling-unit minimum stock remains backward compatible', () {
      final product = Product.fromMap({
        'id': 'product-legacy-threshold',
        'name': 'Legacy product',
        'product_type': 'PACKAGED',
        'stock': 9,
        'min_stock': 10,
        'selling_units': [
          {
            'id': 'unit-pack',
            'product_id': 'product-legacy-threshold',
            'name': 'pack',
            'conversion_to_base': 6,
            'is_active': true,
          },
        ],
      });

      expect(product.effectiveMinimumStock, 10);
      expect(product.status, 'lowStock');
    });

    test('maps server stock movement history fields', () {
      final movement = StockMovement.fromMap({
        'id': 'movement-1',
        'product_id': 'product-1',
        'product_barcode': 'P-1',
        'product_name': 'Packaged product',
        'movement_type': 'stock_adjustment',
        'quantity_change': 6,
        'unit_cost': 50,
        'running_stock': 8,
        'reference_type': 'stock_adjustment',
        'reference_id': 'adjustment-1',
        'source_description': 'Adjustment ADJ-2026-000005',
        'notes': 'Physical count',
        'user_id': 'user-1',
        'created_at': '2026-09-19T10:00:00.000',
      });

      expect(movement.productId, 'product-1');
      expect(movement.quantityChange, 6);
      expect(movement.runningStock, 8);
      expect(movement.sourceDescription, 'Adjustment ADJ-2026-000005');
    });

    setUp(() async {
      final dbPath =
          'product_domain_${DateTime.now().microsecondsSinceEpoch}.sqlite';
      manager = SQLiteManager(databasePath: dbPath);
      await manager.initialize();
      final sellingUnitColumns = await manager.database
          .rawQuery('PRAGMA table_info(product_selling_units)');
      expect(
        sellingUnitColumns.map((column) => column['name']),
        containsAll(<String>[
          'id',
          'product_id',
          'name',
          'conversion_to_base',
          'selling_price',
          'cost_price',
          'wholesale_price',
          'barcode',
          'is_default',
          'is_active',
          'created_at',
          'updated_at',
        ]),
      );
      await manager.insert('categories', {
        'id': 'General',
        'name': 'General',
        'color': '#000000',
        'sort_order': 0,
      });
      productRepository = ProductCatalogRepository(manager);
      sellingUnitRepository = SellingUnitRepository(manager);
      barcodeLookupService =
          BarcodeLookupService(productRepository, sellingUnitRepository);
    });

    tearDown(() async {
      await manager.close();
      for (final suffix in ['', '-wal', '-shm']) {
        final file = File('${manager.databasePath}$suffix');
        if (file.existsSync()) {
          file.deleteSync();
        }
      }
    });

    test('STANDARD product metadata uses base unit piece and default precision',
        () async {
      final product = await productRepository.createProduct(
        name: 'Notebook',
        barcode: 'STD-001',
        price: 25.0,
        productType: ProductType.standard,
        baseUnit: 'piece',
        quantityPrecision: 3,
      );

      expect(product.productType, ProductType.standard);
      expect(product.baseUnit, 'piece');
      expect(product.quantityPrecision, 3);
      expect(product.internalReference, isNotNull);
      expect(product.internalReference, startsWith('PRD-'));
    });

    test('WEIGHTED product keeps decimal quantity precision without truncation',
        () async {
      final product = await productRepository.createProduct(
        name: 'Potato',
        barcode: 'WT-001',
        price: 300.0,
        productType: ProductType.weighted,
        baseUnit: 'kg',
        quantityPrecision: 3,
      );

      expect(product.productType, ProductType.weighted);
      expect(product.baseUnit, 'kg');
      expect(product.quantityPrecision, 3);
      expect(product.allowPartialPackageSale, isFalse);
    });

    test('PACKAGED product allows three selling units and a default unit',
        () async {
      final product = await productRepository.createProduct(
        name: 'Coca-Cola',
        barcode: 'CC-001',
        price: 500.0,
        productType: ProductType.packaged,
        baseUnit: 'bottle',
        allowPartialPackageSale: true,
      );

      await sellingUnitRepository.create(
        productId: product.id,
        name: 'Bottle',
        conversionToBase: 1,
        cost: 30,
        sellingPrice: 500,
        barcode: 'A',
        isDefault: true,
      );
      await Future<void>.delayed(const Duration(milliseconds: 1));
      await sellingUnitRepository.create(
        productId: product.id,
        name: 'Pack',
        conversionToBase: 6,
        cost: 200,
        sellingPrice: 2400,
        barcode: 'B',
      );
      await Future<void>.delayed(const Duration(milliseconds: 1));
      await sellingUnitRepository.create(
        productId: product.id,
        name: 'Carton',
        conversionToBase: 12,
        cost: 400,
        sellingPrice: 4500,
        barcode: 'C',
      );

      final units = await sellingUnitRepository.listByProduct(product.id);
      expect(units, hasLength(3));
      expect(units.where((unit) => unit.isDefault).length, 1);
      expect((await sellingUnitRepository.findDefaultUnit(product.id))?.name,
          'Bottle');
      final costs = {for (final unit in units) unit.name: unit.cost};
      expect(costs, {'Bottle': 30.0, 'Pack': 200.0, 'Carton': 400.0});

      final pack = units.singleWhere((unit) => unit.name == 'Pack');
      final quantityOnlyUpdate = await sellingUnitRepository.update(
        unit: pack,
        conversionToBase: 20,
      );
      expect(quantityOnlyUpdate.conversionToBase, 20.0);
      expect(quantityOnlyUpdate.cost, 200.0);
      expect(quantityOnlyUpdate.sellingPrice, 2400.0);
      expect(quantityOnlyUpdate.wholesalePrice, isNull);

      final costOnlyUpdate = await sellingUnitRepository.update(
        unit: quantityOnlyUpdate,
        cost: 210,
      );
      expect(costOnlyUpdate.conversionToBase, 20.0);
      expect(costOnlyUpdate.cost, 210.0);

      final priceOnlyUpdate = await sellingUnitRepository.update(
        unit: costOnlyUpdate,
        sellingPrice: 2500,
      );
      expect(priceOnlyUpdate.conversionToBase, 20.0);
      expect(priceOnlyUpdate.cost, 210.0);
      expect(priceOnlyUpdate.sellingPrice, 2500.0);
      final packRow = (await manager.query(
        'product_selling_units',
        where: 'id = ?',
        whereArgs: [pack.id],
      ))
          .single;
      expect((packRow['conversion_to_base'] as num).toDouble(), 20.0);
      expect((packRow['cost_price'] as num).toDouble(), 210.0);
      expect((packRow['selling_price'] as num).toDouble(), 2500.0);
      expect(packRow['wholesale_price'], isNull);
    });

    test('PACKAGED units allow unknown cost and Piece omits wholesale',
        () async {
      final product = await productRepository.createProduct(
        name: 'Water',
        barcode: 'WATER-OPTIONAL-COST',
        price: 0,
        productType: ProductType.packaged,
        baseUnit: 'piece',
      );

      await sellingUnitRepository.create(
        productId: product.id,
        name: 'Piece',
        conversionToBase: 1,
        sellingPrice: 50,
        cost: 30,
        isDefault: true,
      );
      await Future<void>.delayed(const Duration(milliseconds: 1));
      await sellingUnitRepository.create(
        productId: product.id,
        name: 'Pack',
        conversionToBase: 30,
        cost: 200,
        sellingPrice: 240,
        wholesalePrice: 220,
      );
      await Future<void>.delayed(const Duration(milliseconds: 1));
      await sellingUnitRepository.create(
        productId: product.id,
        name: 'Box',
        conversionToBase: 360,
        cost: 500,
        sellingPrice: 2400,
        wholesalePrice: 2200,
      );

      final units = await sellingUnitRepository.listByProduct(product.id);
      final piece = units.singleWhere((unit) => unit.name == 'Piece');
      final pack = units.singleWhere((unit) => unit.name == 'Pack');
      final box = units.singleWhere((unit) => unit.name == 'Box');
      expect(piece.cost, 30);
      expect(piece.wholesalePrice, isNull);
      expect(pack.cost, 200);
      expect(pack.wholesalePrice, 220);
      expect(box.cost, 500);
      expect(box.wholesalePrice, 2200);
    });

    test(
        'PACKAGED save path persists the product and all selling units in SQLite',
        () async {
      final categoryId = 'Invariant';
      await manager.insert(
          'categories',
          {
            'id': categoryId,
            'name': categoryId,
            'color': '#000000',
            'sort_order': 0,
          },
          conflictAlgorithm: ConflictAlgorithm.ignore);

      final product = await productRepository.createProduct(
        name: 'Eggs',
        barcode: 'PKG-EGGS',
        productType: ProductType.packaged,
        baseUnit: 'piece',
        quantityPrecision: 3,
        allowPartialPackageSale: true,
        price: 0,
        category: categoryId,
      );

      final productRows = await manager.query(
        'products',
        where: 'id = ?',
        whereArgs: [product.id],
      );
      expect(productRows, hasLength(1));
      expect(productRows.single['name'], 'Eggs');
      expect(productRows.single['product_type'], 'PACKAGED');
      expect(productRows.single['category_id'], categoryId);
      expect((productRows.single['price'] as num).toDouble(), 0.0);
      expect((productRows.single['min_price'] as num).toDouble(), 0.0);
      expect((productRows.single['wholesale_price'] as num).toDouble(), 0.0);

      final rows = <(_SellingUnitInput, bool)>[
        (
          _SellingUnitInput(
            name: 'Piece',
            conversionToBase: 1,
            cost: 30,
            sellingPrice: 40,
            wholesale: 35,
            barcode: '111111',
            isDefault: true,
          ),
          true
        ),
        (
          _SellingUnitInput(
            name: 'Pack',
            conversionToBase: 30,
            cost: 200,
            sellingPrice: 240,
            wholesale: 220,
            barcode: '222222',
            isDefault: false,
          ),
          false
        ),
        (
          _SellingUnitInput(
            name: 'Box',
            conversionToBase: 60,
            cost: 400,
            sellingPrice: 500,
            wholesale: 450,
            barcode: '333333',
            isDefault: false,
          ),
          false
        ),
      ];

      for (final row in rows) {
        final unit = await sellingUnitRepository.create(
          productId: product.id,
          name: row.$1.name,
          conversionToBase: row.$1.conversionToBase,
          cost: row.$1.cost,
          sellingPrice: row.$1.sellingPrice,
          wholesalePrice: row.$1.wholesale,
          barcode: row.$1.barcode,
          isDefault: row.$2,
        );
        expect(unit.productId, product.id);
        final persistedUnit = await manager.query(
          'product_selling_units',
          where: 'id = ?',
          whereArgs: [unit.id],
          limit: 1,
        );
        expect(persistedUnit, hasLength(1));
      }

      final unitRows = await manager.query(
        'product_selling_units',
        where: 'product_id = ?',
        whereArgs: [product.id],
      );
      expect(unitRows, hasLength(3));
      expect(
        unitRows.map((row) => row['id']).toSet(),
        hasLength(3),
      );
      expect(unitRows.map((row) => row['product_id']).toSet(), {product.id});
      final byName = {for (final row in unitRows) row['name'] as String: row};
      expect(byName['Piece']!['conversion_to_base'], 1.0);
      expect(byName['Pack']!['conversion_to_base'], 30.0);
      expect(byName['Box']!['conversion_to_base'], 60.0);
      expect((byName['Piece']!['cost_price'] as num).toDouble(), 30.0);
      expect((byName['Pack']!['cost_price'] as num).toDouble(), 200.0);
      expect((byName['Box']!['cost_price'] as num).toDouble(), 400.0);
      expect((byName['Piece']!['selling_price'] as num).toDouble(), 40.0);
      expect((byName['Pack']!['selling_price'] as num).toDouble(), 240.0);
      expect((byName['Box']!['selling_price'] as num).toDouble(), 500.0);
      expect((byName['Piece']!['wholesale_price'] as num).toDouble(), 35.0);
      expect((byName['Pack']!['wholesale_price'] as num).toDouble(), 220.0);
      expect((byName['Box']!['wholesale_price'] as num).toDouble(), 450.0);
    });

    test('PACKAGED selling units keep cost values through update round trips',
        () async {
      final product = await productRepository.createProduct(
        name: 'Eggs',
        barcode: 'EGGS-001',
        price: 0,
        productType: ProductType.packaged,
        baseUnit: 'piece',
      );

      final pack = await sellingUnitRepository.create(
        productId: product.id,
        name: 'Pack',
        conversionToBase: 6,
        cost: 50,
        sellingPrice: 70,
        wholesalePrice: 60,
        barcode: '222222',
        isDefault: true,
      );

      final persisted = await sellingUnitRepository.findById(pack.id);
      expect(persisted?.cost, 50.0);

      final updated = await sellingUnitRepository.update(
        unit: persisted!,
        conversionToBase: 20,
        cost: 200,
        sellingPrice: 240,
        wholesalePrice: 220,
      );

      expect(updated.conversionToBase, 20.0);
      expect(updated.cost, 200.0);
      expect(updated.sellingPrice, 240.0);
      expect(updated.wholesalePrice, 220.0);

      final reloaded = await sellingUnitRepository.findById(pack.id);
      expect(reloaded?.conversionToBase, 20.0);
      expect(reloaded?.cost, 200.0);
      expect(reloaded?.sellingPrice, 240.0);
      expect(reloaded?.wholesalePrice, 220.0);
    });

    test(
        'internal reference is generated uniquely and kept stable after rename',
        () async {
      final product = await productRepository.createProduct(
        name: 'Starter Product',
        barcode: 'IR-001',
        price: 40.0,
      );

      final secondReference =
          await productRepository.generateInternalReference();
      expect(secondReference, startsWith('PRD-'));
      expect(secondReference, isNot(product.internalReference));

      final renamed = product.copyWith(name: 'Updated Product Name');
      await productRepository.updateProduct(renamed);

      final reloaded = await productRepository.findById(product.id);
      expect(reloaded?.internalReference, product.internalReference);
      expect(reloaded?.name, 'Updated Product Name');
    });

    test(
        'selling unit validation rejects invalid conversion and negative pricing',
        () async {
      expect(
        () => SellingUnit(
          productId: 'p-1',
          name: 'Broken',
          conversionToBase: 0,
          sellingPrice: 10,
        ),
        throwsA(isA<ArgumentError>()),
      );

      expect(
        () => SellingUnit(
          productId: 'p-1',
          name: 'Negative',
          conversionToBase: 1,
          sellingPrice: -1,
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('default selling unit is enforced at one active default per product',
        () async {
      final product = await productRepository.createProduct(
        name: 'Tea',
        barcode: 'TEA-1',
        price: 10,
        productType: ProductType.packaged,
        baseUnit: 'bottle',
      );

      final first = await sellingUnitRepository.create(
        productId: product.id,
        name: 'Bottle',
        conversionToBase: 1,
        sellingPrice: 10,
        isDefault: true,
      );

      final second = await sellingUnitRepository.create(
        productId: product.id,
        name: 'Case',
        conversionToBase: 12,
        sellingPrice: 120,
        isDefault: true,
      );

      expect(first.isDefault, isTrue);
      expect(second.isDefault, isTrue);

      final defaults = (await sellingUnitRepository.listByProduct(product.id))
          .where((unit) => unit.isDefault)
          .toList();
      expect(defaults, hasLength(1));
      expect(defaults.first.id, second.id);
    });

    test(
        'barcode lookup resolves the single product barcode to its default unit',
        () async {
      final product = await productRepository.createProduct(
        name: 'Pepsi',
        barcode: 'LEGACY-BARCODE',
        price: 15,
      );
      final unit = await sellingUnitRepository.create(
        productId: product.id,
        name: 'Bottle',
        conversionToBase: 1,
        sellingPrice: 15,
        barcode: 'UNIT-PEPSI',
        isDefault: true,
      );

      expect(await barcodeLookupService.lookup('UNIT-PEPSI'), isNull);

      final legacyResult = await barcodeLookupService.lookup('LEGACY-BARCODE');
      expect(legacyResult?.product.id, product.id);
      expect(legacyResult?.sellingUnit?.id, unit.id);
    });

    test('selling-unit records do not participate in barcode lookup', () async {
      final product = await productRepository.createProduct(
        name: 'Duplicate Barcode',
        barcode: 'DUP-LEGACY',
        price: 5,
      );
      await sellingUnitRepository.create(
        productId: product.id,
        name: 'Bottle',
        conversionToBase: 1,
        sellingPrice: 5,
        barcode: 'DUP-UNIT',
        isDefault: true,
      );

      await manager.insert(
          'product_selling_units',
          {
            'id': 'dupe-unit-2',
            'product_id': product.id,
            'name': 'Pack',
            'conversion_to_base': 6.0,
            'selling_price': 30.0,
            'wholesale_price': 18.0,
            'barcode': 'DUP-UNIT',
            'is_default': 0,
            'is_active': 1,
            'created_at': DateTime.now().toIso8601String(),
            'updated_at': DateTime.now().toIso8601String(),
          },
          conflictAlgorithm: ConflictAlgorithm.ignore);

      expect(await barcodeLookupService.lookup('DUP-UNIT'), isNull);
    });

    test('legacy products resolve to piece base and default compatibility unit',
        () async {
      final product = await productRepository.createProduct(
        name: 'Legacy Item',
        barcode: 'LEGACY-ITEM',
        price: 99.0,
        baseUnit: 'piece',
      );

      final unit = await sellingUnitRepository.create(
        productId: product.id,
        name: 'piece',
        conversionToBase: 1,
        sellingPrice: 99,
        isDefault: true,
      );

      expect(product.baseUnit, 'piece');
      expect(unit.conversionToBase, 1.0);
      expect(unit.sellingPrice, 99.0);
    });

    test('partial package policy blocks implicit decomposition when disabled',
        () async {
      final product = await productRepository.createProduct(
        name: 'Bottle Pack',
        barcode: 'BPK-1',
        price: 100,
        productType: ProductType.packaged,
        baseUnit: 'bottle',
        allowPartialPackageSale: false,
      );
      final defaultUnit = await sellingUnitRepository.create(
        productId: product.id,
        name: 'Pack',
        conversionToBase: 6,
        sellingPrice: 600,
        isDefault: true,
      );
      final requested = await sellingUnitRepository.create(
        productId: product.id,
        name: 'Bottle',
        conversionToBase: 1,
        sellingPrice: 100,
      );

      expect(
          ProductSellingPolicyService.allowsPartialPackageSale(
              product, defaultUnit),
          isTrue);
      expect(
          ProductSellingPolicyService.allowsPartialPackageSale(
              product, requested),
          isFalse);
    });
  });
}
