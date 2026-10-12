import 'package:bloc/bloc.dart';
import 'package:bayaa_pos/core/data/services/persistence_initializer.dart';
import 'package:bayaa_pos/core/network/authority_context.dart';
import 'package:bayaa_pos/core/network/backend_api_client.dart';
import '../../data/models/stock_summary_category_model.dart';
import '../../data/models/product_sales_detail.dart';
import 'stock_summary_state.dart';

class StockSummaryCubit extends Cubit<StockSummaryState> {
  StockSummaryCubit({this.client, this.authorityContext})
      : super(StockSummaryInitial());

  final BackendApiClient? client;
  final AuthorityContext? authorityContext;

  // Removed Hive listeners
  void init() {
    loadData();
  }

  Map<String, double> _parseQuantityByUnit(dynamic value) {
    if (value is! Map) return const {};
    return {
      for (final entry in value.entries)
        entry.key.toString(): (entry.value as num).toDouble(),
    };
  }

  Map<String, List<double>> _parseWholesalePricesByUnit(dynamic value) {
    if (value is! Map) return const {};
    return {
      for (final entry in value.entries)
        entry.key.toString(): (entry.value is List
            ? (entry.value as List)
                .whereType<num>()
                .map((price) => price.toDouble())
                .toList()
            : const <double>[]),
    };
  }

  Future<void> loadData() async {
    if (isClosed) return;
    emit(StockSummaryLoading());
    try {
      if (authorityContext?.readsFromServer == true && client != null) {
        final payload = await client!.getStockSummaryDetail();
        final categories = (payload['categories'] as List? ?? const [])
            .whereType<Map>()
            .map((raw) {
          final item = Map<String, dynamic>.from(raw);
          return StockSummaryCategoryModel(
            categoryId: '${item['category_id'] ?? item['category_name']}',
            categoryName: '${item['category_name']}',
            productCount: (item['product_count'] as num?)?.toInt() ?? 0,
            totalQuantity: (item['total_quantity'] as num?)?.toDouble() ?? 0,
            totalSoldQuantity:
                (item['total_sold_quantity'] as num?)?.toDouble() ?? 0,
            totalHistoricValue:
                (item['total_historic_value'] as num?)?.toDouble() ?? 0,
            historicValueAvailable: item['total_historic_value'] != null,
            totalCurrentInventoryCost:
                (item['total_current_inventory_cost'] as num?)?.toDouble() ?? 0,
            inventoryCostAvailable:
                item['total_current_inventory_cost'] != null,
            totalMinSellValue:
                (item['total_min_sell_value'] as num?)?.toDouble() ?? 0,
            totalDefaultSellValue:
                (item['total_default_sell_value'] as num?)?.toDouble() ?? 0,
            quantityByUnit: _parseQuantityByUnit(item['quantity_by_unit']),
            wholesalePricesByUnit:
                _parseWholesalePricesByUnit(item['wholesale_prices_by_unit']),
            isDeletedCategory: item['is_deleted_category'] == true,
          );
        }).toList();
        if (!isClosed) {
          emit(StockSummaryLoaded(
            categories: categories,
            totalStoreHistoricValue:
                (payload['total_store_historic_value'] as num?)?.toDouble() ??
                    0,
            historicValueAvailable:
                payload['total_store_historic_value'] != null,
            totalStoreCurrentValue:
                (payload['total_store_current_inventory_cost'] as num?)
                        ?.toDouble() ??
                    0,
            inventoryCostAvailable:
                payload['total_store_current_inventory_cost'] != null,
            totalExpectedProfit:
                (payload['total_expected_profit'] as num?)?.toDouble() ?? 0,
          ));
        }

        return;
      }

      print('📊 === STOCK SUMMARY: Loading Data (SQLite) ===');

      final db = PersistenceInitializer.persistenceManager!.sqliteManager;

      // 1. Query Current Stock Grouped by Category
      // Keep quantities separated by base unit; financial values remain summed.
      final stockResults = await db.database.rawQuery('''
        SELECT
          category_id,
          base_unit,
          COUNT(*) as product_count,
          SUM(stock) as total_quantity,
          SUM(stock * cost) as inventory_cost_value,
          SUM(stock * min_price) as min_sell_value,
          SUM(stock * price) as default_sell_value
        FROM products
        WHERE is_active = 1
        GROUP BY category_id, base_unit
      ''');

      final categoryResults = await db.database.rawQuery('''
        SELECT id, name FROM categories
      ''');
      final categoryNames = {
        for (final row in categoryResults)
          row['id'] as String: row['name'] as String,
      };

      final historicResults = await db.database.rawQuery('''
        SELECT p.category_id,
               SUM(sm.quantity_change * sm.unit_cost) AS historic_value
        FROM stock_movements sm
        JOIN products p ON p.id = sm.product_id
        WHERE sm.quantity_change > 0
          AND sm.movement_type IN ('opening_stock', 'purchase', 'stock_adjustment')
        GROUP BY p.category_id
      ''');
      final historicDataMap = {
        for (final row in historicResults)
          (row['category_id'] as String? ?? 'General'):
              (row['historic_value'] as num?)?.toDouble() ?? 0.0,
      };

      // 2. Query Sales History Grouped by Category & Product
      // Join sales to filter out refunds (is_refund = 0)
      // Join products to get category_id.
      // Handle deleted products (p.category_id IS NULL) -> likely category deleted or hard deleted.
      final salesResults = await db.database.rawQuery('''
        SELECT
          p.category_id,
          si.product_id,
          si.product_name,
          si.product_barcode,
          SUM(si.quantity) as sold_qty,
          SUM(si.refunded_quantity) as refunded_qty
        FROM sale_items si
        JOIN sales s ON si.sale_id = s.id
        LEFT JOIN products p ON si.product_id = p.id
        WHERE s.is_refund = 0
        GROUP BY p.category_id, si.product_id
      ''');

      // 3. Process & Merge Data
      final Map<String, StockSummaryCategoryModel> categoryMap = {};

      final stockByCategory = <String, Map<String, dynamic>>{};
      for (var row in stockResults) {
        final categoryId = row['category_id'] as String? ?? 'General';
        final unit = (row['base_unit'] as String?)?.trim().isNotEmpty == true
            ? row['base_unit'] as String
            : 'piece';
        final aggregate = stockByCategory.putIfAbsent(
          categoryId,
          () => <String, dynamic>{
            'product_count': 0,
            'total_quantity': 0.0,
            'inventory_cost_value': 0.0,
            'min_sell_value': 0.0,
            'default_sell_value': 0.0,
            'quantity_by_unit': <String, double>{},
          },
        );
        aggregate['product_count'] =
            (aggregate['product_count'] as int) + (row['product_count'] as int);
        aggregate['total_quantity'] = (aggregate['total_quantity'] as double) +
            (row['total_quantity'] as num).toDouble();
        aggregate['inventory_cost_value'] =
            (aggregate['inventory_cost_value'] as double) +
                ((row['inventory_cost_value'] as num?)?.toDouble() ?? 0);
        aggregate['min_sell_value'] = (aggregate['min_sell_value'] as double) +
            ((row['min_sell_value'] as num?)?.toDouble() ?? 0);
        aggregate['default_sell_value'] =
            (aggregate['default_sell_value'] as double) +
                ((row['default_sell_value'] as num?)?.toDouble() ?? 0);
        final quantities = aggregate['quantity_by_unit'] as Map<String, double>;
        quantities[unit] =
            (quantities[unit] ?? 0) + (row['total_quantity'] as num).toDouble();
      }

      // Process Stock Data
      for (final entry in stockByCategory.entries) {
        final categoryId = entry.key;
        final row = entry.value;

        categoryMap[categoryId] = StockSummaryCategoryModel(
          categoryId: categoryId,
          categoryName: categoryNames[categoryId] ?? categoryId,
          productCount: row['product_count'] as int,
          totalQuantity: (row['total_quantity'] as num).toDouble(),
          totalCurrentInventoryCost:
              row['inventory_cost_value'] as double? ?? 0.0,
          totalMinSellValue: row['min_sell_value'] as double? ?? 0.0,
          totalDefaultSellValue: row['default_sell_value'] as double? ?? 0.0,
          quantityByUnit:
              Map<String, double>.from(row['quantity_by_unit'] as Map),
          // Initialize sales fields to 0, will update next
          totalSoldQuantity: 0,
          totalHistoricValue: 0, // Will add stock value later
          isDeletedCategory: false,
          productDetails: [],
          inventoryCostAvailable: row['inventory_cost_value'] != null,
        );
      }

      // Process Sales Data
      for (var row in salesResults) {
        var categoryId = row['category_id'] as String?;
        categoryId ??= 'Deleted';

        if (!categoryMap.containsKey(categoryId)) {
          // Category exists in sales but not in current active products (maybe deleted category or no active products)
          categoryMap[categoryId] = StockSummaryCategoryModel(
            categoryId: categoryId,
            categoryName: categoryNames[categoryId] ?? categoryId,
            productCount: 0,
            totalQuantity: 0,
            totalCurrentInventoryCost: 0,
            totalMinSellValue: 0,
            totalDefaultSellValue: 0,
            totalSoldQuantity: 0,
            totalHistoricValue: historicDataMap[categoryId] ?? 0,
            isDeletedCategory: categoryId == 'Deleted',
            productDetails: [],
            inventoryCostAvailable: false,
          );
        }

        (row['sold_qty'] as num).toInt();
        (row['refunded_qty'] as num).toInt();
      }

      // RESTART STRATEGY: Accumulate in Maps
      final Map<String, List<ProductSalesDetail>> catDetails = {};
      final Map<String, int> catSoldQty = {};

      for (var row in salesResults) {
        var categoryId = row['category_id'] as String?;
        categoryId ??= 'Deleted';

        final soldQty = (row['sold_qty'] as num).toInt();
        final refundedQty = (row['refunded_qty'] as num).toInt();
        final netSoldQty = soldQty - refundedQty;
        catSoldQty[categoryId] = (catSoldQty[categoryId] ?? 0) + netSoldQty;

        if (!catDetails.containsKey(categoryId)) {
          catDetails[categoryId] = [];
        }

        catDetails[categoryId]!.add(ProductSalesDetail(
          productName: row['product_name'] as String,
          barcode:
              row['product_barcode'] as String? ?? row['product_id'] as String,
          soldQuantity: soldQty,
          refundedQuantity: refundedQty,
        ));
      }

      final List<StockSummaryCategoryModel> summaryList = [];
      // Union of all categories
      final allCats = {
        ...categoryMap.keys,
        ...catDetails.keys
      }; // categoryMap keys from Stock query

      final stockDataMap = {
        for (var r in stockResults)
          (r['category_id'] as String? ?? 'General'): r
      };

      for (var cat in allCats) {
        final stockRow = stockDataMap[cat];
        final currentQty =
            stockRow != null ? (stockRow['total_quantity'] as num).toInt() : 0;
        final currentInventoryCost = stockRow != null
            ? (stockRow['inventory_cost_value'] as double? ?? 0.0)
            : 0.0;
        final minSell = stockRow != null
            ? (stockRow['min_sell_value'] as double? ?? 0.0)
            : 0.0;
        final defaultSell = stockRow != null
            ? (stockRow['default_sell_value'] as double? ?? 0.0)
            : 0.0;
        final productCount =
            stockRow != null ? (stockRow['product_count'] as int) : 0;

        final historicTotal = historicDataMap[cat] ?? 0;

        summaryList.add(StockSummaryCategoryModel(
          categoryId: cat,
          categoryName: categoryNames[cat] ?? cat,
          productCount: productCount,
          totalQuantity: currentQty.toDouble(),
          totalSoldQuantity: (catSoldQty[cat] ?? 0).toDouble(),
          totalHistoricValue: historicTotal,
          totalCurrentInventoryCost: currentInventoryCost,
          totalMinSellValue: minSell,
          totalDefaultSellValue: defaultSell,
          isDeletedCategory: cat == 'Deleted',
          productDetails: catDetails[cat] ?? [],
          inventoryCostAvailable:
              stockRow != null && stockRow['inventory_cost_value'] != null,
        ));
      }

      // 4. Calculate Grand Totals
      double grandHistoric = 0;
      double grandCurrent = 0;
      double grandExpectedProfit = 0;

      for (var s in summaryList) {
        grandHistoric += s.totalHistoricValue;
        grandCurrent += s.totalCurrentInventoryCost;
        grandExpectedProfit += s.expectedProfit;
      }

      print(
          '  💰 Recorded Stock-In Cost: ${grandHistoric.toStringAsFixed(2)}');
      print(
          '  💵 Grand Total Current Value: ${grandCurrent.toStringAsFixed(2)}');
      print('  ✅ Stock summary loaded successfully');

      if (!isClosed) {
        emit(StockSummaryLoaded(
          categories: summaryList,
          totalStoreHistoricValue: grandHistoric,
          totalStoreCurrentValue: grandCurrent,
          totalExpectedProfit: grandExpectedProfit,
          inventoryCostAvailable:
              summaryList.every((item) => item.inventoryCostAvailable),
        ));
      }
    } catch (e) {
      print('  ❌ Stock summary failed: $e');
      if (!isClosed) emit(StockSummaryError("Failed to calculate summary: $e"));
    }
  }
}
