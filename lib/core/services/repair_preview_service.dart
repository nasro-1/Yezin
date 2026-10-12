import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'ledger_reconciliation_service.dart';

class RepairPreviewAction {
  const RepairPreviewAction({
    required this.entityId,
    required this.entityType,
    required this.findingType,
    required this.severity,
    required this.currentLedgerBalance,
    required this.currentLegacyBalance,
    required this.masterOpeningBalance,
    required this.openingLedgerCount,
    required this.difference,
    required this.proposedAction,
    required this.requiresAdminApproval,
    required this.repairRisk,
    required this.explanation,
    required this.before,
    required this.after,
    required this.reason,
    this.previewId,
    this.previewSignature,
    this.oldValue,
    this.newValue,
  });

  final String entityId;
  final String entityType;
  final String findingType;
  final LedgerIssueSeverity severity;
  final double currentLedgerBalance;
  final double? currentLegacyBalance;
  final double? masterOpeningBalance;
  final int openingLedgerCount;
  final double difference;
  final String proposedAction;
  final bool requiresAdminApproval;
  final String repairRisk;
  final String explanation;
  final String before;
  final String after;
  final String reason;
  final String? previewId;
  final String? previewSignature;
  final double? oldValue;
  final double? newValue;

  String get entity => entityId;
  String get finding => findingType;
  double get oldValueNumeric => oldValue ?? currentLegacyBalance ?? 0.0;
  double get newValueNumeric => newValue ?? currentLedgerBalance;
  String get repairId => previewId ?? '';
  String get signature => previewSignature ?? '';
}

class RepairPreviewService {
  const RepairPreviewService();

  String _previewSignatureFor(LedgerBalanceFinding finding) {
    final payload = [
      finding.entityId,
      finding.entityType,
      finding.issueType,
      finding.severity.name,
      finding.ledgerBalance.toString(),
      (finding.legacyCurrentBalance ?? 0.0).toString(),
      (finding.masterOpeningBalance ?? 0.0).toString(),
      finding.openingLedgerCount.toString(),
      finding.difference.toString(),
    ].join('|');
    return md5.convert(utf8.encode(payload)).toString();
  }

  RepairPreviewAction fromFinding(LedgerBalanceFinding finding) {
    switch (finding.issueType) {
      case 'legacy_current_balance_divergence':
        final previewId = 'legacy_current_balance_divergence:${finding.entityType}:${finding.entityId}';
        final signature = _previewSignatureFor(finding);
        return RepairPreviewAction(
          entityId: finding.entityId,
          entityType: finding.entityType,
          findingType: finding.issueType,
          severity: finding.severity,
          currentLedgerBalance: finding.ledgerBalance,
          currentLegacyBalance: finding.legacyCurrentBalance,
          masterOpeningBalance: finding.masterOpeningBalance,
          openingLedgerCount: finding.openingLedgerCount,
          difference: finding.difference,
          proposedAction: 'Update legacy compatibility field from ${finding.legacyCurrentBalance} to ${finding.ledgerBalance}',
          requiresAdminApproval: true,
          repairRisk: 'compatibility-update',
          explanation: 'Legacy current_balance diverges from authoritative ledger sum; preview only and no database mutation is allowed.',
          before: 'current_balance=${finding.legacyCurrentBalance}',
          after: 'MANUAL REVIEW REQUIRED',
          reason: 'Legacy field is non-authoritative and must be reviewed before any explicit compatibility update.',
          previewId: previewId,
          previewSignature: signature,
          oldValue: finding.legacyCurrentBalance,
          newValue: finding.ledgerBalance,
        );
      case 'missing_opening_ledger_entry':
        final previewId = 'missing_opening_ledger_entry:${finding.entityType}:${finding.entityId}';
        final signature = _previewSignatureFor(finding);
        return RepairPreviewAction(
          entityId: finding.entityId,
          entityType: finding.entityType,
          findingType: finding.issueType,
          severity: finding.severity,
          currentLedgerBalance: finding.ledgerBalance,
          currentLegacyBalance: finding.legacyCurrentBalance,
          masterOpeningBalance: finding.masterOpeningBalance,
          openingLedgerCount: finding.openingLedgerCount,
          difference: finding.difference,
          proposedAction: 'Requires historical evidence; no automatic repair',
          requiresAdminApproval: true,
          repairRisk: 'historical-data-ambiguity',
          explanation: 'Master opening_balance exists but no opening ledger row was found; no automatic reconstruction is allowed.',
          before: 'opening_balance=${finding.masterOpeningBalance}; opening_ledger_count=${finding.openingLedgerCount}',
          after: 'MANUAL REVIEW REQUIRED',
          reason: 'No safe reconstruction without source evidence or authoritative historical proof.',
          previewId: previewId,
          previewSignature: signature,
          oldValue: finding.masterOpeningBalance,
          newValue: null,
        );
      case 'duplicate_opening_ledger_entries':
        final previewId = 'duplicate_opening_ledger_entries:${finding.entityType}:${finding.entityId}';
        final signature = _previewSignatureFor(finding);
        return RepairPreviewAction(
          entityId: finding.entityId,
          entityType: finding.entityType,
          findingType: finding.issueType,
          severity: finding.severity,
          currentLedgerBalance: finding.ledgerBalance,
          currentLegacyBalance: finding.legacyCurrentBalance,
          masterOpeningBalance: finding.masterOpeningBalance,
          openingLedgerCount: finding.openingLedgerCount,
          difference: finding.difference,
          proposedAction: 'Requires source evidence; no automatic deletion',
          requiresAdminApproval: true,
          repairRisk: 'historical-data-ambiguity',
          explanation: 'Multiple opening ledger rows exist for a single entity; preview only and no automatic row deletion is permitted.',
          before: 'opening_balance=${finding.masterOpeningBalance}; opening_ledger_count=${finding.openingLedgerCount}',
          after: 'MANUAL REVIEW REQUIRED',
          reason: 'A valid opening entry cannot be selected without archival evidence or authoritative review.',
          previewId: previewId,
          previewSignature: signature,
          oldValue: finding.masterOpeningBalance,
          newValue: null,
        );
      case 'opening_entry_without_master_balance':
        final previewId = 'opening_entry_without_master_balance:${finding.entityType}:${finding.entityId}';
        final signature = _previewSignatureFor(finding);
        return RepairPreviewAction(
          entityId: finding.entityId,
          entityType: finding.entityType,
          findingType: finding.issueType,
          severity: finding.severity,
          currentLedgerBalance: finding.ledgerBalance,
          currentLegacyBalance: finding.legacyCurrentBalance,
          masterOpeningBalance: finding.masterOpeningBalance,
          openingLedgerCount: finding.openingLedgerCount,
          difference: finding.difference,
          proposedAction: 'Compatibility mismatch; review master opening_balance metadata',
          requiresAdminApproval: true,
          repairRisk: 'metadata-only',
          explanation: 'A ledger opening entry exists but the legacy master opening_balance field is zero or missing; no mutation is allowed.',
          before: 'opening_balance=${finding.masterOpeningBalance}; opening_ledger_count=${finding.openingLedgerCount}',
          after: 'MANUAL REVIEW REQUIRED',
          reason: 'The ledger may be accurate while the legacy master value is stale, so metadata review is required without mutation.',
          previewId: previewId,
          previewSignature: signature,
          oldValue: finding.masterOpeningBalance,
          newValue: null,
        );
      case 'balance_after_mismatch':
        final previewId = 'balance_after_mismatch:${finding.entityType}:${finding.entityId}';
        final signature = _previewSignatureFor(finding);
        return RepairPreviewAction(
          entityId: finding.entityId,
          entityType: finding.entityType,
          findingType: finding.issueType,
          severity: finding.severity,
          currentLedgerBalance: finding.ledgerBalance,
          currentLegacyBalance: finding.legacyCurrentBalance,
          masterOpeningBalance: finding.masterOpeningBalance,
          openingLedgerCount: finding.openingLedgerCount,
          difference: finding.difference,
          proposedAction: 'Historical running-balance inconsistency; preserve immutable ledger and require accounting review',
          requiresAdminApproval: true,
          repairRisk: 'immutable-ledger-history',
          explanation: 'The ledger sum is authoritative, but historical balance_after diverges; no ledger row or balance_after field may be mutated.',
          before: 'ledger_sum=${finding.ledgerBalance}; recorded_balance_after=${finding.recordedBalanceAfter}',
          after: 'MANUAL REVIEW REQUIRED',
          reason: 'Ledger entries are immutable and balance_after provides historical metadata that cannot be silently rewritten.',
          previewId: previewId,
          previewSignature: signature,
          oldValue: finding.recordedBalanceAfter,
          newValue: null,
        );
      default:
        final previewId = 'manual_review:${finding.entityType}:${finding.entityId}:${finding.issueType}';
        final signature = _previewSignatureFor(finding);
        return RepairPreviewAction(
          entityId: finding.entityId,
          entityType: finding.entityType,
          findingType: finding.issueType,
          severity: finding.severity,
          currentLedgerBalance: finding.ledgerBalance,
          currentLegacyBalance: finding.legacyCurrentBalance,
          masterOpeningBalance: finding.masterOpeningBalance,
          openingLedgerCount: finding.openingLedgerCount,
          difference: finding.difference,
          proposedAction: 'Manual review required',
          requiresAdminApproval: true,
          repairRisk: 'unknown',
          explanation: 'No safe automated action is available for this finding.',
          before: 'review required',
          after: 'MANUAL REVIEW REQUIRED',
          reason: 'The historical account state is ambiguous and must be reviewed before any repair action.',
          previewId: previewId,
          previewSignature: signature,
          oldValue: finding.legacyCurrentBalance ?? finding.masterOpeningBalance,
          newValue: null,
        );
    }
  }

  List<RepairPreviewAction> previewForFindings(List<LedgerBalanceFinding> findings) {
    return findings.map(fromFinding).toList(growable: false);
  }
}
