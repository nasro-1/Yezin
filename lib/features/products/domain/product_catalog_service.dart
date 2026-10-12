import 'package:bayaa_pos/core/data/services/document_number_service.dart';
import 'package:bayaa_pos/core/data/services/sqlite_manager.dart';
import 'package:bayaa_pos/features/products/data/models/product_model.dart';
import 'package:bayaa_pos/features/products/data/models/selling_unit_model.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class ProductCatalogRepository {
  final SQLiteManager sqliteManager;

  ProductCatalogRepository(this.sqliteManager);

  Future<Product> createProduct({
    String? id,
    required String name,
    String? barcode,
    String? internalReference,
    ProductType productType = ProductType.standard,
    String baseUnit = 'piece',
    int quantityPrecision = 3,
    bool allowPartialPackageSale = false,
    required double price,
    double minPrice = 0.0,
    double wholesalePrice = 0.0,
    double quantity = 0,
    int minQuantity = 0,
    String category = 'General',
    String? imagePath,
  }) async {
    final now = DateTime.now();
    final reference = internalReference ??
        await DocumentNumberService.next(
          sqliteManager.database,
          sequenceKey: 'product',
          prefix: 'PRD',
        );

    final product = Product(
      id: id ?? 'product-${now.microsecondsSinceEpoch}',
      name: name,
      internalReference: reference,
      productType: productType,
      baseUnit: baseUnit,
      quantityPrecision: quantityPrecision,
      allowPartialPackageSale: allowPartialPackageSale,
      price: price,
      minPrice: minPrice,
      wholesalePrice: wholesalePrice,
      quantity: quantity,
      minQuantity: minQuantity,
      category: category,
      barcode: barcode,
      imagePath: imagePath,
      isActive: true,
      createdAt: now,
      updatedAt: now,
    );

    await sqliteManager.database.insert(
      'products',
      product.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );

    return product;
  }

  Future<Product?> findById(String productId) async {
    final rows = await sqliteManager.database.query(
      'products',
      where: 'id = ?',
      whereArgs: [productId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return Product.fromMap(rows.first);
  }

  Future<Product?> findByBarcode(String barcode) async {
    final rows = await sqliteManager.database.query(
      'products',
      where: 'barcode = ?',
      whereArgs: [barcode],
    );
    if (rows.isEmpty) return null;
    if (rows.length > 1) {
      throw StateError(
          'Barcode collision detected for legacy product barcode: $barcode');
    }
    return Product.fromMap(rows.first);
  }

  Future<Product?> findByInternalReference(String reference) async {
    final rows = await sqliteManager.database.query(
      'products',
      where: 'internal_reference = ?',
      whereArgs: [reference],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return Product.fromMap(rows.first);
  }

  Future<String> generateInternalReference() async {
    return DocumentNumberService.next(
      sqliteManager.database,
      sequenceKey: 'product',
      prefix: 'PRD',
    );
  }

  Future<void> updateProduct(Product product) async {
    final now = DateTime.now();
    await sqliteManager.database.update(
      'products',
      product.copyWith(updatedAt: now).toMap(),
      where: 'id = ?',
      whereArgs: [product.id],
    );
  }
}

class SellingUnitRepository {
  final SQLiteManager sqliteManager;

  SellingUnitRepository(this.sqliteManager);

  Future<SellingUnit> create({
    required String productId,
    required String name,
    required double conversionToBase,
    required double sellingPrice,
    double cost = 0.0,
    double? wholesalePrice,
    double minimumStock = 0,
    String? barcode,
    String? iconKey,
    bool isDefault = false,
    bool isActive = true,
  }) async {
    final productRows = await sqliteManager.database.query(
      'products',
      where: 'id = ?',
      whereArgs: [productId],
      limit: 1,
    );
    if (productRows.isEmpty) {
      throw StateError(
          'Cannot create selling unit for missing product: $productId');
    }

    final unit = SellingUnit(
      productId: productId,
      name: name,
      conversionToBase: conversionToBase,
      sellingPrice: sellingPrice,
      cost: cost,
      wholesalePrice: wholesalePrice,
      minimumStock: minimumStock,
      iconKey: iconKey,
      barcode: barcode,
      isDefault: isDefault,
      isActive: isActive,
    );

    final existingName = await sqliteManager.database.query(
      'product_selling_units',
      where: 'product_id = ? AND name = ?',
      whereArgs: [productId, name],
      limit: 1,
    );
    if (existingName.isNotEmpty) {
      throw StateError(
          'Duplicate selling unit name for product $productId: $name');
    }
    final activeRows = await sqliteManager.database.query(
      'product_selling_units',
      where: 'product_id = ? AND is_active = 1',
      whereArgs: [productId],
    );
    final hasActiveDefault = activeRows.any((row) => row['is_default'] == 1);
    final finalDefault = isDefault || (activeRows.isEmpty && !hasActiveDefault);

    await sqliteManager.database.insert(
      'product_selling_units',
      unit
          .copyWith(
            isDefault: finalDefault,
            isActive: isActive,
            updatedAt: DateTime.now(),
          )
          .toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );

    if (finalDefault && activeRows.isNotEmpty) {
      await sqliteManager.database.update(
        'product_selling_units',
        {'is_default': 0, 'updated_at': DateTime.now().toIso8601String()},
        where:
            'product_id = ? AND is_active = 1 AND is_default = 1 AND id != ?',
        whereArgs: [productId, unit.id],
      );
    }

    return unit.copyWith(
      id: unit.id,
      isDefault: finalDefault,
      isActive: isActive,
      updatedAt: DateTime.now(),
    );
  }

  Future<SellingUnit?> findById(String unitId) async {
    final rows = await sqliteManager.database.query(
      'product_selling_units',
      where: 'id = ?',
      whereArgs: [unitId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return SellingUnit.fromMap(rows.first);
  }

  Future<SellingUnit?> findDefaultUnit(String productId) async {
    final rows = await sqliteManager.database.query(
      'product_selling_units',
      where: 'product_id = ? AND is_active = 1 AND is_default = 1',
      whereArgs: [productId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return SellingUnit.fromMap(rows.first);
  }

  Future<SellingUnit?> findByBarcode(String barcode) async {
    final rows = await sqliteManager.database.query(
      'product_selling_units',
      where: 'barcode = ?',
      whereArgs: [barcode],
      limit: 1,
    );
    return rows.isEmpty ? null : SellingUnit.fromMap(rows.first);
  }

  Future<List<SellingUnit>> listByProduct(String productId,
      {bool activeOnly = true}) async {
    final rows = await sqliteManager.database.query(
      'product_selling_units',
      where: activeOnly ? 'product_id = ? AND is_active = 1' : 'product_id = ?',
      whereArgs: [productId],
      orderBy: 'conversion_to_base ASC, name ASC',
    );
    return rows.map((row) => SellingUnit.fromMap(row)).toList();
  }

  Future<SellingUnit> update({
    required SellingUnit unit,
    String? name,
    double? conversionToBase,
    double? sellingPrice,
    double? cost,
    double? wholesalePrice,
    String? barcode,
    bool? isDefault,
    bool? isActive,
  }) async {
    final updated = unit.copyWith(
      name: name,
      conversionToBase: conversionToBase,
      sellingPrice: sellingPrice,
      cost: cost,
      wholesalePrice: wholesalePrice,
      barcode: barcode,
      isDefault: isDefault,
      isActive: isActive,
      updatedAt: DateTime.now(),
    );

    final activeUnits = await listByProduct(unit.productId, activeOnly: true);
    if (updated.isActive && updated.isDefault) {
      for (final candidate
          in activeUnits.where((row) => row.id != updated.id)) {
        await sqliteManager.database.update(
          'product_selling_units',
          {'is_default': 0, 'updated_at': DateTime.now().toIso8601String()},
          where: 'id = ?',
          whereArgs: [candidate.id],
        );
      }
    }

    if (!updated.isActive) {
      final remainingActive = activeUnits
          .where((row) => row.id != updated.id && row.isActive)
          .toList();
      if (remainingActive.isEmpty) {
        throw StateError(
            'A product must retain at least one active selling unit');
      }
      await sqliteManager.database.update(
        'product_selling_units',
        {
          'is_active': 0,
          'is_default': 0,
          'updated_at': DateTime.now().toIso8601String()
        },
        where: 'id = ?',
        whereArgs: [updated.id],
      );
      return updated;
    }

    await sqliteManager.database.update(
      'product_selling_units',
      updated.toMap(),
      where: 'id = ?',
      whereArgs: [updated.id],
    );
    return updated;
  }

  Future<void> deactivate(String unitId) async {
    final unit = await findById(unitId);
    if (unit == null) return;

    final activeUnits = await listByProduct(unit.productId, activeOnly: true);
    final remaining =
        activeUnits.where((candidate) => candidate.id != unitId).toList();
    if (remaining.isEmpty) {
      throw StateError(
          'A product must retain at least one active selling unit');
    }

    await sqliteManager.database.update(
      'product_selling_units',
      {
        'is_active': 0,
        'is_default': 0,
        'updated_at': DateTime.now().toIso8601String()
      },
      where: 'id = ?',
      whereArgs: [unitId],
    );

    if (unit.isDefault && remaining.isNotEmpty) {
      await sqliteManager.database.update(
        'product_selling_units',
        {'is_default': 1, 'updated_at': DateTime.now().toIso8601String()},
        where: 'id = ?',
        whereArgs: [remaining.first.id],
      );
    }
  }
}

class BarcodeLookupResult {
  final Product product;
  final SellingUnit? sellingUnit;

  BarcodeLookupResult({required this.product, this.sellingUnit});
}

class BarcodeLookupService {
  final ProductCatalogRepository productRepository;
  final SellingUnitRepository sellingUnitRepository;

  BarcodeLookupService(this.productRepository, this.sellingUnitRepository);

  Future<BarcodeLookupResult?> lookup(String barcode) async {
    final matchingProduct = await productRepository.findByBarcode(barcode);
    if (matchingProduct != null) {
      final defaultUnit =
          await sellingUnitRepository.findDefaultUnit(matchingProduct.id);
      return BarcodeLookupResult(
          product: matchingProduct, sellingUnit: defaultUnit);
    }

    return null;
  }
}

class ProductSellingPolicyService {
  static bool allowsPartialPackageSale(
      Product product, SellingUnit requestedUnit) {
    if (product.productType != ProductType.packaged) return true;
    if (!product.allowPartialPackageSale) {
      return requestedUnit.productId == product.id && requestedUnit.isDefault;
    }
    return requestedUnit.productId == product.id && requestedUnit.isActive;
  }
}
