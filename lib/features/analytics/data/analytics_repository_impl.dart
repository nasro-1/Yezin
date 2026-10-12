// lib/features/analytics/data/analytics_repository_impl.dart

import 'package:bayaa_pos/core/data/services/persistence_initializer.dart';
import 'package:bayaa_pos/core/data/services/repository_persistence_mixin.dart';
import 'package:dartz/dartz.dart';
import 'package:bayaa_pos/core/di/dependency_injection.dart';
import '../../../core/error/failure.dart';
import '../../sales/domain/sales_repository.dart';
import '../domain/analytics_repository.dart';
import 'models/analytics_summary_model.dart';
import 'local_fifo_analytics_costing.dart';
import '../../sessions/data/models/daily_report_model.dart';
import '../../sessions/data/models/product_performance_model.dart';
import 'package:bayaa_pos/features/sales/data/models/sale_model.dart';
import 'package:bayaa_pos/core/network/backend_api_client.dart';

import '../../sessions/data/repositories/session_repository_impl.dart';

class _AnalyticsDateRange {
  const _AnalyticsDateRange(this.start, this.endExclusive);

  final DateTime start;
  final DateTime endExclusive;
}

class AnalyticsRepositoryImpl
    with RepositoryPersistenceMixin
    implements AnalyticsRepository {
  AnalyticsRepositoryImpl({this.client, this.serverMode = false});

  final BackendApiClient? client;
  final bool serverMode;

  _AnalyticsDateRange _dateRange(DateTime start, DateTime end) {
    final firstDay = DateTime(start.year, start.month, start.day);
    final lastDay = DateTime(end.year, end.month, end.day);
    return _AnalyticsDateRange(
      firstDay,
      DateTime(lastDay.year, lastDay.month, lastDay.day + 1),
    );
  }

  Future<Map<String, dynamic>> _serverAnalytics(
      DateTime start, DateTime end) async {
    if (client == null) {
      throw StateError('Server analytics client is not configured');
    }
    final range = _dateRange(start, end);
    return client!.getAnalytics(
      startDate: range.start,
      endDateExclusive: range.endExclusive,
    );
  }

  // Helper to access DB
  Future<List<Map<String, dynamic>>> _query(String sql,
      [List<Object?>? args]) async {
    final db =
        PersistenceInitializer.persistenceManager!.sqliteManager.database;
    return await db.rawQuery(sql, args);
  }

  Future<LocalFifoAnalyticsCostResult> _localFifoCosts(
    _AnalyticsDateRange range,
  ) async {
    final movements = await _query(
      '''
        SELECT id, product_id, movement_type, quantity_change, unit_cost,
          reference_type, reference_id, lineage_id, created_at
        FROM stock_movements
        WHERE created_at < ?
        ORDER BY created_at ASC, rowid ASC
      ''',
      [range.endExclusive.toIso8601String()],
    );
    final calculated = const LocalFifoAnalyticsCosting().calculate(
      movements: movements,
      start: range.start,
      endExclusive: range.endExclusive,
    );

    final missingSales = await _query('''
      SELECT si.id, si.sale_id, si.product_id
      FROM sale_items si
      JOIN sales s ON s.id = si.sale_id
      WHERE s.is_refund = 0 AND s.created_at >= ? AND s.created_at < ?
        AND NOT EXISTS (
          SELECT 1 FROM stock_movements sm
          WHERE sm.reference_type = 'sale' AND sm.reference_id = s.id
            AND (sm.lineage_id = si.id OR sm.id = si.id || '_movement')
        )
    ''', [
      range.start.toIso8601String(),
      range.endExclusive.toIso8601String(),
    ]);
    final refundRows = await _query('''
      SELECT s.id AS sale_id, si.product_id,
        SUM(COALESCE(si.base_quantity, si.quantity)) AS quantity
      FROM sale_items si
      JOIN sales s ON s.id = si.sale_id
      WHERE s.is_refund = 1 AND s.created_at >= ? AND s.created_at < ?
      GROUP BY s.id, si.product_id
    ''', [
      range.start.toIso8601String(),
      range.endExclusive.toIso8601String(),
    ]);
    final recordedReturns = await _query('''
      SELECT reference_id, product_id, SUM(quantity_change) AS quantity
      FROM stock_movements
      WHERE movement_type = 'customer_return'
        AND created_at >= ? AND created_at < ?
      GROUP BY reference_id, product_id
    ''', [
      range.start.toIso8601String(),
      range.endExclusive.toIso8601String(),
    ]);
    final returnedQuantityByReferenceProduct = <String, double>{
      for (final movement in recordedReturns)
        '${movement['reference_id']}::${movement['product_id']}':
            (movement['quantity'] as num).toDouble(),
    };
    final costByProduct = Map<String, double>.from(calculated.costByProduct);
    final costByLineage = Map<String, double>.from(calculated.costByLineage);
    final costByReferenceProduct =
        Map<String, double>.from(calculated.costByReferenceProduct);
    final unknownCostProducts =
        Set<String>.from(calculated.unknownCostProducts);
    final incompleteReferences =
        Set<String>.from(calculated.incompleteReferences);
    var totalCost = calculated.totalCost;
    for (final sale in missingSales) {
      final productId = sale['product_id'] as String;
      final referenceId = sale['sale_id'] as String;
      incompleteReferences.add('$referenceId::$productId');
      unknownCostProducts.add(productId);
      totalCost = null;
    }
    for (final refund in refundRows) {
      final productId = refund['product_id'] as String;
      final saleId = refund['sale_id'] as String;
      final refundedQuantity = (refund['quantity'] as num).toDouble();
      final recordedQuantity =
          returnedQuantityByReferenceProduct['$saleId::$productId'] ?? 0;
      final unrecordedQuantity = refundedQuantity - recordedQuantity;
      if (unrecordedQuantity <= 1e-9) continue;
      incompleteReferences.add('$saleId::$productId');
      unknownCostProducts.add(productId);
      totalCost = null;
    }

    return LocalFifoAnalyticsCostResult(
      totalCost: unknownCostProducts.isEmpty ? totalCost : null,
      costByProduct: costByProduct,
      costByLineage: costByLineage,
      costByReferenceProduct: costByReferenceProduct,
      unknownCostProducts: unknownCostProducts,
      incompleteReferences: incompleteReferences,
      seenSaleLineages: calculated.seenSaleLineages,
    );
  }

  @override
  Future<Either<Failure, Map<int, double>>> getHourlySales(
      DateTime start, DateTime end) async {
    if (serverMode) {
      try {
        final payload = await _serverAnalytics(start, end);
        return Right({
          for (final entry in (payload['hourly_sales'] as Map? ?? {}).entries)
            int.parse('${entry.key}'): (entry.value as num).toDouble(),
        });
      } catch (error) {
        return Left(ServerFailure(error.toString()));
      }
    }
    try {
      final range = _dateRange(start, end);
      final rows = await _query('''
        SELECT
          CAST(strftime('%H', created_at) AS INTEGER) as hour,
          SUM(CASE WHEN is_refund = 0 THEN total ELSE -total END) as revenue
        FROM sales
        WHERE created_at >= ? AND created_at < ?
        GROUP BY hour
        ORDER BY hour ASC
      ''', [
        range.start.toIso8601String(),
        range.endExclusive.toIso8601String()
      ]);

      final Map<int, double> result = {};
      for (var row in rows) {
        result[row['hour'] as int] =
            (row['revenue'] as num?)?.toDouble() ?? 0.0;
      }
      final exchanges = await _query('''
        SELECT CAST(strftime('%H', created_at) AS INTEGER) AS hour,
          SUM(ei.old_total) AS revenue
        FROM exchange_documents ed
        JOIN exchange_items ei ON ei.exchange_id = ed.id
        WHERE ed.created_at >= ? AND ed.created_at < ?
        GROUP BY hour
      ''', [
        range.start.toIso8601String(),
        range.endExclusive.toIso8601String()
      ]);
      for (final row in exchanges) {
        final hour = row['hour'] as int;
        result[hour] =
            (result[hour] ?? 0) - ((row['revenue'] as num?)?.toDouble() ?? 0);
      }
      for (var hour = 0; hour < 24; hour++) {
        result.putIfAbsent(hour, () => 0);
      }
      return Right(result);
    } catch (e) {
      return Left(CacheFailure("Failed to fetch hourly sales"));
    }
  }

  @override
  Future<Either<Failure, Map<String, double>>> getSalesByCategory(
      DateTime start, DateTime end) async {
    if (serverMode) {
      try {
        final payload = await _serverAnalytics(start, end);
        return Right(_doubleMap(payload['category_sales']));
      } catch (error) {
        return Left(ServerFailure(error.toString()));
      }
    }
    try {
      final range = _dateRange(start, end);
      final rows = await _query('''
        SELECT
          COALESCE(c.name, 'General') as category,
          SUM(CASE WHEN s.is_refund = 0 THEN si.subtotal ELSE -si.subtotal END)
            as revenue
        FROM sale_items si
        JOIN sales s ON si.sale_id = s.id
        JOIN products p ON si.product_id = p.id
        LEFT JOIN categories c ON p.category_id = c.id
        WHERE s.created_at >= ? AND s.created_at < ?
        GROUP BY COALESCE(c.name, 'General')
        ORDER BY revenue DESC
      ''', [
        range.start.toIso8601String(),
        range.endExclusive.toIso8601String()
      ]);

      final Map<String, double> result = {};
      for (var row in rows) {
        final cat = row['category'] as String?;
        if (cat != null && cat.isNotEmpty) {
          result[cat] = (row['revenue'] as num?)?.toDouble() ?? 0.0;
        }
      }
      final exchangeRows = await _query('''
        SELECT COALESCE(c.name, 'General') AS category,
          SUM(ei.old_total) AS revenue
        FROM exchange_documents ed
        JOIN exchange_items ei ON ei.exchange_id = ed.id
        JOIN products p ON p.id = ei.original_product_id
        LEFT JOIN categories c ON c.id = p.category_id
        WHERE ed.created_at >= ? AND ed.created_at < ?
        GROUP BY COALESCE(c.name, 'General')
      ''', [
        range.start.toIso8601String(),
        range.endExclusive.toIso8601String()
      ]);
      for (final row in exchangeRows) {
        final category = row['category'] as String?;
        if (category != null && category.isNotEmpty) {
          result[category] = (result[category] ?? 0) -
              ((row['revenue'] as num?)?.toDouble() ?? 0);
        }
      }
      result.removeWhere((_, revenue) => revenue <= 0);
      if (result.length > 10) {
        final sorted = result.entries.toList()
          ..sort((a, b) => b.value.compareTo(a.value));
        return Right(Map.fromEntries(sorted.take(10)));
      }
      return Right(result);
    } catch (e) {
      return Right({});
    }
  }

  @override
  Future<Either<Failure, Map<String, double>>> getDailyTimeSeries(
      DateTime start, DateTime end) async {
    if (serverMode) {
      try {
        final payload = await _serverAnalytics(start, end);
        return Right({
          for (final entry
              in (payload['daily_time_series'] as Map? ?? {}).entries)
            '${entry.key}': (entry.value as num).toDouble(),
        });
      } catch (error) {
        return Left(ServerFailure(error.toString()));
      }
    }
    try {
      final range = _dateRange(start, end);
      final rows = await _query('''
        SELECT
          date(created_at) as day,
          SUM(CASE WHEN is_refund = 0 THEN total ELSE -total END) as revenue
        FROM sales
        WHERE created_at >= ? AND created_at < ?
        GROUP BY day
        ORDER BY day ASC
      ''', [
        range.start.toIso8601String(),
        range.endExclusive.toIso8601String()
      ]);

      final Map<String, double> result = {};
      for (var row in rows) {
        result[row['day'] as String] =
            (row['revenue'] as num?)?.toDouble() ?? 0.0;
      }
      final exchanges = await _query('''
        SELECT date(created_at) AS day, SUM(ei.old_total) AS revenue
        FROM exchange_documents ed
        JOIN exchange_items ei ON ei.exchange_id = ed.id
        WHERE ed.created_at >= ? AND ed.created_at < ?
        GROUP BY day
      ''', [
        range.start.toIso8601String(),
        range.endExclusive.toIso8601String()
      ]);
      for (final row in exchanges) {
        final day = row['day'] as String;
        result[day] =
            (result[day] ?? 0) - ((row['revenue'] as num?)?.toDouble() ?? 0);
      }
      for (var day = range.start;
          day.isBefore(range.endExclusive);
          day = DateTime(day.year, day.month, day.day + 1)) {
        result.putIfAbsent(
          '${day.year.toString().padLeft(4, '0')}-'
          '${day.month.toString().padLeft(2, '0')}-'
          '${day.day.toString().padLeft(2, '0')}',
          () => 0,
        );
      }
      return Right(result);
    } catch (e) {
      return Left(CacheFailure("Failed to fetch daily time series"));
    }
  }

  @override
  Future<Either<Failure, List<DailyReport>>> getReportsInRange(
      DateTime start, DateTime end) async {
    if (serverMode) {
      return Left(
          ServerFailure('Session reports are unavailable in server mode'));
    }
    try {
      final sessionRepo = getIt<SessionRepositoryImpl>();
      final sessions = await sessionRepo.getSessionsInRange(start, end);

      final List<DailyReport> reports = [];
      for (var session in sessions) {
        if (session.dailyReportId != null) {
          final report = await _generateReportForSession(session.id);
          if (report != null) {
            reports.add(report);
          }
        }
      }
      return Right(reports);
    } catch (e) {
      return Left(CacheFailure('Failed to fetch reports: ${e.toString()}'));
    }
  }

  @override
  Future<Either<Failure, AnalyticsSummaryModel>> getSummary(
      DateTime start, DateTime end) async {
    if (serverMode) {
      try {
        final payload = await _serverAnalytics(start, end);
        final totalCost = (payload['total_cost'] as num?)?.toDouble();
        final totalExpenses = (payload['total_expenses'] as num?)?.toDouble();
        final totalProfit = (payload['total_profit'] as num?)?.toDouble();
        final profitMargin = (payload['profit_margin'] as num?)?.toDouble();
        final expenseDataAvailable =
            payload['expense_data_available'] == true ||
                payload['expenses_data_available'] == true;
        return Right(AnalyticsSummaryModel(
          startDate: start,
          endDate: end,
          totalRevenue: (payload['total_revenue'] as num?)?.toDouble() ?? 0,
          totalCost: totalCost,
          totalProfit: totalProfit,
          profitMargin: profitMargin,
          totalSales: (payload['total_sales'] as num?)?.toInt() ?? 0,
          grossRevenue: (payload['gross_revenue'] as num?)?.toDouble() ?? 0,
          refundedAmount: (payload['refunded_amount'] as num?)?.toDouble() ?? 0,
          totalExpenses: totalExpenses,
          soldQuantity: (payload['sold_quantity'] as num?)?.toDouble() ?? 0,
          refundedQuantity:
              (payload['refunded_quantity'] as num?)?.toDouble() ?? 0,
          costDataAvailable:
              payload['cost_data_available'] == true && totalCost != null,
          expensesDataAvailable: expenseDataAvailable && totalExpenses != null,
          profitDataAvailable: totalProfit != null &&
              profitMargin != null &&
              expenseDataAvailable,
        ));
      } catch (error) {
        return Left(ServerFailure(error.toString()));
      }
    }
    try {
      final range = _dateRange(start, end);
      final startIso = range.start.toIso8601String();
      final endExclusiveIso = range.endExclusive.toIso8601String();

      final salesResult = await _query('''
        SELECT
          COUNT(CASE WHEN is_refund = 0 THEN 1 END) as sales_count,
          SUM(CASE WHEN is_refund = 0 THEN total ELSE 0.0 END) as gross_revenue,
          SUM(CASE WHEN is_refund = 1 THEN total ELSE 0.0 END) as refunded_amount
        FROM sales
        WHERE created_at >= ? AND created_at < ?
      ''', [startIso, endExclusiveIso]);

      final totalSalesCount = (salesResult.first['sales_count'] as int?) ?? 0;
      final grossRevenue =
          (salesResult.first['gross_revenue'] as num?)?.toDouble() ?? 0.0;
      final totalRefunds =
          (salesResult.first['refunded_amount'] as num?)?.toDouble() ?? 0.0;

      final exchangeResult = await _query('''
        SELECT COALESCE(SUM(ei.old_total), 0) AS exchanged_amount
        FROM exchange_documents ed
        JOIN exchange_items ei ON ei.exchange_id = ed.id
        WHERE ed.created_at >= ? AND ed.created_at < ?
      ''', [startIso, endExclusiveIso]);
      final exchangedAmount =
          (exchangeResult.first['exchanged_amount'] as num?)?.toDouble() ?? 0;
      final netRevenue = grossRevenue - totalRefunds - exchangedAmount;

      final fifoCosts = await _localFifoCosts(range);
      final netCost = fifoCosts.totalCost;
      final expensesResult = await _query('''
        SELECT COALESCE(SUM(amount), 0) AS total_expenses
        FROM expenses WHERE created_at >= ? AND created_at < ?
      ''', [startIso, endExclusiveIso]);
      final totalExpenses =
          (expensesResult.first['total_expenses'] as num?)?.toDouble() ?? 0.0;
      final netProfit =
          netCost == null ? null : netRevenue - netCost - totalExpenses;
      final profitMargin = netProfit == null || netRevenue == 0
          ? null
          : (netProfit / netRevenue) * 100;
      final quantityResult = await _query('''
        SELECT
          COALESCE(SUM(CASE WHEN s.is_refund = 0
            THEN COALESCE(si.base_quantity, si.quantity) ELSE 0 END), 0)
            AS sold_quantity,
          COALESCE(SUM(CASE WHEN s.is_refund = 1
            THEN COALESCE(si.base_quantity, si.quantity) ELSE 0 END), 0)
            AS refunded_quantity
        FROM sale_items si
        JOIN sales s ON s.id = si.sale_id
        WHERE s.created_at >= ? AND s.created_at < ?
      ''', [startIso, endExclusiveIso]);

      return Right(AnalyticsSummaryModel(
        startDate: range.start,
        endDate: range.endExclusive.subtract(const Duration(days: 1)),
        totalRevenue: netRevenue,
        totalCost: netCost,
        totalProfit: netProfit,
        profitMargin: profitMargin,
        totalSales: totalSalesCount,
        soldQuantity: (quantityResult.first['sold_quantity'] as num).toDouble(),
        refundedQuantity:
            (quantityResult.first['refunded_quantity'] as num).toDouble(),
        grossRevenue: grossRevenue,
        refundedAmount: totalRefunds,
        totalExpenses: totalExpenses,
        costDataAvailable: netCost != null,
        expensesDataAvailable: true,
        profitDataAvailable: netProfit != null,
      ));
    } catch (e) {
      return Left(
          CacheFailure("Error loading sessions summary: ${e.toString()}"));
    }
  }

  @override
  Future<Either<Failure, List<ProductPerformanceModel>>> getTopProducts(
      int limit, DateTime start, DateTime end) async {
    if (serverMode) {
      try {
        final payload = await _serverAnalytics(start, end);
        final items = (payload['top_products'] as List? ?? const [])
            .whereType<Map>()
            .take(limit)
            .map((raw) {
          final item = Map<String, dynamic>.from(raw);
          final itemCost = item['cost'] as num?;
          if (itemCost == null) {
            throw StateError(
                'Top-product cost is unavailable for ${item['product_id']}');
          }
          return ProductPerformanceModel(
            productId: '${item['product_id']}',
            productName: '${item['product_name']}',
            quantitySold: (item['quantity_sold'] as num?)?.round() ?? 0,
            revenue: (item['revenue'] as num?)?.toDouble() ?? 0,
            cost: itemCost.toDouble(),
            profit: (item['profit'] as num?)?.toDouble() ?? 0,
            profitMargin: (item['profit_margin'] as num?)?.toDouble() ?? 0,
          );
        }).toList();
        return Right(items);
      } catch (error) {
        return Left(ServerFailure(error.toString()));
      }
    }
    try {
      final range = _dateRange(start, end);
      final fifoCosts = await _localFifoCosts(range);
      final sql = '''
        SELECT
          sales.product_id,
          MAX(sales.product_name) AS name,
          SUM(CASE WHEN sales.is_refund = 0 THEN sales.quantity ELSE -sales.quantity END) AS net_qty,
          SUM(CASE WHEN sales.is_refund = 0 THEN sales.revenue ELSE -sales.revenue END) AS net_revenue
        FROM (
          SELECT si.product_id, si.product_name,
            COALESCE(si.base_quantity, si.quantity) AS quantity,
            si.subtotal AS revenue,
            s.is_refund, s.created_at
          FROM sale_items si
          JOIN sales s ON si.sale_id = s.id
          WHERE s.created_at >= ? AND s.created_at < ?
          UNION ALL
          SELECT ei.original_product_id, p.name,
            -COALESCE(ei.original_base_quantity, ei.returned_quantity),
            -ei.old_total,
            0, ed.created_at
          FROM exchange_documents ed
          JOIN exchange_items ei ON ei.exchange_id = ed.id
          JOIN products p ON p.id = ei.original_product_id
          WHERE ed.created_at >= ? AND ed.created_at < ?
        ) sales
        GROUP BY sales.product_id
        HAVING net_qty > 0 AND net_revenue > 0
        ORDER BY net_revenue DESC
        LIMIT ?
      ''';

      final rows = await _query(sql, [
        range.start.toIso8601String(),
        range.endExclusive.toIso8601String(),
        range.start.toIso8601String(),
        range.endExclusive.toIso8601String(),
        limit,
      ]);

      final List<ProductPerformanceModel> toplist = [];
      for (var row in rows) {
        final productId = row['product_id'] as String;
        if (fifoCosts.unknownCostProducts.contains(productId) ||
            !fifoCosts.costByProduct.containsKey(productId)) {
          return Left(CacheFailure(
              'FIFO cost is unavailable for top product $productId'));
        }
        final revenue = (row['net_revenue'] as num?)?.toDouble() ?? 0.0;
        final cost = fifoCosts.costByProduct[productId]!;
        final profit = revenue - cost;
        final margin = revenue > 0 ? (profit / revenue) * 100 : 0.0;

        toplist.add(ProductPerformanceModel(
          productId: productId,
          productName: row['name'] as String,
          quantitySold: (row['net_qty'] as num? ?? 0).round(),
          revenue: revenue,
          cost: cost,
          profit: profit,
          profitMargin: margin,
        ));
      }

      return Right(toplist);
    } catch (e) {
      return Left(CacheFailure("Error loading products: ${e.toString()}"));
    }
  }

  @override
  Future<Either<Failure, DailyReport>> getDailyReport(DateTime date) async {
    if (serverMode) {
      return Left(
          ServerFailure('Daily reports are unavailable in server mode'));
    }
    try {
      final start = DateTime(date.year, date.month, date.day, 0, 0, 0);
      final end = DateTime(date.year, date.month, date.day, 23, 59, 59);

      final salesRepo = getIt<SalesRepository>();
      await salesRepo.getRecentSales(limit: 10000);

      final salesRows = await _query('''
        SELECT * FROM sales
        WHERE created_at BETWEEN ? AND ?
      ''', [start.toIso8601String(), end.toIso8601String()]);

      if (salesRows.isEmpty) {
        return Left(CacheFailure("No data found for this day."));
      }

      final summary = await getSummary(start, end);
      return summary.fold((f) => Left(f), (analyticsModel) async {
        final topProducts = await getTopProducts(50, start, end);

        return Right(DailyReport(
          id: "DATE_${date.millisecondsSinceEpoch}",
          sessionId: "DATE_AGGREGATE",
          date: date,
          totalSales:
              analyticsModel.grossRevenue ?? analyticsModel.totalRevenue,
          totalRefunds: analyticsModel.refundedAmount ?? 0,
          netRevenue: analyticsModel.totalRevenue,
          totalTransactions: analyticsModel.totalSales,
          closedByUserName: "System",
          topProducts: topProducts.getOrElse(() => []),
          refundedProducts: [],
          transactions: [],
          historicalCogs: analyticsModel.totalCost,
          historicalCogsAvailable: analyticsModel.costDataAvailable,
        ));
      });
    } catch (e) {
      return Left(CacheFailure("Error fetching daily report: ${e.toString()}"));
    }
  }

  @override
  Future<Either<Failure, DailyReport?>> getReportForSession(
      String sessionId) async {
    if (serverMode) {
      return Left(
          ServerFailure('Session reports are unavailable in server mode'));
    }
    try {
      final salesRepo = getIt<SalesRepository>();
      final db =
          PersistenceInitializer.persistenceManager!.sqliteManager.database;

      final salesIds = await db.query(
        'sales',
        columns: ['id'],
        where: 'shift_id = ?',
        whereArgs: [sessionId],
      );

      if (salesIds.isEmpty) {
        return Right(DailyReport(
          id: 'EMPTY_$sessionId',
          sessionId: sessionId,
          date: DateTime.now(),
          totalSales: 0,
          totalRefunds: 0,
          netRevenue: 0,
          totalTransactions: 0,
          closedByUserName: 'System',
          topProducts: [],
          transactions: [],
          refundedProducts: [],
        ));
      }

      final ids = salesIds.map((r) => r['id'] as String).toList();
      final salesResult = await salesRepo.getSalesByIds(ids);

      return await salesResult.fold<Future<Either<Failure, DailyReport>>>(
        (failure) async => Left(failure),
        (sales) async =>
            Right(await _generateReportFromSales(sales, DateTime.now())),
      );
    } catch (e) {
      return Left(
          CacheFailure("Failed to fetch session report: ${e.toString()}"));
    }
  }

  Future<DailyReport?> _generateReportForSession(String sessionId) async {
    final result = await getReportForSession(sessionId);
    return result.fold((l) => null, (r) => r);
  }

  Future<DailyReport> _generateReportFromSales(
      List<Sale> sales, DateTime date) async {
    double totalSales = 0.0;
    double totalRefunds = 0.0;
    final Map<String, ProductPerformanceModel> productStats = {};
    final Map<String, ProductPerformanceModel> refundStats = {};
    final fifoCosts = sales.isEmpty
        ? null
        : await _localFifoCosts(
            _dateRange(
              sales.map((sale) => sale.date).reduce(
                    (a, b) => a.isBefore(b) ? a : b,
                  ),
              sales.map((sale) => sale.date).reduce(
                    (a, b) => a.isAfter(b) ? a : b,
                  ),
            ),
          );
    final historicalCostsBySaleProduct = <String, double?>{};
    var historicalCogsAvailable = true;
    for (final sale in sales) {
      for (final productId
          in sale.saleItems.map((item) => item.productId).toSet()) {
        final key = '${sale.id}::$productId';
        final cost = fifoCosts?.costByReferenceProduct[key];
        final complete =
            fifoCosts != null && !fifoCosts.incompleteReferences.contains(key);
        historicalCostsBySaleProduct[key] = complete ? cost : null;
        if (!complete || cost == null) historicalCogsAvailable = false;
      }
    }
    final totalHistoricalCogs = historicalCogsAvailable
        ? historicalCostsBySaleProduct.values.fold<double>(
            0,
            (total, cost) => total + cost!,
          )
        : null;
    final seenCostProducts = <String>{};

    for (final sale in sales) {
      final isRefund = sale.isRefund;
      final sign = isRefund ? -1.0 : 1.0;

      if (isRefund) {
        totalRefunds += sale.total.abs();
      } else {
        totalSales += sale.total;
      }

      for (final item in sale.saleItems) {
        final revenue = (item.price * item.quantity) * sign;
        final costKey = '${sale.id}::${item.productId}';
        final cost = seenCostProducts.add(costKey)
            ? historicalCostsBySaleProduct[costKey] ?? 0.0
            : 0.0;
        final qty = item.quantity * (isRefund ? -1 : 1);

        if (productStats.containsKey(item.productId)) {
          final existing = productStats[item.productId]!;
          productStats[item.productId] = existing.copyWith(
            quantitySold: (existing.quantitySold + qty).toInt(),
            revenue: existing.revenue + revenue,
            cost: existing.cost + cost,
          );
        } else {
          productStats[item.productId] = ProductPerformanceModel(
            productId: item.productId,
            productName: item.name,
            quantitySold: qty.toInt(),
            revenue: revenue,
            cost: cost,
            profit: 0,
            profitMargin: 0,
          );
        }

        if (isRefund) {
          if (refundStats.containsKey(item.productId)) {
            final existing = refundStats[item.productId]!;
            refundStats[item.productId] = existing.copyWith(
              quantitySold: (existing.quantitySold + item.quantity.toInt()),
              revenue: existing.revenue + item.total,
              cost: existing.cost + cost.abs(),
            );
          } else {
            refundStats[item.productId] = ProductPerformanceModel(
              productId: item.productId,
              productName: item.name,
              quantitySold: item.quantity.toInt(),
              revenue: item.total,
              cost: cost.abs(),
              profit: 0,
              profitMargin: 0,
            );
          }
        }
      }
    }

    final topProducts = productStats.values.map((p) {
      final profit = historicalCogsAvailable ? p.revenue - p.cost : 0.0;
      final margin = historicalCogsAvailable && p.revenue > 0
          ? (profit / p.revenue) * 100
          : 0.0;
      return p.copyWith(profit: profit, profitMargin: margin);
    }).toList()
      ..removeWhere(
          (product) => product.quantitySold <= 0 || product.revenue <= 0)
      ..sort((a, b) => b.revenue.compareTo(a.revenue));

    return DailyReport(
      id: "SESSION_REP",
      sessionId: "SESSION",
      date: date,
      totalSales: totalSales,
      totalRefunds: totalRefunds,
      netRevenue: totalSales - totalRefunds,
      totalTransactions: sales.length,
      closedByUserName: "System",
      topProducts: topProducts,
      refundedProducts: refundStats.values.toList(),
      transactions: sales,
      historicalCogs: totalHistoricalCogs,
      historicalCogsAvailable: historicalCogsAvailable,
    );
  }

  @override
  Future<Either<Failure, Map<String, double>>> getDailySales(
      DateTime start, DateTime end) async {
    final result = await getSummary(start, end);
    return result.fold((failure) => Left(failure), (summary) {
      final values = <String, double>{'Total sales': summary.totalRevenue};
      if (summary.costDataAvailable && summary.totalCost != null) {
        values['Total cost'] = summary.totalCost!;
      }
      if (summary.profitDataAvailable && summary.totalProfit != null) {
        values['Net profit'] = summary.totalProfit!;
      }
      return Right(values);
    });
  }

  @override
  Future<void> deleteReport(String reportId) async {
    try {
      print(
          'Delete report called for ID: $reportId (no-op in current implementation)');
    } catch (e) {
      print('Error in deleteReport: ${e.toString()}');
    }
  }

  @override
  Future<Either<Failure, Map<int, double>>> getHourlySalesForSession(
      String sessionId) async {
    try {
      final rows = await _query('''
        SELECT
          CAST(strftime('%H', created_at) AS INTEGER) as hour,
          SUM(total) as revenue
        FROM sales
        WHERE is_refund = 0 AND shift_id = ?
        GROUP BY hour
        ORDER BY hour ASC
      ''', [sessionId]);

      final Map<int, double> result = {};
      for (var row in rows) {
        result[row['hour'] as int] =
            (row['revenue'] as num?)?.toDouble() ?? 0.0;
      }
      return Right(result);
    } catch (e) {
      return Left(CacheFailure(
          "Failed to fetch hourly sales for session: ${e.toString()}"));
    }
  }

  @override
  Future<Either<Failure, Map<String, double>>> getCategorySalesForSession(
      String sessionId) async {
    try {
      final rows = await _query('''
        SELECT
          COALESCE(c.name, 'General') as category,
          SUM(CASE WHEN s.is_refund = 0 THEN si.subtotal ELSE -si.subtotal END)
            as revenue
        FROM sale_items si
        JOIN sales s ON si.sale_id = s.id
        JOIN products p ON si.product_id = p.id
        LEFT JOIN categories c ON p.category_id = c.id
        WHERE s.shift_id = ?
        GROUP BY COALESCE(c.name, 'General')
        ORDER BY revenue DESC
        LIMIT 10
      ''', [sessionId]);

      final Map<String, double> result = {};
      for (var row in rows) {
        final cat = row['category'] as String?;
        if (cat != null && cat.isNotEmpty) {
          result[cat] = (row['revenue'] as num?)?.toDouble() ?? 0.0;
        }
      }
      return Right(result);
    } catch (e) {
      return Right({});
    }
  }

  @override
  Future<Either<Failure, List<ProductPerformanceModel>>>
      getTopProductsForSession(String sessionId, int limit) async {
    final report = await getReportForSession(sessionId);
    return report.fold(
      (failure) => Left(failure),
      (value) => value == null
          ? Left(CacheFailure('Session report is unavailable'))
          : Right(value.topProducts.take(limit).toList()),
    );
  }

  @override
  Future<Either<Failure, Map<String, double>>> getMonthlySales(
      DateTime start, DateTime end) async {
    if (serverMode) {
      try {
        final payload = await _serverAnalytics(start, end);
        return Right(_doubleMap(payload['monthly_sales']));
      } catch (error) {
        return Left(ServerFailure(error.toString()));
      }
    }
    try {
      final range = _dateRange(start, end);
      final rows = await _query('''
        SELECT
          strftime('%Y-%m', created_at) as month,
          SUM(CASE WHEN is_refund = 0 THEN total ELSE -total END) as net_revenue
        FROM sales
        WHERE created_at >= ? AND created_at < ?
        GROUP BY month
        ORDER BY month ASC
      ''', [
        range.start.toIso8601String(),
        range.endExclusive.toIso8601String()
      ]);

      final Map<String, double> result = {};
      for (var row in rows) {
        final value = (row['net_revenue'] as num?)?.toDouble() ?? 0.0;
        if (value > 0) {
          result[row['month'] as String] = value;
        }
      }
      final exchanges = await _query('''
        SELECT strftime('%Y-%m', ed.created_at) AS month,
          SUM(ei.old_total) AS amount
        FROM exchange_documents ed
        JOIN exchange_items ei ON ei.exchange_id = ed.id
        WHERE ed.created_at >= ? AND ed.created_at < ?
        GROUP BY month
      ''', [
        range.start.toIso8601String(),
        range.endExclusive.toIso8601String()
      ]);
      for (final row in exchanges) {
        final month = row['month'] as String;
        result[month] =
            (result[month] ?? 0) - ((row['amount'] as num?)?.toDouble() ?? 0);
      }
      result.removeWhere((_, revenue) => revenue <= 0);
      return Right(result);
    } catch (e) {
      return Left(CacheFailure("Failed to fetch monthly sales"));
    }
  }

  @override
  Future<Either<Failure, Map<String, double>>> getYearlySales(
      DateTime start, DateTime end) async {
    if (serverMode) {
      try {
        final payload = await _serverAnalytics(start, end);
        return Right(_doubleMap(payload['yearly_sales']));
      } catch (error) {
        return Left(ServerFailure(error.toString()));
      }
    }
    try {
      final range = _dateRange(start, end);
      final rows = await _query('''
        SELECT
          strftime('%Y', created_at) as year,
          SUM(CASE WHEN is_refund = 0 THEN total ELSE -total END) as net_revenue
        FROM sales
        WHERE created_at >= ? AND created_at < ?
        GROUP BY year
        ORDER BY year ASC
      ''', [
        range.start.toIso8601String(),
        range.endExclusive.toIso8601String()
      ]);

      final Map<String, double> result = {};
      for (var row in rows) {
        final value = (row['net_revenue'] as num?)?.toDouble() ?? 0.0;
        if (value > 0) {
          result[row['year'] as String] = value;
        }
      }
      final exchanges = await _query('''
        SELECT strftime('%Y', ed.created_at) AS year,
          SUM(ei.old_total) AS amount
        FROM exchange_documents ed
        JOIN exchange_items ei ON ei.exchange_id = ed.id
        WHERE ed.created_at >= ? AND ed.created_at < ?
        GROUP BY year
      ''', [
        range.start.toIso8601String(),
        range.endExclusive.toIso8601String()
      ]);
      for (final row in exchanges) {
        final year = row['year'] as String;
        result[year] =
            (result[year] ?? 0) - ((row['amount'] as num?)?.toDouble() ?? 0);
      }
      result.removeWhere((_, revenue) => revenue <= 0);
      return Right(result);
    } catch (e) {
      return Left(CacheFailure("Failed to fetch yearly sales"));
    }
  }

  Map<String, double> _doubleMap(Object? raw) => {
        for (final entry in (raw as Map? ?? {}).entries)
          '${entry.key}': (entry.value as num).toDouble(),
      };

  @override
  Future<Either<Failure, List<ProductPerformanceModel>>> getTopProductsForMonth(
      String yearMonth, int limit) async {
    final parts = yearMonth.split('-');
    final year = parts.length == 2 ? int.tryParse(parts[0]) : null;
    final month = parts.length == 2 ? int.tryParse(parts[1]) : null;
    if (year == null ||
        month == null ||
        month < 1 ||
        month > 12 ||
        parts[0].length != 4 ||
        parts[1].length != 2) {
      return Left(CacheFailure('Invalid analytics month: $yearMonth'));
    }
    return getTopProducts(
      limit,
      DateTime(year, month),
      DateTime(year, month + 1, 0),
    );
  }
}
