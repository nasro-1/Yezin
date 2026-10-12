import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../features/auth/data/models/user_model.dart';
import '../data/services/background_write_queue.dart';
import '../data/services/backup_manager.dart';
import '../data/services/persistence_initializer.dart';
import '../data/models/activity_log.dart';
import '../security/permission_guard.dart';
import 'activity_logger.dart';
import 'repair_preview_service.dart';

class CompatibilityRepairResult {
  const CompatibilityRepairResult({
    required this.success,
    required this.status,
    this.repairId,
    this.entityId,
    this.entityType,
    this.findingType,
    this.oldValue,
    this.newValue,
    this.backupId,
    this.failureReason,
    this.reconciliationBefore,
    this.reconciliationAfter,
    this.stalePreview = false,
    this.idempotent = false,
  });

  final bool success;
  final String status;
  final String? repairId;
  final String? entityId;
  final String? entityType;
  final String? findingType;
  final double? oldValue;
  final double? newValue;
  final String? backupId;
  final String? failureReason;
  final double? reconciliationBefore;
  final double? reconciliationAfter;
  final bool stalePreview;
  final bool idempotent;

  bool get wasNoOp => status == 'ALREADY_APPLIED';
}

class CompatibilityRepairService {
  const CompatibilityRepairService({
    this.backupManager,
    this.activityLogger,
    this.backupValidator,
  });

  final BackupManager? backupManager;
  final ActivityLogger? activityLogger;
  final Future<bool> Function(String? backupId)? backupValidator;

  Future<CompatibilityRepairResult> executeApprovedRepair({
    required RepairPreviewAction preview,
    required User actor,
    DatabaseExecutor? database,
    String? backupId,
    Future<bool> Function(String? backupId)? backupValidation,
  }) async {
    if (preview.findingType != 'legacy_current_balance_divergence') {
      return CompatibilityRepairResult(
        success: false,
        status: 'REJECTED',
        repairId: preview.previewId,
        entityId: preview.entityId,
        entityType: preview.entityType,
        findingType: preview.findingType,
        oldValue: preview.oldValueNumeric,
        newValue: preview.newValueNumeric,
        backupId: backupId,
        failureReason: 'Only legacy_current_balance_divergence is eligible for compatibility repair in this phase.',
      );
    }

    try {
      PermissionGuard.requireAdminHistoricalRepair(actor);
    } on PermissionDeniedException catch (error) {
      return CompatibilityRepairResult(
        success: false,
        status: 'DENIED',
        repairId: preview.previewId,
        entityId: preview.entityId,
        entityType: preview.entityType,
        findingType: preview.findingType,
        oldValue: preview.oldValueNumeric,
        newValue: preview.newValueNumeric,
        backupId: backupId,
        failureReason: error.message,
      );
    }

    final db = database ?? PersistenceInitializer.persistenceManager?.sqliteManager.database;
    if (db == null) {
      return CompatibilityRepairResult(
        success: false,
        status: 'FAILED',
        repairId: preview.previewId,
        entityId: preview.entityId,
        entityType: preview.entityType,
        findingType: preview.findingType,
        oldValue: preview.oldValueNumeric,
        newValue: preview.newValueNumeric,
        backupId: backupId,
        failureReason: 'No active database is available for compatibility repair.',
      );
    }

    final resolvedBackupId = backupId ?? 'manual_backup_validation';
    final isBackupValid = await (backupValidation ?? backupValidator ?? _defaultBackupValidator)(resolvedBackupId);
    if (!isBackupValid) {
      return CompatibilityRepairResult(
        success: false,
        status: 'BACKUP_REJECTED',
        repairId: preview.previewId,
        entityId: preview.entityId,
        entityType: preview.entityType,
        findingType: preview.findingType,
        oldValue: preview.oldValueNumeric,
        newValue: preview.newValueNumeric,
        backupId: resolvedBackupId,
        failureReason: 'Backup validation failed; repair cannot proceed.',
      );
    }

    final repairId = preview.previewId ?? preview.previewSignature ?? _stableRepairId(preview);
    final tableName = preview.entityType == 'supplier' || preview.entityType == 'suppliers'
        ? 'suppliers'
        : 'customers';
    final ledgerTable = preview.entityType == 'supplier' || preview.entityType == 'suppliers'
        ? 'supplier_ledger'
        : 'customer_ledger';

    final legacyBefore = await _readLegacyValue(db, tableName, preview.entityId);
    final ledgerBefore = await _readLedgerSum(db, ledgerTable, preview.entityId);
    final isAlreadyAppliedByValue = legacyBefore == preview.newValueNumeric && ledgerBefore == preview.currentLedgerBalance;
    final isAlreadyApplied = await _isRepairAlreadyApplied(db, repairId);
    if (isAlreadyAppliedByValue || isAlreadyApplied) {
      return CompatibilityRepairResult(
        success: true,
        status: 'ALREADY_APPLIED',
        repairId: repairId,
        entityId: preview.entityId,
        entityType: preview.entityType,
        findingType: preview.findingType,
        oldValue: preview.oldValueNumeric,
        newValue: preview.newValueNumeric,
        backupId: resolvedBackupId,
        idempotent: true,
        reconciliationBefore: ledgerBefore,
        reconciliationAfter: ledgerBefore,
      );
    }
    if (legacyBefore != preview.oldValueNumeric || ledgerBefore != preview.currentLedgerBalance) {
      return CompatibilityRepairResult(
        success: false,
        status: 'STALE_PREVIEW',
        repairId: repairId,
        entityId: preview.entityId,
        entityType: preview.entityType,
        findingType: preview.findingType,
        oldValue: preview.oldValueNumeric,
        newValue: preview.newValueNumeric,
        backupId: resolvedBackupId,
        failureReason: 'Preview is stale: the current legacy value or ledger authority no longer matches the approved preview.',
        reconciliationBefore: ledgerBefore,
        reconciliationAfter: ledgerBefore,
        stalePreview: true,
      );
    }

    bool executed = false;
    double? postReconcile;
    final oldValue = legacyBefore;
    final newValue = preview.newValueNumeric;
    try {
      await DatabaseLifecycleCoordinator.instance.withExclusiveAccess(() async {
        if (db is Database) {
          await db.transaction((txn) async {
            await txn.update(
              tableName,
              {'current_balance': newValue},
              where: 'id = ?',
              whereArgs: [preview.entityId],
            );

            final afterRow = await txn.query(
              tableName,
              columns: ['current_balance'],
              where: 'id = ?',
              whereArgs: [preview.entityId],
            );
            final updatedLegacy = (afterRow.first['current_balance'] as num).toDouble();
            final updatedLedger = await _readLedgerSumFromTransaction(txn, ledgerTable, preview.entityId);
            if ((updatedLegacy - newValue).abs() > 0.0000001 || updatedLedger != preview.currentLedgerBalance) {
              throw StateError('Post-repair reconciliation is inconsistent.');
            }
            executed = true;
            postReconcile = updatedLedger;
          });
        } else {
          await db.update(
            tableName,
            {'current_balance': newValue},
            where: 'id = ?',
            whereArgs: [preview.entityId],
          );
          final afterRow = await db.query(
            tableName,
            columns: ['current_balance'],
            where: 'id = ?',
            whereArgs: [preview.entityId],
          );
          final updatedLegacy = (afterRow.first['current_balance'] as num).toDouble();
          final updatedLedger = await _readLedgerSum(db, ledgerTable, preview.entityId);
          if ((updatedLegacy - newValue).abs() > 0.0000001 || updatedLedger != preview.currentLedgerBalance) {
            throw StateError('Post-repair reconciliation is inconsistent.');
          }
          executed = true;
          postReconcile = updatedLedger;
        }
      });
    } catch (error) {
      return CompatibilityRepairResult(
        success: false,
        status: 'ROLLED_BACK',
        repairId: repairId,
        entityId: preview.entityId,
        entityType: preview.entityType,
        findingType: preview.findingType,
        oldValue: oldValue,
        newValue: newValue,
        backupId: resolvedBackupId,
        failureReason: 'Compatibility-fix transaction failed or post-repair reconciliation did not satisfy expected state: $error',
        reconciliationBefore: ledgerBefore,
        reconciliationAfter: postReconcile,
      );
    }

    final finalLegacy = await _readLegacyValue(db, tableName, preview.entityId);
    final finalLedger = await _readLedgerSum(db, ledgerTable, preview.entityId);
    if (finalLegacy != newValue || finalLedger != preview.currentLedgerBalance) {
      return CompatibilityRepairResult(
        success: false,
        status: 'RECONCILIATION_FAILED',
        repairId: repairId,
        entityId: preview.entityId,
        entityType: preview.entityType,
        findingType: preview.findingType,
        oldValue: oldValue,
        newValue: newValue,
        backupId: resolvedBackupId,
        failureReason: 'Repair executed but the expected reconciliation state was not reached.',
        reconciliationBefore: ledgerBefore,
        reconciliationAfter: finalLedger,
      );
    }

    await db.insert('activity_logs', {
      'id': 'repair_${repairId.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_')}',
      'session_id': 'compatibility_repair',
      'timestamp': DateTime.now().toIso8601String(),
      'type': preview.entityType == 'supplier' || preview.entityType == 'suppliers'
          ? 'supplierUpdated'
          : 'customerUpdated',
      'description': 'Compatibility repair for ${preview.entityType} ${preview.entityId}',
      'user_name': actor.name,
      'details': jsonEncode({
        'repair_id': repairId,
        'entity_id': preview.entityId,
        'entity_type': preview.entityType,
        'finding_type': preview.findingType,
        'old_value': oldValue,
        'new_value': newValue,
        'reason': preview.reason,
        'backup_id': resolvedBackupId,
        'reconciliation_before': ledgerBefore,
        'reconciliation_after': finalLedger,
        'status': 'SUCCESS',
      }),
      'event_key': 'compatibility_repair',
      'parameters': jsonEncode({
        'repair_id': repairId,
        'entity_id': preview.entityId,
        'entity_type': preview.entityType,
        'finding_type': preview.findingType,
        'old_value': oldValue,
        'new_value': newValue,
        'reason': preview.reason,
        'backup_id': resolvedBackupId,
        'reconciliation_before': ledgerBefore,
        'reconciliation_after': finalLedger,
        'status': 'SUCCESS',
      }),
    });

    return CompatibilityRepairResult(
      success: true,
      status: 'SUCCESS',
      repairId: repairId,
      entityId: preview.entityId,
      entityType: preview.entityType,
      findingType: preview.findingType,
      oldValue: oldValue,
      newValue: newValue,
      backupId: resolvedBackupId,
      reconciliationBefore: ledgerBefore,
      reconciliationAfter: finalLedger,
    );
  }

  Future<CompatibilityRepairResult> executeCustomerRepair({
    required RepairPreviewAction preview,
    required User actor,
    DatabaseExecutor? database,
    String? backupId,
    Future<bool> Function(String? backupId)? backupValidation,
  }) async {
    return executeApprovedRepair(
      preview: preview,
      actor: actor,
      database: database,
      backupId: backupId,
      backupValidation: backupValidation,
    );
  }

  Future<CompatibilityRepairResult> executeSupplierRepair({
    required RepairPreviewAction preview,
    required User actor,
    DatabaseExecutor? database,
    String? backupId,
    Future<bool> Function(String? backupId)? backupValidation,
  }) async {
    return executeApprovedRepair(
      preview: preview,
      actor: actor,
      database: database,
      backupId: backupId,
      backupValidation: backupValidation,
    );
  }

  Future<bool> _defaultBackupValidator(String? backupId) async {
    if (backupManager == null) {
      return false;
    }
    if (backupId == null || backupId.isEmpty) {
      return false;
    }
    return await backupManager!.validateBackup(backupManager!.backupsPath);
  }

  String _stableRepairId(RepairPreviewAction preview) {
    final payload = [
      preview.entityType,
      preview.entityId,
      preview.findingType,
      preview.oldValueNumeric.toString(),
      preview.newValueNumeric.toString(),
      preview.currentLedgerBalance.toString(),
    ].join('|');
    return 'compatibility-${md5.convert(utf8.encode(payload)).toString()}';
  }

  Future<bool> _isRepairAlreadyApplied(DatabaseExecutor db, String repairId) async {
    final rows = await db.query(
      'activity_logs',
      columns: ['parameters'],
      where: 'event_key = ?',
      whereArgs: ['compatibility_repair'],
    );

    for (final row in rows) {
      final paramsValue = row['parameters'];
      if (paramsValue is String && paramsValue.isNotEmpty) {
        try {
          final params = jsonDecode(paramsValue) as Map<String, dynamic>;
          if (params['repair_id'] == repairId) {
            return true;
          }
        } catch (_) {
          continue;
        }
      }
    }
    return false;
  }

  Future<double> _readLegacyValue(DatabaseExecutor db, String tableName, String entityId) async {
    final rows = await db.query(
      tableName,
      columns: ['current_balance'],
      where: 'id = ?',
      whereArgs: [entityId],
      limit: 1,
    );
    if (rows.isEmpty) return 0.0;
    return ((rows.first['current_balance'] as num?) ?? 0).toDouble();
  }

  Future<double> _readLedgerSum(DatabaseExecutor db, String ledgerTable, String entityId) async {
    final rows = await db.query(
      ledgerTable,
      columns: ['SUM(amount) AS total'],
      where: '${ledgerTable == 'customer_ledger' ? 'customer_id' : 'supplier_id'} = ?',
      whereArgs: [entityId],
    );
    return ((rows.first['total'] as num?) ?? 0).toDouble();
  }

  Future<double> _readLedgerSumFromTransaction(
    DatabaseExecutor txn,
    String ledgerTable,
    String entityId,
  ) async {
    final rows = await txn.query(
      ledgerTable,
      columns: ['SUM(amount) AS total'],
      where: '${ledgerTable == 'customer_ledger' ? 'customer_id' : 'supplier_id'} = ?',
      whereArgs: [entityId],
    );
    return ((rows.first['total'] as num?) ?? 0).toDouble();
  }
}

class LegacyCompatibilityRepairService extends CompatibilityRepairService {
  const LegacyCompatibilityRepairService({
    super.backupManager,
    super.activityLogger,
    super.backupValidator,
  });
}
