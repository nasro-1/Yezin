import 'dart:convert';

import 'package:bayaa_pos/core/di/dependency_injection.dart';
import 'package:bayaa_pos/core/network/backend_api_client.dart';
import 'package:bayaa_pos/core/network/authority_context.dart';
import 'package:bayaa_pos/core/network/backend_token_store.dart';
import 'package:bayaa_pos/features/auth/data/models/user_model.dart';
import 'package:bayaa_pos/features/auth/presentation/cubit/user_cubit.dart';
import 'package:bayaa_pos/features/products/data/models/product_model.dart';
import 'package:bayaa_pos/features/products/data/repository/product_api_repository.dart';
import 'package:bayaa_pos/features/products/presentation/widgets/product_details_dialog.dart';
import 'package:bayaa_pos/features/purchases/data/repository/purchase_api_repository.dart';
import 'package:bayaa_pos/features/purchases/data/repository/purchase_repository_impl.dart';
import 'package:bayaa_pos/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final _serverAuthority = AuthorityContext(
  readMode: AuthorityMode.server,
  writeMode: AuthorityMode.server,
);

class _TestUserCubit implements UserCubit {
  @override
  User get currentUser => User(
        username: 'admin',
        name: 'Admin',
        phone: '',
        userType: UserType.admin,
        password: '',
      );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FifoTransport implements BackendHttpTransport {
  final requests = <Uri>[];
  Map<String, dynamic>? correctionPayload;
  var layerReads = 0;
  List<Map<String, dynamic>> purchaseHistory = const [];

  @override
  Future<BackendHttpResponse> get(
    Uri uri, {
    Map<String, String> headers = const {},
  }) async {
    requests.add(uri);
    if (uri.path.endsWith('/stock-movements')) {
      return const BackendHttpResponse(
        200,
        '[{"id":"opening-product-cola-movement","product_id":"product-cola",'
        '"product_barcode":"","product_name":"Test Standard Cola",'
        '"movement_type":"opening_stock","quantity_change":50,"unit_cost":60,'
        '"line_total":3000,'
        '"running_stock":50,"reference_type":"opening_stock",'
        '"reference_id":"OPEN-1","source_description":"OPEN-1",'
        '"created_at":"2026-09-27T10:00:00"},'
        '{"id":"remove-product-cola-movement","product_id":"product-cola",'
        '"product_barcode":"","product_name":"Test Standard Cola",'
        '"movement_type":"stock_adjustment","quantity_change":-30,"unit_cost":30,'
        '"line_total":900,"running_stock":20,"reference_type":"stock_adjustment",'
        '"reference_id":"ADJ-1","source_description":"Adjustment ADJ-1",'
        '"created_at":"2026-09-27T11:00:00"}]',
      );
    }
    if (uri.path.endsWith('/purchase-history')) {
      return BackendHttpResponse(200, jsonEncode(purchaseHistory));
    }
    if (uri.path.endsWith('/fifo-layers')) {
      layerReads++;
      final corrected = layerReads > 1;
      return BackendHttpResponse(
        200,
        corrected
            ? '[{"layer_id":"layer-1-corrected","acquisition_date":"2026-09-27T10:00:00",'
                '"source_movement_id":"opening-product-cola-movement",'
                '"acquisition_reference":"OPEN-1","original_unit_cost":60,'
                '"current_unit_cost":50,"remaining_quantity":50,'
                '"correction_old_unit_cost":60,"correction_new_unit_cost":50,'
                '"correction_created_at":"2026-09-27T10:30:00"}]'
            : '[{"layer_id":"layer-1","acquisition_date":"2026-09-27T10:00:00",'
                '"source_movement_id":"opening-product-cola-movement",'
                '"acquisition_reference":"OPEN-1","original_unit_cost":60,'
                '"current_unit_cost":60,"remaining_quantity":50}]',
      );
    }
    return const BackendHttpResponse(404, '{"detail":"Not found"}');
  }

  @override
  Future<BackendHttpResponse> post(
    Uri uri, {
    Map<String, String> headers = const {},
    String? body,
  }) async {
    requests.add(uri);
    correctionPayload = jsonDecode(body!) as Map<String, dynamic>;
    return const BackendHttpResponse(201, '{}');
  }

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

void main() {
  late _FifoTransport transport;

  setUp(() async {
    await getIt.reset();
    transport = _FifoTransport();
    final tokenStore = BackendTokenStore()..save('test-token');
    final client = BackendApiClient(
      tokenStore: tokenStore,
      transport: transport,
    );
    getIt.registerSingleton<ProductApiRepository>(ProductApiRepository(client));
    getIt.registerSingleton<PurchaseRepository>(PurchaseApiRepository(client));
    getIt.registerSingleton<UserCubit>(_TestUserCubit());
  });

  tearDown(() async {
    await getIt.reset();
  });

  testWidgets(
      'Product Details Purchases loads server purchase history and shows quantity cost and total',
      (tester) async {
    transport.purchaseHistory = [
      {
        'purchase_id': 'purchase-1',
        'reference_number': 'PUR-TEST-1',
        'quantity': '10.000000',
        'base_quantity': '10.000000',
        'unit_cost': '900.000000',
        'line_total': '9000.00',
        'conversion_factor_snapshot': '1.000000',
        'selling_unit_name_snapshot': 'kg',
        'base_unit_snapshot': 'kg',
      },
    ];
    final product = Product(
      id: 'product-olive-oil',
      name: 'Olive Oil Premium',
      productType: ProductType.weighted,
      baseUnit: 'kg',
      price: 1200,
      minPrice: 1000,
      wholesalePrice: 0,
      cost: 500,
      quantity: 35,
      minQuantity: 0,
      category: 'Beverages',
    );

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: ProductDetailsDialog(
            product: product,
            authorityContext: _serverAuthority,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Tab).at(2));
    await tester.pumpAndSettle();

    expect(
      transport.requests.any(
        (uri) =>
            uri.path == '/api/v1/products/product-olive-oil/purchase-history',
      ),
      isTrue,
      reason: 'Server purchase history should be requested for the product',
    );
    expect(find.text('PUR-TEST-1'), findsOneWidget);
    expect(find.textContaining('10 kg'), findsOneWidget);
    expect(find.textContaining('900.00 / kg'), findsOneWidget);
    expect(find.textContaining('9000.00'), findsOneWidget);
    expect(find.text('No purchase history for this product.'), findsNothing);
  });

  testWidgets(
      'Product Details Purchases keeps the empty state when server has no history',
      (tester) async {
    final product = Product(
      id: 'product-without-purchases',
      name: 'Product Without Purchases',
      price: 100,
      minPrice: 90,
      wholesalePrice: 80,
      quantity: 0,
      minQuantity: 0,
      category: 'Beverages',
    );

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: ProductDetailsDialog(
            product: product,
            authorityContext: _serverAuthority,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Tab).at(2));
    await tester.pumpAndSettle();

    expect(find.text('No purchase history for this product.'), findsOneWidget);
  });

  testWidgets(
      'Product Details Stock History uses server API in server mode and displays FIFO-reconstructed Remove cost',
      (tester) async {
    final product = Product(
      id: 'product-cola',
      name: 'Test Standard Cola',
      price: 100,
      minPrice: 90,
      wholesalePrice: 80,
      cost: 60,
      quantity: 50,
      minQuantity: 0,
      category: 'Beverages',
      baseUnit: 'Piece',
    );

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<bool>(
                context: context,
                builder: (_) => ProductDetailsDialog(
                  product: product,
                  authorityContext: _serverAuthority,
                ),
              ),
              child: const Text('Open history'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open history'));
    await tester.pumpAndSettle();

    // In server mode, should call stock-movements endpoint
    expect(
      transport.requests.any(
        (uri) => uri.path == '/api/v1/products/product-cola/stock-movements',
      ),
      isTrue,
      reason:
          'Product Details should load stock movements from API in server mode',
    );

    await tester.tap(find.byType(Tab).at(1));
    await tester.pumpAndSettle();
    expect(find.text('Selling Price'), findsOneWidget);
    expect(find.text('Wholesale Price'), findsOneWidget);
    expect(find.text('Min Price'), findsOneWidget);
    expect(find.text('Cost'), findsNothing);

    await tester.tap(find.byType(Tab).last);
    await tester.pumpAndSettle();
    expect(find.text('Opening Stock'), findsOneWidget);

    // Verify Opening Stock displays correctly
    expect(find.textContaining('Cost: 60.00 DA/Piece'), findsOneWidget);
    expect(find.textContaining('Total: 3000.00 DA'), findsOneWidget);

    // Verify Remove movement displays FIFO-reconstructed cost (not 0)
    expect(find.textContaining('Cost: 30.00 DA/Piece'), findsOneWidget);
    expect(find.textContaining('Total: 900.00 DA'), findsOneWidget);
    expect(find.byIcon(Icons.edit_outlined), findsOneWidget);
    expect(find.textContaining('50.000 Piece'), findsOneWidget);
    expect(find.text('FIFO Cost Layers'), findsNothing);

    await tester.ensureVisible(find.byIcon(Icons.edit_outlined));
    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byType(TextField));
    expect(find.text('Cost'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    await tester.enterText(find.byType(TextField), '50');
    await tester.ensureVisible(find.byIcon(Icons.check));
    await tester.tap(find.byIcon(Icons.check));
    await tester.pumpAndSettle();
    expect(find.textContaining('Cost: 50.00 DA/Piece'), findsOneWidget);
    expect(find.textContaining('Cost corrected: 60.00'), findsOneWidget);
    expect(find.textContaining('Date: 27/09/2026'), findsOneWidget);
    expect(find.textContaining('2500.00 DA'), findsOneWidget);

    expect(
      transport.requests.any(
        (uri) =>
            uri.path == '/api/v1/products/product-cola/fifo-cost-corrections',
      ),
      isTrue,
    );
    expect(transport.correctionPayload, containsPair('layer_id', 'layer-1'));
    expect(transport.correctionPayload, isNot(contains('quantity')));
    expect(transport.correctionPayload, isNot(contains('reason')));
    expect(transport.correctionPayload, containsPair('new_unit_cost', 50));
    expect(transport.correctionPayload, isNot(contains('idempotency_key')));
    expect(transport.layerReads, 2);
    expect(product.cost, 60);
  });
}
