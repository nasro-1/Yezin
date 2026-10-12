// ignore_for_file: avoid_print

import 'package:bayaa_pos/core/data/services/persistence_initializer.dart';
import 'package:bayaa_pos/core/data/services/repository_persistence_mixin.dart';

import 'package:bayaa_pos/features/auth/data/models/user_model.dart';
import 'package:bayaa_pos/features/sales/data/models/sale_model.dart';
import 'package:bayaa_pos/features/analytics/data/local_fifo_analytics_costing.dart';
import '../models/daily_report_model.dart';
import '../models/product_performance_model.dart';

import '../models/session_model.dart';

class SessionRepositoryImpl with RepositoryPersistenceMixin {
  SessionRepositoryImpl({this.serverMode = false});

  final bool serverMode;
  Session? _cachedSession;

  Future<Map<String, double?>> historicalCogsBySaleProduct(
    List<Sale> sales,
  ) async {
    final productIdsBySale = <String, Set<String>>{
      for (final sale in sales)
        sale.id: sale.saleItems.map((item) => item.productId).toSet(),
    };
    if (serverMode) {
      final totals = <String, double>{};
      final incomplete = <String>{};
      for (final sale in sales) {
        for (final item in sale.saleItems) {
          final key = _saleProductKey(sale.id, item.productId);
          if (item.historicalCost == null) {
            incomplete.add(key);
          } else {
            totals[key] = (totals[key] ?? 0) + item.historicalCost!;
          }
        }
      }
      return {
        for (final sale in sales)
          for (final productId in productIdsBySale[sale.id]!)
            _saleProductKey(sale.id, productId):
                incomplete.contains(_saleProductKey(sale.id, productId))
                    ? null
                    : (totals[_saleProductKey(sale.id, productId)] ?? 0) *
                        (sale.isRefund ? -1 : 1),
      };
    }
    if (sales.isEmpty) return const {};

    final start = DateTime.fromMillisecondsSinceEpoch(0);
    final latestSaleTime = sales
        .map((sale) => sale.date)
        .reduce((a, b) => a.isAfter(b) ? a : b)
        .toUtc();
    final db = PersistenceInitializer.persistenceManager!.sqliteManager;
    final movements = await db.rawQuery(
      '''
        SELECT id, product_id, movement_type, quantity_change, unit_cost,
          reference_type, reference_id, lineage_id, created_at
        FROM stock_movements
        WHERE datetime(created_at) <= datetime(?)
        ORDER BY datetime(created_at) ASC, rowid ASC
      ''',
      [latestSaleTime.toIso8601String()],
    );
    final result = const LocalFifoAnalyticsCosting().calculate(
      movements: movements,
      start: start,
      endExclusive: latestSaleTime.add(const Duration(microseconds: 1)),
    );
    return {
      for (final sale in sales)
        for (final productId in productIdsBySale[sale.id]!)
          _saleProductKey(sale.id, productId): result.incompleteReferences
                  .contains(_saleProductKey(sale.id, productId))
              ? null
              : result
                  .costByReferenceProduct[_saleProductKey(sale.id, productId)],
    };
  }

  String _saleProductKey(String saleId, String productId) =>
      '$saleId::$productId';

  void clearCurrentSession() {
    _cachedSession = null;
    print('DEBUG_SESSION: current session cleared from cache');
  }

  Future<void> loadCurrentSession({String? userId}) async {
    try {
      final db = PersistenceInitializer.persistenceManager!.sqliteManager;
      final results = await db.query(
        'shifts',
        where: userId == null ? 'is_open = 1' : 'is_open = 1 AND user_id = ?',
        whereArgs: userId == null ? null : [userId],
        orderBy: 'open_time DESC',
        limit: 1,
      );
      print(
          'DEBUG_SESSION: loadCurrentSession found ${results.length} results');
      if (results.isNotEmpty) {
        _cachedSession = Session.fromMap(results.first);
        print('DEBUG_SESSION: loaded session ${_cachedSession!.id}');
      } else {
        _cachedSession = null;
        print('DEBUG_SESSION: no open session found in DB');
      }
    } catch (e) {
      print('Failed to load session: $e');
    }
  }

  Session? getCurrentSession() {
    return _cachedSession;
  }

  /// Opens a new session if one doesn't exist.
  Future<Session> openSession(User user) async {
    print('DEBUG_SESSION: openSession called for user ${user.username}');
    // Refresh cache first? Or trust memory?

    if (_cachedSession != null &&
        _cachedSession!.isOpen &&
        _cachedSession!.openedByUserId == user.username) {
      print(
          'DEBUG_SESSION: returning existing cached session ${_cachedSession!.id}');
      return _cachedSession!;
    }

    // Double check DB
    await loadCurrentSession(userId: user.username);
    if (_cachedSession != null && _cachedSession!.isOpen) {
      print('DEBUG_SESSION: found session in DB ${_cachedSession!.id}');
      return _cachedSession!;
    }

    final newSession = Session(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      openTime: DateTime.now(),
      openedByUserId: user.username,
      isOpen: true,
    );
    print('DEBUG_SESSION: creating NEW session ${newSession.id}');

    await writeCritical(
      entity: 'session',
      id: newSession.id,
      data: newSession.toMap(),
      sqliteWrite: () async {
        final db = PersistenceInitializer.persistenceManager!.sqliteManager;
        await db.insert('shifts', {
          'id': newSession.id,
          'user_id': newSession.openedByUserId,
          'open_time': newSession.openTime.toIso8601String(),
          'is_open': 1,
        });
      },
    );

    _cachedSession = newSession;
    print('DEBUG_SESSION: Session ${newSession.id} open and cached');
    return newSession;
  }

  /// Closes the current session and generates a DailyReport snapshot.
  Future<DailyReport> closeSession(
    User user, {
    required double totalSales,
    required double totalRefunds,
    required double netRevenue,
    required int totalTransactions,
    required List<ProductPerformanceModel> topProducts,
    List<ProductPerformanceModel> refundedProducts = const [],
    List<Sale> transactions = const [],
    double? historicalCogs,
    bool historicalCogsAvailable = true,
  }) async {
    // Ensure we have current session
    if (_cachedSession == null ||
        _cachedSession!.openedByUserId != user.username) {
      await loadCurrentSession(userId: user.username);
    }

    final session = _cachedSession;
    if (session == null) {
      throw Exception("No open session found to close.");
    }

    final now = DateTime.now();
    final reportId = "${session.id}_REPORT";

    final report = DailyReport(
      id: reportId,
      sessionId: session.id,
      date: now,
      totalSales: totalSales,
      totalRefunds: totalRefunds,
      netRevenue: netRevenue,
      totalTransactions: totalTransactions,
      closedByUserName: user.name,
      topProducts: topProducts,
      refundedProducts: refundedProducts,
      transactions: transactions,
      historicalCogs: historicalCogs,
      historicalCogsAvailable: historicalCogsAvailable,
    );

    // Update session object
    session.isOpen = false;
    session.closeTime = now;
    session.closedByUserId = user.username;
    session.dailyReportId = report.id;

    await writeCritical(
      entity: 'report',
      id: report.id,
      data: report.toMap(),
      sqliteWrite: () async {
        final db = PersistenceInitializer.persistenceManager!.sqliteManager;

        // Update shift in SQLite
        await db.update(
            'shifts',
            {
              'close_time': session.closeTime?.toIso8601String(),
              'closed_by': session.closedByUserId,
              'is_open': 0,
            },
            where: 'id = ?',
            whereArgs: [session.id]);

        // We don't have a 'daily_reports' table to store the snapshot.
        // The data exists in sales/shifts tables implicitly for history.
      },
    );

    _cachedSession = null; // Clear cache as it's closed
    return report;
  }

  /// Get all closed sessions (for history)
  /// Changed to async because pure SQLite is async
  Future<List<Session>> getClosedSessions() async {
    try {
      final db = PersistenceInitializer.persistenceManager!.sqliteManager;
      print('DEBUG: Querying shifts table for closed sessions...');

      final results = await db.query(
        'shifts',
        where: 'is_open = ?', // Use proper parameter binding
        whereArgs: [0], // Pass as argument
        orderBy: 'open_time DESC', // Newest first
      );

      print('DEBUG: Found ${results.length} closed sessions');

      return results.map((row) => Session.fromMap(row)).toList();
    } catch (e) {
      print('ERROR getting closed sessions: $e');
      return [];
    }
  }

  /// Delete a closed session
  Future<void> deleteSession(Session session) async {
    if (session.isOpen) {
      throw Exception('Cannot delete an open session.');
    }

    await deleteCritical(
      entity: 'session',
      id: session.id,
      sqliteWrite: () async {
        final db = PersistenceInitializer.persistenceManager!.sqliteManager;
        await db.transaction((txn) async {
          // 1. Unlink sales from session (preserve sales data)
          await txn.rawUpdate(
              'UPDATE sales SET shift_id = NULL WHERE shift_id = ?',
              [session.id]);

          // 2. Delete activity logs for this session
          await txn.delete('activity_logs',
              where: 'session_id = ?', whereArgs: [session.id]);

          // 3. Delete the session itself
          await txn.delete('shifts', where: 'id = ?', whereArgs: [session.id]);
        });
      },
    );
  }

  /// Delete all closed sessions whose closeTime is between [start] and [end]
  Future<int> deleteSessionsInRange(DateTime start, DateTime end) async {
    // Fetch IDs first to return count, then delete
    final db = PersistenceInitializer.persistenceManager!.sqliteManager;
    final results = await db.query('shifts',
        columns: ['id'],
        where: 'is_open = 0 AND close_time >= ? AND close_time <= ?',
        whereArgs: [start.toIso8601String(), end.toIso8601String()]);

    final count = results.length;
    if (count > 0) {
      results.map((r) => r['id']).toList();
      await deleteCritical(
          entity: 'sessions_range',
          id: 'range_delete',
          sqliteWrite: () async {
            final db = PersistenceInitializer.persistenceManager!.sqliteManager;
            await db.transaction((txn) async {
              final startIso = start.toIso8601String();
              final endIso = end.toIso8601String();

              // 1. Unlink sales from sessions (preserve sales data)
              await txn.rawUpdate('''
                UPDATE sales SET shift_id = NULL
                WHERE shift_id IN (
                  SELECT id FROM shifts
                  WHERE is_open = 0 AND close_time >= ? AND close_time <= ?
                )
             ''', [startIso, endIso]);

              // 2. Delete activity logs for these sessions
              await txn.rawDelete('''
                DELETE FROM activity_logs
                WHERE session_id IN (
                  SELECT id FROM shifts
                  WHERE is_open = 0 AND close_time >= ? AND close_time <= ?
                )
             ''', [startIso, endIso]);

              // 3. Delete the sessions
              await txn.delete('shifts',
                  where: 'is_open = 0 AND close_time >= ? AND close_time <= ?',
                  whereArgs: [startIso, endIso]);
            });
          });
    }

    return count;
  }

  /// Get all closed sessions whose closeTime is between [start] and [end]
  Future<List<Session>> getSessionsInRange(DateTime start, DateTime end) async {
    try {
      final db = PersistenceInitializer.persistenceManager!.sqliteManager;
      final results = await db.query(
        'shifts',
        where: 'is_open = 0 AND close_time >= ? AND close_time <= ?',
        whereArgs: [start.toIso8601String(), end.toIso8601String()],
        orderBy: 'close_time DESC',
      );

      return results.map((row) => Session.fromMap(row)).toList();
    } catch (e) {
      print('Failed to get sessions in range: $e');
      return [];
    }
  }

  /// Returns the total number of closed sessions.
  Future<int> getSessionsCount() async {
    try {
      final db = PersistenceInitializer.persistenceManager!.sqliteManager;
      final result = await db.query(
        'shifts',
        columns: ['COUNT(*) as count'],
        where: 'is_open = 0',
      );
      if (result.isNotEmpty) {
        return (result.first['count'] as int?) ?? 0;
      }
      return 0;
    } catch (e) {
      print('Failed to get sessions count: $e');
      return 0;
    }
  }

  /// Generates a DailyReport from the database for a given session ID.
  /// Re-calculates totals from Sales associated with this session.
  Future<DailyReport?> generateDailyReport(String sessionId) async {
    try {
      final db = PersistenceInitializer.persistenceManager!.sqliteManager;

      // 1. Get Session
      final sessionRows =
          await db.query('shifts', where: 'id = ?', whereArgs: [sessionId]);
      if (sessionRows.isEmpty) return null;
      final session = Session.fromMap(sessionRows.first);

      // 2. Get Sales
      final saleRows = await db
          .query('sales', where: 'shift_id = ?', whereArgs: [sessionId]);

      // Calculate totals
      double totalSales = 0;
      double totalRefunds = 0;
      int transactionsCount = saleRows.length;

      // We need transactions list for the report
      // Fetch items for all sales to build Sale objects correctly

      final saleIds = saleRows.map((r) => r['id'] as String).toList();
      Map<String, List<SaleItem>> itemsMap = {};

      if (saleIds.isNotEmpty) {
        final placeholders = List.filled(saleIds.length, '?').join(',');
        final allItems = await db.query('sale_items',
            where: 'sale_id IN ($placeholders)', whereArgs: saleIds);

        for (var row in allItems) {
          final sid = row['sale_id'] as String;
          if (!itemsMap.containsKey(sid)) itemsMap[sid] = [];
          itemsMap[sid]!.add(SaleItem(
            saleItemId: row['id'] as String?,
            productId: row['product_id'] as String,
            name: row['product_name'] as String,
            price: (row['price'] as num).toDouble(),
            quantity: (row['quantity'] as num).toDouble(),
            total: (row['subtotal'] as num).toDouble(),
            wholesalePrice: (row['wholesale_price'] as num?)?.toDouble() ?? 0.0,
            refundedQuantity:
                (row['refunded_quantity'] as num?)?.toDouble() ?? 0.0,
          ));
        }
      }

      List<Sale> transactions = [];
      List<ProductPerformanceModel> topProducts = [];
      List<ProductPerformanceModel> refundedProducts = [];

      Map<String, ProductPerformanceModel> productStats = {};
      Map<String, ProductPerformanceModel> refundStats = {};

      for (final row in saleRows) {
        final id = row['id'] as String;
        final isRefund = (row['is_refund'] as int? ?? 0) == 1;
        transactions.add(Sale(
          id: id,
          total: (row['total'] as num).toDouble(),
          items: (row['items_count'] as int? ?? 0),
          date: DateTime.parse(row['created_at'] as String),
          saleItems: itemsMap[id] ?? [],
          cashierName: row['cashier_name'] as String?,
          cashierUsername: row['user_id'] as String?,
          sessionId: sessionId,
          invoiceTypeIndex: isRefund ? 1 : 0,
          refundOriginalInvoiceId: row['original_sale_id'] as String?,
        ));
      }
      final historicalCosts = await historicalCogsBySaleProduct(transactions);
      final historicalCogsAvailable =
          historicalCosts.values.every((cost) => cost != null);
      final historicalCogs = historicalCogsAvailable
          ? historicalCosts.values.fold<double>(
              0,
              (total, cost) => total + cost!,
            )
          : null;
      final seenCostProducts = <String>{};

      for (var row in saleRows) {
        final id = row['id'] as String;
        final total = (row['total'] as num).toDouble();
        final isRefund = (row['is_refund'] as int? ?? 0) == 1;

        // Accumulate totals
        if (isRefund) {
          totalRefunds += total;
        } else {
          totalSales += total;
        }

        final items = itemsMap[id] ?? [];

        // Aggregate product stats
        for (var item in items) {
          final costKey = _saleProductKey(id, item.productId);
          final cost =
              seenCostProducts.add(costKey) ? historicalCosts[costKey] ?? 0 : 0;
          if (isRefund) {
            if (!refundStats.containsKey(item.productId)) {
              refundStats[item.productId] = ProductPerformanceModel(
                productId: item.productId,
                productName: item.name,
                quantitySold: 0,
                revenue: 0,
                cost: 0,
                profit: 0,
                profitMargin: 0,
              );
            }
            // Update refund stats
            var current = refundStats[item.productId]!;
            refundStats[item.productId] = ProductPerformanceModel(
              productId: current.productId,
              productName: current.productName,
              quantitySold: current.quantitySold +
                  item.quantity.toInt(), // Tracking quantity returned
              revenue: current.revenue + item.total, // Value returned
              cost: current.cost + cost.abs(),
              profit: 0,
              profitMargin: 0,
            );
          } else {
            if (!productStats.containsKey(item.productId)) {
              productStats[item.productId] = ProductPerformanceModel(
                productId: item.productId,
                productName: item.name,
                quantitySold: 0,
                revenue: 0,
                cost: 0,
                profit: 0,
                profitMargin: 0,
              );
            }
            // Update sales stats
            var current = productStats[item.productId]!;
            var revenue = item.total;
            var profit = revenue - cost;
            var newRev = current.revenue + revenue;
            var newProfit = current.profit + profit;

            productStats[item.productId] = ProductPerformanceModel(
              productId: current.productId,
              productName: current.productName,
              quantitySold: current.quantitySold + item.quantity.toInt(),
              revenue: newRev,
              cost: current.cost + cost,
              profit: newProfit,
              profitMargin: newRev > 0 ? (newProfit / newRev) * 100 : 0,
            );
          }
        }
      }

      topProducts = productStats.values.toList();
      topProducts
          .sort((a, b) => b.revenue.compareTo(a.revenue)); // Sort by revenue

      refundedProducts = refundStats.values.toList();
      refundedProducts.sort((a, b) => b.revenue.compareTo(a.revenue));

      return DailyReport(
        id: '${sessionId}_REPORT',
        sessionId: sessionId,
        date: session.closeTime ?? DateTime.now(),
        totalSales: totalSales,
        totalRefunds: totalRefunds,
        netRevenue: totalSales - totalRefunds,
        totalTransactions: transactionsCount,
        closedByUserName: session.closedByUserId ?? 'System',
        topProducts: topProducts,
        refundedProducts: refundedProducts,
        transactions: transactions,
        historicalCogs: historicalCogs,
        historicalCogsAvailable: historicalCogsAvailable,
      );
    } catch (e) {
      print('Failed to generate report: $e');
      return null;
    }
  }
}
