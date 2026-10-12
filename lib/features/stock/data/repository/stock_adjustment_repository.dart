import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../../../core/data/services/persistence_initializer.dart';
import '../../../../core/data/services/sqlite_manager.dart';
import '../models/stock_adjustment_model.dart';

class StockAdjustmentRepository {
  final SQLiteManager? sqliteManager;

  StockAdjustmentRepository({this.sqliteManager});

  Database get _database => (sqliteManager ??
          PersistenceInitializer.persistenceManager!.sqliteManager)
      .database;

  Future<List<StockAdjustmentDocument>> getPostedDocuments({
    int limit = 100,
    int offset = 0,
  }) async {
    final rows = await _database.query(
      'stock_adjustment_documents',
      where: "status = 'posted'",
      orderBy: 'posted_at DESC',
      limit: limit,
      offset: offset,
    );
    return Future.wait(rows.map(_withLines));
  }

  Future<StockAdjustmentDocument?> getById(String id) async {
    final rows = await _database.query(
      'stock_adjustment_documents',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _withLines(rows.first);
  }

  Future<StockAdjustmentDocument?> getByReference(
    String referenceNumber,
  ) async {
    final rows = await _database.query(
      'stock_adjustment_documents',
      where: 'reference_number = ?',
      whereArgs: [referenceNumber],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _withLines(rows.first);
  }

  Future<void> insertDocument(
    DatabaseExecutor txn,
    StockAdjustmentDocument document,
  ) {
    return txn.insert('stock_adjustment_documents', {
      'id': document.id,
      'reference_number': document.referenceNumber,
      'idempotency_key': document.idempotencyKey,
      'status': document.status.name,
      'adjustment_date': document.adjustmentDate.toIso8601String(),
      'reason': document.reason,
      'notes': document.notes,
      'posted_at': document.postedAt.toIso8601String(),
      'posted_by': document.postedBy,
      'created_at': document.createdAt.toIso8601String(),
    });
  }

  Future<void> insertItem(
    DatabaseExecutor txn,
    StockAdjustmentLine item,
  ) {
    return txn.insert('stock_adjustment_items', {
      'id': item.id,
      'document_id': item.documentId,
      'product_id': item.productId,
      'product_barcode': item.productBarcode,
      'product_name': item.productName,
      'current_quantity': item.currentQuantity,
      'counted_quantity': item.countedQuantity,
      'delta': item.quantityChange,
      'quantity_change': item.quantityChange,
      'unit_cost': item.unitCost,
      'line_total': item.lineTotal,
      'created_at': item.createdAt.toIso8601String(),
    });
  }

  Future<void> insertLine(
    DatabaseExecutor txn,
    StockAdjustmentLine item,
  ) {
    return insertItem(txn, item);
  }

  Future<StockAdjustmentDocument> _withLines(
    Map<String, dynamic> documentRow,
  ) async {
    final itemRows = await _database.query(
      'stock_adjustment_items',
      where: 'document_id = ?',
      whereArgs: [documentRow['id']],
      orderBy: 'created_at ASC',
    );
    return StockAdjustmentDocument.fromMap(
      documentRow,
      lines: itemRows.map(StockAdjustmentLine.fromMap).toList(),
    );
  }
}
