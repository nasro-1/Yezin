import 'package:dartz/dartz.dart';

import '../../../core/data/services/persistence_initializer.dart';
import '../../../core/error/failure.dart';

class CustomerLedgerEntry {
  final String id;
  final String customerId;
  final String entryType;
  final double amount;
  final double balanceAfter;
  final String? referenceType;
  final String? referenceId;
  final String? notes;
  final DateTime createdAt;

  const CustomerLedgerEntry({
    required this.id,
    required this.customerId,
    required this.entryType,
    required this.amount,
    required this.balanceAfter,
    this.referenceType,
    this.referenceId,
    this.notes,
    required this.createdAt,
  });

  factory CustomerLedgerEntry.fromMap(Map<String, dynamic> map) {
    return CustomerLedgerEntry(
      id: map['id'] as String,
      customerId: map['customer_id'] as String,
      entryType: map['entry_type'] as String,
      amount: (map['amount'] as num).toDouble(),
      balanceAfter: (map['balance_after'] as num).toDouble(),
      referenceType: map['reference_type'] as String?,
      referenceId: map['reference_id'] as String?,
      notes: map['notes'] as String?,
      createdAt: DateTime.parse(map['created_at'] as String),
    );
  }
}

class CustomerAccountService {
  Future<Either<Failure, double>> getAuthoritativeCustomerBalance(
      String customerId) async {
    try {
      final db = PersistenceInitializer.persistenceManager?.sqliteManager;
      if (db == null) {
        return const Right(0.0);
      }
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

  Future<Either<Failure, double>> getCustomerBalance(String customerId) async {
    return getAuthoritativeCustomerBalance(customerId);
  }

  Future<Either<Failure, List<CustomerLedgerEntry>>> getCustomerLedger(
    String customerId,
  ) async {
    try {
      final db = PersistenceInitializer.persistenceManager?.sqliteManager;
      if (db == null) {
        return const Right([]);
      }
      final rows = await db.query(
        'customer_ledger',
        where: 'customer_id = ?',
        whereArgs: [customerId],
        orderBy: 'created_at DESC',
      );
      return Right(rows.map(CustomerLedgerEntry.fromMap).toList());
    } catch (e) {
      return Left(CacheFailure('Unable to load customer ledger: $e'));
    }
  }

  Future<Either<Failure, Unit>> recordEntry({
    required String customerId,
    required String entryType,
    required double amount,
    required String referenceType,
    String? referenceId,
    String? notes,
  }) async {
    try {
      final db = PersistenceInitializer.persistenceManager?.sqliteManager;
      if (db == null) {
        return const Right(unit);
      }

      final currentBalance = await getCustomerBalance(customerId);
      final balanceAfter = currentBalance.fold<double>(
        (_) => 0.0,
        (value) => value,
      );
      final nextBalance = balanceAfter + amount;
      final id = '${DateTime.now().microsecondsSinceEpoch}';

      await db.insert('customer_ledger', {
        'id': id,
        'customer_id': customerId,
        'entry_type': entryType,
        'amount': amount,
        'balance_after': nextBalance,
        'reference_type': referenceType,
        'reference_id': referenceId,
        'notes': notes,
        'created_at': DateTime.now().toIso8601String(),
      });
      return const Right(unit);
    } catch (e) {
      return Left(CacheFailure('Unable to record customer ledger entry: $e'));
    }
  }
}
