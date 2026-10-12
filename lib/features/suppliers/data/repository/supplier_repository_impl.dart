import 'package:bayaa_pos/core/security/permission_guard.dart';
import 'package:bayaa_pos/features/auth/presentation/cubit/user_cubit.dart';
import 'package:dartz/dartz.dart';
import 'package:get_it/get_it.dart';

import '../../../../core/data/models/activity_log.dart';
import '../../../../core/data/services/persistence_initializer.dart';
import '../../../../core/data/services/document_number_service.dart';
import '../../../../core/error/failure.dart';
import '../../../../core/services/activity_logger.dart';
import '../models/supplier_model.dart';

abstract class SupplierRepository {
  Future<Either<Failure, List<Supplier>>> getAllSuppliers();
  Future<Either<Failure, Supplier?>> getSupplierById(String supplierId);
  Future<Either<Failure, List<Supplier>>> searchSuppliers(String query,
      {int limit = 50});
  Future<Either<Failure, Unit>> createSupplier(Supplier supplier);
  Future<Either<Failure, Unit>> updateSupplier(Supplier supplier);
  Future<Either<Failure, Unit>> deleteSupplier(String supplierId);
  Future<Either<Failure, double>> getSupplierBalance(String supplierId);
  Future<Either<Failure, List<Map<String, dynamic>>>> getSupplierLedger(
      String supplierId);
}

class SupplierRepositoryImpl implements SupplierRepository {
  @override
  Future<Either<Failure, List<Supplier>>> getAllSuppliers() async {
    try {
      final db = PersistenceInitializer.persistenceManager?.sqliteManager;
      if (db == null) return const Right([]);
      final rows = await db.query(
        'suppliers',
        where: 'is_active = 1',
        orderBy: 'name COLLATE NOCASE ASC',
      );
      return Right(rows.map(Supplier.fromMap).toList());
    } catch (e) {
      return Left(CacheFailure('Unable to load suppliers: $e'));
    }
  }

  @override
  Future<Either<Failure, Supplier?>> getSupplierById(String supplierId) async {
    try {
      final db = PersistenceInitializer.persistenceManager?.sqliteManager;
      if (db == null) return const Right(null);
      final rows =
          await db.query('suppliers', where: 'id = ?', whereArgs: [supplierId]);
      if (rows.isEmpty) return const Right(null);
      return Right(Supplier.fromMap(rows.first));
    } catch (e) {
      return Left(CacheFailure('Unable to load supplier: $e'));
    }
  }

  @override
  Future<Either<Failure, List<Supplier>>> searchSuppliers(String query,
      {int limit = 50}) async {
    try {
      final cleaned = query.trim();
      final db = PersistenceInitializer.persistenceManager?.sqliteManager;
      if (db == null) return const Right([]);
      if (cleaned.isEmpty) return getAllSuppliers();

      final filter = '%$cleaned%';
      final rows = await db.query(
        'suppliers',
        where:
            '(code LIKE ? OR name LIKE ? OR phone LIKE ? OR mobile LIKE ? OR registration_name LIKE ? OR supplier_reference LIKE ? OR tax_id LIKE ?) AND is_active = 1',
        whereArgs: [filter, filter, filter, filter, filter, filter, filter],
        orderBy: 'name COLLATE NOCASE ASC',
        limit: limit,
      );
      return Right(rows.map(Supplier.fromMap).toList());
    } catch (e) {
      return Left(CacheFailure('Unable to search suppliers: $e'));
    }
  }

  void _requireSupplierAccess() {
    try {
      final currentUser = GetIt.instance<UserCubit>().currentUser;
      PermissionGuard.requireSupplierAccess(currentUser);
    } catch (_) {
      throw PermissionDeniedException(
        'Supplier access requires an authenticated manager or admin user.',
      );
    }
  }

  @override
  Future<Either<Failure, Unit>> createSupplier(Supplier supplier) async {
    try {
      _requireSupplierAccess();
      final db = PersistenceInitializer.persistenceManager?.sqliteManager;
      if (db == null) return const Right(unit);
      if (supplier.name.trim().isEmpty) {
        return const Left(ValidationFailure('Supplier name is required.'));
      }
      if (supplier.code.trim().isNotEmpty) {
        final duplicate = await db.query('suppliers',
            where: 'code = ?', whereArgs: [supplier.code], limit: 1);
        if (duplicate.isNotEmpty) {
          return const Left(ValidationFailure('Supplier code must be unique.'));
        }
      }

      final now = DateTime.now().toIso8601String();
      final values = supplier.toMap()
        ..['created_at'] = now
        ..['updated_at'] = now
        ..['current_balance'] = 0.0;
      await db.transaction((txn) async {
        if (supplier.code.trim().isEmpty) {
          values['code'] = await DocumentNumberService.next(
            txn,
            sequenceKey: 'supplier',
            prefix: 'SUP',
            table: 'suppliers',
            column: 'code',
          );
        }
        await txn.insert('suppliers', values);
        if (supplier.openingBalance != 0) {
          await txn.insert('supplier_ledger', {
            'id': '${supplier.id}_opening',
            'supplier_id': supplier.id,
            'entry_type': 'opening_balance',
            'amount': supplier.openingBalance,
            'balance_after': supplier.openingBalance,
            'reference_type': 'supplier',
            'reference_id': supplier.id,
            'notes': 'Opening balance',
            'created_at': now,
          });
        }
      });

      await ActivityLogger().logActivity(
        type: ActivityType.supplierCreated,
        description: 'Supplier created: ${supplier.name}',
        userName: 'system',
        details: {'supplierId': supplier.id, 'supplierCode': supplier.code},
      );
      return const Right(unit);
    } catch (e) {
      return Left(CacheFailure('Unable to create supplier: $e'));
    }
  }

  @override
  Future<Either<Failure, Unit>> updateSupplier(Supplier supplier) async {
    try {
      _requireSupplierAccess();
      final db = PersistenceInitializer.persistenceManager?.sqliteManager;
      if (db == null) return const Right(unit);
      final values = supplier.toMap()
        ..remove('code')
        ..remove('current_balance')
        ..remove('opening_balance')
        ..['updated_at'] = DateTime.now().toIso8601String();
      await db.update('suppliers', values,
          where: 'id = ?', whereArgs: [supplier.id]);

      await ActivityLogger().logActivity(
        type: ActivityType.supplierUpdated,
        description: 'Supplier updated: ${supplier.name}',
        userName: 'system',
        details: {'supplierId': supplier.id},
      );
      return const Right(unit);
    } catch (e) {
      return Left(CacheFailure('Unable to update supplier: $e'));
    }
  }

  @override
  Future<Either<Failure, Unit>> deleteSupplier(String supplierId) async {
    try {
      _requireSupplierAccess();
      final db = PersistenceInitializer.persistenceManager?.sqliteManager;
      if (db == null) return const Right(unit);
      final changed = await db.update(
        'suppliers',
        {'is_active': 0, 'updated_at': DateTime.now().toIso8601String()},
        where: 'id = ?',
        whereArgs: [supplierId],
      );
      if (changed == 0) {
        return const Left(ValidationFailure('Supplier was not found.'));
      }
      await ActivityLogger().logActivity(
        type: ActivityType.supplierDeleted,
        description: 'Supplier deleted',
        userName: 'system',
        details: {'supplierId': supplierId},
      );
      return const Right(unit);
    } catch (e) {
      return Left(CacheFailure('Unable to delete supplier: $e'));
    }
  }

  @override
  Future<Either<Failure, double>> getSupplierBalance(String supplierId) async {
    try {
      final db = PersistenceInitializer.persistenceManager?.sqliteManager;
      if (db == null) return const Right(0.0);
      final rows = await db.query(
        'supplier_ledger',
        columns: ['SUM(amount) AS total'],
        where: 'supplier_id = ?',
        whereArgs: [supplierId],
      );
      final total = rows.isNotEmpty
          ? (rows.first['total'] as num?)?.toDouble() ?? 0.0
          : 0.0;
      return Right(total);
    } catch (e) {
      return Left(CacheFailure('Unable to calculate supplier balance: $e'));
    }
  }

  @override
  Future<Either<Failure, List<Map<String, dynamic>>>> getSupplierLedger(
      String supplierId) async {
    try {
      final db = PersistenceInitializer.persistenceManager?.sqliteManager;
      if (db == null) return const Right([]);
      final rows = await db.query(
        'supplier_ledger',
        where: 'supplier_id = ?',
        whereArgs: [supplierId],
        orderBy: 'created_at DESC',
      );
      return Right(rows);
    } catch (e) {
      return Left(CacheFailure('Unable to load supplier ledger: $e'));
    }
  }

  Future<Either<Failure, Unit>> saveSupplier(Supplier supplier) async {
    final existing = await getSupplierById(supplier.id);
    final hasSupplier = existing.fold(
      (_) => false,
      (value) => value != null,
    );
    if (hasSupplier) {
      return updateSupplier(supplier);
    }
    return createSupplier(supplier);
  }
}
