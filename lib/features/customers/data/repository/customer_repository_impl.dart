import 'package:bayaa_pos/core/security/permission_guard.dart';
import 'package:bayaa_pos/features/auth/presentation/cubit/user_cubit.dart';
import 'package:dartz/dartz.dart';
import 'package:get_it/get_it.dart';

import '../../../../core/data/models/activity_log.dart';
import '../../../../core/data/services/persistence_initializer.dart';
import '../../../../core/data/services/document_number_service.dart';
import '../../../../core/error/failure.dart';
import '../../../../core/services/activity_logger.dart';
import '../models/customer_model.dart';

abstract class CustomerRepository {
  Future<Either<Failure, List<Customer>>> getAllCustomers();
  Future<Either<Failure, Customer?>> getCustomerById(String customerId);
  Future<Either<Failure, List<Customer>>> searchCustomers(String query,
      {int limit = 50});
  Future<Either<Failure, Unit>> createCustomer(Customer customer);
  Future<Either<Failure, Unit>> updateCustomer(Customer customer);
  Future<Either<Failure, Unit>> deleteCustomer(String customerId);
  Future<Either<Failure, double>> getCustomerBalance(String customerId);
  Future<Either<Failure, List<Map<String, dynamic>>>> getCustomerLedger(
      String customerId);
}

class CustomerRepositoryImpl implements CustomerRepository {
  @override
  Future<Either<Failure, List<Customer>>> getAllCustomers() async {
    try {
      final db = PersistenceInitializer.persistenceManager?.sqliteManager;
      if (db == null) return const Right([]);

      final rows = await db.query(
        'customers',
        where: 'is_active = 1',
        orderBy: 'name COLLATE NOCASE ASC',
      );
      return Right(rows.map(Customer.fromMap).toList());
    } catch (e) {
      return Left(CacheFailure('Unable to load customers: $e'));
    }
  }

  @override
  Future<Either<Failure, Customer?>> getCustomerById(String customerId) async {
    try {
      final db = PersistenceInitializer.persistenceManager?.sqliteManager;
      if (db == null) return const Right(null);
      final rows = await db.query(
        'customers',
        where: 'id = ?',
        whereArgs: [customerId],
      );
      if (rows.isEmpty) return const Right(null);
      return Right(Customer.fromMap(rows.first));
    } catch (e) {
      return Left(CacheFailure('Unable to load customer: $e'));
    }
  }

  @override
  Future<Either<Failure, List<Customer>>> searchCustomers(String query,
      {int limit = 50}) async {
    try {
      final cleaned = query.trim();
      final db = PersistenceInitializer.persistenceManager?.sqliteManager;
      if (db == null) return const Right([]);
      if (cleaned.isEmpty) {
        return getAllCustomers();
      }

      final filter = '%$cleaned%';
      final rows = await db.query(
        'customers',
        where:
            '(code LIKE ? OR name LIKE ? OR phone LIKE ? OR mobile LIKE ? OR registration_name LIKE ? OR customer_reference LIKE ? OR tax_id LIKE ?) AND is_active = 1',
        whereArgs: [filter, filter, filter, filter, filter, filter, filter],
        orderBy: 'name COLLATE NOCASE ASC',
        limit: limit,
      );
      return Right(rows.map(Customer.fromMap).toList());
    } catch (e) {
      return Left(CacheFailure('Unable to search customers: $e'));
    }
  }

  void _requireCustomerAccess() {
    try {
      final currentUser = GetIt.instance<UserCubit>().currentUser;
      PermissionGuard.requireCustomerAccess(currentUser);
    } catch (_) {
      throw PermissionDeniedException(
        'Customer access requires an authenticated manager or admin user.',
      );
    }
  }

  @override
  Future<Either<Failure, Unit>> createCustomer(Customer customer) async {
    try {
      _requireCustomerAccess();
      final db = PersistenceInitializer.persistenceManager?.sqliteManager;
      if (db == null) return const Right(unit);
      if (customer.name.trim().isEmpty) {
        return const Left(ValidationFailure('Customer name is required.'));
      }
      if (customer.code.trim().isNotEmpty) {
        final duplicate = await db.query('customers',
            where: 'code = ?', whereArgs: [customer.code], limit: 1);
        if (duplicate.isNotEmpty) {
          return const Left(ValidationFailure('Customer code must be unique.'));
        }
      }

      final now = DateTime.now().toIso8601String();
      final values = customer.toMap()
        ..['created_at'] = now
        ..['updated_at'] = now
        ..['current_balance'] = 0.0;
      await db.transaction((txn) async {
        if (customer.code.trim().isEmpty) {
          values['code'] = await DocumentNumberService.next(
            txn,
            sequenceKey: 'customer',
            prefix: 'CUS',
            table: 'customers',
            column: 'code',
          );
        }
        await txn.insert('customers', values);
        if (customer.openingBalance != 0) {
          await txn.insert('customer_ledger', {
            'id': '${customer.id}_opening',
            'customer_id': customer.id,
            'entry_type': 'opening_balance',
            'amount': customer.openingBalance,
            'balance_after': customer.openingBalance,
            'reference_type': 'customer',
            'reference_id': customer.id,
            'notes': 'Opening balance',
            'created_at': now,
          });
        }
      });

      await ActivityLogger().logActivity(
        type: ActivityType.customerCreated,
        description: 'Customer created: ${customer.name}',
        userName: 'system',
        details: {'customerId': customer.id, 'customerCode': customer.code},
      );
      return const Right(unit);
    } catch (e) {
      return Left(CacheFailure('Unable to create customer: $e'));
    }
  }

  @override
  Future<Either<Failure, Unit>> updateCustomer(Customer customer) async {
    try {
      _requireCustomerAccess();
      final db = PersistenceInitializer.persistenceManager?.sqliteManager;
      if (db == null) return const Right(unit);

      final values = customer.toMap()
        ..remove('code')
        ..remove('current_balance')
        ..remove('opening_balance')
        ..['updated_at'] = DateTime.now().toIso8601String();
      await db.update(
        'customers',
        values,
        where: 'id = ?',
        whereArgs: [customer.id],
      );

      await ActivityLogger().logActivity(
        type: ActivityType.customerUpdated,
        description: 'Customer updated: ${customer.name}',
        userName: 'system',
        details: {'customerId': customer.id},
      );
      return const Right(unit);
    } catch (e) {
      return Left(CacheFailure('Unable to update customer: $e'));
    }
  }

  @override
  Future<Either<Failure, Unit>> deleteCustomer(String customerId) async {
    try {
      _requireCustomerAccess();
      final db = PersistenceInitializer.persistenceManager?.sqliteManager;
      if (db == null) return const Right(unit);
      final changed = await db.update(
        'customers',
        {'is_active': 0, 'updated_at': DateTime.now().toIso8601String()},
        where: 'id = ?',
        whereArgs: [customerId],
      );
      if (changed == 0) {
        return const Left(ValidationFailure('Customer was not found.'));
      }
      await ActivityLogger().logActivity(
        type: ActivityType.customerDeleted,
        description: 'Customer deleted',
        userName: 'system',
        details: {'customerId': customerId},
      );
      return const Right(unit);
    } catch (e) {
      return Left(CacheFailure('Unable to delete customer: $e'));
    }
  }

  @override
  Future<Either<Failure, double>> getCustomerBalance(String customerId) async {
    try {
      final db = PersistenceInitializer.persistenceManager?.sqliteManager;
      if (db == null) return const Right(0.0);
      final rows = await db.query(
        'customer_ledger',
        columns: ['SUM(amount) AS total'],
        where: 'customer_id = ?',
        whereArgs: [customerId],
      );
      final total = rows.isNotEmpty
          ? (rows.first['total'] as num?)?.toDouble() ?? 0.0
          : 0.0;
      return Right(total);
    } catch (e) {
      return Left(CacheFailure('Unable to calculate customer balance: $e'));
    }
  }

  @override
  Future<Either<Failure, List<Map<String, dynamic>>>> getCustomerLedger(
      String customerId) async {
    try {
      final db = PersistenceInitializer.persistenceManager?.sqliteManager;
      if (db == null) return const Right([]);
      final rows = await db.query(
        'customer_ledger',
        where: 'customer_id = ?',
        whereArgs: [customerId],
        orderBy: 'created_at DESC',
      );
      return Right(rows);
    } catch (e) {
      return Left(CacheFailure('Unable to load customer ledger: $e'));
    }
  }

  Future<Either<Failure, Unit>> saveCustomer(Customer customer) async {
    final existing = await getCustomerById(customer.id);
    final hasCustomer = existing.fold(
      (_) => false,
      (value) => value != null,
    );
    if (hasCustomer) {
      return updateCustomer(customer);
    }
    return createCustomer(customer);
  }
}
