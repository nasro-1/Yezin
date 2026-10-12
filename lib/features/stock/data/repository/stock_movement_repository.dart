import 'package:bayaa_pos/core/security/permission_guard.dart';
import 'package:bayaa_pos/features/auth/presentation/cubit/user_cubit.dart';
import 'package:dartz/dartz.dart';
import 'package:get_it/get_it.dart';

import '../../../../core/data/services/persistence_initializer.dart';
import '../../../../core/data/services/sqlite_manager.dart';
import '../../../../core/error/failure.dart';
import '../models/stock_movement_model.dart';
import '../../services/canonical_stock_posting_service.dart';

class StockMovementRepository {
  final SQLiteManager? sqliteManager;
  static const _stockPosting = CanonicalStockPostingService();

  StockMovementRepository({this.sqliteManager});

  Future<Either<Failure, List<StockMovement>>> getRecentMovements(
      {int limit = 50}) async {
    try {
      final db = sqliteManager ??
          PersistenceInitializer.persistenceManager?.sqliteManager;
      if (db == null) {
        return const Right([]);
      }

      final results = await db.query(
        'stock_movements',
        orderBy: 'created_at DESC',
        limit: limit,
      );

      return Right(results.map(StockMovement.fromMap).toList());
    } catch (e) {
      return Left(CacheFailure('Unable to load stock movements: $e'));
    }
  }

  Future<List<StockMovement>> getProductMovements(String productId) async {
    final db = sqliteManager ??
        PersistenceInitializer.persistenceManager?.sqliteManager;
    if (db == null) return const [];

    final rows = await db.database.rawQuery('''
      SELECT sm.*,
        CASE
          WHEN sm.reference_type = 'purchase' AND p.reference_number IS NOT NULL
            THEN 'Purchase ' || p.reference_number ||
              CASE WHEN s.name IS NOT NULL THEN ' - ' || s.name ELSE '' END
          WHEN sm.reference_type IN ('sale', 'customer_return')
            AND sale.reference_number IS NOT NULL
            THEN 'Invoice ' || sale.reference_number
          WHEN sm.reference_type = 'refund'
            AND refund.reference_number IS NOT NULL
            THEN 'Return ' || refund.reference_number ||
              CASE WHEN original.reference_number IS NOT NULL
                THEN ' - Invoice ' || original.reference_number ELSE '' END
          WHEN sm.reference_type = 'supplier_return'
            AND sr.reference IS NOT NULL
            THEN 'Return ' || sr.reference ||
              CASE WHEN s2.name IS NOT NULL THEN ' - ' || s2.name ELSE '' END ||
              CASE WHEN p2.reference_number IS NOT NULL
                THEN ' - Purchase ' || p2.reference_number ELSE '' END
          WHEN sm.reference_type = 'stock_adjustment'
            AND adj.reference_number IS NOT NULL
            THEN 'Adjustment ' || adj.reference_number ||
              CASE WHEN adj.reason IS NOT NULL THEN ' - ' || adj.reason ELSE '' END
          WHEN sm.reference_type = 'opening_stock'
            AND os.reference_number IS NOT NULL
            THEN 'Opening Stock ' || os.reference_number
          ELSE NULL
        END AS source_description
      FROM stock_movements sm
      LEFT JOIN purchases p
        ON sm.reference_type = 'purchase' AND p.id = sm.reference_id
      LEFT JOIN suppliers s ON s.id = p.supplier_id
      LEFT JOIN sales sale
        ON sm.reference_type IN ('sale', 'customer_return')
        AND sale.id = sm.reference_id
      LEFT JOIN sales refund
        ON sm.reference_type = 'refund' AND refund.id = sm.reference_id
      LEFT JOIN sales original
        ON original.id = refund.original_sale_id
      LEFT JOIN supplier_returns sr
        ON sm.reference_type = 'supplier_return' AND sr.id = sm.reference_id
      LEFT JOIN suppliers s2 ON s2.id = sr.supplier_id
      LEFT JOIN purchases p2 ON p2.id = sr.purchase_id
      LEFT JOIN stock_adjustment_documents adj
        ON sm.reference_type = 'stock_adjustment' AND adj.id = sm.reference_id
      LEFT JOIN opening_stock_documents os
        ON sm.reference_type = 'opening_stock' AND os.id = sm.reference_id
      WHERE sm.product_id = ?
      ORDER BY sm.created_at ASC, sm.rowid ASC
    ''', [productId]);
    return rows.map(StockMovement.fromMap).toList();
  }

  Future<Either<Failure, Unit>> recordMovement(StockMovement movement) async {
    try {
      try {
        final currentUser = GetIt.instance<UserCubit>().currentUser;
        PermissionGuard.requireStockAdjustmentPermission(currentUser);
      } catch (_) {
        throw PermissionDeniedException(
          'Stock movement recording requires manager or admin privileges.',
        );
      }

      final db = PersistenceInitializer.persistenceManager?.sqliteManager;
      if (db == null) {
        return const Right(unit);
      }

      await db.database.transaction((txn) async {
        await _stockPosting.post(
          txn: txn,
          movementId: movement.id,
          productId: movement.productId,
          quantityChange: movement.quantityChange,
          movementType: movement.movementType,
          referenceType: movement.referenceType ?? 'stock_movement',
          referenceId: movement.referenceId ?? movement.id,
          lineageId: movement.lineageId,
          notes: movement.notes,
          userId: movement.userId,
          unitCost: movement.unitCost,
          createdAt: movement.createdAt,
        );
      });
      return const Right(unit);
    } catch (e) {
      return Left(CacheFailure('Unable to record stock movement: $e'));
    }
  }
}
