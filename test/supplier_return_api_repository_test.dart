import 'dart:convert';

import 'package:bayaa_pos/core/network/authority_context.dart';
import 'package:bayaa_pos/core/network/backend_api_client.dart';
import 'package:bayaa_pos/core/network/backend_token_store.dart';
import 'package:bayaa_pos/features/suppliers/data/models/supplier_return_model.dart';
import 'package:bayaa_pos/features/suppliers/data/repository/supplier_return_api_repository.dart';
import 'package:bayaa_pos/features/suppliers/data/repository/supplier_return_repository_impl.dart';
import 'package:flutter_test/flutter_test.dart';

class _ReturnTransport implements BackendHttpTransport {
  Uri? postedUri;
  Map<String, String>? postedHeaders;
  Map<String, dynamic>? postedPayload;

  @override
  Future<BackendHttpResponse> get(
    Uri uri, {
    Map<String, String> headers = const {},
  }) async =>
      const BackendHttpResponse(404, '{"detail":"Not found"}');

  @override
  Future<BackendHttpResponse> post(
    Uri uri, {
    Map<String, String> headers = const {},
    String? body,
  }) async {
    postedUri = uri;
    postedHeaders = headers;
    postedPayload = jsonDecode(body!) as Map<String, dynamic>;
    return const BackendHttpResponse(
      201,
      '{"return_id":"return-1","reference":"SR-TEST-1",'
      '"supplier_id":"server-supplier","source_purchase_id":"purchase-1",'
      '"source_purchase_reference":"PUR-1790707886631140-1",'
      '"return_date":"2026-09-30T10:00:00","status":"POSTED",'
      '"total":"4500.00","balance_after":"500.00",'
      '"lines":[{"purchase_item_id":"purchase-line-1",'
      '"product_id":"olive-oil","quantity":"5","base_quantity":"5",'
      '"unit_cost":"900","return_value":"4500.00","unit_name":"kg"}],'
      '"created_at":"2026-09-30T10:00:00"}',
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
  test('authority selects server API and preserves local return repository',
      () {
    final client = BackendApiClient(
      tokenStore: BackendTokenStore()..save('test-token'),
      transport: _ReturnTransport(),
    );
    final local = supplierReturnRepositoryForAuthority(
      authorityContext: AuthorityContext(
        readMode: AuthorityMode.local,
        writeMode: AuthorityMode.local,
      ),
      client: client,
    );
    final server = supplierReturnRepositoryForAuthority(
      authorityContext: AuthorityContext(
        readMode: AuthorityMode.server,
        writeMode: AuthorityMode.server,
      ),
      client: client,
    );

    expect(local, isA<SupplierReturnRepositoryImpl>());
    expect(server, isA<SupplierReturnApiRepository>());
  });

  test('5 kg return posts to server using request id as idempotency key',
      () async {
    final transport = _ReturnTransport();
    final client = BackendApiClient(
      tokenStore: BackendTokenStore()..save('test-token'),
      transport: transport,
    );
    final result = await SupplierReturnApiRepository(client).createReturn(
      SupplierReturn(
        id: 'return-request-1',
        reference: 'SR-TEST-1',
        supplierId: 'server-supplier',
        purchaseId: 'purchase-1',
        returnDate: DateTime(2026, 9, 30, 10),
        lines: const [
          SupplierReturnLine(
            purchaseItemId: 'purchase-line-1',
            productId: 'olive-oil',
            quantity: 5,
          ),
        ],
        createdBy: 'admin',
      ),
    );

    expect(result.isRight(), isTrue);
    expect(
        transport.postedUri?.path, '/api/v1/suppliers/server-supplier/returns');
    expect(transport.postedHeaders?['Idempotency-Key'], 'return-request-1');
    expect(transport.postedPayload?['idempotency_key'], 'return-request-1');
    expect(transport.postedPayload?['reference'], 'SR-TEST-1');
    expect(transport.postedPayload?['purchase_id'], 'purchase-1');
    final lines = transport.postedPayload?['lines'] as List;
    expect(lines.single['quantity'], 5);
    expect(lines.single['purchase_item_id'], 'purchase-line-1');
    expect(lines.single['product_id'], 'olive-oil');
  });

  test('server rejection is surfaced as a validation failure', () async {
    final client = BackendApiClient(
      tokenStore: BackendTokenStore()..save('test-token'),
      transport: _RejectedReturnTransport(),
    );
    final result = await SupplierReturnApiRepository(client).createReturn(
      SupplierReturn(
        id: 'return-request-2',
        reference: 'SR-TEST-2',
        supplierId: 'server-supplier',
        purchaseId: 'purchase-1',
        returnDate: DateTime(2026, 9, 30, 10),
        lines: const [
          SupplierReturnLine(
            purchaseItemId: 'purchase-line-1',
            productId: 'olive-oil',
            quantity: 11,
          ),
        ],
        createdBy: 'admin',
      ),
    );
    expect(result.isLeft(), isTrue);
  });
}

class _RejectedReturnTransport extends _ReturnTransport {
  @override
  Future<BackendHttpResponse> post(
    Uri uri, {
    Map<String, String> headers = const {},
    String? body,
  }) async =>
      const BackendHttpResponse(
        422,
        '{"detail":"Return quantity exceeds the remaining returnable quantity"}',
      );
}
