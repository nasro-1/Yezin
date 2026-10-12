import 'dart:convert';

import 'package:bayaa_pos/core/network/authority_context.dart';
import 'package:bayaa_pos/core/network/backend_api_client.dart';
import 'package:bayaa_pos/core/network/backend_token_store.dart';
import 'package:bayaa_pos/features/suppliers/data/models/supplier_payment_model.dart';
import 'package:bayaa_pos/features/suppliers/data/repository/supplier_api_repository.dart';
import 'package:bayaa_pos/features/suppliers/data/repository/supplier_payment_api_repository.dart';
import 'package:bayaa_pos/features/suppliers/data/repository/supplier_payment_repository_impl.dart';
import 'package:flutter_test/flutter_test.dart';

class _PaymentTransport implements BackendHttpTransport {
  final requests = <Uri>[];
  final payloads = <String, Map<String, dynamic>>{};

  @override
  Future<BackendHttpResponse> get(
    Uri uri, {
    Map<String, String> headers = const {},
  }) async {
    requests.add(uri);
    if (uri.path == '/api/v1/suppliers') {
      return const BackendHttpResponse(
        200,
        '{"items":[{"id":"server-supplier-id","shop_id":"shop-1",'
        '"code":"SUP-000001","name":"Test Supplier",'
        '"registration_name":"","activity":"Retail","address":"",'
        '"phone":"0550000000","mobile":"","email":null,"tax_number":null,'
        '"registration_number":null,"supplier_reference":"SUP-000001",'
        '"contact_person":null,"commercial_register":null,"tax_id":null,'
        '"nis":null,"ai":null,"bank_name":null,"bank_account":null,'
        '"currency":"DZD","credit_limit":"0","opening_balance":"0",'
        '"current_balance":"9000","notes":null,"is_active":true,'
        '"created_at":"2026-09-29T10:00:00","updated_at":"2026-09-29T10:00:00"}],'
        '"total":1}',
      );
    }
    if (uri.path.endsWith('/ledger')) {
      return const BackendHttpResponse(
        200,
        '[{"id":"payment-ledger","supplier_id":"server-supplier-id",'
        '"entry_type":"supplier_payment","amount":"-9000.00",'
        '"balance_after":"0.00","reference_type":"supplier_payment",'
        '"reference_id":"supplier-payment-key-1","notes":null,'
        '"created_at":"2026-09-29T19:51:47"}]',
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
    final payload = jsonDecode(body!) as Map<String, dynamic>;
    payloads[uri.path] = payload;
    return BackendHttpResponse(
      201,
      jsonEncode({
        'payment_id': 'supplier-payment-key-1',
        'supplier_id': 'server-supplier-id',
        'amount': '9000.00',
        'payment_date': '2026-09-29T19:51:47',
        'payment_method': 'cash',
        'reference': 'supplier-payment-key-1',
        'notes': null,
        'balance_after': '0.00',
        'created_at': '2026-09-29T19:51:47',
      }),
    );
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
  test('repository selection keeps local mode and selects server API mode', () {
    final transport = _PaymentTransport();
    final client = BackendApiClient(
      tokenStore: BackendTokenStore()..save('test-token'),
      transport: transport,
    );

    final local = supplierPaymentRepositoryForAuthority(
      authorityContext: AuthorityContext(
        readMode: AuthorityMode.local,
        writeMode: AuthorityMode.local,
      ),
      client: client,
    );
    final server = supplierPaymentRepositoryForAuthority(
      authorityContext: AuthorityContext(
        readMode: AuthorityMode.server,
        writeMode: AuthorityMode.server,
      ),
      client: client,
    );

    expect(local, isA<SupplierPaymentRepositoryImpl>());
    expect(server, isA<SupplierPaymentApiRepository>());
  });

  test('server supplier can be selected and 9000 payment posts to API',
      () async {
    final transport = _PaymentTransport();
    final client = BackendApiClient(
      tokenStore: BackendTokenStore()..save('test-token'),
      transport: transport,
    );
    final supplierResult =
        await SupplierApiRepository(client).getAllSuppliers();
    final supplier =
        supplierResult.getOrElse(() => throw StateError('missing'));
    expect(supplier.single.id, 'server-supplier-id');

    final result = await SupplierPaymentApiRepository(client).createPayment(
      SupplierPayment(
        id: 'payment-key-1',
        supplierId: supplier.single.id,
        amount: 9000,
        paymentDate: DateTime(2026, 9, 29, 19, 51, 47),
        paymentMethod: 'cash',
        reference: '',
        createdBy: 'admin',
      ),
    );

    expect(result.isRight(), isTrue);
    final uri = transport.requests.singleWhere(
      (request) =>
          request.path == '/api/v1/suppliers/server-supplier-id/payments',
    );
    expect(uri, isNotNull);
    expect(
      transport.payloads[uri.path],
      containsPair('amount', 9000),
    );
    expect(
      transport.payloads[uri.path],
      containsPair('idempotency_key', 'payment-key-1'),
    );
    expect(transport.payloads[uri.path], isNot(contains('created_by')));
  });

  test('server payment history uses supplier ledger entries', () async {
    final transport = _PaymentTransport();
    final client = BackendApiClient(
      tokenStore: BackendTokenStore()..save('test-token'),
      transport: transport,
    );

    final result = await SupplierPaymentApiRepository(client)
        .getPaymentHistory(supplierId: 'server-supplier-id');

    expect(result.isRight(), isTrue);
    final payments = result.getOrElse(() => []);
    expect(payments.single['amount'], 9000.0);
    expect(payments.single['supplier_id'], 'server-supplier-id');
    expect(
      transport.requests.single.path,
      '/api/v1/suppliers/server-supplier-id/ledger',
    );
  });
}
