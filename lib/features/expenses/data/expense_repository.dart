import '../../../core/data/services/persistence_initializer.dart';
import '../../../core/data/services/canonical_cash_posting_service.dart';
import '../../../core/data/services/background_write_queue.dart';
import '../../../core/di/dependency_injection.dart';
import '../../../core/session/session_manager.dart';
import 'expense_model.dart';
import 'package:flutter/foundation.dart';
import '../../../core/data/models/activity_log.dart';
import '../../../core/services/activity_logger.dart';
import '../../auth/presentation/cubit/user_cubit.dart';

class ExpenseRepository {
  static final _cashPosting = CanonicalCashPostingService();
  Future<List<Expense>> getExpenses({DateTime? start, DateTime? end}) async {
    debugPrint(
        '[EXPENSE_REPOSITORY_TRACE] getExpenses start=$start end=$end');
    final db = PersistenceInitializer.persistenceManager!.sqliteManager;
    final clauses = <String>[];
    final args = <Object?>[];
    if (start != null) {
      clauses.add('created_at >= ?');
      args.add(start.toIso8601String());
    }
    if (end != null) {
      clauses.add('created_at <= ?');
      args.add(end.toIso8601String());
    }
    final rows = await db.query('expenses',
        where: clauses.isEmpty ? null : clauses.join(' AND '),
        whereArgs: args.isEmpty ? null : args,
        orderBy: 'created_at DESC');
    final expenses = rows.map(Expense.fromMap).toList();
    debugPrint(
        '[EXPENSE_DB_TRACE] SELECT expenses count=${expenses.length}');
    return expenses;
  }

  Future<double> total(DateTime start, DateTime end) async {
    debugPrint(
        '[EXPENSE_REPOSITORY_TRACE] total start=$start end=$end');
    final db = PersistenceInitializer.persistenceManager!.sqliteManager;
    final rows = await db.database.rawQuery(
      'SELECT COALESCE(SUM(amount), 0) AS total FROM expenses WHERE created_at BETWEEN ? AND ?',
      [start.toIso8601String(), end.toIso8601String()],
    );
    final total = (rows.first['total'] as num?)?.toDouble() ?? 0;
    debugPrint('[EXPENSE_DB_TRACE] SUM expenses total=$total');
    return total;
  }

  Future<void> add(Expense expense) async {
    debugPrint(
        '[EXPENSE_REPOSITORY_TRACE] add started id=${expense.id} '
        'amount=${expense.amount} category=${expense.category} '
        'paymentMethod=${expense.paymentMethod}');
    try {
      await DatabaseLifecycleCoordinator.instance.withWriteAccess(() {
        final db = PersistenceInitializer.persistenceManager!.sqliteManager;
        return db.transaction((txn) async {
          debugPrint(
              '[EXPENSE_DB_TRACE] INSERT expenses id=${expense.id} '
              'amount=${expense.amount}');
          await txn.insert('expenses', expense.toMap());
          if (expense.paymentMethod == 'cash') {
            await _cashPosting.postInTransaction(
              txn: txn,
              movementType: 'expense_cash',
              amount: -expense.amount,
              referenceType: 'expense',
              referenceId: expense.id,
              sessionId: getIt<SessionManager>().currentSession?.id,
              idempotencyKey: 'expense:${expense.id}:cash',
              description: 'Cash expense ${expense.title}',
              createdAt: expense.date,
            );
          }
        });
      });
    } catch (error, stackTrace) {
      debugPrint('[EXPENSE_DB_TRACE] transaction failed: $error');
      debugPrint('$stackTrace');
      rethrow;
    }
    debugPrint('[EXPENSE_REPOSITORY_TRACE] add committed id=${expense.id}');
    if (getIt.isRegistered<ActivityLogger>()) {
      final userName = getIt.isRegistered<UserCubit>()
          ? getIt<UserCubit>().currentUser.name
          : 'system';
      await getIt<ActivityLogger>().logActivity(
        type: ActivityType.expense,
        description: 'Expense recorded',
        userName: userName,
        details: {
          'expense_id': expense.id,
          'amount': expense.amount,
          'category': expense.category,
        },
        eventKey: 'expenseCreated',
      );
    }
  }

  Future<void> delete(String id) async {
    final db = PersistenceInitializer.persistenceManager!.sqliteManager;
    await db.delete('expenses', where: 'id = ?', whereArgs: [id]);
  }
}
