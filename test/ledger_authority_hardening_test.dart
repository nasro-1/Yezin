import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:bayaa_pos/core/data/services/sqlite_manager.dart';
import 'package:bayaa_pos/core/services/ledger_reconciliation_service.dart';

Future<Database> _openLedgerTestDatabase() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  final tempDir = await Directory.systemTemp.createTemp('bayaa_ledger_');
  final dbPath = p.join(tempDir.path, 'ledger_test.db');
  final manager = SQLiteManager(databasePath: dbPath);
  await manager.initialize();
  return await openDatabase(dbPath);
}

void main() {
  group('ledger authority hardening', () {
    test('customer and supplier balances derive from ledger sums', () async {
      final db = await _openLedgerTestDatabase();
      addTearDown(() async => db.close());

      await db.insert('customers', {
        'id': 'cust-ledger-auth',
        'code': 'CUS-LEDGER',
        'name': 'Ledger Customer',
        'credit_limit': 0.0,
        'opening_balance': 0.0,
        'current_balance': 300.0,
        'is_active': 1,
        'created_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      });
      await db.insert('customer_ledger', {
        'id': 'cust-sale',
        'customer_id': 'cust-ledger-auth',
        'entry_type': 'sale',
        'amount': 500.0,
        'balance_after': 500.0,
        'reference_type': 'sale',
        'reference_id': 'sale-1',
        'notes': 'Sale',
        'created_at': DateTime.now().toIso8601String(),
      });
      await db.insert('customer_ledger', {
        'id': 'cust-payment',
        'customer_id': 'cust-ledger-auth',
        'entry_type': 'customer_payment',
        'amount': -200.0,
        'balance_after': 300.0,
        'reference_type': 'customer_payment',
        'reference_id': 'payment-1',
        'notes': 'Payment',
        'created_at': DateTime.now().toIso8601String(),
      });
      await db.insert('customer_ledger', {
        'id': 'cust-refund',
        'customer_id': 'cust-ledger-auth',
        'entry_type': 'refund',
        'amount': -100.0,
        'balance_after': 200.0,
        'reference_type': 'refund',
        'reference_id': 'refund-1',
        'notes': 'Refund',
        'created_at': DateTime.now().toIso8601String(),
      });

      final customerTotal = (await db.rawQuery(
        'SELECT SUM(amount) AS total FROM customer_ledger WHERE customer_id = ?',
        ['cust-ledger-auth'],
      ))
          .first['total'] as num;
      expect(customerTotal, 200.0);
      final customerCurrent = (await db.query(
        'customers',
        columns: ['current_balance'],
        where: 'id = ?',
        whereArgs: ['cust-ledger-auth'],
      ))
          .first['current_balance'] as num;
      expect(customerCurrent, 300.0);
      expect(customerCurrent != customerTotal, isTrue);

      await db.insert('suppliers', {
        'id': 'supp-ledger-auth',
        'code': 'SUP-LEDGER',
        'name': 'Ledger Supplier',
        'credit_limit': 0.0,
        'opening_balance': 0.0,
        'current_balance': 700.0,
        'is_active': 1,
        'created_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      });
      await db.insert('supplier_ledger', {
        'id': 'supp-purchase',
        'supplier_id': 'supp-ledger-auth',
        'entry_type': 'purchase',
        'amount': 1000.0,
        'balance_after': 1000.0,
        'reference_type': 'purchase',
        'reference_id': 'purchase-1',
        'notes': 'Purchase',
        'created_at': DateTime.now().toIso8601String(),
      });
      await db.insert('supplier_ledger', {
        'id': 'supp-payment',
        'supplier_id': 'supp-ledger-auth',
        'entry_type': 'supplier_payment',
        'amount': -300.0,
        'balance_after': 700.0,
        'reference_type': 'supplier_payment',
        'reference_id': 'payment-1',
        'notes': 'Payment',
        'created_at': DateTime.now().toIso8601String(),
      });
      await db.insert('supplier_ledger', {
        'id': 'supp-return',
        'supplier_id': 'supp-ledger-auth',
        'entry_type': 'supplier_return',
        'amount': -200.0,
        'balance_after': 500.0,
        'reference_type': 'supplier_return',
        'reference_id': 'return-1',
        'notes': 'Return',
        'created_at': DateTime.now().toIso8601String(),
      });

      final supplierTotal = (await db.rawQuery(
        'SELECT SUM(amount) AS total FROM supplier_ledger WHERE supplier_id = ?',
        ['supp-ledger-auth'],
      ))
          .first['total'] as num;
      expect(supplierTotal, 500.0);
      final supplierCurrent = (await db.query(
        'suppliers',
        columns: ['current_balance'],
        where: 'id = ?',
        whereArgs: ['supp-ledger-auth'],
      ))
          .first['current_balance'] as num;
      expect(supplierCurrent, 700.0);
      expect(supplierCurrent != supplierTotal, isTrue);
    });

    test('opening balances are counted exactly once through the ledger', () async {
      final db = await _openLedgerTestDatabase();
      addTearDown(() async => db.close());

      await db.insert('customers', {
        'id': 'cust-opening-once',
        'code': 'CUS-OPEN-ONCE',
        'name': 'Opening Customer',
        'credit_limit': 0.0,
        'opening_balance': 1000.0,
        'current_balance': 999.0,
        'is_active': 1,
        'created_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      });
      await db.insert('customer_ledger', {
        'id': 'cust-opening-ledger',
        'customer_id': 'cust-opening-once',
        'entry_type': 'opening_balance',
        'amount': 1000.0,
        'balance_after': 1000.0,
        'reference_type': 'customer',
        'reference_id': 'cust-opening-once',
        'notes': 'Opening balance',
        'created_at': DateTime.now().toIso8601String(),
      });

      final customerLedgerTotal = (await db.rawQuery(
        'SELECT SUM(amount) AS total FROM customer_ledger WHERE customer_id = ?',
        ['cust-opening-once'],
      ))
          .first['total'] as num;
      expect(customerLedgerTotal, 1000.0);

      final customerLegacyField = (await db.query(
        'customers',
        columns: ['current_balance'],
        where: 'id = ?',
        whereArgs: ['cust-opening-once'],
      ))
          .first['current_balance'] as num;
      expect(customerLegacyField, 999.0);
      expect(customerLegacyField != customerLedgerTotal, isTrue);

      await db.insert('suppliers', {
        'id': 'sup-opening-once',
        'code': 'SUP-OPEN-ONCE',
        'name': 'Opening Supplier',
        'credit_limit': 0.0,
        'opening_balance': 2000.0,
        'current_balance': 123.0,
        'is_active': 1,
        'created_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      });
      await db.insert('supplier_ledger', {
        'id': 'sup-opening-ledger',
        'supplier_id': 'sup-opening-once',
        'entry_type': 'opening_balance',
        'amount': 2000.0,
        'balance_after': 2000.0,
        'reference_type': 'supplier',
        'reference_id': 'sup-opening-once',
        'notes': 'Opening balance',
        'created_at': DateTime.now().toIso8601String(),
      });

      final supplierLedgerTotal = (await db.rawQuery(
        'SELECT SUM(amount) AS total FROM supplier_ledger WHERE supplier_id = ?',
        ['sup-opening-once'],
      ))
          .first['total'] as num;
      expect(supplierLedgerTotal, 2000.0);

      final supplierLegacyField = (await db.query(
        'suppliers',
        columns: ['current_balance'],
        where: 'id = ?',
        whereArgs: ['sup-opening-once'],
      ))
          .first['current_balance'] as num;
      expect(supplierLegacyField, 123.0);
      expect(supplierLegacyField != supplierLedgerTotal, isTrue);
    });

    test('customer and supplier ledger rows reject update and delete', () async {
      final db = await _openLedgerTestDatabase();
      addTearDown(() async => db.close());

      await db.insert('customers', {
        'id': 'cust-immutable',
        'code': 'CUS-IMM',
        'name': 'Immutable Customer',
        'credit_limit': 0.0,
        'opening_balance': 0.0,
        'current_balance': 0.0,
        'is_active': 1,
        'created_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      });
      await db.insert('customer_ledger', {
        'id': 'cust-immutable-ledger',
        'customer_id': 'cust-immutable',
        'entry_type': 'sale',
        'amount': 150.0,
        'balance_after': 150.0,
        'reference_type': 'sale',
        'reference_id': 'sale-immutable',
        'notes': 'sale',
        'created_at': DateTime.now().toIso8601String(),
      });
      await db.insert('suppliers', {
        'id': 'sup-immutable',
        'code': 'SUP-IMM',
        'name': 'Immutable Supplier',
        'credit_limit': 0.0,
        'opening_balance': 0.0,
        'current_balance': 0.0,
        'is_active': 1,
        'created_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      });
      await db.insert('supplier_ledger', {
        'id': 'sup-immutable-ledger',
        'supplier_id': 'sup-immutable',
        'entry_type': 'purchase',
        'amount': 200.0,
        'balance_after': 200.0,
        'reference_type': 'purchase',
        'reference_id': 'purchase-immutable',
        'notes': 'purchase',
        'created_at': DateTime.now().toIso8601String(),
      });

      await expectLater(
        db.update(
          'customer_ledger',
          {'amount': 50.0},
          where: 'id = ?',
          whereArgs: ['cust-immutable-ledger'],
        ),
        throwsException,
      );
      await expectLater(
        db.delete(
          'customer_ledger',
          where: 'id = ?',
          whereArgs: ['cust-immutable-ledger'],
        ),
        throwsException,
      );
      await expectLater(
        db.update(
          'supplier_ledger',
          {'amount': 75.0},
          where: 'id = ?',
          whereArgs: ['sup-immutable-ledger'],
        ),
        throwsException,
      );
      await expectLater(
        db.delete(
          'supplier_ledger',
          where: 'id = ?',
          whereArgs: ['sup-immutable-ledger'],
        ),
        throwsException,
      );
    });

    test('clean customer and supplier ledgers reconcile without issues', () async {
      final db = await _openLedgerTestDatabase();
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
        'id': 'cust-clean-opening',
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
        'id': 'cust-clean-sale',
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
        'id': 'cust-clean-payment',
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
        'id': 'cust-clean-refund',
        'customer_id': 'cust-clean',
        'entry_type': 'refund',
        'amount': -100.0,
        'balance_after': 1200.0,
        'reference_type': 'refund',
        'reference_id': 'refund-1',
        'notes': 'refund',
        'created_at': DateTime.now().add(const Duration(minutes: 3)).toIso8601String(),
      });

      await db.insert('suppliers', {
        'id': 'sup-clean',
        'code': 'SUP-CLEAN',
        'name': 'Clean Supplier',
        'currency': 'EGP',
        'credit_limit': 0.0,
        'opening_balance': 2000.0,
        'current_balance': 2500.0,
        'is_active': 1,
        'created_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      });
      await db.insert('supplier_ledger', {
        'id': 'sup-clean-opening',
        'supplier_id': 'sup-clean',
        'entry_type': 'opening_balance',
        'amount': 2000.0,
        'balance_after': 2000.0,
        'reference_type': 'supplier',
        'reference_id': 'sup-clean',
        'notes': 'Opening balance',
        'created_at': DateTime.now().add(const Duration(minutes: 4)).toIso8601String(),
      });
      await db.insert('supplier_ledger', {
        'id': 'sup-clean-purchase',
        'supplier_id': 'sup-clean',
        'entry_type': 'purchase',
        'amount': 1000.0,
        'balance_after': 3000.0,
        'reference_type': 'purchase',
        'reference_id': 'purchase-1',
        'notes': 'purchase',
        'created_at': DateTime.now().add(const Duration(minutes: 5)).toIso8601String(),
      });
      await db.insert('supplier_ledger', {
        'id': 'sup-clean-payment',
        'supplier_id': 'sup-clean',
        'entry_type': 'supplier_payment',
        'amount': -300.0,
        'balance_after': 2700.0,
        'reference_type': 'supplier_payment',
        'reference_id': 'pay-1',
        'notes': 'payment',
        'created_at': DateTime.now().add(const Duration(minutes: 6)).toIso8601String(),
      });
      await db.insert('supplier_ledger', {
        'id': 'sup-clean-return',
        'supplier_id': 'sup-clean',
        'entry_type': 'supplier_return',
        'amount': -200.0,
        'balance_after': 2500.0,
        'reference_type': 'supplier_return',
        'reference_id': 'return-1',
        'notes': 'return',
        'created_at': DateTime.now().add(const Duration(minutes: 7)).toIso8601String(),
      });

      final service = const LedgerReconciliationService();
      final findings = await service.reconcileAll(database: db);
      expect(findings, isEmpty);
      final customerTotal = (await db.rawQuery(
        'SELECT SUM(amount) AS total FROM customer_ledger WHERE customer_id = ?',
        ['cust-clean'],
      )).first['total'] as num;
      final supplierTotal = (await db.rawQuery(
        'SELECT SUM(amount) AS total FROM supplier_ledger WHERE supplier_id = ?',
        ['sup-clean'],
      )).first['total'] as num;
      expect(customerTotal, 1200.0);
      expect(supplierTotal, 2500.0);
    });

    test('legacy divergence is reported as P1 without repair', () async {
      final db = await _openLedgerTestDatabase();
      addTearDown(() async => db.close());

      await db.insert('customers', {
        'id': 'cust-divergent',
        'code': 'CUS-DIV',
        'name': 'Divergent Customer',
        'credit_limit': 0.0,
        'opening_balance': 1000.0,
        'current_balance': 50.0,
        'is_active': 1,
        'created_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      });
      await db.insert('customer_ledger', {
        'id': 'cust-divergent-opening',
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
        'id': 'cust-divergent-sale',
        'customer_id': 'cust-divergent',
        'entry_type': 'sale',
        'amount': 200.0,
        'balance_after': 1200.0,
        'reference_type': 'sale',
        'reference_id': 'sale-div',
        'notes': 'sale',
        'created_at': DateTime.now().add(const Duration(minutes: 1)).toIso8601String(),
      });

      await db.insert('suppliers', {
        'id': 'sup-divergent',
        'code': 'SUP-DIV',
        'name': 'Divergent Supplier',
        'currency': 'EGP',
        'credit_limit': 0.0,
        'opening_balance': 2000.0,
        'current_balance': 75.0,
        'is_active': 1,
        'created_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      });
      await db.insert('supplier_ledger', {
        'id': 'sup-divergent-opening',
        'supplier_id': 'sup-divergent',
        'entry_type': 'opening_balance',
        'amount': 2000.0,
        'balance_after': 2000.0,
        'reference_type': 'supplier',
        'reference_id': 'sup-divergent',
        'notes': 'Opening balance',
        'created_at': DateTime.now().add(const Duration(minutes: 2)).toIso8601String(),
      });
      await db.insert('supplier_ledger', {
        'id': 'sup-divergent-purchase',
        'supplier_id': 'sup-divergent',
        'entry_type': 'purchase',
        'amount': 500.0,
        'balance_after': 2500.0,
        'reference_type': 'purchase',
        'reference_id': 'purchase-div',
        'notes': 'purchase',
        'created_at': DateTime.now().add(const Duration(minutes: 3)).toIso8601String(),
      });

      final service = const LedgerReconciliationService();
      final findings = await service.reconcileAll(database: db);
      expect(findings.where((f) => f.issueType == 'legacy_current_balance_divergence').length, 2);
      expect(findings.every((f) => f.severity == LedgerIssueSeverity.p1), isTrue);
      final customerFinding = findings.firstWhere((f) => f.entityType == 'customer');
      expect(customerFinding.legacyCurrentBalance, 50.0);
      expect(customerFinding.ledgerBalance, 1200.0);
      expect(customerFinding.difference, 1150.0);
      final supplierFinding = findings.firstWhere((f) => f.entityType == 'supplier');
      expect(supplierFinding.difference, 2425.0);
    });

    test('supplier missing and duplicate opening entries are reported without repair', () async {
      final db = await _openLedgerTestDatabase();
      addTearDown(() async => db.close());

      await db.insert('suppliers', {
        'id': 'sup-missing-opening',
        'code': 'SUP-MISS',
        'name': 'Missing Opening Supplier',
        'credit_limit': 0.0,
        'opening_balance': 2000.0,
        'current_balance': 0.0,
        'is_active': 1,
        'created_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      });
      await db.insert('supplier_ledger', {
        'id': 'sup-missing-purchase',
        'supplier_id': 'sup-missing-opening',
        'entry_type': 'purchase',
        'amount': 400.0,
        'balance_after': 400.0,
        'reference_type': 'purchase',
        'reference_id': 'purchase-miss',
        'notes': 'purchase',
        'created_at': DateTime.now().toIso8601String(),
      });

      await db.insert('suppliers', {
        'id': 'sup-duplicate-opening',
        'code': 'SUP-DUP',
        'name': 'Duplicate Opening Supplier',
        'credit_limit': 0.0,
        'opening_balance': 2000.0,
        'current_balance': 0.0,
        'is_active': 1,
        'created_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      });
      for (final id in ['sup-duplicate-opening-a', 'sup-duplicate-opening-b']) {
        await db.insert('supplier_ledger', {
          'id': id,
          'supplier_id': 'sup-duplicate-opening',
          'entry_type': 'opening_balance',
          'amount': 1000.0,
          'balance_after': 1000.0,
          'reference_type': 'supplier',
          'reference_id': 'sup-duplicate-opening',
          'notes': 'Opening balance',
          'created_at': DateTime.now().toIso8601String(),
        });
      }

      final service = const LedgerReconciliationService();
      final findings = await service.reconcileSuppliers(database: db);
      expect(findings.any((f) => f.issueType == 'missing_opening_ledger_entry'), isTrue);
      expect(findings.any((f) => f.issueType == 'duplicate_opening_ledger_entries'), isTrue);
      expect(findings.where((f) => f.entityType == 'supplier').every((f) => f.difference >= 0.0), isTrue);
    });

    test('missing and duplicate opening entries are reported without repair', () async {
      final db = await _openLedgerTestDatabase();
      addTearDown(() async => db.close());

      await db.insert('customers', {
        'id': 'cust-missing-opening',
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
        'customer_id': 'cust-missing-opening',
        'entry_type': 'sale',
        'amount': 300.0,
        'balance_after': 300.0,
        'reference_type': 'sale',
        'reference_id': 'sale-miss',
        'notes': 'sale',
        'created_at': DateTime.now().toIso8601String(),
      });

      await db.insert('customers', {
        'id': 'cust-duplicate-opening',
        'code': 'CUS-DUP',
        'name': 'Duplicate Opening',
        'credit_limit': 0.0,
        'opening_balance': 1000.0,
        'current_balance': 0.0,
        'is_active': 1,
        'created_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      });
      for (final id in ['cust-duplicate-opening-a', 'cust-duplicate-opening-b']) {
        await db.insert('customer_ledger', {
          'id': id,
          'customer_id': 'cust-duplicate-opening',
          'entry_type': 'opening_balance',
          'amount': 500.0,
          'balance_after': 500.0,
          'reference_type': 'customer',
          'reference_id': 'cust-duplicate-opening',
          'notes': 'Opening balance',
          'created_at': DateTime.now().toIso8601String(),
        });
      }

      final service = const LedgerReconciliationService();
      final findings = await service.reconcileCustomers(database: db);
      expect(findings.any((f) => f.issueType == 'missing_opening_ledger_entry'), isTrue);
      expect(findings.any((f) => f.issueType == 'duplicate_opening_ledger_entries'), isTrue);
      final customerRows = await db.query('customer_ledger', where: 'customer_id = ?', whereArgs: ['cust-missing-opening']);
      expect(customerRows, hasLength(1));
      final duplicateRows = await db.query('customer_ledger', where: 'customer_id = ?', whereArgs: ['cust-duplicate-opening']);
      expect(duplicateRows, hasLength(2));
    });

    test('balance_after mismatch is reported while authoritative SUM remains correct', () async {
      final db = await _openLedgerTestDatabase();
      addTearDown(() async => db.close());

      await db.insert('customers', {
        'id': 'cust-balance-mismatch',
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
        'id': 'cust-balance-opening',
        'customer_id': 'cust-balance-mismatch',
        'entry_type': 'opening_balance',
        'amount': 1000.0,
        'balance_after': 500.0,
        'reference_type': 'customer',
        'reference_id': 'cust-balance-mismatch',
        'notes': 'Opening balance',
        'created_at': DateTime.now().toIso8601String(),
      });
      await db.insert('customer_ledger', {
        'id': 'cust-balance-sale',
        'customer_id': 'cust-balance-mismatch',
        'entry_type': 'sale',
        'amount': 500.0,
        'balance_after': 800.0,
        'reference_type': 'sale',
        'reference_id': 'sale-bal',
        'notes': 'sale',
        'created_at': DateTime.now().add(const Duration(minutes: 1)).toIso8601String(),
      });

      final service = const LedgerReconciliationService();
      final findings = await service.reconcileCustomers(database: db);
      expect(findings.any((f) => f.issueType == 'balance_after_mismatch'), isTrue);
      final total = (await db.rawQuery(
        'SELECT SUM(amount) AS total FROM customer_ledger WHERE customer_id = ?',
        ['cust-balance-mismatch'],
      )).first['total'] as num;
      expect(total, 1500.0);
    });
  });
}
