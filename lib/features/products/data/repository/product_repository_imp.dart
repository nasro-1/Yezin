// ignore_for_file: avoid_print

import 'package:bayaa_pos/core/data/services/persistence_initializer.dart';
import 'package:bayaa_pos/core/data/services/repository_persistence_mixin.dart';
import 'package:bayaa_pos/core/error/failure.dart';
import 'package:bayaa_pos/core/error/error_handler.dart';
import 'package:bayaa_pos/core/state/state_synchronizer.dart';
import 'package:bayaa_pos/features/products/data/models/product_model.dart';
import 'package:bayaa_pos/features/products/data/models/selling_unit_model.dart';
import 'package:bayaa_pos/features/products/domain/product_repository_int.dart';
import 'package:either_dart/either.dart';
import 'package:flutter/foundation.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:bayaa_pos/features/auth/data/models/user_model.dart';
import 'package:bayaa_pos/features/stock/data/models/stock_adjustment_model.dart';
import 'package:bayaa_pos/features/stock/services/stock_adjustment_service.dart';
import 'package:bayaa_pos/core/network/backend_api_config.dart';
import 'package:bayaa_pos/core/network/authority_context.dart';
import 'product_api_repository.dart';

Future<void> deleteProductRecord(DatabaseExecutor db, String productId) async {
  final productRows = await db.query(
    'products',
    columns: ['id'],
    where: 'id = ?',
    whereArgs: [productId],
    limit: 1,
  );
  if (productRows.isEmpty) {
    throw StateError('Product not found');
  }
  final resolvedProductId = productRows.single['id'] as String;
  final historicalTables = <String>[
    'sale_items',
    'purchase_items',
    'order_items',
    'proforma_items',
    'supplier_return_items',
    'stock_movements',
    'opening_stock_lines',
    'stock_adjustment_items',
  ];
  var hasHistory = false;
  for (final table in historicalTables) {
    if ((await db.rawQuery(
      'SELECT 1 FROM $table WHERE product_id = ? LIMIT 1',
      [resolvedProductId],
    ))
        .isNotEmpty) {
      hasHistory = true;
      break;
    }
  }
  if (hasHistory) {
    await db.update(
      'products',
      {
        'is_active': 0,
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [resolvedProductId],
    );
    return;
  }

  final deletedRows = await db.delete(
    'products',
    where: 'id = ?',
    whereArgs: [resolvedProductId],
  );
  if (deletedRows != 1) {
    throw StateError('Product was not deleted');
  }
}

class ProductRepositoryImp extends ProductRepositoryInt
    with RepositoryPersistenceMixin {
  List<SellingUnit> _normalizePackagedSellingUnits(
    List<SellingUnit> units,
  ) {
    final activeUnits = units.where((unit) => unit.isActive).toList();
    if (activeUnits.isEmpty) return units;

    final existingDefault = activeUnits.cast<SellingUnit?>().firstWhere(
          (unit) => unit!.isDefault,
          orElse: () => null,
        );
    final defaultUnit = existingDefault ?? activeUnits.first;
    return units
        .map(
          (unit) => unit.isActive
              ? unit.copyWith(isDefault: identical(unit, defaultUnit))
              : unit,
        )
        .toList();
  }

  // Removed Hive data sources
  ProductRepositoryImp({
    ProductApiRepository? serverReadRepository,
    ProductReadMode readMode = ProductReadMode.local,
    ProductWriteMode? writeMode,
    AuthorityContext? authorityContext,
  })  : _serverReadRepository = serverReadRepository,
        _authorityContext = authorityContext ??
            AuthorityContext(
              readMode: readMode == ProductReadMode.server
                  ? AuthorityMode.server
                  : AuthorityMode.local,
              writeMode: (writeMode ?? BackendApiConfig.productWriteMode) ==
                      ProductWriteMode.server
                  ? AuthorityMode.server
                  : AuthorityMode.local,
            ),
        _readMode = authorityContext?.readsFromServer == true
            ? ProductReadMode.server
            : authorityContext == null
                ? readMode
                : ProductReadMode.local,
        _writeMode = authorityContext?.writesToServer == true
            ? ProductWriteMode.server
            : authorityContext == null
                ? writeMode ?? BackendApiConfig.productWriteMode
                : ProductWriteMode.local;

  final ProductApiRepository? _serverReadRepository;
  final AuthorityContext _authorityContext;
  final ProductReadMode _readMode;
  final ProductWriteMode _writeMode;

  ProductReadMode get readMode => _readMode;
  ProductWriteMode get writeMode => _writeMode;
  AuthorityContext get authorityContext => _authorityContext;

  @override
  Future<Either<Failure, Map<String, String>>> getServerCategories() {
    final repository = _serverReadRepository;
    if (repository == null) {
      return Future.value(
        const Left(CacheFailure('Server category repository is unavailable')),
      );
    }
    return repository.getServerCategories();
  }

  @override
  Future<Either<Failure, Map<String, String>>> getCategoryNamesById() async {
    if (_readMode == ProductReadMode.server) {
      final result = await getServerCategories();
      return result.fold(
        (failure) => Left(failure),
        (idsByName) => Right({
          for (final entry in idsByName.entries) entry.value: entry.key,
        }),
      );
    }

    try {
      final db = PersistenceInitializer.persistenceManager!.sqliteManager;
      final rows = await db.query(
        'categories',
        columns: ['id', 'name'],
        orderBy: 'sort_order ASC, name COLLATE NOCASE ASC',
      );
      return Right({
        for (final row in rows)
          if (row['id'] is String && row['name'] is String)
            row['id'] as String: row['name'] as String,
      });
    } on Exception catch (error) {
      return Left(CacheFailure('Error loading category names: $error'));
    }
  }

  void _logReadPath(String message) {
    if (kDebugMode) {
      debugPrint('[ProductRepositoryImp] $message');
    }
  }

  @override
  Future<Either<Failure, void>> deleteProduct(String productId) async {
    if (_writeMode == ProductWriteMode.server) {
      final serverRepository = _serverReadRepository;
      if (serverRepository == null) {
        return const Left(CacheFailure(
          'Server product writes are enabled but the API repository is not configured',
        ));
      }
      final result = await serverRepository.deleteProduct(productId);
      return result.isLeft ? Left(result.left) : const Right(null);
    }
    return ErrorHandler.executeWithErrorHandlingEitherDart(
      operation: () async {
        await deleteCritical(
          entity: 'product',
          id: productId,
          sqliteWrite: () async {
            final db = PersistenceInitializer.persistenceManager!.sqliteManager;
            await deleteProductRecord(db.database, productId);
          },
        );

        // Notify state change
        StateSynchronizer.notify(DataChangeEvent(
          entityType: 'product',
          operation: 'delete',
          id: productId,
        ));

        return const Right(null);
      },
      operationName: 'deleteProduct',
      userFriendlyMessage: 'Failed to delete product',
      source: 'ProductRepository',
    );
  }

  @override
  Future<Either<Failure, List<Product>>> getAllProduct() async {
    try {
      _logReadPath('getAllProduct mode=$_readMode');
      if (_readMode == ProductReadMode.server) {
        final serverRepository = _serverReadRepository;
        if (serverRepository == null) {
          return Left(CacheFailure(
            'Server product reads are enabled but the API repository is not configured',
          ));
        }

        _logReadPath('starting server product list read');
        final serverResult = await serverRepository.getProducts(
          page: 0,
          pageSize: 50,
        );
        _logReadPath(
          serverResult.isRight
              ? 'server product list read succeeded'
              : 'server product list read failed: ${serverResult.left.message}',
        );
        return serverResult;
      }
      print('📦 === LOADING PRODUCTS (SQLite) ===');

      final db = PersistenceInitializer.persistenceManager!.sqliteManager;
      final results = await db.query('products', where: 'is_active = 1');
      print('  📦 Products in SQL: ${results.length}');

      final products = results
          .map((m) => Product(
                id: m['id']?.toString() ?? (m['barcode'] as String? ?? ''),
                name: m['name'] as String,
                barcode: (m['barcode'] as String?) ?? '',
                internalReference: m['internal_reference']?.toString(),
                productType: ProductType.fromValue(m['product_type']),
                baseUnit: m['base_unit']?.toString() ?? 'piece',
                quantityPrecision:
                    ((m['quantity_precision'] ?? 3) as num).toInt(),
                allowPartialPackageSale:
                    (m['allow_partial_package_sale'] ?? 0) == 1,
                price: (m['price'] as num?)?.toDouble() ?? 0.0,
                minPrice: (m['min_price'] as num?)?.toDouble() ?? 0.0,
                wholesalePrice:
                    (m['wholesale_price'] as num?)?.toDouble() ?? 0.0,
                cost: (m['cost'] as num?)?.toDouble() ?? 0.0,
                quantity:
                    ((m['stock'] ?? m['quantity'] ?? 0) as num).toDouble(),
                minQuantity:
                    ((m['min_stock'] ?? m['min_quantity'] ?? 0) as num).toInt(),
                category: m['category_id'] as String? ??
                    m['category'] as String? ??
                    'General',
                imagePath: m['image_path'] as String?,
                isActive: (m['is_active'] ?? 1) == 1,
                createdAt: m['created_at'] != null
                    ? DateTime.tryParse(m['created_at'].toString())
                    : null,
                updatedAt: m['updated_at'] != null
                    ? DateTime.tryParse(m['updated_at'].toString())
                    : null,
              ))
          .toList();

      return Right(products);
    } on Exception catch (e) {
      print('  ❌ Failed to load products: $e');
      return Left(CacheFailure("Error fetching products: ${e.toString()}"));
    }
  }

  @override
  Future<Either<Failure, Product?>> findProductByBarcode(
    String barcode,
  ) async {
    final normalized = barcode.trim();
    _logReadPath('barcode lookup started value=$normalized');
    if (normalized.isEmpty) {
      return const Right(null);
    }
    if (_readMode == ProductReadMode.server) {
      final repository = _serverReadRepository;
      if (repository == null) {
        return const Left(CacheFailure(
          'Server product reads are enabled but the API repository is not configured',
        ));
      }
      final result = await repository.getProductByBarcode(normalized);
      if (result.isLeft &&
          result.left.message.toLowerCase().contains('not found')) {
        return const Right(null);
      }
      return result;
    }
    try {
      final all = await getAllProduct();
      if (all.isLeft) return Left(all.left);
      final productMatches =
          all.right.where((product) => product.barcode == normalized).toList();
      if (productMatches.isNotEmpty) return Right(productMatches.first);
      return const Right(null);
    } on Exception catch (error) {
      return Left(CacheFailure('Failed to find product by barcode: $error'));
    }
  }

  @override
  Future<Either<Failure, List<Product>>> getProductsPaginated({
    required int page,
    required int pageSize,
    String? category,
    String? availability,
    String? searchQuery,
  }) async {
    try {
      _logReadPath(
        'getProductsPaginated page=$page mode=$_readMode',
      );
      if (_readMode == ProductReadMode.server) {
        final serverRepository = _serverReadRepository;
        if (serverRepository == null) {
          return Left(CacheFailure(
            'Server product reads are enabled but the API repository is not configured',
          ));
        }
        _logReadPath('starting server product list read');
        final serverResult = await serverRepository.getProducts(
          page: page,
          pageSize: pageSize,
          category: category,
          searchQuery: searchQuery,
        );
        _logReadPath(
          serverResult.isRight
              ? 'server product list read succeeded'
              : 'server product list read failed: ${serverResult.left.message}',
        );
        return serverResult;
      }
      print('📦 === LOADING PRODUCTS PAGE $page (SQLite) ===');

      final db = PersistenceInitializer.persistenceManager!.sqliteManager;
      final offset = page * pageSize;

      String whereClause = 'is_active = 1';
      List<Object?> whereArgs = [];

      if (category != null && category != '*') {
        whereClause += ' AND category_id = ?';
        whereArgs.add(category);
      }

      if (availability != null && availability != '*') {
        if (availability == 'outOfStock') {
          whereClause += ' AND stock = 0';
        } else if (availability == 'lowStock') {
          whereClause += ' AND stock > 0 AND stock <= min_stock';
        } else if (availability == 'available') {
          whereClause += ' AND stock > min_stock';
        }
      }

      if (searchQuery != null && searchQuery.isNotEmpty) {
        whereClause += ' AND (name LIKE ? OR barcode LIKE ?)';
        whereArgs.add('%$searchQuery%');
        whereArgs.add('%$searchQuery%');
      }

      final results = await db.query(
        'products',
        where: whereClause,
        whereArgs: whereArgs,
        orderBy: 'name COLLATE NOCASE ASC, id ASC',
        limit: pageSize,
        offset: offset,
      );

      print(
          '  📦 Loaded ${results.length} products (page $page, offset $offset)');

      final products = results
          .map((m) => Product(
                id: m['id']?.toString() ?? (m['barcode'] as String? ?? ''),
                name: m['name'] as String,
                barcode: (m['barcode'] as String?) ?? '',
                internalReference: m['internal_reference']?.toString(),
                productType: ProductType.fromValue(m['product_type']),
                baseUnit: m['base_unit']?.toString() ?? 'piece',
                quantityPrecision:
                    ((m['quantity_precision'] ?? 3) as num).toInt(),
                allowPartialPackageSale:
                    (m['allow_partial_package_sale'] ?? 0) == 1,
                price: (m['price'] as num?)?.toDouble() ?? 0.0,
                minPrice: (m['min_price'] as num?)?.toDouble() ?? 0.0,
                wholesalePrice:
                    (m['wholesale_price'] as num?)?.toDouble() ?? 0.0,
                cost: (m['cost'] as num?)?.toDouble() ?? 0.0,
                quantity:
                    ((m['stock'] ?? m['quantity'] ?? 0) as num).toDouble(),
                minQuantity:
                    ((m['min_stock'] ?? m['min_quantity'] ?? 0) as num).toInt(),
                category: m['category_id'] as String? ??
                    m['category'] as String? ??
                    'General',
                imagePath: m['image_path'] as String?,
                isActive: (m['is_active'] ?? 1) == 1,
                createdAt: m['created_at'] != null
                    ? DateTime.tryParse(m['created_at'].toString())
                    : null,
                updatedAt: m['updated_at'] != null
                    ? DateTime.tryParse(m['updated_at'].toString())
                    : null,
              ))
          .toList();

      return Right(products);
    } on Exception catch (e) {
      print('  ❌ Failed to load products page: $e');
      return Left(CacheFailure("Error fetching products: ${e.toString()}"));
    }
  }

  Future<Either<Failure, void>> _createProductOnServer(
    Product product, {
    List<SellingUnit>? packagedSellingUnits,
    required double openingQuantity,
    required double openingUnitCost,
    required String openingReason,
    String? openingNotes,
    String? openingUnit,
    List<OpeningStockLine>? openingLines,
  }) async {
    if (kDebugMode) {
      debugPrint('[ProductRepositoryImp] SERVER CREATE PATH ENTERED');
      debugPrint('[ProductRepositoryImp] productId=${product.id}');
      debugPrint('[ProductRepositoryImp] barcode=${product.barcode}');
      debugPrint('[ProductRepositoryImp] openingQuantity=$openingQuantity');
    }
    final serverRepository = _serverReadRepository;
    if (serverRepository == null) {
      return Left(CacheFailure(
        'Server product writes are enabled but the API repository is not configured',
      ));
    }
    final result = await serverRepository.createProduct(
      product,
      packagedSellingUnits: packagedSellingUnits == null
          ? null
          : _normalizePackagedSellingUnits(packagedSellingUnits),
      openingQuantity: openingQuantity,
      openingUnitCost: openingUnitCost,
      openingReason: openingReason,
      openingNotes: openingNotes,
      openingUnit: openingUnit,
      openingLines: openingLines,
    );
    if (result.isLeft) {
      if (kDebugMode) {
        debugPrint(
          '[ProductRepositoryImp] SERVER CREATE FAILURE '
          '${result.left.message}',
        );
      }
      return Left(result.left);
    }
    if (kDebugMode) {
      debugPrint(
        '[ProductRepositoryImp] SERVER CREATE SUCCESS id=${result.right.id}',
      );
    }
    return const Right(null);
  }

  @override
  Future<Either<Failure, void>> saveProduct(
    Product product, {
    List<SellingUnit>? packagedSellingUnits,
  }) async {
    if (_writeMode == ProductWriteMode.server) {
      final serverRepository = _serverReadRepository;
      if (serverRepository == null) {
        return const Left(CacheFailure(
          'Server product writes are enabled but the API repository is not configured',
        ));
      }
      final existing = await serverRepository.productExistsOnServer(product.id);
      if (kDebugMode) {
        debugPrint(
          '[ProductRepositoryImp] server existence check '
          'productId=${product.id} result='
          '${existing.isRight ? existing.right : 'failure: ${existing.left.message}'}',
        );
      }
      if (existing.isLeft) return Left(existing.left);
      if (existing.right) {
        final updated = await serverRepository.updateProduct(
          product,
          packagedSellingUnits: packagedSellingUnits,
        );
        return updated.isLeft ? Left(updated.left) : const Right(null);
      }
      return _createProductOnServer(
        product,
        packagedSellingUnits: packagedSellingUnits,
        openingQuantity: 0,
        openingUnitCost: 0,
        openingReason: 'product creation',
        openingNotes: null,
      );
    }
    return ErrorHandler.executeWithErrorHandlingEitherDart(
      operation: () async {
        final db = PersistenceInitializer.persistenceManager!.sqliteManager;
        final isUpdate = (await db.query(
          'products',
          columns: ['id'],
          where: 'id = ?',
          whereArgs: [product.id],
          limit: 1,
        ))
            .isNotEmpty;

        await writeCritical(
          entity: 'product',
          id: product.barcode,
          data: product.toMap(),
          sqliteWrite: () async {
            // Check if product exists to preserve created_at
            final existing = await db
                .query('products', where: 'id = ?', whereArgs: [product.id]);
            final now = DateTime.now().toIso8601String();
            final values = <String, Object?>{
              'id': product.id,
              'barcode': product.barcode.trim().isEmpty
                  ? null
                  : product.barcode.trim(),
              'internal_reference': product.internalReference,
              'product_type': product.productType.value,
              'base_unit': product.baseUnit,
              'quantity_precision': product.quantityPrecision,
              'allow_partial_package_sale':
                  product.allowPartialPackageSale ? 1 : 0,
              'name': product.name,
              'price': product.price,
              'min_price': product.minPrice,
              'wholesale_price': product.wholesalePrice,
              'cost': product.cost,
              'min_stock': product.minQuantity.toDouble(),
              'category_id': product.category,
              'image_path': product.imagePath,
              'is_active': 1,
              'updated_at': now,
            };
            if (existing.isNotEmpty) {
              await db.update(
                'products',
                values,
                where: 'id = ?',
                whereArgs: [product.id],
              );
            } else {
              await db.insert('products', {
                'id': product.id,
                ...values,
                'stock': product.quantity.toDouble(),
                'created_at': now,
              });
            }

            if (product.productType == ProductType.packaged &&
                packagedSellingUnits != null) {
              final units =
                  _normalizePackagedSellingUnits(packagedSellingUnits);
              for (final unit in units) {
                final values = unit
                    .copyWith(
                      productId: product.id,
                      updatedAt: DateTime.now(),
                    )
                    .toMap();
                final existingUnit = await db.query(
                  'product_selling_units',
                  columns: ['id'],
                  where: 'id = ? AND product_id = ?',
                  whereArgs: [unit.id, product.id],
                  limit: 1,
                );
                if (existingUnit.isEmpty) {
                  await db.insert(
                    'product_selling_units',
                    values,
                    conflictAlgorithm: ConflictAlgorithm.abort,
                  );
                } else {
                  await db.update(
                    'product_selling_units',
                    values,
                    where: 'id = ? AND product_id = ?',
                    whereArgs: [unit.id, product.id],
                  );
                }
              }
            }
          },
        );

        // Notify state change
        StateSynchronizer.notify(DataChangeEvent(
          entityType: 'product',
          operation: isUpdate ? 'update' : 'create',
          id: product.barcode,
        ));

        return const Right(null);
      },
      operationName: 'saveProduct',
      userFriendlyMessage: 'Failed to save product',
      source: 'ProductRepository',
    );
  }

  @override
  Future<Either<Failure, void>> saveProductWithOpeningStock(
    Product product, {
    required double openingQuantity,
    required double openingUnitCost,
    required String openingReason,
    String openingNotes = '',
    required User user,
    List<SellingUnit>? packagedSellingUnits,
    String? openingUnit,
    List<OpeningStockLine>? openingLines,
  }) async {
    if (kDebugMode) {
      debugPrint(
        '[ProductRepositoryImp] saveProductWithOpeningStock '
        'writeMode=$_writeMode productId=${product.id} '
        'code=${product.code} barcode=${product.barcode} '
        'openingQuantity=$openingQuantity',
      );
    }
    if (_writeMode == ProductWriteMode.server) {
      if (kDebugMode) {
        debugPrint(
          '[ProductRepositoryImp] server branch entered '
          'openingQuantity=$openingQuantity',
        );
      }
      if (openingQuantity < 0) {
        return Left(CacheFailure(
          'Opening stock quantity cannot be negative',
        ));
      }
      final serverRepository = _serverReadRepository;
      if (serverRepository == null) {
        return const Left(CacheFailure(
          'Server product writes are enabled but the API repository is not configured',
        ));
      }
      final existing = await serverRepository.productExistsOnServer(product.id);
      if (kDebugMode) {
        debugPrint(
          '[ProductRepositoryImp] server existence check '
          'productId=${product.id} result='
          '${existing.isRight ? existing.right : 'failure: ${existing.left.message}'}',
        );
      }
      if (existing.isLeft) return Left(existing.left);
      if (existing.right) {
        final updated = await serverRepository.updateProduct(
          product,
          packagedSellingUnits: packagedSellingUnits,
        );
        return updated.isLeft ? Left(updated.left) : const Right(null);
      }
      return _createProductOnServer(
        product,
        packagedSellingUnits: packagedSellingUnits,
        openingQuantity: openingQuantity,
        openingUnitCost: openingUnitCost,
        openingReason: openingReason,
        openingNotes: openingNotes,
        openingUnit: openingUnit,
        openingLines: openingLines,
      );
    }
    return ErrorHandler.executeWithErrorHandlingEitherDart(
      operation: () async {
        final manager =
            PersistenceInitializer.persistenceManager!.sqliteManager;
        await manager.database.transaction((txn) async {
          final now = DateTime.now().toIso8601String();
          final selectedOpeningUnit =
              packagedSellingUnits == null || packagedSellingUnits.isEmpty
                  ? null
                  : packagedSellingUnits.firstWhere(
                      (unit) =>
                          unit.name.toLowerCase() ==
                          (openingUnit ?? '').toLowerCase(),
                      orElse: () => packagedSellingUnits.first,
                    );
          final openingConversion =
              selectedOpeningUnit?.conversionToBase ?? 1.0;
          final baseUnitCost = product.productType == ProductType.packaged &&
                  openingQuantity > 0 &&
                  openingConversion > 0
              ? openingUnitCost / openingConversion
              : product.cost;
          await txn.insert('products', {
            'id': product.id,
            'barcode':
                product.barcode.trim().isEmpty ? null : product.barcode.trim(),
            'internal_reference': product.internalReference,
            'product_type': product.productType.value,
            'base_unit': product.baseUnit,
            'quantity_precision': product.quantityPrecision,
            'allow_partial_package_sale':
                product.allowPartialPackageSale ? 1 : 0,
            'name': product.name,
            'price': product.price,
            'min_price': product.minPrice,
            'wholesale_price': product.wholesalePrice,
            'cost': baseUnitCost,
            'min_stock': product.minQuantity.toDouble(),
            'category_id': product.category,
            'image_path': product.imagePath,
            'is_active': 1,
            'stock': 0.0,
            'created_at': now,
            'updated_at': now,
          });

          if (packagedSellingUnits != null && packagedSellingUnits.isNotEmpty) {
            final units = _normalizePackagedSellingUnits(packagedSellingUnits);
            for (final unit in units) {
              final row = unit
                  .copyWith(
                    productId: product.id,
                    createdAt: DateTime.now(),
                    updatedAt: DateTime.now(),
                  )
                  .toMap();
              await txn.insert(
                'product_selling_units',
                row,
                conflictAlgorithm: ConflictAlgorithm.replace,
              );
            }
          }

          final localOpeningLines = openingLines ??
              (openingQuantity > 0
                  ? [
                      OpeningStockLine(
                        unit: openingUnit ?? product.baseUnit,
                        quantity: openingQuantity,
                        unitCost: openingUnitCost,
                      ),
                    ]
                  : const <OpeningStockLine>[]);
          if (localOpeningLines.isNotEmpty) {
            final unitByName = {
              for (final unit
                  in (packagedSellingUnits ?? const <SellingUnit>[]))
                unit.name.toLowerCase(): unit,
            };
            await StockAdjustmentService(sqliteManager: manager).post(
              idempotencyKey: 'product-opening-${product.id}',
              lines: localOpeningLines.map((line) {
                final conversion =
                    unitByName[line.unit.toLowerCase()]?.conversionToBase ?? 1;
                return StockAdjustmentLineInput(
                  productId: product.id,
                  countedQuantity: line.quantity * conversion,
                  unitCost: line.unitCost / conversion,
                );
              }).toList(),
              user: user,
              reason: openingReason.trim(),
              notes: openingNotes.trim().isEmpty ? null : openingNotes.trim(),
              transaction: txn,
            );
          }
        });

        StateSynchronizer.notify(DataChangeEvent(
          entityType: 'product',
          operation: 'create',
          id: product.barcode,
        ));
        return const Right(null);
      },
      operationName: 'saveProductWithOpeningStock',
      userFriendlyMessage: 'Failed to save product',
      source: 'ProductRepository',
    );
  }

  Future<bool> _productExists(String barcode) async {
    final normalizedBarcode = barcode.trim();
    if (normalizedBarcode.isEmpty) return false;
    final db = PersistenceInitializer.persistenceManager!.sqliteManager;
    final result = await db.rawQuery(
      'SELECT 1 FROM products '
      'WHERE is_active = 1 AND trim(barcode) = ? LIMIT 1',
      [normalizedBarcode],
    );
    return result.isNotEmpty;
  }

  @override
  Future<Either<Failure, void>> deleteCategory(
      {required String category,
      bool forceDelete = false,
      String? newCategory}) async {
    if (_writeMode == ProductWriteMode.server) {
      final repository = _serverReadRepository;
      if (repository == null) {
        return const Left(CacheFailure(
          'Server category writes are enabled but the API repository is unavailable',
        ));
      }
      final categoryId = repository.categoryIdForName(category);
      if (categoryId == null) {
        return Left(CacheFailure('Category not found: $category'));
      }
      final result = await repository.deleteCategory(categoryId);
      return result.isLeft ? Left(result.left) : const Right(null);
    }
    if (_readMode == ProductReadMode.server) {
      return const Left(CacheFailure(
        'Local category deletion is disabled in server-authoritative mode',
      ));
    }
    List<Product> productsList = [];
    try {
      if (category == newCategory) {
        return Left(
            NetworkFailure("Cannot move products to the same category."));
      }

      final productsResult = await getAllProduct();
      productsResult.fold(
          (failure) => Left(NetworkFailure("Error fetching products")),
          (products) => productsList = products);

      var filteredProducts = productsList
          .where((product) => product.category == category)
          .toList();

      if (forceDelete) {
        for (var product in filteredProducts) {
          await deleteProduct(product.id);
        }

        await deleteCritical(
          entity: 'category',
          id: category,
          sqliteWrite: () async {
            final db = PersistenceInitializer.persistenceManager!.sqliteManager;
            await db
                .delete('categories', where: 'name = ?', whereArgs: [category]);
          },
        );
        return const Right(null);
      } else {
        if (filteredProducts.isNotEmpty) {
          if (newCategory == null || newCategory.isEmpty) {
            return Left(CacheFailure(
                "Cannot delete category because it contains products. Please choose a new category to move products to or use force delete."));
          }
          for (var product in filteredProducts) {
            var updatedProduct = Product(
              barcode: product.barcode,
              name: product.name,
              price: product.price,
              category: newCategory,
              quantity: product.quantity,
              minPrice: product.minPrice,
              minQuantity: product.minQuantity,
              wholesalePrice: product.wholesalePrice,
              imagePath: product.imagePath,
            );
            await saveProduct(updatedProduct);
          }
          await deleteCritical(
            entity: 'category',
            id: category,
            sqliteWrite: () async {
              final db =
                  PersistenceInitializer.persistenceManager!.sqliteManager;
              await db.delete('categories',
                  where: 'name = ?', whereArgs: [category]);
            },
          );
          return const Right(null);
        }
      }
      await deleteCritical(
        entity: 'category',
        id: category,
        sqliteWrite: () async {
          final db = PersistenceInitializer.persistenceManager!.sqliteManager;
          await db
              .delete('categories', where: 'name = ?', whereArgs: [category]);
        },
      );
      return const Right(null);
    } on Exception {
      return Left(NetworkFailure("Error deleting category"));
    }
  }

  @override
  Future<Either<Failure, List<String>>> getAllCategory() async {
    try {
      print('📁 === LOADING CATEGORIES (SQLite) ===');

      final db = PersistenceInitializer.persistenceManager!.sqliteManager;
      final results = await db.query(
        'categories',
        orderBy: 'sort_order ASC',
      );
      print('  📁 Categories in SQL: ${results.length}');

      final categories = results.map((m) => m['name'] as String).toList();

      return Right(categories);
    } on Exception catch (e) {
      print('  ❌ Failed to load categories: $e');
      return Left(CacheFailure("Error fetching categories: ${e.toString()}"));
    }
  }

  @override
  Future<Either<Failure, String>> resolveCategoryId(String categoryName) async {
    try {
      final db = PersistenceInitializer.persistenceManager!.sqliteManager;
      final rows = await db.query(
        'categories',
        columns: ['id'],
        where: 'name = ?',
        whereArgs: [categoryName],
        limit: 1,
      );
      if (rows.isEmpty) {
        return Left(CacheFailure('Category not found: $categoryName'));
      }
      return Right(rows.single['id'] as String);
    } on Exception catch (e) {
      return Left(CacheFailure('Error resolving category: ${e.toString()}'));
    }
  }

  @override
  Future<Either<Failure, void>> saveCategory(String category) async {
    if (_writeMode == ProductWriteMode.server) {
      final repository = _serverReadRepository;
      if (repository == null) {
        return const Left(CacheFailure(
          'Server category writes are enabled but the API repository is unavailable',
        ));
      }
      final result = await repository.createCategory(category);
      return result.isLeft ? Left(result.left) : const Right(null);
    }
    return ErrorHandler.executeWithErrorHandlingEitherDart(
      operation: () async {
        await writeCritical(
          entity: 'category',
          id: category,
          data: {'name': category},
          sqliteWrite: () async {
            final db = PersistenceInitializer.persistenceManager!.sqliteManager;
            await db.insert('categories', {
              'id': category,
              'name': category,
            });
          },
        );

        // Notify state change
        StateSynchronizer.notify(DataChangeEvent(
          entityType: 'category',
          operation: 'create',
          id: category,
        ));

        return const Right(null);
      },
      operationName: 'saveCategory',
      userFriendlyMessage: 'Failed to save category',
      source: 'ProductRepository',
    );
  }

  @override
  Future<Either<Failure, bool>> productExists(String barcode) async {
    try {
      final exists = await _productExists(barcode);
      return Right(exists);
    } catch (e) {
      return Left(
          CacheFailure("Error checking product existence: ${e.toString()}"));
    }
  }
}
