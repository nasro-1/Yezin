import 'product_sales_detail.dart';

class StockSummaryCategoryModel {
  final String categoryId;
  final String categoryName;
  final int productCount;
  final double totalQuantity;
  final double totalSoldQuantity;
  final double totalHistoricValue;
  final double totalCurrentInventoryCost;
  final double totalMinSellValue;
  final double totalDefaultSellValue;
  final Map<String, double> quantityByUnit;
  final Map<String, List<double>> wholesalePricesByUnit;
  final bool isDeletedCategory;
  final List<ProductSalesDetail> productDetails;
  final bool historicValueAvailable;
  final bool inventoryCostAvailable;

  StockSummaryCategoryModel({
    required this.categoryId,
    required this.categoryName,
    required this.productCount,
    required this.totalQuantity,
    required this.totalSoldQuantity,
    required this.totalHistoricValue,
    required this.totalCurrentInventoryCost,
    required this.totalMinSellValue,
    required this.totalDefaultSellValue,
    this.quantityByUnit = const {},
    this.wholesalePricesByUnit = const {},
    this.isDeletedCategory = false,
    this.productDetails = const [],
    this.historicValueAvailable = true,
    this.inventoryCostAvailable = true,
  });

  double get expectedProfit =>
      totalDefaultSellValue - totalCurrentInventoryCost;
  double get minPossibleProfit => totalMinSellValue - totalCurrentInventoryCost;
  double get profitMarginPercent => totalDefaultSellValue == 0
      ? 0
      : (expectedProfit / totalDefaultSellValue) * 100;
}
