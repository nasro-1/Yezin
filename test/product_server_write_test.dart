import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:either_dart/either.dart';

import 'package:bayaa_pos/core/network/backend_api_client.dart';
import 'package:bayaa_pos/core/network/backend_api_config.dart';
import 'package:bayaa_pos/core/network/backend_token_store.dart';
import 'package:bayaa_pos/core/error/failure.dart';
import 'package:bayaa_pos/features/products/data/models/product_model.dart';
import 'package:bayaa_pos/features/products/data/models/selling_unit_model.dart';
import 'package:bayaa_pos/features/products/data/repository/product_api_repository.dart';
import 'package:bayaa_pos/features/products/data/repository/product_repository_imp.dart';
import 'package:bayaa_pos/features/products/domain/product_repository_int.dart';
import 'package:bayaa_pos/features/products/presentation/cubit/product_cubit.dart';
import 'package:bayaa_pos/features/products/presentation/cubit/product_states.dart';
import 'package:bayaa_pos/features/auth/data/models/user_model.dart';
import 'package:bayaa_pos/core/services/activity_logger.dart';
import 'package:bayaa_pos/core/di/dependency_injection.dart';
import 'package:bayaa_pos/core/state/state_synchronizer.dart';
import 'package:bayaa_pos/core/session/session_manager.dart';
import 'package:bayaa_pos/features/auth/presentation/cubit/user_cubit.dart';

class _FakeTransport implements BackendHttpTransport {
  _FakeTransport(this.response, {this.getResponse, this.categoryResponse});

  final BackendHttpResponse response;
  final BackendHttpResponse? getResponse;
  final BackendHttpResponse? categoryResponse;
  String? requestBody;
  Uri? requestedUri;
  Map<String, String>? requestedHeaders;
  bool putCalled = false;
  bool postCalled = false;
  bool deleteCalled = false;

  @override
  Future<BackendHttpResponse> get(
    Uri uri, {
    Map<String, String> headers = const {},
  }) async {
    requestedUri = uri;
    requestedHeaders = headers;
    if (uri.path.endsWith('/categories') && categoryResponse != null) {
      return categoryResponse!;
    }
    return getResponse ?? response;
  }

  @override
  Future<BackendHttpResponse> put(
    Uri uri, {
    Map<String, String> headers = const {},
    String? body,
  }) async {
    requestedUri = uri;
    requestedHeaders = headers;
    requestBody = body;
    putCalled = true;
    return response;
  }

  @override
  Future<BackendHttpResponse> patch(
    Uri uri, {
    Map<String, String> headers = const {},
    String? body,
  }) async {
    requestedUri = uri;
    requestedHeaders = headers;
    requestBody = body;
    return response;
  }

  @override
  Future<BackendHttpResponse> post(
    Uri uri, {
    Map<String, String> headers = const {},
    String? body,
  }) async {
    requestedUri = uri;
    requestedHeaders = headers;
    requestBody = body;
    postCalled = true;
    return response;
  }

  @override
  Future<BackendHttpResponse> delete(
    Uri uri, {
    Map<String, String> headers = const {},
  }) async {
    requestedUri = uri;
    requestedHeaders = headers;
    deleteCalled = true;
    return response;
  }
}

Product _product() => Product(
      id: 'p-create',
      name: 'Created',
      code: 'CREATE-1',
      barcode: '555',
      price: 100,
      minPrice: 90,
      wholesalePrice: 80,
      cost: 50,
      quantity: 42,
      minQuantity: 2,
      category: 'General',
      productType: ProductType.packaged,
    );

class _CubitRepository implements ProductRepositoryInt {
  bool saveCalled = false;
  String? requestedCategory;
  int productListRequestCount = 0;
  Map<String, String> categoryNamesById = {};
  final List<Product> products = [];
  final Map<int, List<Product>> paginatedProducts = {};

  @override
  Future<Either<Failure, void>> saveProductWithOpeningStock(
    Product product, {
    required double openingQuantity,
    required double openingUnitCost,
    required String openingReason,
    String openingNotes = '',
    String? openingUnit,
    required User user,
    List<SellingUnit>? packagedSellingUnits,
    List<OpeningStockLine>? openingLines,
  }) async {
    saveCalled = true;
    return const Right(null);
  }

  @override
  Future<Either<Failure, List<Product>>> getProductsPaginated({
    required int page,
    required int pageSize,
    String? category,
    String? availability,
    String? searchQuery,
  }) async =>
      _captureProductsRequest(category, page);

  Either<Failure, List<Product>> _captureProductsRequest(
    String? category, [
    int page = 0,
  ]) {
    requestedCategory = category;
    productListRequestCount++;
    return Right(
      List<Product>.from(paginatedProducts[page] ?? products),
    );
  }

  @override
  Future<Either<Failure, List<Product>>> getAllProduct() async =>
      const Right([]);

  @override
  Future<Either<Failure, void>> saveProduct(Product product,
          {List<SellingUnit>? packagedSellingUnits}) async =>
      const Right(null);

  @override
  Future<Either<Failure, void>> deleteProduct(String productId) async =>
      _deleteProduct(productId);

  Either<Failure, void> _deleteProduct(String productId) {
    products.removeWhere((product) => product.id == productId);
    return const Right(null);
  }

  @override
  Future<Either<Failure, List<String>>> getAllCategory() async =>
      const Right([]);

  @override
  Future<Either<Failure, Map<String, String>>> getServerCategories() async =>
      const Right({});

  @override
  Future<Either<Failure, Map<String, String>>> getCategoryNamesById() async =>
      Right(categoryNamesById);

  @override
  Future<Either<Failure, String>> resolveCategoryId(
          String categoryName) async =>
      Right(categoryName);

  @override
  Future<Either<Failure, void>> saveCategory(String category) async =>
      const Right(null);

  @override
  Future<Either<Failure, void>> deleteCategory({
    required String category,
    bool forceDelete = false,
    String? newCategory,
  }) async =>
      const Right(null);

  @override
  Future<Either<Failure, bool>> productExists(String barcode) async =>
      const Right(false);

  @override
  Future<Either<Failure, Product?>> findProductByBarcode(
          String barcode) async =>
      const Right(null);
}

class _TestSessionManager implements SessionManager {
  @override
  Future<String> ensureSessionId({String? userName}) async => 'test-session';

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _TestUserCubit implements UserCubit {
  @override
  User get currentUser => User(
        username: 'test',
        name: 'Test',
        phone: '',
        userType: UserType.admin,
        password: '',
      );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  setUpAll(() {
    if (!getIt.isRegistered<ActivityLogger>()) {
      getIt.registerSingleton<ActivityLogger>(ActivityLogger());
    }
  });

  test('local write mode remains the default', () {
    expect(ProductRepositoryImp().writeMode, ProductWriteMode.local);
  });

  test('server write mode can be selected explicitly', () {
    expect(
      ProductRepositoryImp(writeMode: ProductWriteMode.server).writeMode,
      ProductWriteMode.server,
    );
  });

  test('ProductApiRepository maps server product creation', () async {
    final transport = _FakeTransport(
      BackendHttpResponse(
        201,
        jsonEncode({
          'id': 'p-create',
          'name': 'Created',
          'barcode': '555',
          'product_type': 'PACKAGED',
          'price': 100,
          'min_price': 90,
          'wholesale_price': 80,
          'cost': 50,
          'stock': 0,
          'min_stock': 2,
          'is_active': true,
          'selling_units': [
            {
              'id': 'unit-box',
              'name': 'box',
              'conversion_to_base': 10,
              'selling_price': 950,
              'cost_price': 500,
              'is_default': true,
              'is_active': true,
            },
          ],
        }),
      ),
    );
    final tokenStore = BackendTokenStore()..save('token');
    final repository = ProductApiRepository(
      BackendApiClient(tokenStore: tokenStore, transport: transport),
    );

    final result = await repository.createProduct(
      _product(),
      packagedSellingUnits: [
        SellingUnit(
          id: 'unit-box',
          productId: 'p-create',
          name: 'box',
          conversionToBase: 10,
          sellingPrice: 950,
          cost: 500,
          isDefault: true,
        ),
      ],
      openingQuantity: 0,
      openingUnitCost: 0,
      openingReason: 'test',
    );

    expect(result.isRight, isTrue);
    expect(result.right.id, 'p-create');
    expect(result.right.quantity, 0);
    expect(jsonDecode(transport.requestBody!)['stock'], 0);
    expect(jsonDecode(transport.requestBody!)['selling_units'], hasLength(1));
    expect(transport.requestedUri?.path, '/api/v1/products');
  });

  test('ProductApiRepository sends a real category ID', () async {
    final transport = _FakeTransport(
      BackendHttpResponse(201, jsonEncode({'id': 'p-create', 'stock': 0})),
    );
    final repository = ProductApiRepository(
      BackendApiClient(
        tokenStore: BackendTokenStore()..save('token'),
        transport: transport,
      ),
    );

    await repository.createProduct(
      _product().copyWith(category: 'cat-one'),
      openingQuantity: 0,
      openingUnitCost: 0,
      openingReason: 'test',
    );

    expect(jsonDecode(transport.requestBody!)['category_id'], 'cat-one');
  });

  test('ProductApiRepository sends packaged opening lines and never null', () async {
    final transport = _FakeTransport(
      BackendHttpResponse(201, jsonEncode({'id': 'p-create', 'stock': 1020})),
    );
    final repository = ProductApiRepository(
      BackendApiClient(
        tokenStore: BackendTokenStore()..save('token'),
        transport: transport,
      ),
    );

    await repository.createProduct(
      _product().copyWith(productType: ProductType.packaged),
      packagedSellingUnits: [
        SellingUnit(
          id: 'unit-piece',
          productId: 'p-create',
          name: 'Piece',
          conversionToBase: 1,
          sellingPrice: 50,
          isDefault: true,
        ),
        SellingUnit(
          id: 'unit-pack',
          productId: 'p-create',
          name: 'Pack',
          conversionToBase: 30,
          sellingPrice: 900,
        ),
        SellingUnit(
          id: 'unit-box',
          productId: 'p-create',
          name: 'Box',
          conversionToBase: 360,
          sellingPrice: 8500,
        ),
      ],
      openingQuantity: 0,
      openingUnitCost: 0,
      openingReason: 'initial inventory',
      openingLines: const [
        OpeningStockLine(unit: 'Pack', quantity: 10, unitCost: 900),
        OpeningStockLine(unit: 'Box', quantity: 2, unitCost: 8500),
      ],
    );

    final payload = jsonDecode(transport.requestBody!) as Map<String, dynamic>;
    expect(payload['opening_quantity'], 0);
    expect(payload['opening_lines'], hasLength(2));
    expect(payload['selling_units'], hasLength(3));
  });

  test('ProductApiRepository sends an empty opening line list when unused',
      () async {
    final transport = _FakeTransport(
      BackendHttpResponse(201, jsonEncode({'id': 'p-create', 'stock': 0})),
    );
    final repository = ProductApiRepository(
      BackendApiClient(
        tokenStore: BackendTokenStore()..save('token'),
        transport: transport,
      ),
    );

    await repository.createProduct(
      _product(),
      openingQuantity: 0,
      openingUnitCost: 0,
      openingReason: 'initial inventory',
    );

    final payload = jsonDecode(transport.requestBody!) as Map<String, dynamic>;
    expect(payload['opening_lines'], isEmpty);
  });

  test('ProductApiRepository does not send All as a category ID', () async {
    final transport = _FakeTransport(
      BackendHttpResponse(201, jsonEncode({'id': 'p-create', 'stock': 0})),
    );
    final repository = ProductApiRepository(
      BackendApiClient(
        tokenStore: BackendTokenStore()..save('token'),
        transport: transport,
      ),
    );

    await repository.createProduct(
      _product().copyWith(category: 'الكل'),
      openingQuantity: 0,
      openingUnitCost: 0,
      openingReason: 'test',
    );

    expect(jsonDecode(transport.requestBody!)['category_id'], isNull);
  });

  test('server write propagates API failure without SQLite fallback', () async {
    final transport = _FakeTransport(
      const BackendHttpResponse(409, '{"detail":"Barcode already exists"}'),
    );
    final tokenStore = BackendTokenStore()..save('token');
    final apiRepository = ProductApiRepository(
      BackendApiClient(tokenStore: tokenStore, transport: transport),
    );
    final repository = ProductRepositoryImp(
      serverReadRepository: apiRepository,
      writeMode: ProductWriteMode.server,
    );

    final result = await repository.saveProduct(_product());

    expect(result.isLeft, isTrue);
    expect(result.left.message, 'Barcode already exists');
  });

  test('server zero-opening save reaches product creation API', () async {
    final transport = _FakeTransport(
      BackendHttpResponse(
        201,
        jsonEncode({
          'id': 'p-create',
          'name': 'Created',
          'barcode': '555',
          'product_type': 'STANDARD',
          'stock': 0,
          'price': 100,
          'min_price': 90,
          'wholesale_price': 80,
          'cost': 50,
          'min_stock': 2,
          'is_active': true,
        }),
      ),
      getResponse:
          const BackendHttpResponse(404, '{"detail":"Product not found"}'),
    );
    final apiRepository = ProductApiRepository(
      BackendApiClient(
        tokenStore: BackendTokenStore()..save('token'),
        transport: transport,
      ),
    );
    final repository = ProductRepositoryImp(
      serverReadRepository: apiRepository,
      writeMode: ProductWriteMode.server,
    );

    final result = await repository.saveProductWithOpeningStock(
      _product(),
      openingQuantity: 0,
      openingUnitCost: 0,
      openingReason: 'test',
      user: User(
        username: 'test',
        name: 'Test',
        phone: '',
        userType: UserType.admin,
        password: '',
      ),
    );

    expect(result.isRight, isTrue);
    expect(transport.requestedUri?.path, '/api/v1/products');
  });

  test('successful server creation emits no local state-change event',
      () async {
    final transport = _FakeTransport(
      BackendHttpResponse(
        201,
        jsonEncode({
          'id': 'p-create',
          'name': 'Created',
          'barcode': '555',
          'product_type': 'STANDARD',
          'stock': 0,
        }),
      ),
    );
    final repository = ProductRepositoryImp(
      serverReadRepository: ProductApiRepository(
        BackendApiClient(
          tokenStore: BackendTokenStore()..save('token'),
          transport: transport,
        ),
      ),
      writeMode: ProductWriteMode.server,
    );
    final events = <DataChangeEvent>[];
    final subscription = StateSynchronizer.events.listen(events.add);
    addTearDown(subscription.cancel);

    final result = await repository.saveProduct(_product());
    await Future<void>.delayed(Duration.zero);

    expect(result.isRight, isTrue);
    expect(events, isEmpty);
  });

  test('existing server product uses PUT and never POSTs create', () async {
    final transport = _FakeTransport(
      BackendHttpResponse(
        200,
        jsonEncode({
          'id': 'p-create',
          'name': 'Updated',
          'barcode': '555',
          'product_type': 'STANDARD',
          'stock': 0,
        }),
      ),
    );
    final repository = ProductRepositoryImp(
      serverReadRepository: ProductApiRepository(
        BackendApiClient(
          tokenStore: BackendTokenStore()..save('token'),
          transport: transport,
        ),
      ),
      writeMode: ProductWriteMode.server,
    );

    final result = await repository.saveProduct(_product());

    expect(result.isRight, isTrue);
    expect(transport.putCalled, isTrue);
    expect(transport.postCalled, isFalse);
    expect(transport.requestedUri?.path, '/api/v1/products/p-create');
  });

  test('server product delete uses DELETE and bypasses local persistence',
      () async {
    final transport = _FakeTransport(
      BackendHttpResponse(
        200,
        jsonEncode({
          'id': 'p-create',
          'name': 'Created',
          'barcode': '555',
          'product_type': 'STANDARD',
          'stock': 0,
          'price': 100,
          'min_price': 90,
          'wholesale_price': 80,
          'cost': 50,
          'min_stock': 2,
          'is_active': false,
        }),
      ),
      getResponse: BackendHttpResponse(
        200,
        jsonEncode({
          'items': <dynamic>[],
          'total': 0,
          'page': 1,
          'page_size': 50,
        }),
      ),
      categoryResponse: const BackendHttpResponse(200, '[]'),
    );
    final repository = ProductRepositoryImp(
      serverReadRepository: ProductApiRepository(
        BackendApiClient(
          tokenStore: BackendTokenStore()..save('token'),
          transport: transport,
        ),
      ),
      writeMode: ProductWriteMode.server,
      readMode: ProductReadMode.server,
    );

    final result = await repository.deleteProduct('p-create');

    expect(result.isRight, isTrue);
    expect(transport.deleteCalled, isTrue);
    expect(transport.requestedUri?.path, '/api/v1/products/p-create');
    expect(transport.requestedHeaders?['Authorization'], isNotNull);

    final products = await repository.getAllProduct();
    expect(products.isRight, isTrue);
    expect(products.right, isEmpty);
    expect(transport.requestedUri?.path, '/api/v1/products');
  });

  test('server write sends nonzero opening stock to the API', () async {
    final transport = _FakeTransport(
      BackendHttpResponse(
        201,
        jsonEncode({
          'id': 'p-create',
          'name': 'Created',
          'barcode': '555',
          'product_type': 'STANDARD',
          'stock': 1,
          'price': 100,
          'min_price': 90,
          'wholesale_price': 80,
          'cost': 50,
          'min_stock': 2,
          'is_active': true,
        }),
      ),
      getResponse:
          const BackendHttpResponse(404, '{"detail":"Product not found"}'),
    );
    final repository = ProductRepositoryImp(
      serverReadRepository: ProductApiRepository(
        BackendApiClient(
          tokenStore: BackendTokenStore()..save('token'),
          transport: transport,
        ),
      ),
      writeMode: ProductWriteMode.server,
    );

    final result = await repository.saveProductWithOpeningStock(
      _product(),
      openingQuantity: 1,
      openingUnitCost: 50,
      openingReason: 'test',
      user: User(
        username: 'test',
        name: 'Test',
        phone: '',
        userType: UserType.admin,
        password: '',
      ),
    );

    expect(result.isRight, isTrue);
    expect(transport.requestedUri?.path, '/api/v1/products');
    final request = jsonDecode(transport.requestBody!) as Map<String, dynamic>;
    expect(request['opening_quantity'], 1);
    expect(request['opening_unit_cost'], 50);
    expect(request['opening_reason'], 'test');
  });

  test('ProductCubit forwards server zero-opening save without local lookup',
      () async {
    final repository = _CubitRepository();
    final cubit = ProductCubit(productRepositoryInt: repository);
    final result = await cubit.saveProductWithOpeningStock(
      _product(),
      openingQuantity: 0,
      openingUnitCost: 0,
      openingReason: 'test',
      user: User(
        username: 'test',
        name: 'Test',
        phone: '',
        userType: UserType.admin,
        password: '',
      ),
    );

    expect(result.isRight, isTrue);
    expect(repository.saveCalled, isTrue);
    await cubit.close();
  });

  test('ProductCubit maps a server category name to its server ID', () async {
    final repository = _CubitRepository();
    final cubit = ProductCubit(productRepositoryInt: repository);
    cubit.serverCategoryIds['Soft Drinks'] = 'dev-soft-drinks';
    repository.categoryNamesById['dev-soft-drinks'] = 'Soft Drinks';

    cubit.filterByCategory('Soft Drinks');
    await Future<void>.delayed(const Duration(milliseconds: 1));

    expect(repository.requestedCategory, 'dev-soft-drinks');
    await cubit.close();
  });

  test('ProductCubit resolves loaded local category IDs for product display',
      () async {
    final repository = _CubitRepository()
      ..categoryNamesById = {
        'local-category-id': 'Beverages',
      }
      ..products.add(
        Product(
          id: 'local-cola',
          name: 'Test Standard Cola',
          price: 10,
          minPrice: 0,
          wholesalePrice: 0,
          quantity: 5,
          minQuantity: 0,
          category: 'local-category-id',
        ),
      );
    final cubit = ProductCubit(productRepositoryInt: repository);

    await cubit.getAllProducts();

    expect(cubit.allProducts.single.category, 'local-category-id');
    expect(cubit.allProducts.single.displayCategoryName, 'Beverages');
    expect(cubit.allProducts.single.displayCategoryName,
        isNot('local-category-id'));
    await cubit.close();
  });

  test('ProductCubit resolves categories for products loaded on later pages',
      () async {
    const categoryId = 'category-f6365b94d0664daa89a0539ffd286d7';
    final repository = _CubitRepository()
      ..categoryNamesById[categoryId] = 'Beverages'
      ..paginatedProducts[0] = List<Product>.generate(
        ProductCubit.pageSize,
        (index) => Product(
          id: 'page-one-$index',
          name: 'Page one product $index',
          barcode: 'page-one-$index',
          price: 10,
          minPrice: 0,
          wholesalePrice: 0,
          quantity: 5,
          minQuantity: 0,
          category: 'General',
        ),
      )
      ..paginatedProducts[1] = [
        Product(
          id: 'cola-page-two',
          name: 'Test Standard Cola',
          barcode: 'cola-001',
          price: 10,
          minPrice: 80,
          wholesalePrice: 90,
          quantity: 5,
          minQuantity: 0,
          category: categoryId,
        ),
      ];
    final cubit = ProductCubit(productRepositoryInt: repository);

    await cubit.getAllProducts();
    cubit.loadMoreProducts();
    await Future<void>.delayed(Duration.zero);

    final cola = cubit.allProducts
        .singleWhere((product) => product.id == 'cola-page-two');
    expect(cola.category, categoryId);
    expect(cola.displayCategoryName, 'Beverages');
    await cubit.close();
  });

  test('ProductCubit omits the category filter for All', () async {
    final repository = _CubitRepository();
    final cubit = ProductCubit(productRepositoryInt: repository);
    cubit.serverCategoryIds['Soft Drinks'] = 'dev-soft-drinks';
    repository.categoryNamesById['dev-soft-drinks'] = 'Soft Drinks';

    cubit.filterByCategory('*');
    await Future<void>.delayed(const Duration(milliseconds: 1));

    expect(repository.requestedCategory, isNull);
    await cubit.close();
  });

  test('ProductCubit rejects an unknown server category without a request',
      () async {
    final repository = _CubitRepository();
    final cubit = ProductCubit(productRepositoryInt: repository);
    cubit.serverCategoryIds['Soft Drinks'] = 'dev-soft-drinks';
    repository.categoryNamesById['dev-soft-drinks'] = 'Soft Drinks';

    cubit.filterByCategory('Missing Category');
    await Future<void>.delayed(const Duration(milliseconds: 1));

    expect(repository.requestedCategory, isNull);
    expect(cubit.state, isA<ProductErrorState>());
    await cubit.close();
  });

  test('ProductCubit preserves local category filter values', () async {
    final repository = _CubitRepository();
    final cubit = ProductCubit(productRepositoryInt: repository);

    cubit.filterByCategory('local-category-id');
    await Future<void>.delayed(const Duration(milliseconds: 1));

    expect(repository.requestedCategory, 'local-category-id');
    await cubit.close();
  });

  test('ProductCubit refreshes active products from server after deletion',
      () async {
    final repository = _CubitRepository()..products.add(_product());
    final cubit = ProductCubit(productRepositoryInt: repository)
      ..products = [_product()];
    final previousListRequestCount = repository.productListRequestCount;

    getIt.registerSingleton<SessionManager>(_TestSessionManager());
    getIt.registerSingleton<UserCubit>(_TestUserCubit());
    addTearDown(() async {
      await cubit.close();
      await getIt.unregister<UserCubit>();
      await getIt.unregister<SessionManager>();
    });

    await cubit.deleteProduct('p-create');

    expect(repository.productListRequestCount, previousListRequestCount + 1);
    expect(repository.products, isEmpty);
    expect(cubit.products, isEmpty);
    expect(cubit.state, isA<ProductSuccessState>());
  });
}
