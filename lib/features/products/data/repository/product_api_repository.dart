import 'package:either_dart/either.dart';
import 'package:flutter/foundation.dart';

import '../../../../core/error/failure.dart';
import '../../../../core/network/backend_api_client.dart';
import '../../../../core/network/backend_api_config.dart';
import '../models/product_model.dart';
import '../models/selling_unit_model.dart';
import '../../../stock/data/models/stock_movement_model.dart';

class ProductApiRepository {
  ProductApiRepository(this.client);

  final BackendApiClient client;
  bool _authenticationAttempted = false;
  Map<String, String> _categoryIds = {};
  Map<String, String> _categoryNamesById = {};
  bool _serverCategoriesLoaded = false;
  String? _serverCategoriesOwner;
  Future<void>? _serverCategoriesLoad;

  String? categoryIdForName(String name) => _categoryIds[name];

  Future<void> _ensureAuthenticated() async {
    if (client.tokenStore.accessToken != null || _authenticationAttempted) {
      return;
    }
    _authenticationAttempted = true;
    if (BackendApiConfig.username.isEmpty ||
        BackendApiConfig.password.isEmpty) {
      throw const BackendApiException(
        401,
        'Server product reads require BAYAA_API_USERNAME and '
        'BAYAA_API_PASSWORD',
      );
    }
    await client.login(
      username: BackendApiConfig.username,
      password: BackendApiConfig.password,
    );
  }

  Future<Either<Failure, List<Product>>> getProducts({
    required int page,
    required int pageSize,
    String? category,
    String? searchQuery,
  }) async {
    try {
      await _ensureAuthenticated();
      await _ensureServerCategoriesLoaded();
      final payload = await client.getProducts(
        page: page + 1,
        pageSize: pageSize,
        categoryId: category == null || category == '*' ? null : category,
        search: searchQuery,
      );
      final items = payload['items'];
      if (items is! List) {
        throw const FormatException('Product list response is missing items');
      }
      final products = items.map(_mapProduct).toList();
      if (kDebugMode) {
        debugPrint(
          '[ProductApiRepository] server product list returned '
          '${products.length} products',
        );
      }
      return Right(products);
    } on BackendApiException catch (error) {
      return Left(CacheFailure(error.message));
    } on FormatException catch (error) {
      return Left(CacheFailure(error.message));
    } on Exception catch (error) {
      return Left(CacheFailure('Failed to load products from server: $error'));
    }
  }

  Future<Either<Failure, Product>> getProduct(String id) async {
    try {
      await _ensureAuthenticated();
      return Right(_mapProduct(await client.getProduct(id)));
    } on BackendApiException catch (error) {
      return Left(CacheFailure(error.message));
    } on FormatException catch (error) {
      return Left(CacheFailure(error.message));
    } on Exception catch (error) {
      return Left(CacheFailure('Failed to load product from server: $error'));
    }
  }

  Future<Either<Failure, Product>> getProductByBarcode(String barcode) async {
    debugPrint('[BARCODE] ProductApiRepository lookup barcode=$barcode');
    try {
      await _ensureAuthenticated();
      return Right(_mapProduct(await client.getProductByBarcode(barcode)));
    } on BackendApiException catch (error) {
      return Left(CacheFailure(error.message));
    } on FormatException catch (error) {
      return Left(CacheFailure('Invalid product response: ${error.message}'));
    } on Exception catch (error) {
      return Left(CacheFailure('Failed to load product from server: $error'));
    }
  }

  Future<Either<Failure, List<StockMovement>>> getProductStockMovements(
    String productId,
  ) async {
    try {
      await _ensureAuthenticated();
      final rows = await client.getProductStockMovements(productId);
      return Right(
        rows
            .whereType<Map>()
            .map((row) => StockMovement.fromMap(
                  Map<String, dynamic>.from(row),
                ))
            .toList(),
      );
    } on BackendApiException catch (error) {
      return Left(CacheFailure(error.message));
    } on FormatException catch (error) {
      return Left(CacheFailure(error.message));
    } on Exception catch (error) {
      return Left(CacheFailure(
        'Failed to load product stock movements from server: $error',
      ));
    }
  }

  Future<Either<Failure, List<Map<String, dynamic>>>> getProductFifoLayers(
    String productId,
  ) async {
    try {
      await _ensureAuthenticated();
      final rows = await client.getProductFifoLayers(productId);
      return Right(
        rows
            .whereType<Map>()
            .map((row) => Map<String, dynamic>.from(row))
            .toList(),
      );
    } on BackendApiException catch (error) {
      return Left(CacheFailure(error.message));
    } on FormatException catch (error) {
      return Left(CacheFailure(error.message));
    } on Exception catch (error) {
      return Left(
          CacheFailure('Failed to load FIFO layers from server: $error'));
    }
  }

  Future<Either<Failure, Map<String, dynamic>>> correctProductFifoLayerCost({
    required String productId,
    required String layerId,
    required double newUnitCost,
    required String idempotencyKey,
  }) async {
    try {
      await _ensureAuthenticated();
      final result = await client.postProductFifoCostCorrection(
        productId,
        {
          'layer_id': layerId,
          'new_unit_cost': newUnitCost,
        },
        idempotencyKey: idempotencyKey,
      );
      return Right(result);
    } on BackendApiException catch (error) {
      return Left(CacheFailure(error.message));
    } on FormatException catch (error) {
      return Left(CacheFailure(error.message));
    } on Exception catch (error) {
      return Left(CacheFailure('Failed to correct FIFO layer cost: $error'));
    }
  }

  Future<Either<Failure, void>> deleteProduct(String productId) async {
    try {
      await _ensureAuthenticated();
      await client.deleteProduct(productId);
      return const Right(null);
    } on BackendApiException catch (error) {
      return Left(CacheFailure(error.message));
    } on Exception catch (error) {
      return Left(CacheFailure('Failed to delete product on server: $error'));
    }
  }

  Future<Either<Failure, bool>> productExistsOnServer(String id) async {
    try {
      await _ensureAuthenticated();
      await client.getProduct(id);
      return const Right(true);
    } on BackendApiException catch (error) {
      if (error.statusCode == 404) return const Right(false);
      return Left(CacheFailure(error.message));
    } on Exception catch (error) {
      return Left(CacheFailure('Failed to check server product: $error'));
    }
  }

  Future<Either<Failure, Product>> updateProduct(
    Product product, {
    List<SellingUnit>? packagedSellingUnits,
  }) async {
    try {
      await _ensureAuthenticated();
      final units = packagedSellingUnits
              ?.where((unit) => unit.isActive)
              .map((unit) => {
                    'id': unit.id,
                    'name': unit.name,
                    'icon_key': unit.iconKey,
                    'conversion_to_base': unit.conversionToBase,
                    'selling_price': unit.sellingPrice,
                    'cost_price': unit.cost,
                    'wholesale_price': unit.wholesalePrice,
                    'minimum_stock': unit.minimumStock,
                    'is_default': unit.isDefault,
                    'is_active': unit.isActive,
                  })
              .toList() ??
          const <Map<String, dynamic>>[];
      final payload = <String, dynamic>{
        'id': product.id,
        'name': product.name,
        'code': product.code,
        'barcode': product.barcode,
        'internal_reference': product.internalReference,
        'product_type': product.productType.value,
        'base_unit': product.baseUnit,
        'quantity_precision': product.quantityPrecision,
        'allow_partial_package_sale': product.allowPartialPackageSale,
        'price': product.price,
        'min_price': product.minPrice,
        'wholesale_price': product.wholesalePrice,
        'cost': product.cost,
        'min_stock': product.minQuantity,
        'category_id': _categoryIdForPayload(product.category),
        'image_path': product.imagePath,
        'is_active': product.isActive,
        'selling_units': units,
      };
      return Right(
          _mapProduct(await client.updateProduct(product.id, payload)));
    } on BackendApiException catch (error) {
      return Left(CacheFailure(error.message));
    } on FormatException catch (error) {
      return Left(CacheFailure(error.message));
    } on Exception catch (error) {
      return Left(CacheFailure('Failed to update product on server: $error'));
    }
  }

  Future<Either<Failure, Product>> createProduct(
    Product product, {
    List<SellingUnit>? packagedSellingUnits,
    required double openingQuantity,
    required double openingUnitCost,
    required String openingReason,
    String? openingNotes,
    String? openingUnit,
    List<OpeningStockLine>? openingLines,
  }) async {
    try {
      await _ensureAuthenticated();
      if (kDebugMode) {
        debugPrint('[ProductApiRepository] product create started');
      }

      final units = packagedSellingUnits
              ?.where((unit) => unit.isActive)
              .map((unit) => {
                    'id': unit.id,
                    'name': unit.name,
                    'icon_key': unit.iconKey,
                    'conversion_to_base': unit.conversionToBase,
                    'selling_price': unit.sellingPrice,
                    'cost_price': unit.cost,
                    'wholesale_price': unit.wholesalePrice,
                    'minimum_stock': unit.minimumStock,
                    'is_default': unit.isDefault,
                    'is_active': unit.isActive,
                  })
              .toList() ??
          const <Map<String, dynamic>>[];
      final payload = <String, dynamic>{
        'id': product.id,
        'name': product.name,
        'code': product.code,
        'barcode': product.barcode,
        'internal_reference': product.internalReference,
        'product_type': product.productType.value,
        'base_unit': product.baseUnit,
        'quantity_precision': product.quantityPrecision,
        'allow_partial_package_sale': product.allowPartialPackageSale,
        'price': product.price,
        'min_price': product.minPrice,
        'wholesale_price': product.wholesalePrice,
        'cost': product.cost,
        'stock': 0,
        'opening_quantity': openingQuantity,
        'opening_unit_cost': openingUnitCost,
        'opening_reason': openingReason,
        'opening_notes': openingNotes,
        'opening_unit': openingUnit,
        'opening_lines': openingLines
                ?.map((line) => {
                      'unit': line.unit,
                      'quantity': line.quantity,
                      'unit_cost': line.unitCost,
                    })
                .toList() ??
            const <Map<String, dynamic>>[],
        'min_stock': product.minQuantity,
        'category_id': _categoryIdForPayload(product.category),
        'image_path': product.imagePath,
        'is_active': product.isActive,
        'selling_units': units,
      };
      if (kDebugMode) {
        debugPrint(
          '[ProductApiRepository] product.category=${product.category} '
          'normalizedCategoryId=${payload['category_id']}',
        );
      }
      return Right(_mapProduct(await client.createProduct(payload)));
    } on BackendApiException catch (error) {
      if (kDebugMode) {
        debugPrint(
          '[ProductApiRepository] product create failed '
          '${error.statusCode}: ${error.message}',
        );
      }

      return Left(CacheFailure(error.message));
    } on FormatException catch (error) {
      return Left(CacheFailure(error.message));
    } on Exception catch (error) {
      return Left(CacheFailure('Failed to create product on server: $error'));
    }
  }

  Future<Either<Failure, Map<String, String>>> getServerCategories() async {
    try {
      await _ensureAuthenticated();
      await _loadServerCategories(refresh: true);
      return Right(Map.unmodifiable(_categoryIds));
    } on FormatException catch (error) {
      return Left(CacheFailure(error.message));
    } on BackendApiException catch (error) {
      return Left(CacheFailure(error.message));
    } on Exception catch (error) {
      return Left(
          CacheFailure('Failed to load categories from server: $error'));
    }
  }

  Future<Either<Failure, void>> createCategory(String name) async {
    try {
      await _ensureAuthenticated();
      final category = await client.createCategory(name);
      final id = category['id'];
      final categoryName = category['name'];
      if (id is! String || categoryName is! String) {
        throw const FormatException('Invalid category response');
      }
      _categoryIds[categoryName] = id;
      _categoryNamesById[id] = categoryName;
      return const Right(null);
    } on BackendApiException catch (error) {
      return Left(CacheFailure(error.message));
    } on Exception catch (error) {
      return Left(CacheFailure('Failed to create category on server: $error'));
    }
  }

  Future<Either<Failure, void>> deleteCategory(String categoryId) async {
    try {
      await _ensureAuthenticated();
      await client.deleteCategory(categoryId);
      _categoryIds.removeWhere((_, id) => id == categoryId);
      _categoryNamesById.remove(categoryId);
      return const Right(null);
    } on BackendApiException catch (error) {
      return Left(CacheFailure(error.message));
    } on Exception catch (error) {
      return Left(CacheFailure('Failed to delete category on server: $error'));
    }
  }

  Future<void> _ensureServerCategoriesLoaded() async {
    if (_serverCategoriesLoaded &&
        _serverCategoriesOwner == _categoryCacheOwner) {
      return;
    }
    await _loadServerCategories();
  }

  String get _categoryCacheOwner => '${client.tokenStore.userId ?? ''}:'
      '${client.tokenStore.shopId ?? ''}:'
      '${client.tokenStore.accessToken ?? ''}';

  Future<void> _loadServerCategories({bool refresh = false}) async {
    if (!refresh &&
        _serverCategoriesLoaded &&
        _serverCategoriesOwner == _categoryCacheOwner) {
      return;
    }
    if (refresh || _serverCategoriesOwner != _categoryCacheOwner) {
      _serverCategoriesLoaded = false;
      _serverCategoriesOwner = null;
      _categoryIds = {};
      _categoryNamesById = {};
    }
    final inFlight = _serverCategoriesLoad;
    if (inFlight != null) return inFlight;

    final load = () async {
      final categories = await client.getCategories();
      final idsByName = <String, String>{};
      final namesById = <String, String>{};
      for (final category in categories) {
        final id = category['id'];
        final name = category['name'];
        if (id is! String ||
            id.trim().isEmpty ||
            name is! String ||
            name.trim().isEmpty) {
          throw const FormatException('Invalid category list response');
        }
        idsByName[name] = id;
        namesById[id] = name;
      }
      _categoryIds = idsByName;
      _categoryNamesById = namesById;
      _serverCategoriesLoaded = true;
      _serverCategoriesOwner = _categoryCacheOwner;
    }();
    _serverCategoriesLoad = load;
    try {
      await load;
    } finally {
      if (identical(_serverCategoriesLoad, load)) {
        _serverCategoriesLoad = null;
      }
    }
  }

  String? _categoryIdForPayload(String? category) {
    final value = category?.trim();
    if (value == null ||
        value.isEmpty ||
        value == 'All' ||
        value == 'الكل' ||
        value == '*') {
      return null;
    }
    return value;
  }

  Product _mapProduct(dynamic value) {
    if (value is! Map) {
      throw const FormatException('Product response is not an object');
    }
    final map = Map<String, dynamic>.from(value);
    final categoryId = map['category_id']?.toString();
    final hasCurrentServerCategoryList = _serverCategoriesLoaded &&
        _serverCategoriesOwner == _categoryCacheOwner;
    final categoryName = categoryId == null
        ? null
        : hasCurrentServerCategoryList
            ? _categoryNamesById[categoryId]
            : map['category_name']?.toString();
    final rawUnits = map['selling_units'];
    final units = rawUnits is List
        ? rawUnits
            .whereType<Map>()
            .map((unit) => SellingUnit.fromMap(Map<String, dynamic>.from(unit)))
            .where((unit) => unit.isActive)
            .toList()
        : <SellingUnit>[];
    return Product.fromMap({
      ...map,
      'category_name': categoryName,
      'selling_units': units,
    });
  }
}
