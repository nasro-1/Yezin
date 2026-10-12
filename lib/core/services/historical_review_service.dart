import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../features/auth/data/models/user_model.dart';
import '../data/models/activity_log.dart';
import '../data/services/background_write_queue.dart';
import '../security/permission_guard.dart';
import 'activity_logger.dart';
import 'ledger_reconciliation_service.dart';
import 'repair_preview_service.dart';

enum HistoricalReviewStatus {
  DETECTED,
  UNDER_REVIEW,
  EVIDENCE_REQUIRED,
  APPROVED_FOR_FUTURE_REPAIR,
  REJECTED,
  RESOLVED,
  DEFERRED,
  RESOLVED_BY_RECONCILIATION,
  STALE,
}

class HistoricalReviewRecord {
  const HistoricalReviewRecord({
    required this.reviewId,
    required this.entityType,
    required this.entityId,
    required this.findingType,
    required this.severity,
    required this.ledgerBalance,
    required this.difference,
    required this.previewId,
    required this.previewSignature,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    this.legacyCurrentBalance,
    this.masterOpeningBalance,
    this.openingLedgerCount = 0,
    this.adminNotes,
    this.evidenceNotes,
    this.reviewerId,
    this.reviewerUsername,
  });

  final String reviewId;
  final String entityType;
  final String entityId;
  final String findingType;
  final LedgerIssueSeverity severity;
  final double ledgerBalance;
  final double? legacyCurrentBalance;
  final double? masterOpeningBalance;
  final int openingLedgerCount;
  final double difference;
  final String? previewId;
  final String? previewSignature;
  final HistoricalReviewStatus status;
  final String? adminNotes;
  final String? evidenceNotes;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? reviewerId;
  final String? reviewerUsername;

  Map<String, dynamic> toMap() => {
        'review_id': reviewId,
        'entity_type': entityType,
        'entity_id': entityId,
        'finding_type': findingType,
        'severity': severity.name,
        'ledger_balance': ledgerBalance,
        'legacy_current_balance': legacyCurrentBalance,
        'master_opening_balance': masterOpeningBalance,
        'opening_ledger_count': openingLedgerCount,
        'difference': difference,
        'preview_id': previewId,
        'preview_signature': previewSignature,
        'status': status.name,
        'admin_notes': adminNotes,
        'evidence_notes': evidenceNotes,
        'created_at': createdAt.toIso8601String(),
        'updated_at': updatedAt.toIso8601String(),
        'reviewer_id': reviewerId,
        'reviewer_username': reviewerUsername,
      };

  factory HistoricalReviewRecord.fromMap(Map<String, dynamic> map) {
    return HistoricalReviewRecord(
      reviewId: map['review_id']?.toString() ?? '',
      entityType: map['entity_type']?.toString() ?? '',
      entityId: map['entity_id']?.toString() ?? '',
      findingType: map['finding_type']?.toString() ?? '',
      severity: LedgerIssueSeverity.values.firstWhere(
        (value) => value.name == (map['severity']?.toString() ?? ''),
        orElse: () => LedgerIssueSeverity.p1,
      ),
      ledgerBalance: (map['ledger_balance'] as num?)?.toDouble() ?? 0.0,
      legacyCurrentBalance: (map['legacy_current_balance'] as num?)?.toDouble(),
      masterOpeningBalance: (map['master_opening_balance'] as num?)?.toDouble(),
      openingLedgerCount: (map['opening_ledger_count'] as num?)?.toInt() ?? 0,
      difference: (map['difference'] as num?)?.toDouble() ?? 0.0,
      previewId: map['preview_id']?.toString(),
      previewSignature: map['preview_signature']?.toString(),
      status: HistoricalReviewStatus.values.firstWhere(
        (value) => value.name == (map['status']?.toString() ?? ''),
        orElse: () => HistoricalReviewStatus.DETECTED,
      ),
      adminNotes: map['admin_notes']?.toString(),
      evidenceNotes: map['evidence_notes']?.toString(),
      createdAt: DateTime.tryParse(map['created_at']?.toString() ?? '') ?? DateTime.now(),
      updatedAt: DateTime.tryParse(map['updated_at']?.toString() ?? '') ?? DateTime.now(),
      reviewerId: map['reviewer_id']?.toString(),
      reviewerUsername: map['reviewer_username']?.toString(),
    );
  }

  HistoricalReviewRecord copyWith({
    String? reviewId,
    String? entityType,
    String? entityId,
    String? findingType,
    LedgerIssueSeverity? severity,
    double? ledgerBalance,
    double? legacyCurrentBalance,
    double? masterOpeningBalance,
    int? openingLedgerCount,
    double? difference,
    String? previewId,
    String? previewSignature,
    HistoricalReviewStatus? status,
    String? adminNotes,
    String? evidenceNotes,
    DateTime? createdAt,
    DateTime? updatedAt,
    String? reviewerId,
    String? reviewerUsername,
  }) {
    return HistoricalReviewRecord(
      reviewId: reviewId ?? this.reviewId,
      entityType: entityType ?? this.entityType,
      entityId: entityId ?? this.entityId,
      findingType: findingType ?? this.findingType,
      severity: severity ?? this.severity,
      ledgerBalance: ledgerBalance ?? this.ledgerBalance,
      legacyCurrentBalance: legacyCurrentBalance ?? this.legacyCurrentBalance,
      masterOpeningBalance: masterOpeningBalance ?? this.masterOpeningBalance,
      openingLedgerCount: openingLedgerCount ?? this.openingLedgerCount,
      difference: difference ?? this.difference,
      previewId: previewId ?? this.previewId,
      previewSignature: previewSignature ?? this.previewSignature,
      status: status ?? this.status,
      adminNotes: adminNotes ?? this.adminNotes,
      evidenceNotes: evidenceNotes ?? this.evidenceNotes,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      reviewerId: reviewerId ?? this.reviewerId,
      reviewerUsername: reviewerUsername ?? this.reviewerUsername,
    );
  }
}

class HistoricalReviewDecisionResult {
  const HistoricalReviewDecisionResult({
    required this.record,
    required this.success,
    this.message,
  });

  final HistoricalReviewRecord record;
  final bool success;
  final String? message;
}

class HistoricalReviewService {
  const HistoricalReviewService({this.activityLogger});

  final ActivityLogger? activityLogger;

  static const List<String> supportedFindingTypes = [
    'missing_opening_ledger_entry',
    'duplicate_opening_ledger_entries',
    'opening_entry_without_master_balance',
    'balance_after_mismatch',
  ];

  Future<void> ensureSchema(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS historical_review_records (
        review_id TEXT PRIMARY KEY,
        entity_type TEXT NOT NULL,
        entity_id TEXT NOT NULL,
        finding_type TEXT NOT NULL,
        severity TEXT NOT NULL,
        ledger_balance REAL NOT NULL,
        legacy_current_balance REAL,
        master_opening_balance REAL,
        opening_ledger_count INTEGER NOT NULL DEFAULT 0,
        difference REAL NOT NULL,
        preview_id TEXT,
        preview_signature TEXT,
        status TEXT NOT NULL,
        admin_notes TEXT,
        evidence_notes TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        reviewer_id TEXT,
        reviewer_username TEXT
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_historical_reviews_status ON historical_review_records(status)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_historical_reviews_entity ON historical_review_records(entity_type, entity_id)',
    );
    await db.execute('''
      CREATE TABLE IF NOT EXISTS historical_review_audit (
        audit_id TEXT PRIMARY KEY,
        review_id TEXT NOT NULL,
        actor TEXT NOT NULL,
        timestamp TEXT NOT NULL,
        old_status TEXT NOT NULL,
        new_status TEXT NOT NULL,
        notes TEXT,
        preview_id TEXT,
        finding_type TEXT NOT NULL,
        entity_type TEXT,
        entity_id TEXT
      )
    ''' );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_historical_review_audit_review_id ON historical_review_audit(review_id)',
    );
  }

  Future<void> _writeReviewAudit(
    DatabaseExecutor db, {
    required String reviewId,
    required String actor,
    required String oldStatus,
    required String newStatus,
    String? notes,
    String? previewId,
    required String findingType,
    String? entityType,
    String? entityId,
  }) async {
    await ensureSchema(db);
    final timestamp = DateTime.now().toUtc().toIso8601String();
    final auditId = 'audit_${md5.convert(utf8.encode([
      reviewId,
      actor,
      oldStatus,
      newStatus,
      notes ?? '',
      previewId ?? '',
      findingType,
      entityType ?? '',
      entityId ?? '',
      timestamp,
    ].join('|'))).toString()}';

    await db.insert('historical_review_audit', {
      'audit_id': auditId,
      'review_id': reviewId,
      'actor': actor,
      'timestamp': timestamp,
      'old_status': oldStatus,
      'new_status': newStatus,
      'notes': notes,
      'preview_id': previewId,
      'finding_type': findingType,
      'entity_type': entityType,
      'entity_id': entityId,
    });
  }

  String _reviewIdFor(RepairPreviewAction preview) {
    final payload = [
      preview.entityType,
      preview.entityId,
      preview.findingType,
      preview.previewSignature ?? preview.previewId ?? '',
      preview.currentLedgerBalance.toString(),
      preview.currentLegacyBalance?.toString() ?? '',
      preview.masterOpeningBalance?.toString() ?? '',
      preview.openingLedgerCount.toString(),
    ].join('|');
    return 'review_${md5.convert(utf8.encode(payload)).toString()}';
  }

  Future<HistoricalReviewRecord> createReview({
    required DatabaseExecutor db,
    required RepairPreviewAction preview,
    String? evidenceNotes,
    String? adminNotes,
  }) async {
    if (!supportedFindingTypes.contains(preview.findingType)) {
      throw StateError('Unsupported historical review finding: ${preview.findingType}');
    }

    await ensureSchema(db);
    final now = DateTime.now();
    final reviewId = preview.previewId ?? _reviewIdFor(preview);
    final record = HistoricalReviewRecord(
      reviewId: reviewId,
      entityType: preview.entityType,
      entityId: preview.entityId,
      findingType: preview.findingType,
      severity: preview.severity,
      ledgerBalance: preview.currentLedgerBalance,
      legacyCurrentBalance: preview.currentLegacyBalance,
      masterOpeningBalance: preview.masterOpeningBalance,
      openingLedgerCount: preview.openingLedgerCount,
      difference: preview.difference,
      previewId: preview.previewId,
      previewSignature: preview.previewSignature,
      status: HistoricalReviewStatus.DETECTED,
      adminNotes: adminNotes,
      evidenceNotes: evidenceNotes,
      createdAt: now,
      updatedAt: now,
    );

    final existingRows = await db.query(
      'historical_review_records',
      where: 'review_id = ?',
      whereArgs: [reviewId],
    );
    if (existingRows.isEmpty) {
      await db.insert('historical_review_records', record.toMap());
    } else {
      await db.update(
        'historical_review_records',
        record.toMap(),
        where: 'review_id = ?',
        whereArgs: [reviewId],
      );
    }

    await _writeReviewAudit(
      db,
      reviewId: reviewId,
      actor: 'system',
      oldStatus: HistoricalReviewStatus.DETECTED.name,
      newStatus: HistoricalReviewStatus.DETECTED.name,
      notes: adminNotes ?? evidenceNotes ?? 'Historical review created.',
      previewId: preview.previewId,
      findingType: preview.findingType,
      entityType: preview.entityType,
      entityId: preview.entityId,
    );

    await _logReviewActivity(
      db,
      type: preview.entityType == 'supplier' || preview.entityType == 'suppliers'
          ? ActivityType.supplierUpdated
          : ActivityType.customerUpdated,
      description: 'Historical review recorded for ${preview.entityType} ${preview.entityId}',
      userName: 'system',
      eventKey: 'historical_review',
      details: {
        'review_id': reviewId,
        'entity_id': preview.entityId,
        'entity_type': preview.entityType,
        'finding_type': preview.findingType,
        'status': HistoricalReviewStatus.DETECTED.name,
      },
      parameters: {
        'review_id': reviewId,
        'entity_id': preview.entityId,
        'entity_type': preview.entityType,
        'finding_type': preview.findingType,
        'status': HistoricalReviewStatus.DETECTED.name,
      },
    );

    return record;
  }

  Future<void> _logReviewActivity(
    DatabaseExecutor db, {
    required ActivityType type,
    required String description,
    required String userName,
    String sessionId = '',
    Map<String, dynamic>? details,
    String? eventKey,
    Map<String, dynamic>? parameters,
  }) async {
    final timestamp = DateTime.now().toIso8601String();
    final id = 'review_activity_${md5.convert(utf8.encode([
      type.name,
      description,
      userName,
      sessionId,
      eventKey ?? '',
      timestamp,
    ].join('|'))).toString()}';

    await db.insert('activity_logs', {
      'id': id,
      'session_id': sessionId,
      'timestamp': timestamp,
      'type': type.toString().split('.').last,
      'description': description,
      'user_name': userName,
      'details': details == null ? null : jsonEncode(details),
      'event_key': eventKey,
      'parameters': parameters == null ? null : jsonEncode(parameters),
    });

    final logger = activityLogger;
    if (logger != null) {
      await logger.logActivity(
        type: type,
        description: description,
        userName: userName,
        sessionId: sessionId,
        details: details,
        eventKey: eventKey,
        parameters: parameters,
      );
    }
  }

  Future<HistoricalReviewRecord> _fetchById(DatabaseExecutor db, String reviewId) async {
    final rows = await db.query(
      'historical_review_records',
      where: 'review_id = ?',
      whereArgs: [reviewId],
      limit: 1,
    );
    if (rows.isEmpty) {
      throw StateError('Historical review not found: $reviewId');
    }
    return HistoricalReviewRecord.fromMap(rows.first);
  }

  Future<HistoricalReviewDecisionResult> submitDecision({
    required DatabaseExecutor db,
    required HistoricalReviewRecord review,
    required User actor,
    required HistoricalReviewStatus newStatus,
    required String notes,
    RepairPreviewAction? preview,
  }) async {
    if (newStatus == HistoricalReviewStatus.APPROVED_FOR_FUTURE_REPAIR ||
        newStatus == HistoricalReviewStatus.REJECTED ||
        newStatus == HistoricalReviewStatus.DEFERRED ||
        newStatus == HistoricalReviewStatus.EVIDENCE_REQUIRED) {
      if (newStatus == HistoricalReviewStatus.APPROVED_FOR_FUTURE_REPAIR) {
        PermissionGuard.requireHistoricalReviewApproval(actor);
      } else if (newStatus == HistoricalReviewStatus.EVIDENCE_REQUIRED) {
        if (!(PermissionGuard.canReviewHistoricalFindings(actor) || PermissionGuard.canApproveHistoricalFindings(actor))) {
          throw PermissionDeniedException('Historical review evidence requests require manager or admin privileges.');
        }
      } else {
        PermissionGuard.requireHistoricalReviewApproval(actor);
      }
    } else if (!PermissionGuard.canReviewHistoricalFindings(actor)) {
      throw PermissionDeniedException('Historical review access requires manager or admin privileges.');
    }

    final beforeFinancial = await _captureFinancialSnapshot(db, review.entityType, review.entityId);
    final oldStatus = review.status;
    final effectivePreview = preview ?? RepairPreviewAction(
      entityId: review.entityId,
      entityType: review.entityType,
      findingType: review.findingType,
      severity: review.severity,
      currentLedgerBalance: review.ledgerBalance,
      currentLegacyBalance: review.legacyCurrentBalance,
      masterOpeningBalance: review.masterOpeningBalance,
      openingLedgerCount: review.openingLedgerCount,
      difference: review.difference,
      proposedAction: 'Review only',
      requiresAdminApproval: true,
      repairRisk: 'review-only',
      explanation: 'Historical review record only; no repair execution.',
      before: 'review-only',
      after: 'review-only',
      reason: 'No financial mutation is permitted in review mode.',
      previewId: review.previewId,
      previewSignature: review.previewSignature,
      oldValue: review.legacyCurrentBalance,
      newValue: review.legacyCurrentBalance,
    );

    final previewMatches = _previewMatchesReview(review, effectivePreview);
    if (!previewMatches) {
      final staleRecord = review.copyWith(
        status: HistoricalReviewStatus.STALE,
        adminNotes: notes.isNotEmpty ? notes : 'Review decision rejected because the underlying preview data changed.',
        evidenceNotes: review.evidenceNotes,
        reviewerId: actor.username,
        reviewerUsername: actor.name,
        updatedAt: DateTime.now(),
      );
      await db.update(
        'historical_review_records',
        staleRecord.toMap(),
        where: 'review_id = ?',
        whereArgs: [review.reviewId],
      );
      await _logReviewActivity(
        db,
        type: review.entityType == 'supplier' || review.entityType == 'suppliers'
            ? ActivityType.supplierUpdated
            : ActivityType.customerUpdated,
        description: 'Historical review rejected as stale for ${review.entityType} ${review.entityId}',
        userName: actor.name,
        eventKey: 'historical_review',
        details: {
          'review_id': review.reviewId,
          'old_status': oldStatus.name,
          'new_status': HistoricalReviewStatus.STALE.name,
          'notes': notes,
          'preview_id': review.previewId,
          'finding_type': review.findingType,
        },
        parameters: {
          'review_id': review.reviewId,
          'old_status': oldStatus.name,
          'new_status': HistoricalReviewStatus.STALE.name,
          'notes': notes,
          'preview_id': review.previewId,
          'finding_type': review.findingType,
        },
      );
      return HistoricalReviewDecisionResult(
        record: staleRecord,
        success: false,
        message: 'Review is stale: the source preview has changed; require a new reconciliation/preview.',
      );
    }

    final updated = review.copyWith(
      status: newStatus,
      adminNotes: notes.isNotEmpty ? notes : review.adminNotes,
      evidenceNotes: review.evidenceNotes,
      reviewerId: actor.username,
      reviewerUsername: actor.name,
      updatedAt: DateTime.now(),
    );

    await db.update(
      'historical_review_records',
      updated.toMap(),
      where: 'review_id = ?',
      whereArgs: [review.reviewId],
    );

    final afterFinancial = await _captureFinancialSnapshot(db, review.entityType, review.entityId);
    if (jsonEncode(beforeFinancial) != jsonEncode(afterFinancial)) {
      throw StateError('Review action attempted to mutate financial state.');
    }

    await _writeReviewAudit(
      db,
      reviewId: review.reviewId,
      actor: actor.name,
      oldStatus: oldStatus.name,
      newStatus: newStatus.name,
      notes: notes,
      previewId: review.previewId,
      findingType: review.findingType,
      entityType: review.entityType,
      entityId: review.entityId,
    );

    await _logReviewActivity(
      db,
      type: review.entityType == 'supplier' || review.entityType == 'suppliers'
          ? ActivityType.supplierUpdated
          : ActivityType.customerUpdated,
      description: 'Historical review updated for ${review.entityType} ${review.entityId}',
      userName: actor.name,
      eventKey: 'historical_review',
      details: {
        'review_id': review.reviewId,
        'entity_id': review.entityId,
        'entity_type': review.entityType,
        'finding_type': review.findingType,
        'old_status': oldStatus.name,
        'new_status': newStatus.name,
        'notes': notes,
        'preview_id': review.previewId,
      },
      parameters: {
        'review_id': review.reviewId,
        'entity_id': review.entityId,
        'entity_type': review.entityType,
        'finding_type': review.findingType,
        'old_status': oldStatus.name,
        'new_status': newStatus.name,
        'notes': notes,
        'preview_id': review.previewId,
      },
    );

    return HistoricalReviewDecisionResult(
      record: updated,
      success: true,
      message: 'Historical review status updated without any financial mutation.',
    );
  }

  Future<HistoricalReviewDecisionResult> requestEvidence({
    required DatabaseExecutor db,
    required HistoricalReviewRecord review,
    required User actor,
    String notes = 'Evidence required before any future repair action.',
    RepairPreviewAction? preview,
  }) async {
    if (!PermissionGuard.canReviewHistoricalFindings(actor)) {
      throw PermissionDeniedException(
        'Historical review evidence requests require manager or admin privileges.',
      );
    }
    return submitDecision(
      db: db,
      review: review,
      actor: actor,
      newStatus: HistoricalReviewStatus.EVIDENCE_REQUIRED,
      notes: notes,
      preview: preview,
    );
  }

  Future<HistoricalReviewDecisionResult> approveForFutureRepair({
    required DatabaseExecutor db,
    required HistoricalReviewRecord review,
    required User actor,
    String notes = 'Approved for future repair only; no financial repair executed.',
    RepairPreviewAction? preview,
  }) async {
    PermissionGuard.requireHistoricalReviewApproval(actor);
    return submitDecision(
      db: db,
      review: review,
      actor: actor,
      newStatus: HistoricalReviewStatus.APPROVED_FOR_FUTURE_REPAIR,
      notes: notes,
      preview: preview,
    );
  }

  Future<HistoricalReviewDecisionResult> rejectReview({
    required DatabaseExecutor db,
    required HistoricalReviewRecord review,
    required User actor,
    String notes = 'Rejected after review.',
    RepairPreviewAction? preview,
  }) async {
    PermissionGuard.requireHistoricalReviewApproval(actor);
    return submitDecision(
      db: db,
      review: review,
      actor: actor,
      newStatus: HistoricalReviewStatus.REJECTED,
      notes: notes,
      preview: preview,
    );
  }

  Future<HistoricalReviewDecisionResult> deferReview({
    required DatabaseExecutor db,
    required HistoricalReviewRecord review,
    required User actor,
    String notes = 'Deferred pending additional evidence.',
    RepairPreviewAction? preview,
  }) async {
    PermissionGuard.requireHistoricalReviewApproval(actor);
    return submitDecision(
      db: db,
      review: review,
      actor: actor,
      newStatus: HistoricalReviewStatus.DEFERRED,
      notes: notes,
      preview: preview,
    );
  }

  Future<HistoricalReviewRecord> refreshReviewStatus({
    required DatabaseExecutor db,
    required HistoricalReviewRecord review,
    required List<LedgerBalanceFinding> currentFindings,
  }) async {
    await ensureSchema(db);
    final stillPresent = currentFindings.any(
      (finding) =>
          finding.entityId == review.entityId &&
          finding.entityType == review.entityType &&
          finding.issueType == review.findingType,
    );

    final updated = review.copyWith(
      status: stillPresent ? review.status : HistoricalReviewStatus.RESOLVED_BY_RECONCILIATION,
      updatedAt: DateTime.now(),
    );

    await db.update(
      'historical_review_records',
      updated.toMap(),
      where: 'review_id = ?',
      whereArgs: [review.reviewId],
    );
    return updated;
  }

  Future<List<HistoricalReviewRecord>> listReviews(DatabaseExecutor db) async {
    await ensureSchema(db);
    final rows = await db.query('historical_review_records', orderBy: 'updated_at DESC');
    return rows.map(HistoricalReviewRecord.fromMap).toList();
  }

  Future<Map<String, dynamic>> _captureFinancialSnapshot(DatabaseExecutor db, String entityType, String entityId) async {
    if (entityType == 'customer' || entityType == 'customers') {
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
      final openingCount = await db.rawQuery(
        'SELECT COUNT(*) AS count FROM customer_ledger WHERE customer_id = ? AND entry_type = ?',
        [entityId, 'opening_balance'],
      );
      return {
        'entity_type': 'customer',
        'entity_id': entityId,
        'current_balance': customerRow.isNotEmpty ? (customerRow.first['current_balance'] as num?)?.toDouble() ?? 0.0 : 0.0,
        'opening_balance': customerRow.isNotEmpty ? (customerRow.first['opening_balance'] as num?)?.toDouble() ?? 0.0 : 0.0,
        'ledger_total': (ledgerTotal.first['total'] as num?)?.toDouble() ?? 0.0,
        'opening_ledger_count': (openingCount.first['count'] as num?)?.toInt() ?? 0,
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
    final openingCount = await db.rawQuery(
      'SELECT COUNT(*) AS count FROM supplier_ledger WHERE supplier_id = ? AND entry_type = ?',
      [entityId, 'opening_balance'],
    );
    return {
      'entity_type': 'supplier',
      'entity_id': entityId,
      'current_balance': supplierRow.isNotEmpty ? (supplierRow.first['current_balance'] as num?)?.toDouble() ?? 0.0 : 0.0,
      'opening_balance': supplierRow.isNotEmpty ? (supplierRow.first['opening_balance'] as num?)?.toDouble() ?? 0.0 : 0.0,
      'ledger_total': (ledgerTotal.first['total'] as num?)?.toDouble() ?? 0.0,
      'opening_ledger_count': (openingCount.first['count'] as num?)?.toInt() ?? 0,
    };
  }

  bool _previewMatchesReview(HistoricalReviewRecord review, RepairPreviewAction preview) {
    if (review.previewId != null && preview.previewId != null && review.previewId != preview.previewId) return false;
    if (review.previewSignature != null && preview.previewSignature != null && review.previewSignature != preview.previewSignature) return false;
    if (review.entityId != preview.entityId) return false;
    if (review.entityType != preview.entityType) return false;
    if (review.findingType != preview.findingType) return false;
    if ((review.ledgerBalance - preview.currentLedgerBalance).abs() > 0.0000001) return false;
    if (review.legacyCurrentBalance != null && preview.currentLegacyBalance != null &&
        (review.legacyCurrentBalance! - preview.currentLegacyBalance!).abs() > 0.0000001) return false;
    if (review.masterOpeningBalance != null && preview.masterOpeningBalance != null &&
        (review.masterOpeningBalance! - preview.masterOpeningBalance!).abs() > 0.0000001) return false;
    if (review.openingLedgerCount != preview.openingLedgerCount) return false;
    return true;
  }
}
