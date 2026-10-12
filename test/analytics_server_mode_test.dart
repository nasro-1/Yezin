import 'dart:convert';

import 'package:bayaa_pos/core/network/backend_api_client.dart';
import 'package:bayaa_pos/core/network/backend_token_store.dart';
import 'package:bayaa_pos/features/analytics/data/analytics_repository_impl.dart';
import 'package:flutter_test/flutter_test.dart';

class _AnalyticsTransport implements BackendHttpTransport {
  final requests = <Uri>[];

  @override
  Future<BackendHttpResponse> get(
    Uri uri, {
    Map<String, String> headers = const {},
  }) async {
    requests.add(uri);
    return BackendHttpResponse(
      200,
      jsonEncode({
        'total_revenue': 500,
        'total_sales': 3,
        'gross_revenue': 500,
        'refunded_amount': 0,
        'total_cost': null,
        'total_expenses': null,
        'total_profit': null,
        'profit_margin': null,
        'cost_data_available': false,
        'expenses_data_available': false,
        'daily_time_series': {'2026-09-21': 500},
        'hourly_sales': {'18': 500},
        'category_sales': {'category-1': 500},
        'monthly_sales': {'2026-09': 500},
        'yearly_sales': {'2026': 500},
        'top_products': const [],
      }),
    );
  }

  @override
  Future<BackendHttpResponse> post(
    Uri uri, {
    Map<String, String> headers = const {},
    String? body,
  }) =>
      throw UnimplementedError();

  @override
  Future<BackendHttpResponse> put(
    Uri uri, {
    Map<String, String> headers = const {},
    String? body,
  }) =>
      throw UnimplementedError();

  @override
  Future<BackendHttpResponse> patch(
    Uri uri, {
    Map<String, String> headers = const {},
    String? body,
  }) =>
      throw UnimplementedError();

  @override
  Future<BackendHttpResponse> delete(
    Uri uri, {
    Map<String, String> headers = const {},
  }) =>
      throw UnimplementedError();
}

void main() {
  test('server analytics preserves unavailable financial values', () async {
    final transport = _AnalyticsTransport();
    final tokenStore = BackendTokenStore()..save('test-token');
    final client = BackendApiClient(
      transport: transport,
      tokenStore: tokenStore,
    );
    final repository =
        AnalyticsRepositoryImpl(client: client, serverMode: true);

    final result = await repository.getSummary(
      DateTime(2026, 9, 21),
      DateTime(2026, 9, 21, 23, 59, 59),
    );

    expect(result.isRight(), isTrue);
    final summary = result.getOrElse(() => throw StateError('missing summary'));
    expect(summary.totalRevenue, 500);
    expect(summary.totalSales, 3);
    expect(summary.costDataAvailable, isFalse);
    expect(summary.expensesDataAvailable, isFalse);
    expect(summary.profitDataAvailable, isFalse);
    expect(summary.totalCost, isNot(250));
    expect(summary.totalProfit, isNot(-180));
    expect(transport.requests.single.path, '/api/v1/analytics');
    expect(
      transport.requests.single.queryParameters['date_from'],
      '2026-09-21',
    );
    expect(
      transport.requests.single.queryParameters['date_to_exclusive'],
      '2026-09-22',
    );
    expect(
      transport.requests.single.queryParameters.containsKey('date_to'),
      isFalse,
    );
  });

  test('server monthly products use the server analytics endpoint', () async {
    final transport = _AnalyticsTransport();
    final tokenStore = BackendTokenStore()..save('test-token');
    final repository = AnalyticsRepositoryImpl(
      client: BackendApiClient(
        transport: transport,
        tokenStore: tokenStore,
      ),
      serverMode: true,
    );

    final result = await repository.getTopProductsForMonth('2026-09', 5);

    expect(result.isRight(), isTrue);
    expect(transport.requests, hasLength(1));
    expect(
      transport.requests.single.queryParameters['date_from'],
      '2026-09-01',
    );
    expect(
      transport.requests.single.queryParameters['date_to_exclusive'],
      '2026-10-01',
    );
  });
}
