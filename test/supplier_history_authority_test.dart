import 'dart:convert';

import 'package:bayaa_pos/core/di/dependency_injection.dart';
import 'package:bayaa_pos/core/error/failure.dart';
import 'package:bayaa_pos/core/network/authority_context.dart';
import 'package:bayaa_pos/core/network/backend_api_client.dart';
import 'package:bayaa_pos/core/network/backend_token_store.dart';
import 'package:bayaa_pos/features/customers/presentation/entity_history_dialog.dart';
import 'package:bayaa_pos/features/purchases/data/repository/purchase_repository_impl.dart';
import 'package:bayaa_pos/features/products/data/repository/product_api_repository.dart';
import 'package:bayaa_pos/features/suppliers/data/models/supplier_model.dart';
import 'package:bayaa_pos/features/suppliers/data/repository/supplier_payment_repository_impl.dart';
import 'package:bayaa_pos/features/suppliers/data/repository/supplier_repository_impl.dart';
import 'package:dartz/dartz.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _SupplierRepository implements SupplierRepository {
  @override
  Future<Either<Failure, double>> getSupplierBalance(String supplierId) async =>
      const Right(1000);

  @override
  Future<Either<Failure, List<Map<String, dynamic>>>> getSupplierLedger(
    String supplierId,
  ) async =>
      const Right([
        {
          'id': 'return-ledger-1',
          'entry_type': 'supplier_return',
          'amount': '-4500.00',
          'reference_type': 'supplier_return',
          'reference_id': 'supplier-return-1',
          'created_at': '2026-09-30T10:00:00',
          'notes': 'Supplier return SR-TEST-1',
        }
      ]);

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _PurchaseRepository implements PurchaseRepository {
  _PurchaseRepository(this.rows);

  final List<Map<String, dynamic>> rows;

  @override
  Future<Either<Failure, List<Map<String, dynamic>>>> getPurchases() async =>
      Right(rows);

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _SupplierPaymentRepository implements SupplierPaymentRepository {
  _SupplierPaymentRepository(this.rows);

  final List<Map<String, dynamic>> rows;

  @override
  Future<Either<Failure, List<Map<String, dynamic>>>> getPaymentHistory({
    String? supplierId,
  }) async =>
      Right(rows);

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ProductTransport implements BackendHttpTransport {
  _ProductTransport({required this.resolveProduct});

  final bool resolveProduct;
  final requests = <Uri>[];

  @override
  Future<BackendHttpResponse> get(
    Uri uri, {
    Map<String, String> headers = const {},
  }) async {
    requests.add(uri);
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

Supplier _supplier() {
  final now = DateTime(2026, 9, 29);
  return Supplier(
    id: 'supplier-1',
    code: 'SUP-000001',
    name: 'Test Supplier',
    phone: '0550000000',
    createdAt: now,
    updatedAt: now,
  );
}

Future<void> _showHistory(WidgetTester tester) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => showSupplierHistory(
              context,
              supplier: _supplier(),
              repository: _SupplierRepository(),
            ),
            child: const Text('Open history'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open history'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

void _registerServerHistory(_ProductTransport productTransport) {
  getIt.registerSingleton(
    AuthorityContext(
      readMode: AuthorityMode.server,
      writeMode: AuthorityMode.server,
    ),
  );
  getIt.registerSingleton<PurchaseRepository>(_PurchaseRepository([
    {
      'id': 'purchase-1',
      'supplier_id': 'supplier-1',
      'reference': 'PUR-000001',
      'purchase_date': '2026-09-28T10:00:00',
      'total': '9000.00',
      'status': 'confirmed',
      'items': [
        {
          'product_id': 'product-1790605869303686',
          'quantity': '10.000000',
          'unit_cost': '900.000000',
          'line_total': '9000.00',
          'conversion_factor': '1.000000',
          'selling_unit_name': 'kg',
          'base_unit': 'kg',
        }
      ],
    },
    {
      'id': 'purchase-other',
      'supplier_id': 'another-supplier',
      'reference': 'PUR-000002',
      'purchase_date': '2026-09-28T10:00:00',
      'total': '7000.00',
      'status': 'confirmed',
      'items': const [],
    },
  ]));
  getIt.registerSingleton<SupplierPaymentRepository>(
    _SupplierPaymentRepository([
      {
        'payment_id': 'payment-1',
        'supplier_id': 'supplier-1',
        'reference': 'supplier-payment-1',
        'payment_date': '2026-09-29T10:00:00',
        'amount': 8000.0,
        'status': 'confirmed',
      },
    ]),
  );
  final tokenStore = BackendTokenStore()..save('test-token');
  getIt.registerSingleton<ProductApiRepository>(
    ProductApiRepository(
      BackendApiClient(
        tokenStore: tokenStore,
        transport: productTransport,
      ),
    ),
  );
}

void main() {
  setUp(() async {
    await getIt.reset();
  });

  tearDown(() async {
    await getIt.reset();
  });

  testWidgets('server history uses server purchases and payments only',
      (tester) async {
    final productTransport = _ProductTransport(resolveProduct: true);
    _registerServerHistory(productTransport);

    await _showHistory(tester);

    expect(find.text('Supplier History'), findsOneWidget);
    expect(find.text('9000.00'), findsOneWidget);
    expect(find.text('8000.00'), findsNWidgets(2));
    await tester.tap(find.text('Payments'));
    await tester.pump();
    expect(find.text('supplier-payment-1'), findsOneWidget);
    await tester.tap(find.text('Returns'));
    await tester.pump();
    expect(find.textContaining('Supplier Return'), findsOneWidget);
    expect(find.text('4500.00'), findsNWidgets(2));
    await tester.tap(find.text('Purchases'));
    await tester.pump();
    expect(find.text('PUR-000001'), findsOneWidget);
    await tester.tap(find.text('PUR-000001'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Olive Oil Premium'), findsOneWidget);
    expect(find.textContaining('Quantity: 10.000000'), findsOneWidget);
    expect(find.textContaining('Unit cost: 900.000000'), findsOneWidget);
    expect(find.textContaining('Line total: 9000.00'), findsOneWidget);
    expect(
      productTransport.requests.single.path,
      '/api/v1/products/product-1790605869303686',
    );
    expect(find.textContaining('Null check operator'), findsNothing);
  });

  testWidgets('unresolved product keeps the product ID in purchase details',
      (tester) async {
    final productTransport = _ProductTransport(resolveProduct: false);
    _registerServerHistory(productTransport);

    await _showHistory(tester);
    await tester.tap(find.text('Purchases'));
    await tester.pump();
    await tester.tap(find.text('PUR-000001'));
    await tester.pumpAndSettle();

    expect(find.textContaining('product-1790605869303686'), findsOneWidget);
    expect(find.textContaining('Quantity: 10.000000'), findsOneWidget);
    expect(find.textContaining('Unit cost: 900.000000'), findsOneWidget);
    expect(find.textContaining('Line total: 9000.00'), findsOneWidget);
  });
}
