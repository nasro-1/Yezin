import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../models/activity_log.dart';
import 'background_write_queue.dart';
import 'document_number_service.dart';
import 'persistence_initializer.dart';

/// The cash journal uses positive amounts for inflows and negative amounts
/// for outflows. The journal sum is the authoritative register balance.
class CanonicalCashPostingService {
  static const defaultRegisterId = 'main-register';

  static const inflowTypes = {
    'opening_balance',
    'sale_cash',
    'customer_payment_cash',
    'cash_in',
  };

  static const outflowTypes = {
    'supplier_payment_cash',
    'expense_cash',
    'customer_refund_cash',
    'cash_out',
  };

  Future<String> post({
    String registerId = defaultRegisterId,
    required String movementType,
    required double amount,
    String? referenceType,
    String? referenceId,
    String? sessionId,
    String? userId,
    String? idempotencyKey,
    required String description,
    DateTime? createdAt,
  }) {
    return DatabaseLifecycleCoordinator.instance.withWriteAccess(() async {
      final db = PersistenceInitializer.persistenceManager!.sqliteManager;
      return db.transaction((txn) => postInTransaction(
            txn: txn,
            registerId: registerId,
            movementType: movementType,
            amount: amount,
            referenceType: referenceType,
            referenceId: referenceId,
            sessionId: sessionId,
            userId: userId,
            idempotencyKey: idempotencyKey,
            description: description,
            createdAt: createdAt,
          ));
    });
  }

  Future<String> postInTransaction({
    required DatabaseExecutor txn,
    String registerId = defaultRegisterId,
    required String movementType,
    required double amount,
    String? referenceType,
    String? referenceId,
    String? sessionId,
    String? userId,
    String? idempotencyKey,
    required String description,
    DateTime? createdAt,
  }) async {
    _validate(movementType, amount, description);
    if (idempotencyKey != null && idempotencyKey.trim().isEmpty) {
      throw ArgumentError.value(idempotencyKey, 'idempotencyKey');
    }

    final register = await txn.query(
      'cash_registers',
      columns: ['id'],
      where: 'id = ? AND is_active = 1',
      whereArgs: [registerId],
      limit: 1,
    );
    if (register.isEmpty) {
      throw StateError('Cash register $registerId was not found.');
    }

    if (idempotencyKey != null) {
      final existing = await txn.query(
        'cash_movements',
        columns: ['id'],
        where: 'idempotency_key = ?',
        whereArgs: [idempotencyKey.trim()],
        limit: 1,
      );
      if (existing.isNotEmpty) return existing.first['id'] as String;
    }

    String? persistedUserId;
    if (userId != null && userId.trim().isNotEmpty) {
      final userRows = await txn.query(
        'users',
        columns: ['id'],
        where: 'id = ? OR username = ?',
        whereArgs: [userId.trim(), userId.trim()],
        limit: 1,
      );
      if (userRows.isNotEmpty) {
        persistedUserId = userRows.first['id'] as String;
      }
    }

    final timestamp = (createdAt ?? DateTime.now()).toIso8601String();
    var movementSequence = DateTime.now().microsecondsSinceEpoch;
    var movementId = 'cash_$movementSequence';
    while ((await txn.query(
      'cash_movements',
      columns: ['id'],
      where: 'id = ?',
      whereArgs: [movementId],
      limit: 1,
    ))
        .isNotEmpty) {
      movementSequence++;
      movementId = 'cash_$movementSequence';
    }
    final reference = referenceType == null
        ? null
        : (referenceId ?? await DocumentNumberService.next(
              txn,
              sequenceKey: 'cash-movement',
              prefix: 'CASH',
              year: DateTime.now().year.toString(),
              table: 'cash_movements',
              column: 'id',
            ));

    await txn.insert('cash_movements', {
      'id': movementId,
      'cash_register_id': registerId,
      'movement_type': movementType,
      'amount': amount,
      'reference_type': referenceType,
      'reference_id': reference ?? referenceId,
      'session_id': sessionId,
      'user_id': persistedUserId,
      'idempotency_key': idempotencyKey?.trim(),
      'description': description.trim(),
      'created_at': timestamp,
    });
    await txn.insert('activity_logs', {
      'id': '${movementId}_activity',
      'session_id': sessionId ?? '',
      'timestamp': timestamp,
      'type': ActivityType.cashMovement.name,
      'description': 'Cash movement: $description',
      'user_name': userId ?? 'system',
      'details':
          '{"movementId":"$movementId","type":"$movementType","amount":$amount}',
      'event_key': 'cashMovement',
      'parameters': null,
    });
    return movementId;
  }

  Future<double> getCurrentCashBalance(
      {String registerId = defaultRegisterId}) async {
    final db = PersistenceInitializer.persistenceManager!.sqliteManager;
    final rows = await db.query(
      'cash_movements',
      columns: ['COALESCE(SUM(amount), 0) AS balance'],
      where: 'cash_register_id = ?',
      whereArgs: [registerId],
    );
    return (rows.first['balance'] as num?)?.toDouble() ?? 0;
  }

  Future<double> getCashBalanceAt(DateTime timestamp,
      {String registerId = defaultRegisterId}) async {
    final db = PersistenceInitializer.persistenceManager!.sqliteManager;
    final rows = await db.query(
      'cash_movements',
      columns: ['COALESCE(SUM(amount), 0) AS balance'],
      where: 'cash_register_id = ? AND created_at <= ?',
      whereArgs: [registerId, timestamp.toIso8601String()],
    );
    return (rows.first['balance'] as num?)?.toDouble() ?? 0;
  }

  Future<List<Map<String, dynamic>>> getHistory({
    String registerId = defaultRegisterId,
    DateTime? start,
    DateTime? end,
    String? movementType,
    String? sessionId,
    String? userId,
    String? referenceType,
    String? referenceId,
  }) async {
    final db = PersistenceInitializer.persistenceManager!.sqliteManager;
    final clauses = <String>['cash_register_id = ?'];
    final args = <Object?>[registerId];
    void add(String clause, Object? value) {
      clauses.add(clause);
      args.add(value);
    }

    if (start != null) add('created_at >= ?', start.toIso8601String());
    if (end != null) add('created_at <= ?', end.toIso8601String());
    if (movementType != null) add('movement_type = ?', movementType);
    if (sessionId != null) add('session_id = ?', sessionId);
    if (userId != null) add('user_id = ?', userId);
    if (referenceType != null) add('reference_type = ?', referenceType);
    if (referenceId != null) add('reference_id = ?', referenceId);
    return db.query(
      'cash_movements',
      where: clauses.join(' AND '),
      whereArgs: args,
      orderBy: 'created_at DESC',
    );
  }

  void _validate(String movementType, double amount, String description) {
    if (!inflowTypes.contains(movementType) &&
        !outflowTypes.contains(movementType)) {
      throw ArgumentError.value(movementType, 'movementType');
    }
    if (!amount.isFinite || amount == 0) {
      throw ArgumentError.value(amount, 'amount');
    }
    if ((inflowTypes.contains(movementType) && amount < 0) ||
        (outflowTypes.contains(movementType) && amount > 0)) {
      throw ArgumentError('Cash movement amount has the wrong sign.');
    }
    if (description.trim().isEmpty) {
      throw ArgumentError.value(description, 'description');
    }
  }
}
