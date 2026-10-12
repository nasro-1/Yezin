import 'package:dartz/dartz.dart';
import 'package:get_it/get_it.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../../../core/data/models/activity_log.dart';
import '../../../../core/data/services/persistence_initializer.dart';
import '../../../../core/data/services/document_number_service.dart';
import '../../../../core/data/services/canonical_cash_posting_service.dart';
import '../../../../core/error/failure.dart';
import '../../../../core/security/permission_guard.dart';
import '../../../../core/services/activity_logger.dart';
import '../../../auth/presentation/cubit/user_cubit.dart';
import '../../../../core/di/dependency_injection.dart';
import '../../../../core/session/session_manager.dart';
import '../models/supplier_payment_model.dart';

typedef SupplierPaymentFailureInjector = Future<void> Function(Transaction txn);

abstract class SupplierPaymentRepository {
  Future<Either<Failure, Unit>> createPayment(SupplierPayment payment);
  Future<Either<Failure, List<Map<String, dynamic>>>> getPaymentHistory({
    String? supplierId,
  });
}

class SupplierPaymentRepositoryImpl implements SupplierPaymentRepository {
  static final _cashPosting = CanonicalCashPostingService();
  SupplierPaymentRepositoryImpl({this.failureInjector});

  final SupplierPaymentFailureInjector? failureInjector;

  @override
  Future<Either<Failure, Unit>> createPayment(SupplierPayment payment) async {
    try {
      final user = GetIt.instance<UserCubit>().currentUser;
      PermissionGuard.requireSupplierPaymentAccess(user);
      if (payment.amount <= 0) {
        return const Left(
            ValidationFailure('Payment amount must be greater than zero.'));
      }
      final db = PersistenceInitializer.persistenceManager!.sqliteManager;
      await db.transaction((txn) async {
        final supplier = await txn.query(
          'suppliers',
          columns: ['id'],
          where: 'id = ? AND is_active = 1',
          whereArgs: [payment.supplierId],
        );
        if (supplier.isEmpty) throw StateError('Supplier not found.');

        final balanceRows = await txn.query(
          'supplier_ledger',
          columns: ['SUM(amount) AS total'],
          where: 'supplier_id = ?',
          whereArgs: [payment.supplierId],
        );
        final balance = (balanceRows.first['total'] as num?)?.toDouble() ?? 0.0;
        if (payment.amount > balance) {
          throw StateError('Payment exceeds supplier outstanding balance.');
        }
        final now = DateTime.now().toIso8601String();
        final reference = payment.reference.trim().isEmpty
            ? await DocumentNumberService.next(
                txn,
                sequenceKey: 'supplier-payment',
                prefix: 'SP',
                year: DateTime.now().year.toString(),
                table: 'supplier_payments',
              )
            : payment.reference;
        await txn.insert('supplier_payments', {
          'id': payment.id,
          'supplier_id': payment.supplierId,
          'amount': payment.amount,
          'payment_date': payment.paymentDate.toIso8601String(),
          'payment_method': payment.paymentMethod,
          'reference': reference,
          'notes': payment.notes,
          'created_by': payment.createdBy,
          'status': payment.status,
          'created_at': now,
        });
        await txn.insert('supplier_ledger', {
          'id': '${payment.id}_ledger',
          'supplier_id': payment.supplierId,
          'entry_type': 'supplier_payment',
          'amount': -payment.amount,
          'balance_after': balance - payment.amount,
          'reference_type': 'supplier_payment',
          'reference_id': payment.id,
          'notes': payment.notes,
          'created_at': now,
        });
        if (payment.paymentMethod == 'cash') {
          await _cashPosting.postInTransaction(
            txn: txn,
            movementType: 'supplier_payment_cash',
            amount: -payment.amount,
            referenceType: 'supplier_payment',
            referenceId: payment.id,
            sessionId: getIt<SessionManager>().currentSession?.id,
            userId: payment.createdBy,
            idempotencyKey: 'supplier-payment:${payment.id}:cash',
            description: 'Supplier cash payment ${payment.id}',
            createdAt: payment.paymentDate,
          );
        }
        if (failureInjector != null) {
          await failureInjector!(txn);
        }
        await txn.insert('activity_logs', {
          'id': '${payment.id}_activity',
          'session_id': '',
          'timestamp': now,
          'type': ActivityType.supplierPayment.name,
          'description': 'Supplier payment: $reference',
          'user_name': payment.createdBy,
          'details':
              '{"paymentId":"${payment.id}","supplierId":"${payment.supplierId}"}',
          'event_key': 'supplierPayment',
          'parameters': null,
        });
      });
      await ActivityLogger().loadRecentActivities();
      return const Right(unit);
    } catch (e) {
      return Left(CacheFailure('Unable to create supplier payment: $e'));
    }
  }

  @override
  Future<Either<Failure, List<Map<String, dynamic>>>> getPaymentHistory({
    String? supplierId,
  }) async {
    try {
      final db = PersistenceInitializer.persistenceManager!.sqliteManager;
      final rows = await db.rawQuery('''
        SELECT p.*, s.name AS supplier_name
        FROM supplier_payments p
        INNER JOIN suppliers s ON s.id = p.supplier_id
        ${supplierId == null ? '' : 'WHERE p.supplier_id = ?'}
        ORDER BY p.payment_date DESC
      ''', supplierId == null ? null : [supplierId]);
      return Right(rows);
    } catch (e) {
      return Left(CacheFailure('Unable to load supplier payment history: $e'));
    }
  }
}
