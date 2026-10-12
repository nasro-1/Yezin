import 'package:uuid/uuid.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../../core/data/models/activity_log.dart';
import '../../../core/data/services/document_number_service.dart';
import '../../../core/data/services/persistence_initializer.dart';
import '../../../core/data/services/sqlite_manager.dart';
import '../../../core/network/backend_api_config.dart';
import '../../../core/security/permission_guard.dart';
import '../../../core/services/activity_logger.dart';
import '../../auth/data/models/user_model.dart';
import '../data/models/stock_adjustment_model.dart';
import '../data/repository/stock_adjustment_api_repository.dart';
import '../data/repository/stock_adjustment_repository.dart';
import 'canonical_stock_posting_service.dart';

class StockAdjustmentService {
  final StockAdjustmentRepository repository;
  final CanonicalStockPostingService stockPosting;
  final ActivityLogger activityLogger;
  final Uuid _uuid;
  final SQLiteManager? sqliteManager;
  final ProductWriteMode? writeMode;
  final StockAdjustmentApiRepository? apiRepository;

  StockAdjustmentService({
    StockAdjustmentRepository? repository,
    this.stockPosting = const CanonicalStockPostingService(),
    ActivityLogger? activityLogger,
    Uuid? uuid,
    this.sqliteManager,
    this.writeMode,
    this.apiRepository,
  })  : repository = repository ?? StockAdjustmentRepository(),
        activityLogger = activityLogger ?? ActivityLogger(),
        _uuid = uuid ?? const Uuid();

  Future<StockAdjustmentDocument> post({
    required String idempotencyKey,
    required List<StockAdjustmentLineInput> lines,
    required User user,
    DateTime? adjustmentDate,
    String? reason,
    String? notes,
    DatabaseExecutor? transaction,
  }) async {
    PermissionGuard.requireStockAdjustmentPermission(user);
    if (idempotencyKey.trim().isEmpty) {
      throw ArgumentError('Stock adjustment idempotency key is required.');
    }
    _validateLines(lines);
    if (reason?.trim().isEmpty != false) {
      throw ArgumentError('Stock adjustment reason is required.');
    }
    if ((writeMode ?? BackendApiConfig.productWriteMode) ==
        ProductWriteMode.server) {
      final api = apiRepository;
      if (api == null) {
        throw StateError('Server stock adjustment API is not configured.');
      }
      return api.post(
        idempotencyKey: idempotencyKey,
        lines: lines,
        reason: reason!.trim(),
        notes: notes,
        adjustmentDate: adjustmentDate,
      );
    }

    final db = sqliteManager ??
        PersistenceInitializer.persistenceManager!.sqliteManager;
    final now = DateTime.now();
    final effectiveDate = adjustmentDate ?? now;
    final documentId = _uuid.v4();
    late StockAdjustmentDocument document;

    Future<void> operation(DatabaseExecutor txn) async {
      final existing = await txn.query(
        'stock_adjustment_documents',
        columns: ['id'],
        where: 'idempotency_key = ?',
        whereArgs: [idempotencyKey.trim()],
        limit: 1,
      );
      if (existing.isNotEmpty) {
        throw StateError(
          'Stock adjustment request has already been posted.',
        );
      }
      final calculated = <StockAdjustmentLine>[];
      for (final input in lines) {
        final products = await txn.query(
          'products',
          columns: ['id', 'barcode', 'name', 'stock'],
          where: 'id = ? AND is_active = 1',
          whereArgs: [input.productId],
          limit: 1,
        );
        if (products.isEmpty) {
          throw StateError('Product ${input.productId} not found.');
        }
        final product = products.first;
        final current = (product['stock'] as num?)?.toDouble() ?? 0;
        final delta = input.countedQuantity - current;
        if (delta == 0) {
          throw ArgumentError(
            'Counted quantity must differ from current stock for '
            '${product['name']}.',
          );
        }
        var baseUnitCost = input.unitCost;
        if (delta < 0) {
          final positiveMovements = await txn.query(
            'stock_movements',
            columns: ['quantity_change', 'unit_cost'],
            where: 'product_id = ? AND quantity_change > 0',
            whereArgs: [input.productId],
            orderBy: 'created_at ASC, id ASC',
          );
          var remaining = delta.abs();
          var consumedCost = 0.0;
          var consumedQuantity = 0.0;
          for (final movement in positiveMovements) {
            if (remaining <= 0) break;
            final available =
                (movement['quantity_change'] as num?)?.toDouble() ?? 0;
            final taken = available < remaining ? available : remaining;
            final unitCost =
                (movement['unit_cost'] as num?)?.toDouble() ?? 0;
            consumedQuantity += taken;
            consumedCost += taken * unitCost;
            remaining -= taken;
          }
          if (consumedQuantity > 0) {
            baseUnitCost = consumedCost / consumedQuantity;
          }
        }
        final requestedUnit = input.unit?.trim().toLowerCase();
        if (delta >= 0 && requestedUnit != null && requestedUnit.isNotEmpty) {
          final unitRows = await txn.query(
          'selling_units',
          columns: ['name', 'conversion_to_base'],
          where: 'product_id = ? AND is_active = 1',
          whereArgs: [input.productId],
          );
          final selectedUnit = unitRows.cast<Map<String, Object?>>().firstWhere(
              (row) =>
                  (row['name'] as String).trim().toLowerCase() ==
                  requestedUnit,
              orElse: () => <String, Object?>{},
            );
          if (selectedUnit.isNotEmpty) {
          final conversion =
              (selectedUnit['conversion_to_base'] as num?)?.toDouble() ?? 0;
          if (conversion <= 0) {
            throw ArgumentError('Adjustment unit conversion must be positive.');
          }
          baseUnitCost = input.unitCost / conversion;
          }
        }
        calculated.add(StockAdjustmentLine(
          id: '${documentId}_${input.productId}',
          documentId: documentId,
          productId: input.productId,
          productBarcode: product['barcode'] as String?,
          productName: product['name'] as String,
          currentQuantity: current,
          countedQuantity: input.countedQuantity,
          quantityChange: delta,
          unitCost: baseUnitCost,
          lineTotal: delta.abs() * baseUnitCost,
          createdAt: now,
        ));
      }

      final referenceNumber = await DocumentNumberService.next(
        txn,
        sequenceKey: 'stock_adjustment',
        prefix: 'ADJ',
        year: now.year.toString(),
        table: 'stock_adjustment_documents',
        column: 'reference_number',
      );
      final postedAt = DateTime.now();
      document = StockAdjustmentDocument(
        id: documentId,
        referenceNumber: referenceNumber,
        idempotencyKey: idempotencyKey.trim(),
        status: StockAdjustmentStatus.posted,
        adjustmentDate: effectiveDate,
        reason: reason!.trim(),
        notes: notes?.trim().isEmpty == true ? null : notes?.trim(),
        postedAt: postedAt,
        postedBy: user.name,
        createdAt: now,
        lines: calculated,
      );
      await repository.insertDocument(txn, document);

      for (final item in calculated) {
        await repository.insertItem(txn, item);
        await stockPosting.post(
          txn: txn,
          movementId: '${item.id}_movement',
          productId: item.productId,
          quantityChange: item.quantityChange,
          movementType: 'stock_adjustment',
          referenceType: 'stock_adjustment',
          referenceId: documentId,
          notes: reason.trim(),
          userId: user.username,
          unitCost: item.unitCost,
          createdAt: postedAt,
        );
      }

      await activityLogger.logActivityInTransaction(
        txn: txn,
        type: ActivityType.stockAdjustment,
        description: 'Posted stock adjustment: $referenceNumber',
        userName: user.name,
        eventKey: 'stockAdjustmentPosted',
        parameters: {
          'user': user.name,
          'reference': referenceNumber,
          'id': documentId,
          'lines': calculated.length,
          'reason': reason.trim(),
        },
        details: {
          'reference': referenceNumber,
          'reason': reason.trim(),
          'lines': calculated
              .map((item) => {
                    'product': item.productName,
                    'current': item.currentQuantity,
                    'counted': item.countedQuantity,
                    'delta': item.quantityChange,
                  })
              .toList(),
        },
        timestamp: postedAt,
      );
    }

    if (transaction != null) {
      await operation(transaction);
    } else {
      await db.transaction(operation);
    }

    return document;
  }

  void _validateLines(List<StockAdjustmentLineInput> lines) {
    if (lines.isEmpty) {
      throw ArgumentError('Stock adjustment must contain at least one item.');
    }
    final productIds = <String>{};
    for (final line in lines) {
      if (line.productId.trim().isEmpty || line.countedQuantity < 0) {
        throw ArgumentError('Counted quantities cannot be negative.');
      }
      if (line.unitCost < 0) {
        throw ArgumentError('Unit costs cannot be negative.');
      }
      if (!productIds.add(line.productId)) {
        throw ArgumentError(
          'A product can only appear once in a stock adjustment.',
        );
      }
    }
  }
}
