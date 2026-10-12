import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:bayaa_pos/core/data/services/sqlite_manager.dart';
import 'package:bayaa_pos/core/security/permission_guard.dart';
import 'package:bayaa_pos/core/services/historical_review_service.dart';
import 'package:bayaa_pos/core/services/ledger_reconciliation_service.dart';
import 'package:bayaa_pos/core/services/repair_preview_service.dart';
import 'package:bayaa_pos/features/auth/data/models/user_model.dart';

Future<Database> _openHistoricalReviewDatabase() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  final tempDir = await Directory.systemTemp.createTemp('bayaa_historical_review_');
  final dbPath = p.join(tempDir.path, 'historical_review.db');
  final manager = SQLiteManager(databasePath: dbPath);
  await manager.initialize();
  return await openDatabase(dbPath);
}

User _makeUser({required UserType userType, String name = 'Tester'}) => User(
      username: userType.name,
      name: name,
      phone: '0000000000',
      userType: userType,
      password: 'pw',
      permissions: const {},
    );

Future<RepairPreviewAction> _missingOpeningPreview(Database db, String entityId, String entityType) async {
  final findings = await const LedgerReconciliationService().reconcileCustomers(database: db);
  final match = findings.firstWhere(
    (finding) =>
        finding.entityId == entityId &&
        finding.entityType == entityType &&
        finding.issueType == 'missing_opening_ledger_entry',
  );
  return const RepairPreviewService().fromFinding(match);
}

Future<Map<String, dynamic>> _financialSnapshot(Database db, String entityType, String entityId) async {
  if (entityType == 'customer') {
    final customerRow = await db.query(
      'customers',
      columns: ['current_balance', 'opening_balance'],
      where: 'id = ?',
      whereArgs: [entityId],
      limit: 1,
    );
    final ledgerTotal = await db.rawQuery(
      'SELECT COALESCE(SUM(amount), 0) AS total FROM customer_ledger WHERE customer_id = ?',
      [entityId],
    );
    return {
      'current_balance': customerRow.first['current_balance'],
      'opening_balance': customerRow.first['opening_balance'],
      'ledger_total': ledgerTotal.first['total'],
    };
  }
  final supplierRow = await db.query(
    'suppliers',
    columns: ['current_balance', 'opening_balance'],
    where: 'id = ?',
    whereArgs: [entityId],
    limit: 1,
  );
  final ledgerTotal = await db.rawQuery(
    'SELECT COALESCE(SUM(amount), 0) AS total FROM supplier_ledger WHERE supplier_id = ?',
    [entityId],
  );
  return {
    'current_balance': supplierRow.first['current_balance'],
    'opening_balance': supplierRow.first['opening_balance'],
    'ledger_total': ledgerTotal.first['total'],
  };
}

void main() {
  group('historical review service', () {
    test('admin can review missing opening finding without financial mutation', () async {
      final db = await _openHistoricalReviewDatabase();
      addTearDown(() async => db.close());

      await db.insert('customers', {
        'id': 'cust-review-1',
        'code': 'CUS-REV-1',
        'name': 'Review Customer',
        'credit_limit': 0.0,
        'opening_balance': 1000.0,
        'current_balance': 0.0,
        'is_active': 1,
        'created_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      });
      await db.insert('customer_ledger', {
        'id': 'cust-review-sale',
        'customer_id': 'cust-review-1',
        'entry_type': 'sale',
        'amount': 300.0,
        'balance_after': 300.0,
        'reference_type': 'sale',
        'reference_id': 'sale-review-1',
        'notes': 'sale',
        'created_at': DateTime.now().toIso8601String(),
      });

      final preview = await _missingOpeningPreview(db, 'cust-review-1', 'customer');
      final service = HistoricalReviewService();
      final review = await service.createReview(db: db, preview: preview);

      final before = await _financialSnapshot(db, 'customer', 'cust-review-1');
      final decision = await service.submitDecision(
        db: db,
        review: review,
        actor: _makeUser(userType: UserType.admin),
        newStatus: HistoricalReviewStatus.APPROVED_FOR_FUTURE_REPAIR,
        notes: 'Approved for future repair only.',
        preview: preview,
      );
      final after = await _financialSnapshot(db, 'customer', 'cust-review-1');

      expect(decision.success, isTrue);
      expect(decision.record.status, HistoricalReviewStatus.APPROVED_FOR_FUTURE_REPAIR);
      expect(jsonEncode(before), jsonEncode(after));
      final rows = await db.query('historical_review_records', where: 'review_id = ?', whereArgs: [review.reviewId]);
      expect(rows, isNotEmpty);
    });

    test('manager can view but cannot approve', () async {
      final db = await _openHistoricalReviewDatabase();
      addTearDown(() async => db.close());

      await db.insert('customers', {
        'id': 'cust-review-manager',
        'code': 'CUS-REV-M',
        'name': 'Manager Review',
        'credit_limit': 0.0,
        'opening_balance': 1000.0,
        'current_balance': 0.0,
        'is_active': 1,
        'created_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      });
      await db.insert('customer_ledger', {
        'id': 'cust-review-manager-ledger',
        'customer_id': 'cust-review-manager',
        'entry_type': 'sale',
        'amount': 300.0,
        'balance_after': 300.0,
        'reference_type': 'sale',
        'reference_id': 'sale-review-manager',
        'notes': 'sale',
        'created_at': DateTime.now().toIso8601String(),
      });

      final preview = await _missingOpeningPreview(db, 'cust-review-manager', 'customer');
      final service = HistoricalReviewService();
      final review = await service.createReview(db: db, preview: preview);

      expect(
        () => service.submitDecision(
          db: db,
          review: review,
          actor: _makeUser(userType: UserType.manager),
          newStatus: HistoricalReviewStatus.APPROVED_FOR_FUTURE_REPAIR,
          notes: 'Attempted approval',
          preview: preview,
        ),
        throwsA(isA<PermissionDeniedException>()),
      );
    });

    test('cashier cannot access review approval', () async {
      final db = await _openHistoricalReviewDatabase();
      addTearDown(() async => db.close());

      await db.insert('customers', {
        'id': 'cust-review-cashier',
        'code': 'CUS-REV-C',
        'name': 'Cashier Review',
        'credit_limit': 0.0,
        'opening_balance': 1000.0,
        'current_balance': 0.0,
        'is_active': 1,
        'created_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      });
      await db.insert('customer_ledger', {
        'id': 'cust-review-cashier-ledger',
        'customer_id': 'cust-review-cashier',
        'entry_type': 'sale',
        'amount': 300.0,
        'balance_after': 300.0,
        'reference_type': 'sale',
        'reference_id': 'sale-review-cashier',
        'notes': 'sale',
        'created_at': DateTime.now().toIso8601String(),
      });

      final preview = await _missingOpeningPreview(db, 'cust-review-cashier', 'customer');
      final service = HistoricalReviewService();
      final review = await service.createReview(db: db, preview: preview);

      expect(
        () => service.submitDecision(
          db: db,
          review: review,
          actor: _makeUser(userType: UserType.cashier),
          newStatus: HistoricalReviewStatus.EVIDENCE_REQUIRED,
          notes: 'Cashier denied',
          preview: preview,
        ),
        throwsA(isA<PermissionDeniedException>()),
      );
    });

    test('admin can mark evidence required', () async {
      final db = await _openHistoricalReviewDatabase();
      addTearDown(() async => db.close());

      await db.insert('suppliers', {
        'id': 'sup-review-evidence',
        'code': 'SUP-REV-E',
        'name': 'Evidence Supplier',
        'credit_limit': 0.0,
        'opening_balance': 2000.0,
        'current_balance': 0.0,
        'is_active': 1,
        'created_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      });
      await db.insert('supplier_ledger', {
        'id': 'sup-review-evidence-ledger',
        'supplier_id': 'sup-review-evidence',
        'entry_type': 'purchase',
        'amount': 500.0,
        'balance_after': 500.0,
        'reference_type': 'purchase',
        'reference_id': 'purchase-review-evidence',
        'notes': 'purchase',
        'created_at': DateTime.now().toIso8601String(),
      });

      final findings = await const LedgerReconciliationService().reconcileSuppliers(database: db);
      final preview = const RepairPreviewService().fromFinding(
        findings.firstWhere(
          (f) => f.entityId == 'sup-review-evidence' && f.issueType == 'missing_opening_ledger_entry',
        ),
      );
      final service = HistoricalReviewService();
      final review = await service.createReview(db: db, preview: preview);

      final decision = await service.submitDecision(
        db: db,
        review: review,
        actor: _makeUser(userType: UserType.admin),
        newStatus: HistoricalReviewStatus.EVIDENCE_REQUIRED,
        notes: 'Source document required before approval.',
        preview: preview,
      );

      expect(decision.success, isTrue);
      expect(decision.record.status, HistoricalReviewStatus.EVIDENCE_REQUIRED);
    });

    test('stale preview is rejected without permit', () async {
      final db = await _openHistoricalReviewDatabase();
      addTearDown(() async => db.close());

      await db.insert('customers', {
        'id': 'cust-review-stale',
        'code': 'CUS-REV-S',
        'name': 'Stale Review',
        'credit_limit': 0.0,
        'opening_balance': 1000.0,
        'current_balance': 0.0,
        'is_active': 1,
        'created_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      });
      await db.insert('customer_ledger', {
        'id': 'cust-review-stale-ledger',
        'customer_id': 'cust-review-stale',
        'entry_type': 'sale',
        'amount': 300.0,
        'balance_after': 300.0,
        'reference_type': 'sale',
        'reference_id': 'sale-review-stale',
        'notes': 'sale',
        'created_at': DateTime.now().toIso8601String(),
      });

      final preview = await _missingOpeningPreview(db, 'cust-review-stale', 'customer');
      final service = HistoricalReviewService();
      final review = await service.createReview(db: db, preview: preview);

      final stalePreview = RepairPreviewAction(
        entityId: preview.entityId,
        entityType: preview.entityType,
        findingType: preview.findingType,
        severity: preview.severity,
        currentLedgerBalance: preview.currentLedgerBalance + 50.0,
        currentLegacyBalance: preview.currentLegacyBalance,
        masterOpeningBalance: preview.masterOpeningBalance,
        openingLedgerCount: preview.openingLedgerCount,
        difference: preview.difference,
        proposedAction: 'stale',
        requiresAdminApproval: true,
        repairRisk: 'stale',
        explanation: 'stale preview',
        before: 'stale',
        after: 'stale',
        reason: 'stale',
        previewId: preview.previewId,
        previewSignature: 'stale-signature',
        oldValue: preview.oldValue,
        newValue: preview.newValue,
      );

      final decision = await service.submitDecision(
        db: db,
        review: review,
        actor: _makeUser(userType: UserType.admin),
        newStatus: HistoricalReviewStatus.APPROVED_FOR_FUTURE_REPAIR,
        notes: 'This preview is stale.',
        preview: stalePreview,
      );

      expect(decision.success, isFalse);
      expect(decision.record.status, HistoricalReviewStatus.STALE);
    });

    test('review audit record created and reject does not repair financial data', () async {
      final db = await _openHistoricalReviewDatabase();
      addTearDown(() async => db.close());

      await db.insert('customers', {
        'id': 'cust-review-audit',
        'code': 'CUS-REV-A',
        'name': 'Audit Review',
        'credit_limit': 0.0,
        'opening_balance': 1000.0,
        'current_balance': 0.0,
        'is_active': 1,
        'created_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      });
      await db.insert('customer_ledger', {
        'id': 'cust-review-audit-ledger',
        'customer_id': 'cust-review-audit',
        'entry_type': 'sale',
        'amount': 300.0,
        'balance_after': 300.0,
        'reference_type': 'sale',
        'reference_id': 'sale-review-audit',
        'notes': 'sale',
        'created_at': DateTime.now().toIso8601String(),
      });

      final preview = await _missingOpeningPreview(db, 'cust-review-audit', 'customer');
      final service = HistoricalReviewService();
      final review = await service.createReview(db: db, preview: preview);

      final before = await _financialSnapshot(db, 'customer', 'cust-review-audit');
      final rejectResult = await service.submitDecision(
        db: db,
        review: review,
        actor: _makeUser(userType: UserType.admin),
        newStatus: HistoricalReviewStatus.REJECTED,
        notes: 'Historical evidence is insufficient.',
        preview: preview,
      );
      final after = await _financialSnapshot(db, 'customer', 'cust-review-audit');

      expect(rejectResult.success, isTrue);
      expect(rejectResult.record.status, HistoricalReviewStatus.REJECTED);
      expect(jsonEncode(before), jsonEncode(after));

      final logs = await db.query(
        'activity_logs',
        where: 'event_key = ?',
        whereArgs: ['historical_review'],
      );
      expect(logs, isNotEmpty);
    });

    test('reconciliation refresh can resolve a review without financial mutation', () async {
      final db = await _openHistoricalReviewDatabase();
      addTearDown(() async => db.close());

      await db.insert('customers', {
        'id': 'cust-review-resolve',
        'code': 'CUS-REV-R',
        'name': 'Resolve Review',
        'credit_limit': 0.0,
        'opening_balance': 1000.0,
        'current_balance': 0.0,
        'is_active': 1,
        'created_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      });
      await db.insert('customer_ledger', {
        'id': 'cust-review-resolve-ledger',
        'customer_id': 'cust-review-resolve',
        'entry_type': 'sale',
        'amount': 300.0,
        'balance_after': 300.0,
        'reference_type': 'sale',
        'reference_id': 'sale-review-resolve',
        'notes': 'sale',
        'created_at': DateTime.now().toIso8601String(),
      });

      final preview = await _missingOpeningPreview(db, 'cust-review-resolve', 'customer');
      final service = HistoricalReviewService();
      final review = await service.createReview(db: db, preview: preview);
      final refreshed = await service.refreshReviewStatus(db: db, review: review, currentFindings: const []);
      expect(refreshed.status, HistoricalReviewStatus.RESOLVED_BY_RECONCILIATION);
    });
  });
}
