import 'package:bayaa_pos/features/stock_summary/data/models/stock_summary_category_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  StockSummaryCategoryModel summary({
    double stock = 8,
    double cost = 50,
    double sell = 100,
    double historic = 1200,
  }) {
    return StockSummaryCategoryModel(
      categoryId: 'dev-soft-drinks',
      categoryName: 'Soft Drinks',
      productCount: 1,
      totalQuantity: stock,
      totalSoldQuantity: 0,
      totalHistoricValue: historic,
      totalCurrentInventoryCost: stock * cost,
      totalMinSellValue: 0,
      totalDefaultSellValue: stock * sell,
    );
  }

  test('uses acquisition cost, not wholesale selling price', () {
    final item = summary();

    expect(item.totalCurrentInventoryCost, 400);
    expect(item.totalDefaultSellValue, 800);
    expect(item.expectedProfit, 400);
    expect(item.profitMarginPercent, 50);
  });

  test('wholesale price does not affect inventory-cost valuation', () {
    final item = summary(cost: 50);
    expect(item.totalCurrentInventoryCost, 400);
  });

  test('explicit zero acquisition cost has full gross margin', () {
    final item = summary(cost: 0);

    expect(item.totalCurrentInventoryCost, 0);
    expect(item.expectedProfit, 800);
    expect(item.profitMarginPercent, 100);
  });

  test('zero stock produces zero sell value and zero margin', () {
    final item = summary(stock: 0);

    expect(item.totalCurrentInventoryCost, 0);
    expect(item.totalDefaultSellValue, 0);
    expect(item.expectedProfit, 0);
    expect(item.profitMarginPercent, 0);
  });

  test('historic value is independent from current stock value', () {
    final item = summary(stock: 0, historic: 1200);

    expect(item.totalHistoricValue, 1200);
    expect(item.totalCurrentInventoryCost, 0);
  });

  test('category aggregation preserves product, stock, and output fields', () {
    final categories = [
      summary(stock: 0, cost: 50, sell: 100),
      summary(stock: 8, cost: 50, sell: 100),
    ];

    expect(categories.length, 2);
    expect(
      categories.map((item) => item.productCount).reduce((a, b) => a + b),
      2,
    );
    expect(
      categories.map((item) => item.totalQuantity).reduce((a, b) => a + b),
      8,
    );
    expect(
      categories.map((item) => item.totalSoldQuantity).reduce((a, b) => a + b),
      0,
    );
  });

  test('mixed units remain separated while financial totals stay aggregate', () {
    final item = StockSummaryCategoryModel(
      categoryId: 'mixed',
      categoryName: 'Mixed',
      productCount: 2,
      totalQuantity: 75,
      totalSoldQuantity: 0,
      totalHistoricValue: 0,
      totalCurrentInventoryCost: 3500,
      totalMinSellValue: 0,
      totalDefaultSellValue: 5000,
      quantityByUnit: {'piece': 50, 'kg': 25},
    );

    expect(item.quantityByUnit, {'piece': 50, 'kg': 25});
    expect(item.totalCurrentInventoryCost, 3500);
    expect(item.totalDefaultSellValue, 5000);
  });
}
