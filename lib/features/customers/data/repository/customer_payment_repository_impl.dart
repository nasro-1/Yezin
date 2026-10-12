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
import '../models/customer_payment_model.dart';

typedef CustomerPaymentFailureInjector = Future<void> Function(Transaction txn);

abstract class CustomerPaymentRepository {
  Future<Either<Failure, Unit>> createPayment(CustomerPayment payment);
  Future<Either<Failure, List<Map<String, dynamic>>>> getPaymentHistory({
    String? customerId,
  });
  Future<Either<Failure, double>> getCustomerBalance(String customerId);
}

class CustomerPaymentRepositoryImpl implements CustomerPaymentRepository {
  static final _cashPosting = CanonicalCashPostingService();
  CustomerPaymentRepositoryImpl({this.failureInjector});

  final CustomerPaymentFailureInjector? failureInjector;

  @override
  Future<Either<Failure, Unit>> createPayment(CustomerPayment payment) async {
    try {
      final user = GetIt.instance<UserCubit>().currentUser;
      PermissionGuard.requireCustomerPaymentAccess(user);
      if (payment.amount <= 0) {
        return const Left(
            ValidationFailure('Payment amount must be greater than zero.'));
      }
      if (payment.paymentMethod != 'cash') {
        return const Left(ValidationFailure('Unsupported payment method.'));
      }

      final db = PersistenceInitializer.persistenceManager!.sqliteManager;
      await db.transaction((txn) async {
        final customer = await txn.query(
          'customers',
          columns: ['id'],
          where: 'id = ? AND is_active = 1',
          whereArgs: [payment.customerId],
        );
        if (customer.isEmpty) throw StateError('Customer not found.');

        final balanceRows = await txn.query(
          'customer_ledger',
          columns: ['SUM(amount) AS total'],
          where: 'customer_id = ?',
          whereArgs: [payment.customerId],
        );
        final balance = (balanceRows.first['total'] as num?)?.toDouble() ?? 0.0;
        if (payment.amount > balance) {
          throw StateError('Payment exceeds customer outstanding balance.');
        }

        final now = DateTime.now().toIso8601String();
        final reference = payment.reference.trim().isEmpty
            ? await DocumentNumberService.next(
                txn,
                sequenceKey: 'customer-payment',
                prefix: 'CP',
                year: payment.paymentDate.year.toString(),
                table: 'customer_payments',
                column: 'reference',
              )
            : payment.reference.trim();
        await txn.insert('customer_payments', {
          'id': payment.id,
          'customer_id': payment.customerId,
          'amount': payment.amount,
          'payment_date': payment.paymentDate.toIso8601String(),
          'payment_method': payment.paymentMethod,
          'reference': reference,
          'notes': payment.notes,
          'created_by': payment.createdBy,
          'status': payment.status,
          'created_at': now,
        });
        await txn.insert('customer_ledger', {
          'id': '${payment.id}_ledger',
          'customer_id': payment.customerId,
          'entry_type': 'customer_payment',
          'amount': -payment.amount,
          'balance_after': balance - payment.amount,
          'reference_type': 'customer_payment',
          'reference_id': payment.id,
          'notes': payment.notes,
          'created_at': now,
        });
        if (payment.paymentMethod == 'cash') {
          await _cashPosting.postInTransaction(
            txn: txn,
            movementType: 'customer_payment_cash',
            amount: payment.amount,
            referenceType: 'customer_payment',
            referenceId: payment.id,
            sessionId: getIt<SessionManager>().currentSession?.id,
            userId: payment.createdBy,
            idempotencyKey: 'customer-payment:${payment.id}:cash',
            description: 'Customer cash payment ${payment.id}',
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
          'type': ActivityType.customerPayment.name,
          'description': 'Customer payment: $reference',
          'user_name': payment.createdBy,
          'details':
              '{"paymentId":"${payment.id}","customerId":"${payment.customerId}","amount":${payment.amount}}',
          'event_key': 'customerPayment',
          'parameters': null,
        });
      });
      await ActivityLogger().loadRecentActivities();
      return const Right(unit);
    } catch (e) {
      return Left(CacheFailure('Unable to create customer payment: $e'));
    }
  }

  @override
  Future<Either<Failure, List<Map<String, dynamic>>>> getPaymentHistory({
    String? customerId,
  }) async {
    try {
      final db = PersistenceInitializer.persistenceManager!.sqliteManager;
      final rows = await db.rawQuery('''
        SELECT p.*, c.name AS customer_name, c.code AS customer_code, l.balance_after
        FROM customer_payments p
        INNER JOIN customers c ON c.id = p.customer_id
        LEFT JOIN customer_ledger l
          ON l.reference_id = p.id AND l.entry_type = 'customer_payment'
        ${customerId == null ? '' : 'WHERE p.customer_id = ?'}
        ORDER BY p.payment_date DESC
      ''', customerId == null ? null : [customerId]);
      return Right(rows);
    } catch (e) {
      return Left(CacheFailure('Unable to load customer payment history: $e'));
    }
  }

  @override
  Future<Either<Failure, double>> getCustomerBalance(String customerId) async {
    try {
      final db = PersistenceInitializer.persistenceManager!.sqliteManager;
      final rows = await db.query(
        'customer_ledger',
        columns: ['SUM(amount) AS total'],
        where: 'customer_id = ?',
        whereArgs: [customerId],
      );
      return Right((rows.first['total'] as num?)?.toDouble() ?? 0.0);
    } catch (e) {
      return Left(CacheFailure('Unable to calculate customer balance: $e'));
    }
  }
}
