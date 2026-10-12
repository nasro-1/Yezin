import 'dart:convert';

import 'package:bayaa_pos/core/error/failure.dart';
import 'package:bayaa_pos/core/data/models/activity_log.dart';
import 'package:bayaa_pos/core/services/activity_logger.dart';
import 'package:bayaa_pos/core/di/dependency_injection.dart';
import 'package:bayaa_pos/core/network/backend_api_client.dart';
import 'package:bayaa_pos/core/network/backend_token_store.dart';
import 'package:bayaa_pos/features/invoice/presentation/cubit/invoice_cubit.dart';
import 'package:bayaa_pos/features/invoice/presentation/cubit/invoice_state.dart';
import 'package:bayaa_pos/features/dashboard/presentation/dashboard_sales_accounting.dart';
import 'package:bayaa_pos/features/sales/data/models/sale_model.dart';
import 'package:bayaa_pos/features/sales/data/repository/sales_api_repository.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeTransport implements BackendHttpTransport {
  _FakeTransport(this.response, {this.responseFor});

  BackendHttpResponse response;
  final BackendHttpResponse Function(Uri uri)? responseFor;
  final requests = <Map<String, Object?>>[];

  @override
  Future<BackendHttpResponse> get(Uri uri,
      {Map<String, String> headers = const {}}) async {
    requests.add({'method': 'GET', 'uri': uri, 'headers': headers});
    return responseFor?.call(uri) ?? response;
  }

  @override
  Future<BackendHttpResponse> post(Uri uri,
      {Map<String, String> headers = const {}, String? body}) async {
    requests.add({
      'method': 'POST',
      'uri': uri,
      'headers': headers,
      'body': body,
    });
    return response;
  }

  @override
  Future<BackendHttpResponse> put(Uri uri,
      {Map<String, String> headers = const {}, String? body}) async {
    throw UnimplementedError();
  }

  @override
  Future<BackendHttpResponse> patch(Uri uri,
      {Map<String, String> headers = const {}, String? body}) async {
    throw UnimplementedError();
  }

  @override
  Future<BackendHttpResponse> delete(Uri uri,
      {Map<String, String> headers = const {}}) async {
    throw UnimplementedError();
  }
}

Sale _sale() => Sale(
      id: 'client-attempt-1',
      total: 19,
      items: 1,
      date: DateTime.utc(2026, 9, 17),
      cashierName: 'Cashier',
      customerId: 'customer-1',
      paymentMethod: 'cash',
      discount: 1,
      saleItems: [
        SaleItem(
          productId: 'product-1',
          name: 'Boxed item',
          price: 10,
          quantity: 2,
          total: 20,
          wholesalePrice: 7,
          sellingUnitId: 'unit-box',
          sellingQuantity: 2,
          baseQuantity: 20,
          conversionFactorSnapshot: 10,
          sellingUnitNameSnapshot: 'box',
          baseUnitSnapshot: 'piece',
        ),
      ],
    );

Sale _cashSale({
  double total = 480,
  double price = 160,
  double quantity = 3,
  double discount = 0,
}) =>
    Sale(
      id: 'cash-$total-$discount',
      total: total,
      items: 1,
      date: DateTime.utc(2026, 9, 17),
      cashierName: 'Cashier',
      paymentMethod: 'cash',
      discount: discount,
      saleItems: [
        SaleItem(
          productId: 'product-1',
          name: 'Test product',
          price: price,
          quantity: quantity,
          total: price * quantity,
          wholesalePrice: 0,
        ),
      ],
    );

Map<String, dynamic> _postedResponse() => {
      'sale_id': 'sale-server-1',
      'shop_id': 'shop-1',
      'status': 'POSTED',
      'document_reference': 'SALE-001',
      'customer_id': 'customer-1',
      'payment_method': 'cash',
      'subtotal': '20.00',
      'discount': '1.00',
      'total': '19.00',
      'payment_result': '19.00',
      'remaining_amount': '0.00',
      'stock_posting_reference': 'sale:sale-server-1',
      'posted_at': '2026-09-17T20:00:00Z',
      'items': [
        {
          'id': 'line-1',
          'product_id': 'product-1',
          'unit': 'box',
          'quantity': '2',
          'base_quantity': '20',
          'unit_price': '10.00',
          'line_total': '20.00',
          'historical_cost': '140.00',
          'historical_cost_available': true,
        }
      ],
    };

Map<String, dynamic> _listedSale(String id) => {
      ..._postedResponse(),
      'sale_id': id,
    };

SalesApiRepository _repository(_FakeTransport transport) =>
    SalesApiRepository(BackendApiClient(
      tokenStore: BackendTokenStore()..save('token'),
      transport: transport,
    ));

void main() {
  test('maps packaged sale fields and reuses sale id as idempotency key',
      () async {
    final transport =
        _FakeTransport(BackendHttpResponse(201, jsonEncode(_postedResponse())));
    final repository = _repository(transport);

    final firstResult = await repository.saveSale(_sale());
    final secondResult = await repository.saveSale(_sale());
    expect(
      firstResult.isRight(),
      isTrue,
      reason: firstResult.fold((failure) => failure.message, (_) => 'right'),
    );
    expect(secondResult.isRight(), isTrue, reason: '$secondResult');

    final first = jsonDecode(transport.requests[0]['body']! as String);
    final second = jsonDecode(transport.requests[1]['body']! as String);
    expect(first['idempotency_key'], 'client-attempt-1');
    expect(second['idempotency_key'], first['idempotency_key']);
    expect(first['discount'], 1);
    expect(first['paid_amount'], 19);
    expect(first['items'][0], {
      'product_id': 'product-1',
      'quantity': 2,
      'unit': 'box',
      'unit_price': 10,
    });
    expect(
      (transport.requests[0]['headers'] as Map)['Idempotency-Key'],
      'client-attempt-1',
    );
  });

  test('maps server response Decimal fields and packaged unit', () async {
    final transport = _FakeTransport(BackendHttpResponse(
        200,
        jsonEncode({
          'sale_id': 'sale-server-1',
          'shop_id': 'shop-1',
          'status': 'POSTED',
          'document_reference': 'SALE-001',
          'customer_id': 'customer-1',
          'payment_method': 'credit',
          'subtotal': '20.00',
          'discount': '1.25',
          'total': '18.75',
          'payment_result': '0.00',
          'remaining_amount': '18.75',
          'stock_posting_reference': 'sale:sale-server-1',
          'posted_at': '2026-09-17T20:00:00Z',
          'items': [
            {
              'id': 'line-1',
              'product_id': 'product-1',
              'unit': 'box',
              'quantity': '2',
              'base_quantity': '20',
              'unit_price': '10.00',
              'line_total': '20.00',
              'historical_cost': '140.00',
              'historical_cost_available': true,
            }
          ],
        })));

    final result = await _repository(transport).getSale('sale-server-1');
    expect(result.isRight(), isTrue);
    final sale = result.getOrElse(() => throw StateError('missing sale'));
    expect(sale.id, 'sale-server-1');
    expect(sale.total, 18.75);
    expect(sale.saleItems.single.historicalCost, 140);
    expect(sale.discount, 1.25);
    expect(sale.saleItems.single.sellingUnitNameSnapshot, 'box');
    expect(sale.saleItems.single.baseQuantity, 20);
    expect((transport.requests.single['uri'] as Uri).path,
        '/api/v1/sales/sale-server-1');
  });

  test('refreshes original exchange metadata and replacement sale from server',
      () async {
    final original = {
      ..._listedSale('sale-original'),
      'items': [
        {
          ...(_postedResponse()['items'] as List).single
              as Map<String, dynamic>,
          'id': 'original-line',
          'exchanged_quantity': '1',
        },
      ],
    };
    final replacement = {
      ..._listedSale('sale-replacement'),
      'document_reference': 'SALE-REPLACEMENT',
      'total': '200.00',
      'items': [
        {
          ...(_postedResponse()['items'] as List).single
              as Map<String, dynamic>,
          'id': 'replacement-line',
          'product_id': 'replacement-product',
          'quantity': '2',
          'unit_price': '100.00',
          'line_total': '200.00',
        },
      ],
    };
    final transport = _FakeTransport(
      BackendHttpResponse(200, jsonEncode(original)),
      responseFor: (uri) {
        if (uri.path.endsWith('/sale-replacement')) {
          return BackendHttpResponse(200, jsonEncode(replacement));
        }
        if (uri.path.endsWith('/sale-original')) {
          return BackendHttpResponse(200, jsonEncode(original));
        }
        return BackendHttpResponse(
          200,
          jsonEncode({
            'items': [original, replacement],
            'total': 2,
            'page': 1,
            'page_size': 200,
          }),
        );
      },
    );
    final cubit = InvoiceCubit(_repository(transport));

    await cubit.refreshAfterExchange(
      originalSaleId: 'sale-original',
      replacementSaleId: 'sale-replacement',
      replacementDocumentReference: 'SALE-REPLACEMENT',
    );

    final state = cubit.state;
    expect(state.loading, isFalse);
    final sales = state.sales;
    final refreshedOriginal =
        sales.singleWhere((sale) => sale.id == 'sale-original');
    final refreshedReplacement =
        sales.singleWhere((sale) => sale.id == 'sale-replacement');
    expect(refreshedOriginal.saleItems.single.exchangedQuantity, 1);
    expect(refreshedOriginal.saleItems.single.productId, 'product-1');
    expect(refreshedOriginal.replacementInvoiceReference, 'SALE-REPLACEMENT');
    expect(refreshedReplacement.referenceNumber, 'SALE-REPLACEMENT');
    expect(
        refreshedReplacement.saleItems.single.productId, 'replacement-product');
    expect(refreshedReplacement.total, 200);
    expect(
      transport.requests
          .where((request) => request['method'] == 'GET')
          .map((request) => (request['uri'] as Uri).path)
          .toList(),
      containsAll([
        '/api/v1/sales/sale-original',
        '/api/v1/sales/sale-replacement',
        '/api/v1/sales',
      ]),
    );
    await cubit.close();
  });

  test('maps typed API status failures to domain failures', () async {
    for (final entry in <int, Type>{
      400: ValidationFailure,
      401: AuthorizationFailure,
      403: AuthorizationFailure,
      409: ServerFailure,
      500: ServerFailure,
    }.entries) {
      final repository = _repository(
        _FakeTransport(BackendHttpResponse(entry.key, '{"detail":"failure"}')),
      );
      final result = await repository.saveSale(_sale());
      expect(result.isLeft(), isTrue);
      expect(result.fold((failure) => failure.runtimeType, (_) => null),
          entry.value);
    }
  });

  test('calculates exchange accounting contributions without double counting',
      () {
    Sale originalSale({
      required double total,
      required double exchanged,
    }) =>
        Sale(
          id: 'sale-$total-$exchanged',
          total: total,
          items: 1,
          date: DateTime.utc(2026, 9, 24),
          cashierName: 'Cashier',
          saleItems: [
            SaleItem(
              productId: 'product-1',
              name: 'Product',
              price: exchanged,
              quantity: exchanged == 0 ? 1 : 1,
              total: exchanged,
              wholesalePrice: 0,
              exchangedQuantity: exchanged == 0 ? 0 : 1,
            ),
          ],
        );

    Sale replacementSale({
      required String id,
      required double total,
    }) =>
        Sale(
          id: id,
          total: total,
          items: 1,
          date: DateTime.utc(2026, 9, 24),
          cashierName: 'Cashier',
          saleItems: [
            SaleItem(
              productId: 'replacement-product',
              name: 'Replacement',
              price: total,
              quantity: 1,
              total: total,
              wholesalePrice: 0,
            ),
          ],
        );

    final customerPaysOriginal = originalSale(total: 300, exchanged: 100);
    final customerPaysReplacement =
        replacementSale(id: 'replacement-200', total: 200);
    expect(
      customerPaysOriginal.accountingContribution +
          customerPaysReplacement.accountingContribution,
      400,
    );

    final equalOriginal = originalSale(total: 100, exchanged: 100);
    final equalReplacement = replacementSale(id: 'replacement-100', total: 100);
    expect(
      equalOriginal.accountingContribution +
          equalReplacement.accountingContribution,
      100,
    );

    final customerReceivesOriginal = originalSale(total: 200, exchanged: 200);
    final customerReceivesReplacement =
        replacementSale(id: 'replacement-refund', total: 100);
    expect(
      customerReceivesOriginal.accountingContribution +
          customerReceivesReplacement.accountingContribution,
      100,
    );
  });

  test('dashboard net aggregation includes one exchange contribution once', () {
    Sale sale({
      required String id,
      required double total,
      double exchanged = 0,
    }) =>
        Sale(
          id: id,
          total: total,
          items: 1,
          date: DateTime.now(),
          cashierName: 'Cashier',
          saleItems: [
            SaleItem(
              productId: 'product-$id',
              name: 'Product',
              price: exchanged > 0 ? exchanged : total,
              quantity: total / (exchanged > 0 ? exchanged : total),
              total: total,
              wholesalePrice: 0,
              exchangedQuantity: exchanged > 0 ? 1 : 0,
            ),
          ],
        );

    final sales = [
      sale(id: 'baseline', total: 1600),
      sale(id: 'original', total: 300, exchanged: 100),
      sale(id: 'replacement', total: 200),
    ];

    expect(calculateDashboardNetSales(sales), 2000);

    expect(
      calculateDashboardNetSales([
        sale(id: 'equal-original', total: 100, exchanged: 100),
        sale(id: 'equal-replacement', total: 100),
      ]),
      100,
    );
    expect(
      calculateDashboardNetSales([
        sale(id: 'pays-original', total: 100, exchanged: 100),
        sale(id: 'pays-replacement', total: 200),
      ]),
      200,
    );
    expect(
      calculateDashboardNetSales([
        sale(id: 'receives-original', total: 200, exchanged: 200),
        sale(id: 'receives-replacement', total: 100),
      ]),
      100,
    );
  });

  test('registered ActivityLogger exposes one Exchange activity on replay',
      () async {
    final logger = ActivityLogger();
    if (!getIt.isRegistered<ActivityLogger>()) {
      getIt.registerSingleton<ActivityLogger>(logger);
    }
    final registered = getIt<ActivityLogger>();
    expect(identical(logger, registered), isTrue);
    final id = 'exchange-test-${DateTime.now().microsecondsSinceEpoch}';
    expect(
      await registered.logExchangeOnce(
        exchangeId: id,
        originalSaleId: 'original',
        replacementSaleId: 'replacement',
        userName: 'Cashier',
      ),
      isTrue,
    );
    expect(
      await registered.logExchangeOnce(
        exchangeId: id,
        originalSaleId: 'original',
        replacementSaleId: 'replacement',
        userName: 'Cashier',
      ),
      isFalse,
    );
    expect(
      registered.recentActivities
          .where((activity) =>
              activity.type == ActivityType.exchange &&
              activity.details?['exchange_id'] == id)
          .length,
      1,
    );
  });

  test('submits exact cash payment for a 480 total', () async {
    final transport =
        _FakeTransport(BackendHttpResponse(201, jsonEncode(_postedResponse())));
    await _repository(transport).postSale(_cashSale());
    final payload = jsonDecode(transport.requests.single['body']! as String);
    expect(payload['discount'], 0);
    expect(payload['paid_amount'], 480);
    expect(payload['items'][0]['quantity'], 3);
  });

  test('uses posted line total instead of stale sale total for cash payment',
      () async {
    final transport =
        _FakeTransport(BackendHttpResponse(201, jsonEncode(_postedResponse())));
    await _repository(transport).postSale(_cashSale(total: 500));
    final payload = jsonDecode(transport.requests.single['body']! as String);
    expect(payload['subtotal'], 480);
    expect(payload['paid_amount'], 480);
  });

  test('normalizes decimal cash payments to cents', () async {
    final transport =
        _FakeTransport(BackendHttpResponse(201, jsonEncode(_postedResponse())));
    await _repository(transport).postSale(
      _cashSale(total: 20.25, price: 10.125, quantity: 2),
    );
    final payload = jsonDecode(transport.requests.single['body']! as String);
    expect(payload['paid_amount'], 20.25);
  });

  test('fetches large requested limits through supported server pages',
      () async {
    final transport = _FakeTransport(
      BackendHttpResponse(200, '{}'),
      responseFor: (uri) {
        final page = int.parse(uri.queryParameters['page']!);
        final items = page == 1
            ? [_listedSale('sale-1'), _listedSale('sale-2')]
            : page == 2
                ? [_listedSale('sale-3')]
                : <Map<String, dynamic>>[];
        return BackendHttpResponse(
          200,
          jsonEncode({
            'items': items,
            'total': 3,
            'page': page,
            'page_size': 200,
          }),
        );
      },
    );

    final result = await _repository(transport).getRecentSales(limit: 10000);

    expect(result.isRight(), isTrue);
    expect(result.getOrElse(() => const []).map((sale) => sale.id),
        ['sale-1', 'sale-2', 'sale-3']);
    expect(transport.requests, hasLength(2));
    for (final request in transport.requests) {
      final uri = request['uri'] as Uri;
      expect(uri.queryParameters['page_size'], '200');
      expect(
          int.parse(uri.queryParameters['page_size']!), lessThanOrEqualTo(200));
    }
  });

  test('maps refund documents and InvoiceCubit filters them correctly',
      () async {
    final refund = {
      ..._postedResponse(),
      'sale_id': 'refund-1',
      'document_reference': 'REFUND-001',
      'total': '10.00',
      'is_refund': true,
      'original_sale_id': 'sale-1',
      'refunded_total': '0',
    };
    final transport = _FakeTransport(BackendHttpResponse(
      200,
      jsonEncode({
        'items': [_listedSale('sale-1'), refund],
        'total': 2,
        'page': 1,
        'page_size': 200,
      }),
    ));
    if (!getIt.isRegistered<ActivityLogger>()) {
      getIt.registerSingleton<ActivityLogger>(ActivityLogger());
    }
    final cubit = InvoiceCubit(_repository(transport));

    await cubit.loadSales();
    expect(cubit.state.sales.map((sale) => sale.id), ['sale-1']);

    await cubit.setFilterType(InvoiceFilterType.refunded);
    expect(cubit.state.sales.map((sale) => sale.id), ['refund-1']);
    final mappedRefund = cubit.state.sales.single;
    expect(mappedRefund.isRefund, isTrue);
    expect(mappedRefund.refundOriginalInvoiceId, 'sale-1');

    await cubit.setFilterType(InvoiceFilterType.sales);
    expect(cubit.state.sales.every((sale) => !sale.isRefund), isTrue);
    await cubit.setFilterType(InvoiceFilterType.all);
    expect(cubit.state.sales.map((sale) => sale.id), ['sale-1']);
    await cubit.close();
  });

  test('InvoiceCubit loads server sales without an oversized page request',
      () async {
    final transport = _FakeTransport(
      BackendHttpResponse(
        200,
        jsonEncode({
          'items': [_listedSale('sale-1')],
          'total': 1,
          'page': 1,
          'page_size': 200,
        }),
      ),
    );
    if (!getIt.isRegistered<ActivityLogger>()) {
      getIt.registerSingleton<ActivityLogger>(ActivityLogger());
    }
    final cubit = InvoiceCubit(_repository(transport));

    await cubit.loadSales();

    expect(cubit.state.errorMessage, isNull);
    expect(cubit.state.sales.single.id, 'sale-1');
    expect(
        (transport.requests.single['uri'] as Uri).queryParameters['page_size'],
        '200');
    await cubit.close();
  });

  test('submits zero payment for credit sales', () async {
    final transport =
        _FakeTransport(BackendHttpResponse(201, jsonEncode(_postedResponse())));
    await _repository(transport).postSale(
      Sale(
        id: 'credit-1',
        total: 480,
        items: 1,
        date: DateTime.utc(2026, 9, 17),
        cashierName: 'Cashier',
        paymentMethod: 'credit',
        customerId: 'customer-1',
        saleItems: _cashSale().saleItems,
      ),
    );
    final payload = jsonDecode(transport.requests.single['body']! as String);
    expect(payload['paid_amount'], 0);
  });
}
