import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:bayaa_pos/core/data/services/sqlite_manager.dart';
import 'package:bayaa_pos/core/services/compatibility_repair_service.dart';
import 'package:bayaa_pos/core/services/ledger_reconciliation_service.dart';
import 'package:bayaa_pos/core/services/repair_preview_service.dart';
import 'package:bayaa_pos/features/auth/data/models/user_model.dart';

Future<Database> _openCompatibilityRepairDatabase() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  final tempDir = await Directory.systemTemp.createTemp('bayaa_compatibility_');
  final dbPath = p.join(tempDir.path, 'compatibility_repair.db');
  final manager = SQLiteManager(databasePath: dbPath);
  await manager.initialize();
  return await openDatabase(dbPath);
}

Future<RepairPreviewAction> _customerPreview(Database db, String customerId) async {
  final findings = await const LedgerReconciliationService().reconcileCustomers(database: db);
  final preview = const RepairPreviewService().previewForFindings(findings)
      .firstWhere((entry) => entry.entityId == customerId);
  return preview;
}

Future<RepairPreviewAction> _supplierPreview(Database db, String supplierId) async {
  final findings = await const LedgerReconciliationService().reconcileSuppliers(database: db);
  final preview = const RepairPreviewService().previewForFindings(findings)
      .firstWhere((entry) => entry.entityId == supplierId);
  return preview;
}

User _makeUser({required UserType userType, String name = 'Tester'}) => User(
      username: userType.name,
      name: name,
      phone: '0000000000',
      userType: userType,
      password: 'pw',
      permissions: const {},
    );

void main() {
  group('compatibility repair service', () {
    test('admin successful customer repair', () async {
      final db = await _openCompatibilityRepairDatabase();
      addTearDown(() async => db.close());

      await db.insert('customers', {
        'id': 'cust-repair-success',
        'code': 'CUS-REPAIR',
        'name': 'Customer Repair',
        'credit_limit': 0.0,
        'opening_balance': 1000.0,
        'current_balance': 500.0,
        'is_active': 1,
        'created_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      });
      await db.insert('customer_ledger', {
        'id': 'cust-opening',
        'customer_id': 'cust-repair-success',
        'entry_type': 'opening_balance',
        'amount': 1000.0,
        'balance_after': 1000.0,
        'reference_type': 'customer',
        'reference_id': 'cust-repair-success',
        'notes': 'Opening balance',
        'created_at': DateTime.now().toIso8601String(),
      });
      await db.insert('customer_ledger', {
        'id': 'cust-sale',
        'customer_id': 'cust-repair-success',
        'entry_type': 'sale',
        'amount': 200.0,
        'balance_after': 1200.0,
        'reference_type': 'sale',
        'reference_id': 'sale-1',
        'notes': 'sale',
        'created_at': DateTime.now().add(const Duration(minutes: 1)).toIso8601String(),
      });

      final preview = await _customerPreview(db, 'cust-repair-success');
      final result = await LegacyCompatibilityRepairService(
        backupValidator: (_) async => true,
      ).executeApprovedRepair(
        preview: preview,
        actor: _makeUser(userType: UserType.admin),
        database: db,
        backupId: 'backup-001',
      );

      expect(result.success, isTrue);
      expect(result.status, 'SUCCESS');
      final customerRow = await db.query('customers', where: 'id = ?', whereArgs: ['cust-repair-success']);
      expect((customerRow.first['current_balance'] as num).toDouble(), 1200.0);
      final ledgerTotal = (await db.rawQuery(
        'SELECT SUM(amount) AS total FROM customer_ledger WHERE customer_id = ?',
        ['cust-repair-success'],
      )).first['total'] as num;
      expect(ledgerTotal, 1200.0);
      final ledgerCount = (await db.rawQuery('SELECT COUNT(*) AS count FROM customer_ledger WHERE customer_id = ?', ['cust-repair-success'])).first['count'] as int;
      expect(ledgerCount, 2);
      final findingsAfter = await const LedgerReconciliationService().reconcileCustomers(database: db);
      expect(findingsAfter, isEmpty);
    });

    test('admin successful supplier repair', () async {
      final db = await _openCompatibilityRepairDatabase();
      addTearDown(() async => db.close());

      await db.insert('suppliers', {
        'id': 'sup-repair-success',
        'code': 'SUP-REPAIR',
        'name': 'Supplier Repair',
        'credit_limit': 0.0,
        'opening_balance': 2000.0,
        'current_balance': 75.0,
        'is_active': 1,
        'created_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      });
      await db.insert('supplier_ledger', {
        'id': 'sup-opening',
        'supplier_id': 'sup-repair-success',
        'entry_type': 'opening_balance',
        'amount': 2000.0,
        'balance_after': 2000.0,
        'reference_type': 'supplier',
        'reference_id': 'sup-repair-success',
        'notes': 'Opening balance',
        'created_at': DateTime.now().toIso8601String(),
      });
      await db.insert('supplier_ledger', {
        'id': 'sup-purchase',
        'supplier_id': 'sup-repair-success',
        'entry_type': 'purchase',
        'amount': 500.0,
        'balance_after': 2500.0,
        'reference_type': 'purchase',
        'reference_id': 'purchase-1',
        'notes': 'purchase',
        'created_at': DateTime.now().add(const Duration(minutes: 1)).toIso8601String(),
      });

      final preview = await _supplierPreview(db, 'sup-repair-success');
      final result = await LegacyCompatibilityRepairService(
        backupValidator: (_) async => true,
      ).executeApprovedRepair(
        preview: preview,
        actor: _makeUser(userType: UserType.admin),
        database: db,
        backupId: 'backup-002',
      );

      expect(result.success, isTrue);
      final supplierRow = await db.query('suppliers', where: 'id = ?', whereArgs: ['sup-repair-success']);
      expect((supplierRow.first['current_balance'] as num).toDouble(), 2500.0);
      final ledgerTotal = (await db.rawQuery(
        'SELECT SUM(amount) AS total FROM supplier_ledger WHERE supplier_id = ?',
        ['sup-repair-success'],
      )).first['total'] as num;
      expect(ledgerTotal, 2500.0);
      final findingsAfter = await const LedgerReconciliationService().reconcileSuppliers(database: db);
      expect(findingsAfter, isEmpty);
    });

    test('cashier denied', () async {
      final db = await _openCompatibilityRepairDatabase();
      addTearDown(() async => db.close());
      await db.insert('customers', {'id': 'cust-cashier', 'code': 'CUS-CASH', 'name': 'Cashier', 'credit_limit': 0.0, 'opening_balance': 1000.0, 'current_balance': 500.0, 'is_active': 1, 'created_at': DateTime.now().toIso8601String(), 'updated_at': DateTime.now().toIso8601String()});
      await db.insert('customer_ledger', {'id': 'cust-cashier-opening', 'customer_id': 'cust-cashier', 'entry_type': 'opening_balance', 'amount': 1000.0, 'balance_after': 1000.0, 'reference_type': 'customer', 'reference_id': 'cust-cashier', 'notes': 'opening', 'created_at': DateTime.now().toIso8601String()});
      await db.insert('customer_ledger', {'id': 'cust-cashier-sale', 'customer_id': 'cust-cashier', 'entry_type': 'sale', 'amount': 200.0, 'balance_after': 1200.0, 'reference_type': 'sale', 'reference_id': 'sale-cashier', 'notes': 'sale', 'created_at': DateTime.now().add(const Duration(minutes: 1)).toIso8601String()});

      final preview = await _customerPreview(db, 'cust-cashier');
      final result = await LegacyCompatibilityRepairService(backupValidator: (_) async => true).executeApprovedRepair(
        preview: preview,
        actor: _makeUser(userType: UserType.cashier),
        database: db,
        backupId: 'backup-003',
      );

      expect(result.success, isFalse);
      expect(result.status, 'DENIED');
      final current = (await db.query('customers', where: 'id = ?', whereArgs: ['cust-cashier'])).first['current_balance'] as num;
      expect(current, 500.0);
    });

    test('manager denied execution', () async {
      final db = await _openCompatibilityRepairDatabase();
      addTearDown(() async => db.close());
      await db.insert('customers', {'id': 'cust-manager', 'code': 'CUS-MANAGER', 'name': 'Manager', 'credit_limit': 0.0, 'opening_balance': 1000.0, 'current_balance': 500.0, 'is_active': 1, 'created_at': DateTime.now().toIso8601String(), 'updated_at': DateTime.now().toIso8601String()});
      await db.insert('customer_ledger', {'id': 'cust-manager-opening', 'customer_id': 'cust-manager', 'entry_type': 'opening_balance', 'amount': 1000.0, 'balance_after': 1000.0, 'reference_type': 'customer', 'reference_id': 'cust-manager', 'notes': 'opening', 'created_at': DateTime.now().toIso8601String()});
      await db.insert('customer_ledger', {'id': 'cust-manager-sale', 'customer_id': 'cust-manager', 'entry_type': 'sale', 'amount': 200.0, 'balance_after': 1200.0, 'reference_type': 'sale', 'reference_id': 'sale-manager', 'notes': 'sale', 'created_at': DateTime.now().add(const Duration(minutes: 1)).toIso8601String()});

      final preview = await _customerPreview(db, 'cust-manager');
      final result = await LegacyCompatibilityRepairService(backupValidator: (_) async => true).executeApprovedRepair(
        preview: preview,
        actor: _makeUser(userType: UserType.manager),
        database: db,
        backupId: 'backup-004',
      );

      expect(result.success, isFalse);
      expect(result.status, 'DENIED');
    });

    test('stale preview rejected', () async {
      final db = await _openCompatibilityRepairDatabase();
      addTearDown(() async => db.close());
      await db.insert('customers', {'id': 'cust-stale', 'code': 'CUS-STALE', 'name': 'Stale', 'credit_limit': 0.0, 'opening_balance': 1000.0, 'current_balance': 500.0, 'is_active': 1, 'created_at': DateTime.now().toIso8601String(), 'updated_at': DateTime.now().toIso8601String()});
      await db.insert('customer_ledger', {'id': 'cust-stale-opening', 'customer_id': 'cust-stale', 'entry_type': 'opening_balance', 'amount': 1000.0, 'balance_after': 1000.0, 'reference_type': 'customer', 'reference_id': 'cust-stale', 'notes': 'opening', 'created_at': DateTime.now().toIso8601String()});
      await db.insert('customer_ledger', {'id': 'cust-stale-sale', 'customer_id': 'cust-stale', 'entry_type': 'sale', 'amount': 200.0, 'balance_after': 1200.0, 'reference_type': 'sale', 'reference_id': 'sale-stale', 'notes': 'sale', 'created_at': DateTime.now().add(const Duration(minutes: 1)).toIso8601String()});

      final preview = await _customerPreview(db, 'cust-stale');
      await db.update('customers', {'current_balance': 700.0}, where: 'id = ?', whereArgs: ['cust-stale']);
      final result = await LegacyCompatibilityRepairService(backupValidator: (_) async => true).executeApprovedRepair(
        preview: preview,
        actor: _makeUser(userType: UserType.admin),
        database: db,
        backupId: 'backup-005',
      );

      expect(result.success, isFalse);
      expect(result.status, 'STALE_PREVIEW');
      final current = (await db.query('customers', where: 'id = ?', whereArgs: ['cust-stale'])).first['current_balance'] as num;
      expect(current, 700.0);
    });

    test('backup failure blocks repair', () async {
      final db = await _openCompatibilityRepairDatabase();
      addTearDown(() async => db.close());
      await db.insert('customers', {'id': 'cust-backup', 'code': 'CUS-BACKUP', 'name': 'Backup', 'credit_limit': 0.0, 'opening_balance': 1000.0, 'current_balance': 500.0, 'is_active': 1, 'created_at': DateTime.now().toIso8601String(), 'updated_at': DateTime.now().toIso8601String()});
      await db.insert('customer_ledger', {'id': 'cust-backup-opening', 'customer_id': 'cust-backup', 'entry_type': 'opening_balance', 'amount': 1000.0, 'balance_after': 1000.0, 'reference_type': 'customer', 'reference_id': 'cust-backup', 'notes': 'opening', 'created_at': DateTime.now().toIso8601String()});
      await db.insert('customer_ledger', {'id': 'cust-backup-sale', 'customer_id': 'cust-backup', 'entry_type': 'sale', 'amount': 200.0, 'balance_after': 1200.0, 'reference_type': 'sale', 'reference_id': 'sale-backup', 'notes': 'sale', 'created_at': DateTime.now().add(const Duration(minutes: 1)).toIso8601String()});

      final preview = await _customerPreview(db, 'cust-backup');
      final result = await LegacyCompatibilityRepairService(backupValidator: (_) async => false).executeApprovedRepair(
        preview: preview,
        actor: _makeUser(userType: UserType.admin),
        database: db,
        backupId: 'backup-invalid',
      );

      expect(result.success, isFalse);
      expect(result.status, 'BACKUP_REJECTED');
      final current = (await db.query('customers', where: 'id = ?', whereArgs: ['cust-backup'])).first['current_balance'] as num;
      expect(current, 500.0);
    });

    test('repeated execution is idempotent and single audit record', () async {
      final db = await _openCompatibilityRepairDatabase();
      addTearDown(() async => db.close());
      await db.insert('customers', {'id': 'cust-repeat', 'code': 'CUS-REPEAT', 'name': 'Repeat', 'credit_limit': 0.0, 'opening_balance': 1000.0, 'current_balance': 500.0, 'is_active': 1, 'created_at': DateTime.now().toIso8601String(), 'updated_at': DateTime.now().toIso8601String()});
      await db.insert('customer_ledger', {'id': 'cust-repeat-opening', 'customer_id': 'cust-repeat', 'entry_type': 'opening_balance', 'amount': 1000.0, 'balance_after': 1000.0, 'reference_type': 'customer', 'reference_id': 'cust-repeat', 'notes': 'opening', 'created_at': DateTime.now().toIso8601String()});
      await db.insert('customer_ledger', {'id': 'cust-repeat-sale', 'customer_id': 'cust-repeat', 'entry_type': 'sale', 'amount': 200.0, 'balance_after': 1200.0, 'reference_type': 'sale', 'reference_id': 'sale-repeat', 'notes': 'sale', 'created_at': DateTime.now().add(const Duration(minutes: 1)).toIso8601String()});

      final preview = await _customerPreview(db, 'cust-repeat');
      final service = LegacyCompatibilityRepairService(backupValidator: (_) async => true);
      final first = await service.executeApprovedRepair(preview: preview, actor: _makeUser(userType: UserType.admin), database: db, backupId: 'backup-repeat');
      final second = await service.executeApprovedRepair(preview: preview, actor: _makeUser(userType: UserType.admin), database: db, backupId: 'backup-repeat');

      expect(first.success, isTrue);
      expect(second.success, isTrue);
      expect(second.status, 'ALREADY_APPLIED');
      final auditRows = await db.query('activity_logs', where: 'event_key = ?', whereArgs: ['compatibility_repair']);
      expect(auditRows.length, 1);
    });
  });
}
