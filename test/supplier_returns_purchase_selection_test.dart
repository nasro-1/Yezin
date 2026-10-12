import 'dart:convert';

import 'package:bayaa_pos/core/di/dependency_injection.dart';
import 'package:bayaa_pos/core/error/failure.dart';
import 'package:bayaa_pos/core/network/authority_context.dart';
import 'package:bayaa_pos/core/network/backend_api_client.dart';
import 'package:bayaa_pos/core/network/backend_token_store.dart';
import 'package:bayaa_pos/core/services/activity_logger.dart';
import 'package:bayaa_pos/features/auth/data/models/user_model.dart';
import 'package:bayaa_pos/features/auth/domain/repository/user_repository_int.dart';
import 'package:bayaa_pos/features/auth/presentation/cubit/user_cubit.dart';
import 'package:bayaa_pos/features/products/data/repository/product_api_repository.dart';
import 'package:bayaa_pos/features/products/domain/product_repository_int.dart';
import 'package:bayaa_pos/features/products/presentation/cubit/product_cubit.dart';
import 'package:bayaa_pos/features/purchases/data/repository/purchase_api_repository.dart';
import 'package:bayaa_pos/features/purchases/data/repository/purchase_repository_impl.dart';
import 'package:bayaa_pos/features/sessions/data/repositories/session_repository_impl.dart';
import 'package:bayaa_pos/features/suppliers/data/models/supplier_model.dart';
import 'package:bayaa_pos/features/suppliers/data/models/supplier_return_model.dart';
import 'package:bayaa_pos/features/suppliers/data/repository/supplier_repository_impl.dart';
import 'package:bayaa_pos/features/suppliers/data/repository/supplier_return_repository_impl.dart';
import 'package:bayaa_pos/features/suppliers/presentation/supplier_returns_screen.dart';
import 'package:bayaa_pos/l10n/app_localizations.dart';
import 'package:dartz/dartz.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _SupplierRepository implements SupplierRepository {
  _SupplierRepository(this.supplier);

  final Supplier supplier;
  var balanceReads = 0;
  var ledgerReads = 0;

  @override
  Future<Either<Failure, List<Supplier>>> getAllSuppliers() async =>
      Right([supplier]);

  @override
  Future<Either<Failure, double>> getSupplierBalance(String supplierId) async {
    balanceReads++;
    return const Right(500);
  }

  @override
  Future<Either<Failure, List<Map<String, dynamic>>>> getSupplierLedger(
    String supplierId,
  ) async {
    ledgerReads++;
    return const Right([]);
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _SupplierReturnRepository implements SupplierReturnRepository {
  _SupplierReturnRepository({
    required this.localPurchases,
    required this.localItems,
  });

  final List<Map<String, dynamic>> localPurchases;
  final List<Map<String, dynamic>> localItems;
  var purchaseListReads = 0;
  var purchaseItemReads = 0;
  var createCalls = 0;
  SupplierReturn? createdReturn;

  @override
  Future<Either<Failure, List<Map<String, dynamic>>>> getPurchasesForSupplier(
      String supplierId) async {
    purchaseListReads++;
    return Right(localPurchases);
  }

  @override
  Future<Either<Failure, List<Map<String, dynamic>>>> getPurchaseItems(
      String purchaseId) async {
    purchaseItemReads++;
    return Right(localItems);
  }

  @override
  Future<Either<Failure, Unit>> createReturn(SupplierReturn value) async {
    createCalls++;
    createdReturn = value;
    return const Right(unit);
  }

  @override
  Future<Either<Failure, List<Map<String, dynamic>>>>
      getReturnHistory() async => const Right([]);
}

class _UnusedProductRepository implements ProductRepositoryInt {
  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RefreshProductCubit extends ProductCubit {
  _RefreshProductCubit()
      : super(productRepositoryInt: _UnusedProductRepository());

  var refreshCalls = 0;

  @override
  Future<void> getAllProducts() async {
    refreshCalls++;
  }
}

class _UnusedUserRepository implements UserRepositoryInt {
  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ProductTransport implements BackendHttpTransport {
  _ProductTransport({
    required this.resolveProduct,
    required this.purchases,
  });

  final bool resolveProduct;
  final List<Map<String, dynamic>> purchases;
  final requests = <Uri>[];

  @override
  Future<BackendHttpResponse> get(
    Uri uri, {
    Map<String, String> headers = const {},
  }) async {
    requests.add(uri);
    if (uri.path == '/api/v1/purchases') {
      return BackendHttpResponse(
        200,
        jsonEncode({'items': purchases, 'total': purchases.length}),
      );
    }
    if (!resolveProduct) {
      return const BackendHttpResponse(404, '{"detail":"Not found"}');
    }
    return BackendHttpResponse(
      200,
      jsonEncode({
        'id': 'product-1790605869303686',
        'name': 'Olive Oil Premium',
        'price': 1200,
        'min_price': 1000,
        'wholesale_price': 0,
        'cost': 900,
        'stock': 10,
        'min_stock': 0,
        'category_id': 'category-1',
        'quantity_precision': 3,
        'selling_units': [],
      }),
    );
  }

  @override
  Future<BackendHttpResponse> post(
    Uri uri, {
    Map<String, String> headers = const {},
    String? body,
  }) async =>
      const BackendHttpResponse(404, '{}');

  @override
  Future<BackendHttpResponse> put(
    Uri uri, {
    Map<String, String> headers = const {},
    String? body,
  }) async =>
      const BackendHttpResponse(404, '{}');

  @override
  Future<BackendHttpResponse> patch(
    Uri uri, {
    Map<String, String> headers = const {},
    String? body,
  }) async =>
      const BackendHttpResponse(404, '{}');

  @override
  Future<BackendHttpResponse> delete(
    Uri uri, {
    Map<String, String> headers = const {},
  }) async =>
      const BackendHttpResponse(404, '{}');
}

final _supplier = Supplier(
  id: 'server-supplier-1',
  code: 'SUP-000001',
  name: 'Test Supplier',
  phone: '0550000000',
  createdAt: DateTime(2026, 9, 29),
  updatedAt: DateTime(2026, 9, 29),
);

Map<String, dynamic> _serverPurchase(
        {String supplierId = 'server-supplier-1',
        String purchaseId = 'purchase-1'}) =>
    {
      'id': purchaseId,
      'reference': 'PUR-1790707886631140-1',
      'supplier_id': supplierId,
      'purchase_date': '2026-09-29T10:00:00',
      'total': '9000.00',
      'status': 'confirmed',
      'items': [
        {
          'id': 'purchase-line-1',
          'product_id': 'product-1790605869303686',
          'quantity': '10.000000',
          'unit_cost': '900.000000',
          'line_total': '9000.00',
          'conversion_factor': '1.000000',
          'selling_unit_name': 'kg',
          'base_unit': 'kg',
        }
      ],
    };

Future<void> _openScreen(
  WidgetTester tester, {
  required _SupplierReturnRepository returnRepository,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: SupplierReturnsScreen(repository: returnRepository),
      ),
    ),
  );
}

Future<void> _selectSupplierAndOpenPurchasePicker(
  WidgetTester tester,
) async {
  await tester.tap(find.text('Select supplier'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Test Supplier'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
  await tester.tap(find.text('Select purchase'));
  await tester.pumpAndSettle();
}

void _registerServerRepositories({
  required List<Map<String, dynamic>> purchases,
  required _ProductTransport productTransport,
}) {
  getIt.registerSingleton(
    AuthorityContext(
      readMode: AuthorityMode.server,
      writeMode: AuthorityMode.server,
    ),
  );
  getIt.registerSingleton<SupplierRepository>(_SupplierRepository(_supplier));
  final tokenStore = BackendTokenStore()..save('test-token');
  final client = BackendApiClient(
    tokenStore: tokenStore,
    transport: productTransport,
  );
  getIt.registerSingleton<PurchaseRepository>(PurchaseApiRepository(client));
  getIt.registerSingleton<ProductApiRepository>(
    ProductApiRepository(client),
  );
}

void main() {
  setUp(() async {
    await getIt.reset();
  });

  tearDown(() async {
    await getIt.reset();
  });

  testWidgets(
      'server supplier purchase picker shows purchase, resolved item, quantity and total without local reads',
      (tester) async {
    final purchases = [
      _serverPurchase(),
      _serverPurchase(supplierId: 'other', purchaseId: 'purchase-other'),
    ];
    final productTransport = _ProductTransport(
      resolveProduct: true,
      purchases: purchases,
    );
    _registerServerRepositories(
      purchases: purchases,
      productTransport: productTransport,
    );
    final returnRepository = _SupplierReturnRepository(
      localPurchases: const [],
      localItems: const [],
    );

    await _openScreen(tester, returnRepository: returnRepository);
    await _selectSupplierAndOpenPurchasePicker(tester);

    final purchaseListRequest = productTransport.requests.singleWhere(
      (uri) => uri.path == '/api/v1/purchases',
    );
    expect(purchaseListRequest.queryParameters, {
      'page': '1',
      'page_size': '200',
    });
    expect(returnRepository.purchaseListReads, 0);
    expect(returnRepository.purchaseItemReads, 0);
    expect(find.text('PUR-1790707886631140-1'), findsOneWidget);
    expect(find.textContaining('Olive Oil Premium'), findsOneWidget);
    expect(find.textContaining('10 kg'), findsOneWidget);
    expect(find.text('9000.00 DA'), findsOneWidget);

    await tester.tap(find.text('PUR-1790707886631140-1'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Olive Oil Premium'), findsWidgets);
    expect(find.textContaining('10 kg'), findsWidgets);
    expect(find.text('9000.00 DA'), findsOneWidget);
    expect(returnRepository.purchaseItemReads, 0);
    expect(
      productTransport.requests
          .where((uri) => uri.path.startsWith('/api/v1/products/'))
          .map((uri) => uri.path),
      ['/api/v1/products/product-1790605869303686'],
    );
  });

  testWidgets('failed product lookup falls back to product ID', (tester) async {
    final purchases = [_serverPurchase()];
    final productTransport = _ProductTransport(
      resolveProduct: false,
      purchases: purchases,
    );
    _registerServerRepositories(
      purchases: purchases,
      productTransport: productTransport,
    );
    final returnRepository = _SupplierReturnRepository(
      localPurchases: const [],
      localItems: const [],
    );

    await _openScreen(tester, returnRepository: returnRepository);
    await _selectSupplierAndOpenPurchasePicker(tester);

    expect(find.text('PUR-1790707886631140-1'), findsOneWidget);
    expect(find.textContaining('product-1790605869303686'), findsOneWidget);
    expect(find.textContaining('10 kg'), findsOneWidget);

    await tester.tap(find.text('PUR-1790707886631140-1'));
    await tester.pumpAndSettle();
    expect(find.textContaining('product-1790605869303686'), findsWidgets);
    expect(returnRepository.purchaseItemReads, 0);
  });

  testWidgets('local mode keeps using SupplierReturnRepository reads',
      (tester) async {
    getIt.registerSingleton(
      AuthorityContext(
        readMode: AuthorityMode.local,
        writeMode: AuthorityMode.local,
      ),
    );
    getIt.registerSingleton<SupplierRepository>(_SupplierRepository(_supplier));
    final returnRepository = _SupplierReturnRepository(
      localPurchases: [
        {
          'id': 'local-purchase',
          'reference_number': 'PUR-LOCAL',
          'supplier_id': _supplier.id,
          'purchase_date': '2026-09-29T10:00:00',
          'total': 120,
          'status': 'confirmed',
        }
      ],
      localItems: [
        {
          'id': 'local-line',
          'purchase_id': 'local-purchase',
          'product_id': 'local-product',
          'product_name': 'Local Product',
          'quantity': 2.0,
          'unit_cost': 60.0,
          'conversion_factor_snapshot': 1.0,
          'selling_unit_name_snapshot': 'Piece',
        }
      ],
    );

    await _openScreen(tester, returnRepository: returnRepository);
    await _selectSupplierAndOpenPurchasePicker(tester);

    expect(returnRepository.purchaseListReads, 1);
    expect(find.text('PUR-LOCAL'), findsOneWidget);
    await tester.tap(find.text('PUR-LOCAL'));
    await tester.pumpAndSettle();
    expect(returnRepository.purchaseItemReads, 1);
    expect(find.text('Local Product'), findsOneWidget);
  });

  testWidgets('server save refreshes supplier and product data once',
      (tester) async {
    final purchases = [_serverPurchase()];
    final transport = _ProductTransport(
      resolveProduct: true,
      purchases: purchases,
    );
    _registerServerRepositories(
      purchases: purchases,
      productTransport: transport,
    );
    final supplierRepository =
        getIt<SupplierRepository>() as _SupplierRepository;
    getIt.registerSingleton<ActivityLogger>(ActivityLogger());
    final userCubit = UserCubit(
      userRepository: _UnusedUserRepository(),
      sessionRepository: SessionRepositoryImpl(),
    )..currentUser = User(
        username: 'return-manager',
        name: 'Return Manager',
        phone: '',
        userType: UserType.manager,
        password: '',
      );
    final productCubit = _RefreshProductCubit();
    getIt.registerSingleton<UserCubit>(userCubit);
    getIt.registerSingleton<ProductCubit>(productCubit);
    final returnRepository = _SupplierReturnRepository(
      localPurchases: const [],
      localItems: const [],
    );

    await _openScreen(tester, returnRepository: returnRepository);
    await _selectSupplierAndOpenPurchasePicker(tester);
    await tester.tap(find.text('PUR-1790707886631140-1'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Return quantity'),
      '5',
    );
    await tester.drag(find.byType(ListView).last, const Offset(0, -1000));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save return'));
    await tester.pumpAndSettle();

    expect(returnRepository.createCalls, 1);
    expect(returnRepository.createdReturn?.lines.single.quantity, 5);
    expect(supplierRepository.balanceReads, 1);
    expect(supplierRepository.ledgerReads, 1);
    expect(productCubit.refreshCalls, 1);
    expect(find.text('Return completed'), findsOneWidget);
    expect(find.text('500.00 DA'), findsOneWidget);
    expect(
      transport.requests.where((uri) => uri.path.endsWith('/returns')),
      isEmpty,
    );
  });
}
