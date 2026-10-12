import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../../../core/data/services/persistence_initializer.dart';
import '../../../../core/data/services/sqlite_manager.dart';
import '../models/opening_stock_model.dart';

class OpeningStockRepository {
  final SQLiteManager? sqliteManager;

  OpeningStockRepository({this.sqliteManager});

  Database get _database => (sqliteManager ??
          PersistenceInitializer.persistenceManager!.sqliteManager)
      .database;

  Future<List<OpeningStockDocument>> getPostedDocuments({
    int limit = 100,
    int offset = 0,
  }) async {
    final rows = await _database.query(
      'opening_stock_documents',
      where: "status = 'posted'",
      orderBy: 'posted_at DESC',
      limit: limit,
      offset: offset,
    );
    return Future.wait(rows.map(_withLines));
  }

  Future<OpeningStockDocument?> getById(String id) async {
    final rows = await _database.query(
      'opening_stock_documents',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _withLines(rows.first);
  }

  Future<OpeningStockDocument?> getByReference(String referenceNumber) async {
    final rows = await _database.query(
      'opening_stock_documents',
      where: 'reference_number = ?',
      whereArgs: [referenceNumber],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _withLines(rows.first);
  }

  Future<void> insertDocument(
    DatabaseExecutor txn,
    OpeningStockDocument document,
  ) async {
    await txn.insert('opening_stock_documents', {
      'id': document.id,
      'reference_number': document.referenceNumber,
      'status': document.status.name,
      'opening_date': document.openingDate.toIso8601String(),
      'reason': document.reason,
      'notes': document.notes,
      'posted_at': document.postedAt.toIso8601String(),
      'posted_by': document.postedBy,
      'created_at': document.createdAt.toIso8601String(),
    });
  }

  Future<void> insertLine(DatabaseExecutor txn, OpeningStockLine line) async {
    await txn.insert('opening_stock_lines', {
      'id': line.id,
      'document_id': line.documentId,
      'product_id': line.productId,
      'product_barcode': line.productBarcode,
      'product_name': line.productName,
      'quantity': line.quantity,
      'unit_cost': line.unitCost,
      'line_total': line.lineTotal,
      'created_at': line.createdAt.toIso8601String(),
    });
  }

  Future<OpeningStockDocument> _withLines(
    Map<String, dynamic> documentRow,
  ) async {
    final lineRows = await _database.query(
      'opening_stock_lines',
      where: 'document_id = ?',
      whereArgs: [documentRow['id']],
      orderBy: 'created_at ASC',
    );
    return OpeningStockDocument.fromMap(
      documentRow,
      lines: lineRows.map(OpeningStockLine.fromMap).toList(),
    );
  }
}
