import 'package:dartz/dartz.dart';
import 'package:get_it/get_it.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../../../core/data/models/activity_log.dart';
import '../../../../core/data/services/persistence_initializer.dart';
import '../../../../core/data/services/document_number_service.dart';
import '../../../../core/error/failure.dart';
import '../../../../core/security/permission_guard.dart';
import '../../../../core/services/activity_logger.dart';
import '../../../auth/presentation/cubit/user_cubit.dart';
import '../../../stock/services/canonical_stock_posting_service.dart';
import '../models/supplier_return_model.dart';

typedef SupplierReturnFailureInjector = Future<void> Function(Transaction txn);

abstract class SupplierReturnRepository {
  Future<Either<Failure, Unit>> createReturn(SupplierReturn value);
  Future<Either<Failure, List<Map<String, dynamic>>>> getReturnHistory();
  Future<Either<Failure, List<Map<String, dynamic>>>> getPurchasesForSupplier(
      String supplierId);
  Future<Either<Failure, List<Map<String, dynamic>>>> getPurchaseItems(
      String purchaseId);
}

class SupplierReturnRepositoryImpl implements SupplierReturnRepository {
  static const _stockPosting = CanonicalStockPostingService();
  SupplierReturnRepositoryImpl({this.failureInjector});

  final SupplierReturnFailureInjector? failureInjector;

  @override
  Future<Either<Failure, Unit>> createReturn(SupplierReturn value) async {
    try {
      final user = GetIt.instance<UserCubit>().currentUser;
      PermissionGuard.requireSupplierReturnAccess(user);
      if (value.status.trim().toLowerCase() != 'confirmed') {
        return const Left(ValidationFailure(
            'Only confirmed supplier returns can be posted.'));
      }
      if (value.lines.isEmpty ||
          value.lines.any((line) => line.quantity <= 0)) {
        return const Left(
            ValidationFailure('Return lines must have valid quantities.'));
      }
      if (value.lines.map((line) => line.purchaseItemId).toSet().length !=
          value.lines.length) {
        return const Left(
            ValidationFailure('Duplicate purchase items are not allowed.'));
      }
      final db = PersistenceInitializer.persistenceManager!.sqliteManager;
      await db.transaction((txn) async {
        // The return id is the idempotency key. Retries are successful no-ops
        // after verifying that they refer to the same return document.
        final existing = await txn.query('supplier_returns',
            where: 'id = ?', whereArgs: [value.id], limit: 1);
        if (existing.isNotEmpty) {
          final row = existing.single;
          if (row['supplier_id'] != value.supplierId ||
              row['purchase_id'] != value.purchaseId ||
              row['status'] != value.status ||
              (value.reference.trim().isNotEmpty &&
                  row['reference'] != value.reference)) {
            throw StateError(
                'Supplier return id already exists with different data.');
          }
          final existingItems = await txn.query('supplier_return_items',
              where: 'return_id = ?', whereArgs: [value.id]);
          if (existingItems.length != value.lines.length ||
              value.lines.any((line) => !existingItems.any((item) =>
                  item['purchase_item_id'] == line.purchaseItemId &&
                  item['product_id'] == line.productId &&
                  (item['quantity'] as num).toDouble() == line.quantity))) {
            throw StateError(
                'Supplier return id already exists with different lines.');
          }
          return;
        }
        final supplier = await txn.query('suppliers',
            columns: ['id'],
            where: 'id = ? AND is_active = 1',
            whereArgs: [value.supplierId]);
        if (supplier.isEmpty) throw StateError('Supplier not found.');
        final purchase = await txn.query('purchases',
            columns: ['id', 'supplier_id'],
            where: "id = ? AND supplier_id = ? AND status = 'confirmed'",
            whereArgs: [value.purchaseId, value.supplierId]);
        if (purchase.isEmpty) throw StateError('Purchase not found.');
        final now = DateTime.now().toIso8601String();
        var total = 0.0;
        final prepared = <Map<String, dynamic>>[];
        for (final line in value.lines) {
          final item = await txn.query('purchase_items',
              columns: ['id', 'product_id', 'quantity', 'unit_cost'],
              where: 'id = ? AND purchase_id = ? AND product_id = ?',
              whereArgs: [
                line.purchaseItemId,
                value.purchaseId,
                line.productId
              ]);
          if (item.isEmpty) throw StateError('Purchase item not found.');
          final row = item.single;
          final returned = await txn.query('supplier_return_items',
              columns: ['SUM(quantity) AS total'],
              where: 'purchase_item_id = ?',
              whereArgs: [line.purchaseItemId]);
          final alreadyReturned =
              (returned.first['total'] as num?)?.toDouble() ?? 0.0;
          final purchased = (row['quantity'] as num).toDouble();
          if (line.quantity > purchased - alreadyReturned) {
            throw StateError('Return quantity exceeds remaining quantity.');
          }
          final product = await txn.query('products',
              columns: ['barcode', 'name', 'stock'],
              where: 'id = ?',
              whereArgs: [line.productId]);
          if (product.isEmpty) throw StateError('Product not found.');
          final stock = (product.single['stock'] as num).toDouble();
          if (line.quantity > stock) throw StateError('Insufficient stock.');
          final unitPrice = (row['unit_cost'] as num).toDouble();
          final lineTotal = line.quantity * unitPrice;
          total += lineTotal;
          prepared.add({
            'line': line,
            'row': row,
            'stock': stock,
            'unitPrice': unitPrice,
            'lineTotal': lineTotal,
          });
        }
        if (total <= 0) throw StateError('Return total must be positive.');
        final reference = value.reference.trim().isEmpty
            ? await DocumentNumberService.next(txn,
                sequenceKey: 'supplier-return',
                prefix: 'SR',
                year: DateTime.now().year.toString(),
                table: 'supplier_returns')
            : value.reference;
        await txn.insert('supplier_returns', {
          'id': value.id,
          'reference': reference,
          'supplier_id': value.supplierId,
          'purchase_id': value.purchaseId,
          'return_date': value.returnDate.toIso8601String(),
          'total_amount': total,
          'status': value.status,
          'notes': value.notes,
          'created_by': value.createdBy,
          'created_at': now,
          'updated_at': now,
        });
        for (final entry in prepared) {
          final line = entry['line'] as SupplierReturnLine;
          await txn.insert('supplier_return_items', {
            'id': '${value.id}_${line.purchaseItemId}',
            'return_id': value.id,
            'purchase_item_id': line.purchaseItemId,
            'product_id': line.productId,
            'quantity': line.quantity,
            'unit_price': entry['unitPrice'],
            'line_total': entry['lineTotal'],
            'created_at': now,
          });
          await _stockPosting.post(
            txn: txn,
            movementId: '${value.id}_${line.productId}_movement',
            productId: line.productId,
            quantityChange: -line.quantity,
            movementType: 'supplier_return',
            referenceType: 'supplier_return',
            referenceId: value.id,
            notes: 'Supplier return ${value.reference}',
            userId: value.createdBy,
            unitCost: entry['unitPrice'] as double,
            createdAt: DateTime.parse(now),
          );
        }
        final balanceRows = await txn.query('supplier_ledger',
            columns: ['SUM(amount) AS total'],
            where: 'supplier_id = ?',
            whereArgs: [value.supplierId]);
        final balance = (balanceRows.first['total'] as num?)?.toDouble() ?? 0;
        await txn.insert('supplier_ledger', {
          'id': '${value.id}_ledger',
          'supplier_id': value.supplierId,
          'entry_type': 'supplier_return',
          'amount': -total,
          'balance_after': balance - total,
          'reference_type': 'supplier_return',
          'reference_id': value.id,
          'notes': value.notes,
          'created_at': now,
        });
        if (failureInjector != null) await failureInjector!(txn);
        await txn.insert('activity_logs', {
          'id': '${value.id}_activity',
          'session_id': '',
          'timestamp': now,
          'type': ActivityType.supplierReturn.name,
          'description': 'Supplier return: ${value.reference}',
          'user_name': value.createdBy,
          'details':
              '{"returnId":"${value.id}","purchaseId":"${value.purchaseId}"}',
          'event_key': 'supplierReturn',
          'parameters': null,
        });
      });
      await ActivityLogger().loadRecentActivities();
      return const Right(unit);
    } catch (e) {
      return Left(CacheFailure('Unable to create supplier return: $e'));
    }
  }

  @override
  Future<Either<Failure, List<Map<String, dynamic>>>> getReturnHistory() async {
    try {
      final db = PersistenceInitializer.persistenceManager!.sqliteManager;
      return Right(await db.rawQuery('''
        SELECT r.*, s.name AS supplier_name, p.reference_number AS purchase_reference
        FROM supplier_returns r
        INNER JOIN suppliers s ON s.id = r.supplier_id
        INNER JOIN purchases p ON p.id = r.purchase_id
        ORDER BY r.return_date DESC
      '''));
    } catch (e) {
      return Left(CacheFailure('Unable to load supplier return history: $e'));
    }
  }

  @override
  Future<Either<Failure, List<Map<String, dynamic>>>> getPurchasesForSupplier(
      String supplierId) async {
    try {
      final db = PersistenceInitializer.persistenceManager!.sqliteManager;
      return Right(await db.query('purchases',
          where: 'supplier_id = ?',
          whereArgs: [supplierId],
          orderBy: 'purchase_date DESC'));
    } catch (e) {
      return Left(CacheFailure('Unable to load supplier purchases: $e'));
    }
  }

  @override
  Future<Either<Failure, List<Map<String, dynamic>>>> getPurchaseItems(
      String purchaseId) async {
    try {
      final db = PersistenceInitializer.persistenceManager!.sqliteManager;
      return Right(await db.rawQuery('''
          SELECT i.*, p.name AS product_name, p.barcode, p.stock
          FROM purchase_items i INNER JOIN products p ON p.id = i.product_id
          WHERE i.purchase_id = ?
        ''', [purchaseId]));
    } catch (e) {
      return Left(CacheFailure('Unable to load purchase items: $e'));
    }
  }
}
