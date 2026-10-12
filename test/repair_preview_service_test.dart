import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:bayaa_pos/core/services/ledger_reconciliation_service.dart';
import 'package:bayaa_pos/core/services/repair_preview_service.dart';
import 'package:bayaa_pos/core/data/services/sqlite_manager.dart';

Future<Database> _openRepairPreviewDatabase() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  final tempDir = await Directory.systemTemp.createTemp('bayaa_repair_preview_');
  final dbPath = p.join(tempDir.path, 'repair_preview.db');
  final manager = SQLiteManager(databasePath: dbPath);
  await manager.initialize();
  return await openDatabase(dbPath);
}

void main() {
  group('repair preview service', () {
    test('clean customer produces no finding and no preview action', () async {
      final db = await _openRepairPreviewDatabase();
      addTearDown(() async => db.close());

      await db.insert('customers', {
        'id': 'cust-clean',
        'code': 'CUS-CLEAN',
        'name': 'Clean Customer',
        'credit_limit': 0.0,
        'opening_balance': 1000.0,
        'current_balance': 1200.0,
        'is_active': 1,
        'created_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      });
      await db.insert('customer_ledger', {
        'id': 'cust-opening',
        'customer_id': 'cust-clean',
        'entry_type': 'opening_balance',
        'amount': 1000.0,
        'balance_after': 1000.0,
        'reference_type': 'customer',
        'reference_id': 'cust-clean',
        'notes': 'Opening balance',
        'created_at': DateTime.now().toIso8601String(),
      });
      await db.insert('customer_ledger', {
        'id': 'cust-sale',
        'customer_id': 'cust-clean',
        'entry_type': 'sale',
        'amount': 500.0,
        'balance_after': 1500.0,
        'reference_type': 'sale',
        'reference_id': 'sale-1',
        'notes': 'sale',
        'created_at': DateTime.now().add(const Duration(minutes: 1)).toIso8601String(),
      });
      await db.insert('customer_ledger', {
        'id': 'cust-payment',
        'customer_id': 'cust-clean',
        'entry_type': 'customer_payment',
        'amount': -200.0,
        'balance_after': 1300.0,
        'reference_type': 'customer_payment',
        'reference_id': 'pay-1',
        'notes': 'payment',
        'created_at': DateTime.now().add(const Duration(minutes: 2)).toIso8601String(),
      });
      await db.insert('customer_ledger', {
        'id': 'cust-refund',
        'customer_id': 'cust-clean',
        'entry_type': 'refund',
        'amount': -100.0,
        'balance_after': 1200.0,
        'reference_type': 'refund',
        'reference_id': 'refund-1',
        'notes': 'refund',
        'created_at': DateTime.now().add(const Duration(minutes: 3)).toIso8601String(),
      });

      final findings = await const LedgerReconciliationService().reconcileCustomers(database: db);
      expect(findings, isEmpty);

      final preview = const RepairPreviewService().previewForFindings(findings);
      expect(preview, isEmpty);
    });

    test('customer current_balance divergence yields P1 preview without mutation', () async {
      final db = await _openRepairPreviewDatabase();
      addTearDown(() async => db.close());

      await db.insert('customers', {
        'id': 'cust-divergent',
        'code': 'CUS-DIV',
        'name': 'Divergent Customer',
        'credit_limit': 0.0,
        'opening_balance': 1000.0,
        'current_balance': 500.0,
        'is_active': 1,
        'created_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      });
      await db.insert('customer_ledger', {
        'id': 'cust-opening',
        'customer_id': 'cust-divergent',
        'entry_type': 'opening_balance',
        'amount': 1000.0,
        'balance_after': 1000.0,
        'reference_type': 'customer',
        'reference_id': 'cust-divergent',
        'notes': 'Opening balance',
        'created_at': DateTime.now().toIso8601String(),
      });
      await db.insert('customer_ledger', {
        'id': 'cust-sale',
        'customer_id': 'cust-divergent',
        'entry_type': 'sale',
        'amount': 200.0,
        'balance_after': 1200.0,
        'reference_type': 'sale',
        'reference_id': 'sale-div',
        'notes': 'sale',
        'created_at': DateTime.now().add(const Duration(minutes: 1)).toIso8601String(),
      });

      final findings = await const LedgerReconciliationService().reconcileCustomers(database: db);
      final preview = const RepairPreviewService().previewForFindings(findings);

      expect(preview, hasLength(1));
      expect(preview.first.findingType, 'legacy_current_balance_divergence');
      expect(preview.first.requiresAdminApproval, isTrue);
      expect(preview.first.severity, LedgerIssueSeverity.p1);
      expect(preview.first.after, 'MANUAL REVIEW REQUIRED');

      final customerRows = await db.query('customers', where: 'id = ?', whereArgs: ['cust-divergent']);
      expect(customerRows.first['current_balance'], 500.0);
    });

    test('supplier current_balance divergence yields P1 preview without mutation', () async {
      final db = await _openRepairPreviewDatabase();
      addTearDown(() async => db.close());

      await db.insert('suppliers', {
        'id': 'sup-divergent',
        'code': 'SUP-DIV',
        'name': 'Divergent Supplier',
        'credit_limit': 0.0,
        'opening_balance': 2000.0,
        'current_balance': 75.0,
        'is_active': 1,
        'created_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      });
      await db.insert('supplier_ledger', {
        'id': 'sup-opening',
        'supplier_id': 'sup-divergent',
        'entry_type': 'opening_balance',
        'amount': 2000.0,
        'balance_after': 2000.0,
        'reference_type': 'supplier',
        'reference_id': 'sup-divergent',
        'notes': 'Opening balance',
        'created_at': DateTime.now().toIso8601String(),
      });
      await db.insert('supplier_ledger', {
        'id': 'sup-purchase',
        'supplier_id': 'sup-divergent',
        'entry_type': 'purchase',
        'amount': 500.0,
        'balance_after': 2500.0,
        'reference_type': 'purchase',
        'reference_id': 'purchase-div',
        'notes': 'purchase',
        'created_at': DateTime.now().add(const Duration(minutes: 1)).toIso8601String(),
      });

      final findings = await const LedgerReconciliationService().reconcileSuppliers(database: db);
      final preview = const RepairPreviewService().previewForFindings(findings);

      expect(preview, hasLength(1));
      expect(preview.first.findingType, 'legacy_current_balance_divergence');
      expect(preview.first.requiresAdminApproval, isTrue);
      expect(preview.first.severity, LedgerIssueSeverity.p1);
      expect(preview.first.after, 'MANUAL REVIEW REQUIRED');

      final supplierRow = await db.query('suppliers', where: 'id = ?', whereArgs: ['sup-divergent']);
      expect(supplierRow.first['current_balance'], 75.0);
    });

    test('missing opening ledger produces manual review preview without mutation', () async {
      final db = await _openRepairPreviewDatabase();
      addTearDown(() async => db.close());

      await db.insert('customers', {
        'id': 'cust-missing',
        'code': 'CUS-MISS',
        'name': 'Missing Opening',
        'credit_limit': 0.0,
        'opening_balance': 1000.0,
        'current_balance': 0.0,
        'is_active': 1,
        'created_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      });
      await db.insert('customer_ledger', {
        'id': 'cust-missing-sale',
        'customer_id': 'cust-missing',
        'entry_type': 'sale',
        'amount': 300.0,
        'balance_after': 300.0,
        'reference_type': 'sale',
        'reference_id': 'sale-miss',
        'notes': 'sale',
        'created_at': DateTime.now().toIso8601String(),
      });

      final findings = await const LedgerReconciliationService().reconcileCustomers(database: db);
      final preview = const RepairPreviewService().previewForFindings(findings);

      expect(preview.any((entry) => entry.findingType == 'missing_opening_ledger_entry'), isTrue);
      expect(preview.first.requiresAdminApproval, isTrue);
      expect(preview.first.after, 'MANUAL REVIEW REQUIRED');

      final rowCount = await db.query('customer_ledger', where: 'customer_id = ?', whereArgs: ['cust-missing']);
      expect(rowCount, hasLength(1));
      final customerRow = await db.query('customers', where: 'id = ?', whereArgs: ['cust-missing']);
      expect(customerRow.first['opening_balance'], 1000.0);
    });

    test('duplicate opening ledger produces manual review preview without deletion', () async {
      final db = await _openRepairPreviewDatabase();
      addTearDown(() async => db.close());

      await db.insert('suppliers', {
        'id': 'sup-duplicate',
        'code': 'SUP-DUP',
        'name': 'Duplicate Opening Supplier',
        'credit_limit': 0.0,
        'opening_balance': 2000.0,
        'current_balance': 0.0,
        'is_active': 1,
        'created_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      });
      for (final id in ['sup-dup-a', 'sup-dup-b']) {
        await db.insert('supplier_ledger', {
          'id': id,
          'supplier_id': 'sup-duplicate',
          'entry_type': 'opening_balance',
          'amount': 1000.0,
          'balance_after': 1000.0,
          'reference_type': 'supplier',
          'reference_id': 'sup-duplicate',
          'notes': 'Opening balance',
          'created_at': DateTime.now().toIso8601String(),
        });
      }

      final findings = await const LedgerReconciliationService().reconcileSuppliers(database: db);
      final preview = const RepairPreviewService().previewForFindings(findings);

      expect(preview.any((entry) => entry.findingType == 'duplicate_opening_ledger_entries'), isTrue);
      expect(preview.first.requiresAdminApproval, isTrue);
      expect(preview.first.after, 'MANUAL REVIEW REQUIRED');

      final ledgerRows = await db.query('supplier_ledger', where: 'supplier_id = ?', whereArgs: ['sup-duplicate']);
      expect(ledgerRows, hasLength(2));
    });

    test('opening entry without master field yields P2 preview', () async {
      final db = await _openRepairPreviewDatabase();
      addTearDown(() async => db.close());

      await db.insert('customers', {
        'id': 'cust-open-no-master',
        'code': 'CUS-NOMASTER',
        'name': 'No Master Opening',
        'credit_limit': 0.0,
        'opening_balance': 0.0,
        'current_balance': 0.0,
        'is_active': 1,
        'created_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      });
      await db.insert('customer_ledger', {
        'id': 'cust-open-row',
        'customer_id': 'cust-open-no-master',
        'entry_type': 'opening_balance',
        'amount': 1000.0,
        'balance_after': 1000.0,
        'reference_type': 'customer',
        'reference_id': 'cust-open-no-master',
        'notes': 'Opening balance',
        'created_at': DateTime.now().toIso8601String(),
      });

      final findings = await const LedgerReconciliationService().reconcileCustomers(database: db);
      final preview = const RepairPreviewService().previewForFindings(findings);
      final openingMismatch = preview.firstWhere(
        (entry) => entry.findingType == 'opening_entry_without_master_balance',
      );

      expect(openingMismatch.severity, LedgerIssueSeverity.p2);
      expect(openingMismatch.requiresAdminApproval, isTrue);
      expect(openingMismatch.after, 'MANUAL REVIEW REQUIRED');
    });

    test('balance_after mismatch produces manual review preview without mutation', () async {
      final db = await _openRepairPreviewDatabase();
      addTearDown(() async => db.close());

      await db.insert('customers', {
        'id': 'cust-bal-mismatch',
        'code': 'CUS-BAL',
        'name': 'Balance Mismatch',
        'credit_limit': 0.0,
        'opening_balance': 0.0,
        'current_balance': 0.0,
        'is_active': 1,
        'created_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      });
      await db.insert('customer_ledger', {
        'id': 'cust-bal-open',
        'customer_id': 'cust-bal-mismatch',
        'entry_type': 'opening_balance',
        'amount': 1000.0,
        'balance_after': 500.0,
        'reference_type': 'customer',
        'reference_id': 'cust-bal-mismatch',
        'notes': 'Opening balance',
        'created_at': DateTime.now().toIso8601String(),
      });
      await db.insert('customer_ledger', {
        'id': 'cust-bal-sale',
        'customer_id': 'cust-bal-mismatch',
        'entry_type': 'sale',
        'amount': 500.0,
        'balance_after': 800.0,
        'reference_type': 'sale',
        'reference_id': 'sale-bal',
        'notes': 'sale',
        'created_at': DateTime.now().add(const Duration(minutes: 1)).toIso8601String(),
      });

      final findings = await const LedgerReconciliationService().reconcileCustomers(database: db);
      final preview = const RepairPreviewService().previewForFindings(findings);

      expect(preview.any((entry) => entry.findingType == 'balance_after_mismatch'), isTrue);
      expect(preview.first.requiresAdminApproval, isTrue);
      expect(preview.first.after, 'MANUAL REVIEW REQUIRED');

      final rows = await db.query('customer_ledger', where: 'customer_id = ?', whereArgs: ['cust-bal-mismatch']);
      expect(rows, hasLength(2));
      final total = (await db.rawQuery(
        'SELECT SUM(amount) AS total FROM customer_ledger WHERE customer_id = ?',
        ['cust-bal-mismatch'],
      )).first['total'] as num;
      expect(total, 1500.0);
    });

    test('preview does not modify database for any finding type', () async {
      final db = await _openRepairPreviewDatabase();
      addTearDown(() async => db.close());

      await db.insert('customers', {
        'id': 'cust-preview-safety',
        'code': 'CUS-SAFE',
        'name': 'Safety Customer',
        'credit_limit': 0.0,
        'opening_balance': 1000.0,
        'current_balance': 500.0,
        'is_active': 1,
        'created_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      });
      await db.insert('customer_ledger', {
        'id': 'cust-safe-opening',
        'customer_id': 'cust-preview-safety',
        'entry_type': 'opening_balance',
        'amount': 1000.0,
        'balance_after': 1000.0,
        'reference_type': 'customer',
        'reference_id': 'cust-preview-safety',
        'notes': 'Opening balance',
        'created_at': DateTime.now().toIso8601String(),
      });
      await db.insert('customer_ledger', {
        'id': 'cust-safe-sale',
        'customer_id': 'cust-preview-safety',
        'entry_type': 'sale',
        'amount': 200.0,
        'balance_after': 1200.0,
        'reference_type': 'sale',
        'reference_id': 'sale-safe',
        'notes': 'sale',
        'created_at': DateTime.now().add(const Duration(minutes: 1)).toIso8601String(),
      });

      final findings = await const LedgerReconciliationService().reconcileCustomers(database: db);
      final preview = const RepairPreviewService().previewForFindings(findings);
      expect(preview, isNotEmpty);

      final beforeCustomer = (await db.query('customers', where: 'id = ?', whereArgs: ['cust-preview-safety'])).first;
      final beforeLedger = await db.query('customer_ledger', where: 'customer_id = ?', whereArgs: ['cust-preview-safety']);
      final beforeTotal = (await db.rawQuery(
        'SELECT SUM(amount) AS total FROM customer_ledger WHERE customer_id = ?',
        ['cust-preview-safety'],
      )).first['total'] as num;

      expect(beforeCustomer['current_balance'], 500.0);
      expect(beforeCustomer['opening_balance'], 1000.0);
      expect(beforeLedger, hasLength(2));
      expect(beforeTotal, 1200.0);

      final previewAction = preview.first;
      expect(previewAction.proposedAction, isNotEmpty);
      expect(previewAction.requiresAdminApproval, isTrue);

      final afterCustomer = (await db.query('customers', where: 'id = ?', whereArgs: ['cust-preview-safety'])).first;
      final afterLedger = await db.query('customer_ledger', where: 'customer_id = ?', whereArgs: ['cust-preview-safety']);
      final afterTotal = (await db.rawQuery(
        'SELECT SUM(amount) AS total FROM customer_ledger WHERE customer_id = ?',
        ['cust-preview-safety'],
      )).first['total'] as num;

      expect(afterCustomer['current_balance'], beforeCustomer['current_balance']);
      expect(afterCustomer['opening_balance'], beforeCustomer['opening_balance']);
      expect(afterLedger, hasLength(beforeLedger.length));
      expect(afterTotal, beforeTotal);
    });
  });
}
