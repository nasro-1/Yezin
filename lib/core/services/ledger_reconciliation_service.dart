import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../data/services/persistence_initializer.dart';
import '../data/services/sqlite_manager.dart';

enum LedgerIssueSeverity {
  p1,
  p2,
}

class LedgerBalanceFinding {
  const LedgerBalanceFinding({
    required this.entityId,
    required this.entityType,
    required this.issueType,
    required this.severity,
    required this.ledgerBalance,
    required this.difference,
    this.legacyCurrentBalance,
    this.masterOpeningBalance,
    this.openingLedgerCount = 0,
    this.details,
    this.recordedBalanceAfter,
    this.expectedBalanceAfter,
  });

  final String entityId;
  final String entityType;
  final String issueType;
  final LedgerIssueSeverity severity;
  final double ledgerBalance;
  final double difference;
  final double? legacyCurrentBalance;
  final double? masterOpeningBalance;
  final int openingLedgerCount;
  final String? details;
  final double? recordedBalanceAfter;
  final double? expectedBalanceAfter;

  Map<String, dynamic> toMap() => {
        'entity_id': entityId,
        'entity_type': entityType,
        'issue_type': issueType,
        'severity': severity.name.toUpperCase(),
        'ledger_balance': ledgerBalance,
        'difference': difference,
        'legacy_current_balance': legacyCurrentBalance,
        'master_opening_balance': masterOpeningBalance,
        'opening_ledger_count': openingLedgerCount,
        'details': details,
        'recorded_balance_after': recordedBalanceAfter,
        'expected_balance_after': expectedBalanceAfter,
      };
}

class LedgerReconciliationService {
  const LedgerReconciliationService();

  Future<List<Map<String, dynamic>>> _query(
    Object db,
    String table, {
    List<String>? columns,
    String? where,
    List<dynamic>? whereArgs,
    String? orderBy,
    int? limit,
  }) async {
    if (db is SQLiteManager) {
      return db.query(
        table,
        columns: columns,
        where: where,
        whereArgs: whereArgs,
        orderBy: orderBy,
        limit: limit,
      );
    }
    if (db is Database) {
      return db.query(
        table,
        columns: columns,
        where: where,
        whereArgs: whereArgs,
        orderBy: orderBy,
        limit: limit,
      );
    }
    throw StateError('Unsupported database type: ${db.runtimeType}');
  }

  Future<List<Map<String, dynamic>>> _rawQuery(
    Object db,
    String sql, [
    List<dynamic>? arguments,
  ]) async {
    if (db is SQLiteManager) {
      return db.rawQuery(sql, arguments);
    }
    if (db is Database) {
      return db.rawQuery(sql, arguments);
    }
    throw StateError('Unsupported database type: ${db.runtimeType}');
  }

  Future<List<LedgerBalanceFinding>> reconcileCustomers({Object? database}) async {
    final db = database ?? PersistenceInitializer.persistenceManager?.sqliteManager;
    if (db == null) return const [];

    final rows = await _query(db, 'customers', orderBy: 'name COLLATE NOCASE ASC');
    final findings = <LedgerBalanceFinding>[];

    for (final row in rows) {
      final entityId = (row['id'] as String?) ?? '';
      final ledgerRows = await _query(
        db,
        'customer_ledger',
        columns: ['SUM(amount) AS total', 'COUNT(*) AS entry_count'],
        where: 'customer_id = ?',
        whereArgs: [entityId],
      );
      final ledgerBalance = ledgerRows.isNotEmpty
          ? ((ledgerRows.first['total'] as num?) ?? 0).toDouble()
          : 0.0;
      final legacyCurrentBalance = ((row['current_balance'] as num?) ?? 0).toDouble();
      final masterOpeningBalance = ((row['opening_balance'] as num?) ?? 0).toDouble();
      final openingLedgerCount = await _rawQuery(
        db,
        'SELECT COUNT(*) AS count FROM customer_ledger WHERE customer_id = ? AND entry_type = ?',
        [entityId, 'opening_balance'],
      );
      final openingCount = ((openingLedgerCount.first['count'] as num?) ?? 0).toInt();

      if ((legacyCurrentBalance - ledgerBalance).abs() > 0.0000001) {
        final difference = (legacyCurrentBalance - ledgerBalance).abs();
        findings.add(
          LedgerBalanceFinding(
            entityId: entityId,
            entityType: 'customer',
            issueType: 'legacy_current_balance_divergence',
            severity: LedgerIssueSeverity.p1,
            ledgerBalance: ledgerBalance,
            difference: difference,
            legacyCurrentBalance: legacyCurrentBalance,
            masterOpeningBalance: masterOpeningBalance,
            openingLedgerCount: openingCount,
            details: 'customer.current_balance does not match SUM(customer_ledger.amount)',
          ),
        );
      }

      if (masterOpeningBalance != 0.0 && openingCount != 1) {
        final difference = openingCount == 0
            ? masterOpeningBalance.abs()
            : (openingCount - 1).abs() * masterOpeningBalance.abs();
        findings.add(
          LedgerBalanceFinding(
            entityId: entityId,
            entityType: 'customer',
            issueType: openingCount == 0
                ? 'missing_opening_ledger_entry'
                : 'duplicate_opening_ledger_entries',
            severity: openingCount == 0 ? LedgerIssueSeverity.p2 : LedgerIssueSeverity.p1,
            ledgerBalance: ledgerBalance,
            difference: difference,
            legacyCurrentBalance: legacyCurrentBalance,
            masterOpeningBalance: masterOpeningBalance,
            openingLedgerCount: openingCount,
            details: openingCount == 0
                ? 'master opening_balance is set but no opening_balance ledger row exists'
                : 'master opening_balance is set but opening_balance ledger rows are duplicated',
          ),
        );
      } else if (masterOpeningBalance == 0.0 && openingCount > 0) {
        findings.add(
          LedgerBalanceFinding(
            entityId: entityId,
            entityType: 'customer',
            issueType: 'opening_entry_without_master_balance',
            severity: LedgerIssueSeverity.p2,
            ledgerBalance: ledgerBalance,
            difference: 0.0,
            legacyCurrentBalance: legacyCurrentBalance,
            masterOpeningBalance: masterOpeningBalance,
            openingLedgerCount: openingCount,
            details: 'opening_balance ledger row exists while master opening_balance is zero',
          ),
        );
      }

      final lastBalanceRow = await _query(
        db,
        'customer_ledger',
        where: 'customer_id = ?',
        whereArgs: [entityId],
        orderBy: 'created_at DESC',
        limit: 1,
      );
      if (lastBalanceRow.isNotEmpty) {
        final lastBalanceAfter = ((lastBalanceRow.first['balance_after'] as num?) ?? 0).toDouble();
        if ((lastBalanceAfter - ledgerBalance).abs() > 0.0000001) {
          findings.add(
            LedgerBalanceFinding(
              entityId: entityId,
              entityType: 'customer',
              issueType: 'balance_after_mismatch',
              severity: LedgerIssueSeverity.p1,
              ledgerBalance: ledgerBalance,
              difference: (lastBalanceAfter - ledgerBalance).abs(),
              legacyCurrentBalance: legacyCurrentBalance,
              masterOpeningBalance: masterOpeningBalance,
              openingLedgerCount: openingCount,
              recordedBalanceAfter: lastBalanceAfter,
              expectedBalanceAfter: ledgerBalance,
              details: 'customer_ledger final balance_after diverges from the cumulative ledger sum',
            ),
          );
        }
      }
    }

    return findings;
  }

  Future<List<LedgerBalanceFinding>> reconcileSuppliers({Object? database}) async {
    final db = database ?? PersistenceInitializer.persistenceManager?.sqliteManager;
    if (db == null) return const [];

    final rows = await _query(db, 'suppliers', orderBy: 'name COLLATE NOCASE ASC');
    final findings = <LedgerBalanceFinding>[];

    for (final row in rows) {
      final entityId = (row['id'] as String?) ?? '';
      final ledgerRows = await _query(
        db,
        'supplier_ledger',
        columns: ['SUM(amount) AS total', 'COUNT(*) AS entry_count'],
        where: 'supplier_id = ?',
        whereArgs: [entityId],
      );
      final ledgerBalance = ledgerRows.isNotEmpty
          ? ((ledgerRows.first['total'] as num?) ?? 0).toDouble()
          : 0.0;
      final legacyCurrentBalance = ((row['current_balance'] as num?) ?? 0).toDouble();
      final masterOpeningBalance = ((row['opening_balance'] as num?) ?? 0).toDouble();
      final openingLedgerCount = await _rawQuery(
        db,
        'SELECT COUNT(*) AS count FROM supplier_ledger WHERE supplier_id = ? AND entry_type = ?',
        [entityId, 'opening_balance'],
      );
      final openingCount = ((openingLedgerCount.first['count'] as num?) ?? 0).toInt();

      if ((legacyCurrentBalance - ledgerBalance).abs() > 0.0000001) {
        final difference = (legacyCurrentBalance - ledgerBalance).abs();
        findings.add(
          LedgerBalanceFinding(
            entityId: entityId,
            entityType: 'supplier',
            issueType: 'legacy_current_balance_divergence',
            severity: LedgerIssueSeverity.p1,
            ledgerBalance: ledgerBalance,
            difference: difference,
            legacyCurrentBalance: legacyCurrentBalance,
            masterOpeningBalance: masterOpeningBalance,
            openingLedgerCount: openingCount,
            details: 'suppliers.current_balance does not match SUM(supplier_ledger.amount)',
          ),
        );
      }

      if (masterOpeningBalance != 0.0 && openingCount != 1) {
        final difference = openingCount == 0
            ? masterOpeningBalance.abs()
            : (openingCount - 1).abs() * masterOpeningBalance.abs();
        findings.add(
          LedgerBalanceFinding(
            entityId: entityId,
            entityType: 'supplier',
            issueType: openingCount == 0
                ? 'missing_opening_ledger_entry'
                : 'duplicate_opening_ledger_entries',
            severity: openingCount == 0 ? LedgerIssueSeverity.p2 : LedgerIssueSeverity.p1,
            ledgerBalance: ledgerBalance,
            difference: difference,
            legacyCurrentBalance: legacyCurrentBalance,
            masterOpeningBalance: masterOpeningBalance,
            openingLedgerCount: openingCount,
            details: openingCount == 0
                ? 'master opening_balance is set but no opening_balance ledger row exists'
                : 'master opening_balance is set but opening_balance ledger rows are duplicated',
          ),
        );
      } else if (masterOpeningBalance == 0.0 && openingCount > 0) {
        findings.add(
          LedgerBalanceFinding(
            entityId: entityId,
            entityType: 'supplier',
            issueType: 'opening_entry_without_master_balance',
            severity: LedgerIssueSeverity.p2,
            ledgerBalance: ledgerBalance,
            difference: 0.0,
            legacyCurrentBalance: legacyCurrentBalance,
            masterOpeningBalance: masterOpeningBalance,
            openingLedgerCount: openingCount,
            details: 'opening_balance ledger row exists while master opening_balance is zero',
          ),
        );
      }

      final lastBalanceRow = await _query(
        db,
        'supplier_ledger',
        where: 'supplier_id = ?',
        whereArgs: [entityId],
        orderBy: 'created_at DESC',
        limit: 1,
      );
      if (lastBalanceRow.isNotEmpty) {
        final lastBalanceAfter = ((lastBalanceRow.first['balance_after'] as num?) ?? 0).toDouble();
        if ((lastBalanceAfter - ledgerBalance).abs() > 0.0000001) {
          findings.add(
            LedgerBalanceFinding(
              entityId: entityId,
              entityType: 'supplier',
              issueType: 'balance_after_mismatch',
              severity: LedgerIssueSeverity.p1,
              ledgerBalance: ledgerBalance,
              difference: (lastBalanceAfter - ledgerBalance).abs(),
              legacyCurrentBalance: legacyCurrentBalance,
              masterOpeningBalance: masterOpeningBalance,
              openingLedgerCount: openingCount,
              recordedBalanceAfter: lastBalanceAfter,
              expectedBalanceAfter: ledgerBalance,
              details: 'supplier_ledger final balance_after diverges from the cumulative ledger sum',
            ),
          );
        }
      }
    }

    return findings;
  }

  Future<List<LedgerBalanceFinding>> reconcileAll({Object? database}) async {
    final findings = <LedgerBalanceFinding>[];
    findings.addAll(await reconcileCustomers(database: database));
    findings.addAll(await reconcileSuppliers(database: database));
    return findings;
  }
}
