import 'package:dartz/dartz.dart';

import '../../../core/data/services/persistence_initializer.dart';
import '../../../core/error/failure.dart';

class SupplierLedgerEntry {
  final String id;
  final String supplierId;
  final String entryType;
  final double amount;
  final double balanceAfter;
  final String? referenceType;
  final String? referenceId;
  final String? notes;
  final DateTime createdAt;

  const SupplierLedgerEntry({
    required this.id,
    required this.supplierId,
    required this.entryType,
    required this.amount,
    required this.balanceAfter,
    this.referenceType,
    this.referenceId,
    this.notes,
    required this.createdAt,
  });

  factory SupplierLedgerEntry.fromMap(Map<String, dynamic> map) {
    return SupplierLedgerEntry(
      id: map['id'] as String,
      supplierId: map['supplier_id'] as String,
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

class SupplierAccountService {
  Future<Either<Failure, double>> getAuthoritativeSupplierBalance(
      String supplierId) async {
    try {
      final db = PersistenceInitializer.persistenceManager?.sqliteManager;
      if (db == null) {
        return const Right(0.0);
      }
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

  Future<Either<Failure, double>> getSupplierBalance(String supplierId) async {
    return getAuthoritativeSupplierBalance(supplierId);
  }

  Future<Either<Failure, List<SupplierLedgerEntry>>> getSupplierLedger(
    String supplierId,
  ) async {
    try {
      final db = PersistenceInitializer.persistenceManager?.sqliteManager;
      if (db == null) {
        return const Right([]);
      }
      final rows = await db.query(
        'supplier_ledger',
        where: 'supplier_id = ?',
        whereArgs: [supplierId],
        orderBy: 'created_at DESC',
      );
      return Right(rows.map(SupplierLedgerEntry.fromMap).toList());
    } catch (e) {
      return Left(CacheFailure('Unable to load supplier ledger: $e'));
    }
  }

  Future<Either<Failure, Unit>> recordEntry({
    required String supplierId,
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

      final currentBalance = await getSupplierBalance(supplierId);
      final balanceAfter = currentBalance.fold<double>(
        (_) => 0.0,
        (value) => value,
      );
      final nextBalance = balanceAfter + amount;
      final id = '${DateTime.now().microsecondsSinceEpoch}';

      await db.insert('supplier_ledger', {
        'id': id,
        'supplier_id': supplierId,
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
      return Left(CacheFailure('Unable to record supplier ledger entry: $e'));
    }
  }
}
