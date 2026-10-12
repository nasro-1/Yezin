import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:bayaa_pos/core/network/backend_api_client.dart';
import 'package:bayaa_pos/core/network/backend_api_error.dart';
import 'package:bayaa_pos/core/network/backend_api_config.dart';
import 'package:bayaa_pos/core/network/backend_token_store.dart';
import 'package:bayaa_pos/features/products/data/repository/product_api_repository.dart';
import 'package:bayaa_pos/features/auth/data/models/user_model.dart';
import 'package:bayaa_pos/features/stock/data/models/stock_adjustment_model.dart';
import 'package:bayaa_pos/features/stock/data/repository/stock_adjustment_api_repository.dart';
import 'package:bayaa_pos/features/stock/services/stock_adjustment_service.dart';

class FakeTransport implements BackendHttpTransport {
  FakeTransport(this.response, {this.categoryResponse});

  BackendHttpResponse response;
  final BackendHttpResponse? categoryResponse;
  Uri? requestedUri;
  Map<String, String>? requestedHeaders;
  Map<String, String>? rawRequestedHeaders;
  String? requestedBody;

  void _captureHeaders(Map<String, String> headers) {
    rawRequestedHeaders = headers;
    requestedHeaders = headers.map(
      (key, value) => MapEntry(
        key,
        key.toLowerCase() == 'authorization' ? '******' : value,
      ),
    );
  }

  @override
  Future<BackendHttpResponse> get(
    Uri uri, {
    Map<String, String> headers = const {},
  }) async {
    requestedUri = uri;
    _captureHeaders(headers);
    if (uri.path.endsWith('/categories') && categoryResponse != null) {
      return categoryResponse!;
    }
    return response;
  }

  @override
  Future<BackendHttpResponse> put(
    Uri uri, {
    Map<String, String> headers = const {},
    String? body,
  }) async {
    requestedUri = uri;
    _captureHeaders(headers);
    return response;
  }

  @override
  Future<BackendHttpResponse> patch(
    Uri uri, {
    Map<String, String> headers = const {},
    String? body,
  }) async {
    requestedUri = uri;
    _captureHeaders(headers);
    requestedBody = body;
    return response;
  }

  @override
  Future<BackendHttpResponse> post(
    Uri uri, {
    Map<String, String> headers = const {},
    String? body,
  }) async {
    requestedUri = uri;
    _captureHeaders(headers);
    requestedBody = body;
    return response;
  }

  @override
  Future<BackendHttpResponse> delete(
    Uri uri, {
    Map<String, String> headers = const {},
  }) async {
    requestedUri = uri;
    _captureHeaders(headers);
    return response;
  }
}

class CategoryResolutionTransport implements BackendHttpTransport {
  int categoryRequests = 0;
  final product = {
    'id': 'product-cola',
    'name': 'Test Standard Cola',
    'price': 10,
    'min_price': 0,
    'wholesale_price': 0,
    'stock': 5,
    'min_stock': 0,
    'category_id': 'category-4b05821fb0614afa90f8e13bf212840f',
    'category_name': 'Untrusted response value',
    'is_active': true,
  };

  @override
  Future<BackendHttpResponse> get(
    Uri uri, {
    Map<String, String> headers = const {},
  }) async {
    if (uri.path.endsWith('/categories')) {
      categoryRequests++;
      return const BackendHttpResponse(
        200,
        '[{"id":"category-4b05821fb0614afa90f8e13bf212840f",'
        '"name":"Beverages"}]',
      );
    }
    if (uri.path.endsWith('/products')) {
      return BackendHttpResponse(
        200,
        jsonEncode({
          'items': [
            product,
            {
              ...product,
              'id': 'product-unknown-category',
              'category_id': 'category-not-in-shop-list',
            },
          ],
          'total': 2,
          'page': 1,
          'page_size': 50,
        }),
      );
    }
    return const BackendHttpResponse(404, '{}');
  }

  @override
  Future<BackendHttpResponse> post(Uri uri,
          {Map<String, String> headers = const {}, String? body}) async =>
      const BackendHttpResponse(404, '{}');

  @override
  Future<BackendHttpResponse> put(Uri uri,
          {Map<String, String> headers = const {}, String? body}) async =>
      const BackendHttpResponse(404, '{}');

  @override
  Future<BackendHttpResponse> patch(Uri uri,
          {Map<String, String> headers = const {}, String? body}) async =>
      const BackendHttpResponse(404, '{}');

  @override
  Future<BackendHttpResponse> delete(Uri uri,
          {Map<String, String> headers = const {}}) async =>
      const BackendHttpResponse(404, '{}');
}

void main() {
  test('maps each server role to its own user regardless of response order',
      () {
    final users = [
      {
        'username': 'manager',
        'display_name': 'Manager',
        'role': 'manager',
      },
      {
        'username': 'admin',
        'display_name': 'Admin',
        'role': 'admin',
      },
      {
        'username': 'cashier',
        'display_name': 'Cashier',
        'role': 'cashier',
      },
      {
        'username': 'cashier-1',
        'display_name': 'Cashier 1',
        'role': 'cashier',
      },
    ].map(User.fromServerMap).toList();

    final rolesByUsername = {
      for (final user in users) user.username: user.userType,
    };
    expect(rolesByUsername['manager'], UserType.manager);
    expect(rolesByUsername['admin'], UserType.admin);
    expect(rolesByUsername['cashier'], UserType.cashier);
    expect(rolesByUsername['cashier-1'], UserType.cashier);
  });

  test('backend login sends server-compatible credentials and caches identity',
      () async {
    final transport = FakeTransport(
      BackendHttpResponse(
        200,
        '{"access_token":"token","user_id":"admin","shop_id":"dev-shop","role":"admin"}',
      ),
    );
    final client = BackendApiClient(
      config: const BackendApiConfig(baseUrl: 'http://127.0.0.1:8010/api/v1'),
      transport: transport,
    );

    final response = await client.login(
      username: 'admin',
      password: 'admin',
      deviceId: 'bayaa-test',
    );

    expect(jsonDecode(transport.requestedBody!), {
      'username': 'admin',
      'password': 'admin',
    });
    expect(response['user_id'], 'admin');
    expect(client.tokenStore.userId, 'admin');
    expect(client.tokenStore.shopId, 'dev-shop');
    expect(client.tokenStore.role, 'admin');
  });

  test('IoBackendHttpTransport sends Arabic JSON as UTF-8 bytes', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final requestBody = server.first.then((request) async {
      final bytes = await request.fold<List<int>>(
        <int>[],
        (collected, chunk) => collected..addAll(chunk),
      );
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write('{"ok":true}');
      await request.response.close();
      return bytes;
    });
    addTearDown(server.close);

    final body = jsonEncode({'opening_reason': 'المخزون الافتتاحي'});
    final response = await const IoBackendHttpTransport().post(
      Uri.parse('http://127.0.0.1:${server.port}/products'),
      headers: const {'Content-Type': 'application/json; charset=utf-8'},
      body: body,
    );

    expect(response.statusCode, 200);
    expect(jsonDecode(utf8.decode(await requestBody))['opening_reason'],
        'المخزون الافتتاحي');
  });

  test('IoBackendHttpTransport sends ASCII JSON as UTF-8 bytes', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final requestBody = server.first.then((request) async {
      final bytes = await request.fold<List<int>>(
        <int>[],
        (collected, chunk) => collected..addAll(chunk),
      );
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write('{"ok":true}');
      await request.response.close();
      return bytes;
    });
    addTearDown(server.close);

    final body = jsonEncode({'name': 'Created', 'stock': 15});
    final response = await const IoBackendHttpTransport().post(
      Uri.parse('http://127.0.0.1:${server.port}/products'),
      headers: const {'Content-Type': 'application/json; charset=utf-8'},
      body: body,
    );

    expect(response.statusCode, 200);
    expect(jsonDecode(utf8.decode(await requestBody)),
        {'name': 'Created', 'stock': 15});
  });

  const product = {
    'id': 'p1',
    'name': 'Phone',
    'code': 'PHONE-1',
    'barcode': '123',
    'product_type': 'PACKAGED',
    'base_unit': 'piece',
    'quantity_precision': 3,
    'allow_partial_package_sale': false,
    'price': 100,
    'min_price': 90,
    'wholesale_price': 80,
    'cost': 50,
    'stock': 4,
    'min_stock': 2,
    'category_id': 'cat1',
    'is_active': true,
    'selling_units': [
      {
        'id': 'u1',
        'product_id': 'p1',
        'name': 'piece',
        'conversion_to_base': 1,
        'selling_price': 100,
        'cost_price': 50,
        'barcode': '123-piece',
        'is_default': true,
        'is_active': true,
      },
      {
        'id': 'u2',
        'product_id': 'p1',
        'name': 'box',
        'conversion_to_base': 10,
        'selling_price': 950,
        'cost_price': 500,
        'wholesale_price': 900,
        'barcode': '123-box',
        'is_default': false,
        'is_active': true,
      },
    ],
  };

  test('maps product fields and all active packaged selling units', () async {
    final transport = FakeTransport(
      BackendHttpResponse(
        200,
        jsonEncode({
          'items': [product]
        }),
      ),
      categoryResponse: const BackendHttpResponse(200, '[]'),
    );
    final tokenStore = BackendTokenStore()..save('token');
    final repository = ProductApiRepository(
      BackendApiClient(tokenStore: tokenStore, transport: transport),
    );

    final result = await repository.getProducts(page: 0, pageSize: 20);

    expect(result.isRight, isTrue);
    final mapped = result.right.first;
    expect(mapped.code, 'PHONE-1');
    expect(mapped.barcode, '123');
    expect(mapped.quantity, 4);
    expect(mapped.sellingUnits.map((unit) => unit.name), ['piece', 'box']);
    expect(mapped.sellingUnits.last.conversionToBase, 10);
    expect(transport.requestedHeaders?['Authorization'], isNotNull);
    expect(transport.requestedUri?.queryParameters['page'], '1');
  });

  test('uses the real bearer token for authenticated GET requests', () async {
    final transport = FakeTransport(
      const BackendHttpResponse(200, '{"items":[]}'),
      categoryResponse: const BackendHttpResponse(200, '[]'),
    );
    final client = BackendApiClient(
      tokenStore: BackendTokenStore()..save('real-token'),
      transport: transport,
    );

    await client.getProducts();

    expect(
        transport.rawRequestedHeaders?['Authorization'], 'Bearer real-token');
    expect(transport.rawRequestedHeaders?['Authorization'], isNot('******'));
  });

  test('accepts a 204 draft response without reporting invalid JSON', () async {
    final client = BackendApiClient(
      tokenStore: BackendTokenStore()..save('token'),
      transport: FakeTransport(const BackendHttpResponse(204, '')),
    );

    final result = await client.updateSaleDraft(
      'draft-1',
      const {'items': <Map<String, dynamic>>[]},
      version: 1,
    );

    expect(result, isEmpty);
  });

  test('reports status and non-JSON body for draft errors', () async {
    final client = BackendApiClient(
      tokenStore: BackendTokenStore()..save('token'),
      transport: FakeTransport(
        const BackendHttpResponse(502, '<html>proxy failure</html>'),
      ),
    );

    await expectLater(
      client.updateSaleDraft(
        'draft-1',
        const {'items': <Map<String, dynamic>>[]},
        version: 1,
      ),
      throwsA(
        isA<BackendApiException>()
            .having((error) => error.statusCode, 'status', 502)
            .having(
                (error) => error.message, 'body', contains('proxy failure')),
      ),
    );
  });

  test('maps standard API status codes to typed errors', () async {
    for (final entry in <int, BackendApiErrorKind>{
      401: BackendApiErrorKind.authentication,
      403: BackendApiErrorKind.authorization,
      404: BackendApiErrorKind.notFound,
      409: BackendApiErrorKind.conflict,
      422: BackendApiErrorKind.validation,
      500: BackendApiErrorKind.server,
    }.entries) {
      final transport = FakeTransport(
        BackendHttpResponse(entry.key, '{"detail":"failure"}'),
      );
      final client = BackendApiClient(
        tokenStore: BackendTokenStore()..save('token'),
        transport: transport,
      );

      await expectLater(
        client.getProducts(),
        throwsA(
          isA<BackendApiException>().having(
            (error) => error.errorKind,
            'kind',
            entry.value,
          ),
        ),
      );
    }
  });

  test('sends the server category ID when filtering products', () async {
    final transport = FakeTransport(
      BackendHttpResponse(
        200,
        jsonEncode({
          'items': [product],
        }),
      ),
      categoryResponse: const BackendHttpResponse(200, '[]'),
    );
    final tokenStore = BackendTokenStore()..save('token');
    final repository = ProductApiRepository(
      BackendApiClient(tokenStore: tokenStore, transport: transport),
    );

    await repository.getProducts(
      page: 0,
      pageSize: 50,
      category: 'dev-soft-drinks',
    );

    expect(
      transport.requestedUri?.queryParameters['category_id'],
      'dev-soft-drinks',
    );
  });

  test('omits the category ID for the All sentinel', () async {
    final transport = FakeTransport(
      BackendHttpResponse(
        200,
        jsonEncode({
          'items': [product],
        }),
      ),
      categoryResponse: const BackendHttpResponse(200, '[]'),
    );
    final tokenStore = BackendTokenStore()..save('token');
    final repository = ProductApiRepository(
      BackendApiClient(tokenStore: tokenStore, transport: transport),
    );

    await repository.getProducts(page: 0, pageSize: 50, category: '*');

    expect(
      transport.requestedUri?.queryParameters.containsKey('category_id'),
      isFalse,
    );
  });

  test('maps barcode lookup through the API client', () async {
    final transport = FakeTransport(
      BackendHttpResponse(
          200,
          '{"id":"p1","name":"Phone","barcode":"123",'
          '"price":100,"min_price":0,"wholesale_price":0,"stock":1,'
          '"min_stock":0,"is_active":true}'),
    );
    final tokenStore = BackendTokenStore()..save('token');
    final client =
        BackendApiClient(tokenStore: tokenStore, transport: transport);

    final payload = await client.getProductByBarcode('123');

    expect(payload['barcode'], '123');
    expect(transport.requestedUri?.path, '/api/v1/products/barcode/123');
  });

  test('loads authenticated server categories with IDs', () async {
    final transport = FakeTransport(
      const BackendHttpResponse(
        200,
        '[{"id":"dev-soft-drinks","name":"Soft Drinks"}]',
      ),
    );
    final client = BackendApiClient(
      tokenStore: BackendTokenStore()..save('token'),
      transport: transport,
    );

    expect(await client.getCategories(), [
      {'id': 'dev-soft-drinks', 'name': 'Soft Drinks'},
    ]);
    expect(transport.requestedUri?.path, '/api/v1/categories');
  });

  test('server products resolve category IDs from the server category list',
      () async {
    final transport = CategoryResolutionTransport();
    final client = BackendApiClient(
      tokenStore: BackendTokenStore()..save('token'),
      transport: transport,
    );
    final repository = ProductApiRepository(client);

    final firstPage = await repository.getProducts(page: 0, pageSize: 50);
    final secondPage = await repository.getProducts(page: 1, pageSize: 50);

    expect(firstPage.isRight, isTrue);
    final product = firstPage.right.first;
    expect(product.category, 'category-4b05821fb0614afa90f8e13bf212840f');
    expect(product.displayCategoryName, 'Beverages');
    expect(product.displayCategoryName, isNot(contains(product.category)));
    expect(firstPage.right.last.displayCategoryName, isEmpty);
    expect(secondPage.isRight, isTrue);
    expect(transport.categoryRequests, 1);
  });

  test('creates and deletes categories through authenticated server APIs',
      () async {
    final transport = FakeTransport(
      const BackendHttpResponse(201, '{"id":"category-1","name":"Good"}'),
    );
    final client = BackendApiClient(
      tokenStore: BackendTokenStore()..save('token'),
      transport: transport,
    );
    expect(await client.createCategory(' Good '), {
      'id': 'category-1',
      'name': 'Good',
    });
    expect(transport.requestedUri?.path, '/api/v1/categories');
    expect(transport.requestedHeaders?['Authorization'], isNotNull);

    transport.response =
        const BackendHttpResponse(200, '{"id":"category-1","name":"Good"}');
    expect(await client.deleteCategory('category-1'), {
      'id': 'category-1',
      'name': 'Good',
    });
    expect(transport.requestedUri?.path, '/api/v1/categories/category-1');
    expect(transport.requestedHeaders?['Authorization'], isNotNull);
  });

  test('surfaces API errors and missing authentication', () async {
    final errorTransport = FakeTransport(
      const BackendHttpResponse(404, '{"detail":"Product not found"}'),
    );
    final client = BackendApiClient(transport: errorTransport);
    final repository = ProductApiRepository(client);

    final missingToken = await repository.getProduct('p1');
    expect(missingToken.isLeft, isTrue);

    final tokenStore = BackendTokenStore()..save('token');
    final authenticated = ProductApiRepository(
      BackendApiClient(tokenStore: tokenStore, transport: errorTransport),
    );
    final missingProduct = await authenticated.getProduct('p1');
    expect(missingProduct.isLeft, isTrue);
    expect(missingProduct.left.message, 'Product not found');
  });

  test(
      'server stock adjustment posts authenticated reason and notes without SQLite',
      () async {
    final transport = FakeTransport(
      BackendHttpResponse(
        201,
        jsonEncode({
          'document_id': 'adjustment-1',
          'reference_number': 'ADJ-1',
          'idempotency_key': 'key-1',
          'adjustment_date': '2026-09-17T12:00:00.000Z',
          'reason': 'Physical count',
          'notes': 'Server note',
          'posted_at': '2026-09-17T12:00:00.000Z',
          'posted_by': 'user-1',
          'lines': [
            {
              'id': 'line-1',
              'document_id': 'adjustment-1',
              'product_id': 'p1',
              'product_name': 'Phone',
              'product_barcode': '123',
              'unit': 'piece',
              'current_quantity': 4,
              'counted_quantity': 7,
              'quantity_change': 3,
              'unit_cost': 50,
              'line_total': 150,
              'running_stock': 7,
              'created_at': '2026-09-17T12:00:00.000Z',
            }
          ],
          'product': {},
        }),
      ),
    );
    final tokenStore = BackendTokenStore()..save('token');
    final service = StockAdjustmentService(
      writeMode: ProductWriteMode.server,
      apiRepository: StockAdjustmentApiRepository(
        BackendApiClient(tokenStore: tokenStore, transport: transport),
      ),
    );

    final result = await service.post(
      idempotencyKey: 'key-1',
      user: User(
        username: 'manager',
        name: 'Manager',
        phone: '',
        password: '',
        userType: UserType.manager,
      ),
      reason: 'Physical count',
      notes: 'Server note',
      lines: const [
        StockAdjustmentLineInput(
          productId: 'p1',
          countedQuantity: 7,
          unitCost: 50,
          unit: 'piece',
          operation: 'add',
        ),
      ],
    );

    expect(result.lines.single.countedQuantity, 7);
    expect(result.reason, 'Physical count');
    expect(transport.requestedUri?.path, '/api/v1/stock/adjustments');
    expect(transport.requestedHeaders?['Authorization'], isNotNull);
    final request =
        jsonDecode(transport.requestedBody!) as Map<String, dynamic>;
    expect(request['reason'], 'Physical count');
    expect(request['notes'], 'Server note');
  });
}
