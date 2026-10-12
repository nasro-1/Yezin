import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:bayaa_pos/core/network/authority_context.dart';
import 'package:bayaa_pos/core/network/backend_api_client.dart';
import 'package:bayaa_pos/core/network/backend_token_store.dart';
import 'package:bayaa_pos/features/purchases/data/models/purchase_model.dart';
import 'package:bayaa_pos/features/purchases/data/repository/purchase_api_repository.dart';
import 'package:bayaa_pos/features/purchases/data/repository/purchase_repository_impl.dart';
import 'package:bayaa_pos/features/suppliers/data/models/supplier_model.dart';
import 'package:bayaa_pos/features/suppliers/data/repository/supplier_api_repository.dart';
import 'package:bayaa_pos/features/suppliers/data/repository/supplier_repository_impl.dart';

class _RecordingTransport implements BackendHttpTransport {
  final requests = <Map<String, Object?>>[];

  @override
  Future<BackendHttpResponse> get(
    Uri uri, {
    Map<String, String> headers = const {},
  }) async {
    requests.add({'method': 'GET', 'uri': uri, 'headers': headers});
    if (uri.path.endsWith('/suppliers')) {
      return const BackendHttpResponse(
        200,
        '{"items":[{"id":"supplier-1","shop_id":"shop-1","code":"SUP-1",'
        '"name":"Test Supplier","registration_name":"","activity":"Retail",'
        '"address":"","phone":"","mobile":"","email":null,"tax_number":null,'
        '"registration_number":null,"supplier_reference":null,'
        '"contact_person":null,"commercial_register":null,"tax_id":null,'
        '"nis":null,"ai":null,"bank_name":null,"bank_account":null,'
        '"currency":"DZD","credit_limit":"0.00","opening_balance":"0.00",'
        '"current_balance":"0.00","notes":null,"is_active":true,'
        '"created_at":"2026-09-29T10:00:00","updated_at":"2026-09-29T10:00:00"}],'
        '"total":1}',
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
    requests.add({
      'method': 'POST',
      'uri': uri,
      'headers': headers,
      'body': body,
    });
    return const BackendHttpResponse(201, '{"id":"server-purchase"}');
  }

  @override
  Future<BackendHttpResponse> put(
    Uri uri, {
    Map<String, String> headers = const {},
    String? body,
  }) async =>
      const BackendHttpResponse(200, '{}');

  @override
  Future<BackendHttpResponse> patch(
    Uri uri, {
    Map<String, String> headers = const {},
    String? body,
  }) async =>
      const BackendHttpResponse(200, '{}');

  @override
  Future<BackendHttpResponse> delete(
    Uri uri, {
    Map<String, String> headers = const {},
  }) async =>
      const BackendHttpResponse(200, '{}');
}

BackendApiClient _client(_RecordingTransport transport) => BackendApiClient(
      tokenStore: BackendTokenStore()..save('test-token'),
      transport: transport,
    );

Purchase _weightedPurchase() => Purchase(
      id: 'purchase-attempt-1',
      referenceNumber: 'PUR-2026-001',
      supplierId: 'supplier-server-id',
      purchaseDate: DateTime.utc(2026, 9, 29, 10),
      notes: 'Olive Oil restock',
      createdBy: 'manager',
      lines: const [
        PurchaseLine(
          productId: 'olive-oil',
          productName: 'Olive Oil Premium',
          productBarcode: '',
          currentStock: 25.0,
          quantity: 10,
          unitCost: 900,
          baseQuantity: 10,
        ),
      ],
    );

void main() {
  test('repository factory selects server API and preserves local mode', () {
    final client = _client(_RecordingTransport());
    final serverContext = AuthorityContext(
      readMode: AuthorityMode.server,
      writeMode: AuthorityMode.server,
    );
    final localContext = AuthorityContext(
      readMode: AuthorityMode.local,
      writeMode: AuthorityMode.local,
    );

    expect(
      purchaseRepositoryForAuthority(
        authorityContext: serverContext,
        client: client,
      ),
      isA<PurchaseApiRepository>(),
    );
    expect(
      purchaseRepositoryForAuthority(
        authorityContext: localContext,
        client: client,
      ),
      isA<PurchaseRepositoryImpl>(),
    );
    expect(
      supplierRepositoryForAuthority(
        authorityContext: serverContext,
        client: client,
      ),
      isA<SupplierApiRepository>(),
    );
    expect(
      supplierRepositoryForAuthority(
        authorityContext: localContext,
        client: client,
      ),
      isA<SupplierRepositoryImpl>(),
    );
  });

  test('purchase API serializes authoritative weighted data only', () async {
    final transport = _RecordingTransport();
    final repository = PurchaseApiRepository(_client(transport));

    final result = await repository.createPurchase(_weightedPurchase());

    expect(result.isRight(), isTrue);
    expect(transport.requests, hasLength(1));
    final request = transport.requests.single;
    expect(request['method'], 'POST');
    expect((request['uri'] as Uri).path, '/api/v1/purchases');
    final headers = request['headers']! as Map<String, String>;
    expect(headers['Idempotency-Key'], 'purchase-attempt-1');
    final body = jsonDecode(request['body']! as String) as Map<String, dynamic>;
    expect(body['idempotency_key'], 'purchase-attempt-1');
    expect(body['reference'], 'PUR-2026-001');
    expect(body['supplier_id'], 'supplier-server-id');
    expect(body['purchase_date'], '2026-09-29T10:00:00.000Z');
    expect(body['notes'], 'Olive Oil restock');
    expect(body['lines'], [
      {
        'product_id': 'olive-oil',
        'quantity': 10,
        'unit_cost': 900,
      },
    ]);
    expect(jsonEncode(body), isNot(contains('currentStock')));
  });

  test('server supplier mapping accepts JSON boolean and decimal strings',
      () async {
    final repository = SupplierApiRepository(_client(_RecordingTransport()));
    final result = await repository.getAllSuppliers();

    expect(result.isRight(), isTrue);
    final supplier =
        result.getOrElse(() => throw StateError('missing supplier')).single;
    expect(supplier.id, 'supplier-1');
    expect(supplier.isActive, isTrue);
    expect(supplier.currentBalance, 0);
  });

  test('supplier creation maps all supplier fields without local-only values',
      () async {
    final transport = _RecordingTransport();
    final repository = SupplierApiRepository(_client(transport));
    final supplier = Supplier(
      id: 'supplier-created',
      code: '',
      name: 'New Supplier',
      phone: '555-0100',
      supplierReference: 'REF-1',
      contactPerson: 'Contact',
      bankName: 'Bank',
      bankAccount: 'RIB',
      openingBalance: 100,
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
    );

    final result = await repository.createSupplier(supplier);

    expect(result.isRight(), isTrue);
    final body = jsonDecode(transport.requests.single['body']! as String)
        as Map<String, dynamic>;
    expect(body['id'], 'supplier-created');
    expect(body['name'], 'New Supplier');
    expect(body['phone'], '555-0100');
    expect(body['supplier_reference'], 'REF-1');
    expect(body['contact_person'], 'Contact');
    expect(body['bank_name'], 'Bank');
    expect(body['bank_account'], 'RIB');
    expect(body['opening_balance'], 100);
    expect(body.containsKey('current_balance'), isFalse);
    expect(body.containsKey('created_at'), isFalse);
  });
}
