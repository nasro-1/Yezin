import 'package:dartz/dartz.dart';
import 'package:get_it/get_it.dart';

import '../../../../core/data/models/activity_log.dart';
import '../../../../core/data/services/persistence_initializer.dart';
import '../../../../core/data/services/document_number_service.dart';
import '../../../../core/error/failure.dart';
import '../../../../core/security/permission_guard.dart';
import '../../../../core/services/activity_logger.dart';
import '../../../../core/network/authority_context.dart';
import '../../../auth/presentation/cubit/user_cubit.dart';
import '../../../stock/services/canonical_stock_posting_service.dart';
import '../models/purchase_model.dart';

abstract class PurchaseRepository {
  Future<Either<Failure, Unit>> createPurchase(Purchase purchase);
  Future<Either<Failure, List<Map<String, dynamic>>>> getPurchases();
  Future<Either<Failure, List<Map<String, dynamic>>>> getProductPurchaseHistory(
      String productId);
  Future<Either<Failure, Map<String, dynamic>?>> getLatestProductPurchaseCost(
      String productId);
}

class PurchaseRepositoryImpl implements PurchaseRepository {
  static const _stockPosting = CanonicalStockPostingService();

  PurchaseRepositoryImpl({AuthorityContext? authorityContext})
      : authorityContext = authorityContext ??
            AuthorityContext.fromProductConfig();

  final AuthorityContext authorityContext;

  void _ensureLocalAuthority() {
    if (authorityContext.writesToServer) {
      throw StateError(
        'Purchases require a server repository in server-authoritative mode.',
      );
    }
  }

  @override
  Future<Either<Failure, Unit>> createPurchase(Purchase purchase) async {
    try {
      _ensureLocalAuthority();
      final user = GetIt.instance<UserCubit>().currentUser;
      PermissionGuard.requirePurchaseAccess(user);
      if (purchase.status.trim().toLowerCase() != 'confirmed') {
        return const Left(
            ValidationFailure('Only confirmed purchases can be posted.'));
      }
      if (purchase.lines.isEmpty ||
          purchase.lines
              .any((line) => line.quantity <= 0 || line.unitCost < 0)) {
        return const Left(ValidationFailure(
            'Purchase lines must have valid quantities and costs.'));
      }
      if (purchase.lines.map((line) => line.identityKey).toSet().length !=
          purchase.lines.length) {
        return const Left(ValidationFailure(
            'Duplicate product and purchase unit lines are not allowed.'));
      }
      final db = PersistenceInitializer.persistenceManager!.sqliteManager;
      final now = DateTime.now().toIso8601String();
      var alreadyPosted = false;
      await db.transaction((txn) async {
        // The document id is the idempotency key. A retry must not repost
        // stock, supplier liability, or audit entries.
        final existing = await txn.query('purchases',
            where: 'id = ?', whereArgs: [purchase.id], limit: 1);
        if (existing.isNotEmpty) {
          final row = existing.single;
          if (row['supplier_id'] != purchase.supplierId ||
              row['status'] != purchase.status ||
              (purchase.referenceNumber.trim().isNotEmpty &&
                  row['reference_number'] != purchase.referenceNumber)) {
            throw StateError('Purchase id already exists with different data.');
          }
          final existingItems = await txn.query('purchase_items',
              where: 'purchase_id = ?', whereArgs: [purchase.id]);
          if (existingItems.length != purchase.lines.length ||
              purchase.lines.any((line) => !existingItems.any((item) =>
                  item['product_id'] == line.productId &&
                  item['selling_unit_id'] == line.sellingUnitId &&
                  (item['quantity'] as num).toDouble() == line.quantity &&
                  (item['unit_cost'] as num).toDouble() == line.unitCost))) {
            throw StateError(
                'Purchase id already exists with different lines.');
          }
          alreadyPosted = true;
          return;
        }
        final sameReference = await txn.query(
          'purchases',
          columns: ['id', 'status'],
          where: 'reference_number = ?',
          whereArgs: [purchase.referenceNumber],
          limit: 1,
        );
        if (sameReference.isNotEmpty) {
          throw StateError('This purchase has already been posted.');
        }
        final supplier = await txn.query(
          'suppliers',
          columns: ['id'],
          where: 'id = ? AND is_active = 1',
          whereArgs: [purchase.supplierId],
        );
        if (supplier.isEmpty) throw StateError('Supplier not found.');
        final reference = purchase.referenceNumber.trim().isEmpty
            ? await DocumentNumberService.next(txn,
                sequenceKey: 'purchase',
                prefix: 'PUR',
                year: DateTime.now().year.toString(),
                table: 'purchases',
                column: 'reference_number')
            : purchase.referenceNumber;
        await txn.insert('purchases', {
          'id': purchase.id,
          'reference_number': reference,
          'supplier_id': purchase.supplierId,
          'purchase_date': purchase.purchaseDate.toIso8601String(),
          'subtotal': purchase.subtotal,
          'total': purchase.subtotal,
          'notes': purchase.notes,
          'status': purchase.status,
          'created_by': purchase.createdBy,
          'created_at': now,
          'updated_at': now,
        });
        for (final line in purchase.lines) {
          final rows = await txn.query(
            'products',
            columns: ['id', 'barcode', 'name'],
            where: 'id = ?',
            whereArgs: [line.productId],
          );
          if (rows.isEmpty) {
            throw StateError('Product ${line.productId} not found.');
          }
          await txn.insert('purchase_items', {
            'id': line.sellingUnitId == null
                ? '${purchase.id}_${line.productId}'
                : '${purchase.id}_${line.productId}_${line.sellingUnitId}',
            'purchase_id': purchase.id,
            'product_id': line.productId,
            'quantity': line.quantity,
            'unit_cost': line.unitCost,
            'line_total': line.lineTotal,
            'selling_unit_id': line.sellingUnitId,
            'selling_quantity':
                line.sellingUnitId == null ? null : line.quantity,
            'base_quantity': line.baseQuantity,
            'conversion_factor_snapshot': line.conversionFactor,
            'selling_unit_name_snapshot': line.sellingUnitName,
            'base_unit_snapshot': line.sellingUnitId == null ? null : 'piece',
          });
          await _stockPosting.post(
            txn: txn,
            movementId:
                '${purchase.id}_${line.productId}_${line.sellingUnitId ?? 'base'}_movement',
            productId: line.productId,
            quantityChange: line.baseQuantity ?? line.quantity,
            movementType: 'purchase',
            referenceType: 'purchase',
            referenceId: purchase.id,
            notes: 'Purchase $reference',
            userId: purchase.createdBy,
            unitCost: line.unitCost,
            createdAt: DateTime.parse(now),
          );
        }
        final previous = await txn.query(
          'supplier_ledger',
          columns: ['balance_after'],
          where: 'supplier_id = ?',
          whereArgs: [purchase.supplierId],
          orderBy: 'created_at DESC',
          limit: 1,
        );
        final balance = (previous.isEmpty
                ? 0
                : (previous.first['balance_after'] as num).toDouble()) +
            purchase.subtotal;
        await txn.insert('supplier_ledger', {
          'id': '${purchase.id}_ledger',
          'supplier_id': purchase.supplierId,
          'entry_type': 'purchase',
          'amount': purchase.subtotal,
          'balance_after': balance,
          'reference_type': 'purchase',
          'reference_id': purchase.id,
          'notes': 'Purchase $reference',
          'created_at': now,
        });
        await txn.insert('activity_logs', {
          'id': '${purchase.id}_activity',
          'session_id': '',
          'timestamp': now,
          'type': ActivityType.purchaseCreated.name,
          'description': 'Purchase created: ${purchase.referenceNumber}',
          'user_name': purchase.createdBy ?? user.name,
          'details': '{"purchaseId":"${purchase.id}"}',
          'event_key': 'purchaseCreated',
          'parameters': null,
        });
      });
      if (alreadyPosted) return const Right(unit);
      await ActivityLogger().loadRecentActivities();
      return const Right(unit);
    } catch (e) {
      if (e is StateError &&
          e.message == 'This purchase has already been posted.') {
        return const Left(
            ValidationFailure('This purchase has already been posted.'));
      }
      return Left(CacheFailure('Unable to create purchase: $e'));
    }
  }

  @override
  Future<Either<Failure, List<Map<String, dynamic>>>> getPurchases() async {
    try {
      _ensureLocalAuthority();
      final db = PersistenceInitializer.persistenceManager!.sqliteManager;
      return Right(await db.query('purchases', orderBy: 'purchase_date DESC'));
    } catch (e) {
      return Left(CacheFailure('Unable to load purchases: $e'));
    }
  }

  @override
  Future<Either<Failure, List<Map<String, dynamic>>>> getProductPurchaseHistory(
      String productId) async {
    try {
      _ensureLocalAuthority();
      final db = PersistenceInitializer.persistenceManager!.sqliteManager;
      final rows = await db.database.rawQuery('''
        SELECT
          p.id AS purchase_id,
          p.reference_number,
          p.purchase_date,
          p.status,
          p.supplier_id,
          s.name AS supplier_name,
          i.quantity,
          i.unit_cost,
          i.line_total,
          i.selling_unit_id,
          i.selling_quantity,
          i.base_quantity,
          i.conversion_factor_snapshot,
          i.selling_unit_name_snapshot,
          i.base_unit_snapshot
        FROM purchase_items i
        INNER JOIN purchases p ON p.id = i.purchase_id
        LEFT JOIN suppliers s ON s.id = p.supplier_id
        WHERE i.product_id = ?
        ORDER BY p.purchase_date DESC, p.id DESC
      ''', [productId]);
      return Right(rows);
    } catch (e) {
      return Left(CacheFailure('Unable to load product purchase history: $e'));
    }
  }

  @override
  Future<Either<Failure, Map<String, dynamic>?>> getLatestProductPurchaseCost(
      String productId) async {
    try {
      _ensureLocalAuthority();
      final db = PersistenceInitializer.persistenceManager!.sqliteManager;
      final rows = await db.database.rawQuery('''
        SELECT i.unit_cost, i.selling_quantity, i.base_quantity,
               i.conversion_factor_snapshot
        FROM purchase_items i
        INNER JOIN purchases p ON p.id = i.purchase_id
        WHERE i.product_id = ?
        ORDER BY p.purchase_date DESC, p.id DESC
        LIMIT 1
      ''', [productId]);
      if (rows.isNotEmpty) return Right(rows.first);
      final products = await db.query(
        'products',
        columns: ['cost'],
        where: 'id = ?',
        whereArgs: [productId],
        limit: 1,
      );
      return Right(products.isEmpty ? null : products.first);
    } catch (e) {
      return Left(CacheFailure('Unable to load product purchase cost: $e'));
    }
  }
}
