import 'package:flutter_test/flutter_test.dart';

import 'package:bayaa_pos/features/analytics/data/local_fifo_analytics_costing.dart';

void main() {
  test('sale COGS uses a single FIFO layer and ignores current cost', () {
    final cost = const LocalFifoAnalyticsCosting().costForNextSale(
      movements: [
        _movement(
            'opening', 'p1', 'opening_stock', 100, 10, '2026-01-01T00:00:00Z'),
      ],
      productId: 'p1',
      quantity: 20,
      createdAt: DateTime.utc(2026, 1, 2),
    );

    expect(cost, 200);
  });

  test('sale COGS consumes multiple FIFO layers in order', () {
    final cost = const LocalFifoAnalyticsCosting().costForNextSale(
      movements: [
        _movement('lot-a', 'p1', 'purchase', 50, 10, '2026-01-01T00:00:00Z'),
        _movement('lot-b', 'p1', 'purchase', 50, 20, '2026-01-02T00:00:00Z'),
      ],
      productId: 'p1',
      quantity: 70,
      createdAt: DateTime.utc(2026, 1, 3),
    );

    expect(cost, 900);
  });

  test('incomplete FIFO sale cost is not replaced by current product cost', () {
    final result = const LocalFifoAnalyticsCosting().calculate(
      movements: [
        _movement('lot-a', 'p1', 'purchase', 8, 5, '2026-01-01T00:00:00Z'),
        _movement('sale', 'p1', 'sale', -10, 0, '2026-01-02T00:00:00Z',
            lineageId: 'sale-item'),
      ],
      start: DateTime.utc(2026),
      endExclusive: DateTime.utc(2026, 2),
    );

    expect(result.totalCost, isNull);
    expect(
      result.incompleteReferences,
      contains('sale::p1'),
    );
    expect(result.costByReferenceProduct, isNot(contains('sale::p1')));
  });

  test('local FIFO matches the complete refund and exchange scenario', () {
    final result = const LocalFifoAnalyticsCosting().calculate(
      movements: [
        _movement('lot-a', 'old', 'purchase', 10, 50, '2026-01-01T00:00:00Z'),
        _movement('lot-b', 'old', 'purchase', 10, 80, '2026-01-02T00:00:00Z'),
        _movement('sale', 'old', 'sale', -15, 0, '2026-01-03T00:00:00Z',
            lineageId: 'sale-item'),
        _movement(
            'refund', 'old', 'customer_return', 5, 0, '2026-01-04T00:00:00Z',
            lineageId: 'sale-item'),
        _movement('exchange-return', 'old', 'customer_return', 1, 0,
            '2026-01-05T00:00:00Z',
            lineageId: 'sale-item'),
        _movement('replacement-lot', 'new', 'purchase', 1, 30,
            '2026-01-01T00:00:00Z'),
        _movement(
            'replacement-sale', 'new', 'sale', -1, 0, '2026-01-05T00:00:01Z',
            lineageId: 'replacement-item'),
      ],
      start: DateTime.utc(2026),
      endExclusive: DateTime.utc(2026, 2),
    );

    expect(result.totalCost, 480);
    expect(result.costByProduct['old'], 450);
    expect(result.costByProduct['new'], 30);
  });
}

Map<String, dynamic> _movement(
  String id,
  String productId,
  String type,
  double quantity,
  double unitCost,
  String createdAt, {
  String? lineageId,
}) {
  return {
    'id': id,
    'product_id': productId,
    'movement_type': type,
    'quantity_change': quantity,
    'unit_cost': unitCost,
    'reference_type': type,
    'reference_id': id,
    'lineage_id': lineageId,
    'created_at': createdAt,
  };
}
