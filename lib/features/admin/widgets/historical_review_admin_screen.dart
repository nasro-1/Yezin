import 'package:flutter/material.dart';

import '../../../core/services/historical_review_service.dart';

enum HistoricalReviewAction {
  requireEvidence,
  approveForFutureRepair,
  reject,
  defer,
}

class HistoricalReviewAdminScreen extends StatelessWidget {
  const HistoricalReviewAdminScreen({
    super.key,
    required this.reviews,
    this.onAction,
  });

  final List<HistoricalReviewRecord> reviews;
  final void Function(HistoricalReviewRecord review, HistoricalReviewAction action, String notes)? onAction;

  @override
  Widget build(BuildContext context) {
    if (reviews.isEmpty) {
      return const Center(
        child: Text('No unresolved historical findings require review.'),
      );
    }

    return ListView.builder(
      itemCount: reviews.length,
      itemBuilder: (context, index) {
        final review = reviews[index];
        return Card(
          margin: const EdgeInsets.all(8),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${review.entityType}: ${review.entityId}'),
                const SizedBox(height: 8),
                Text('Finding: ${review.findingType}'),
                Text('Severity: ${review.severity.name}'),
                Text('Ledger balance: ${review.ledgerBalance}'),
                Text('Legacy balance: ${review.legacyCurrentBalance ?? 'n/a'}'),
                Text('Opening balance: ${review.masterOpeningBalance ?? 'n/a'}'),
                Text('Opening entries: ${review.openingLedgerCount}'),
                Text('Difference: ${review.difference}'),
                Text('Status: ${review.status.name}'),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    ElevatedButton(
                      onPressed: () => onAction?.call(review, HistoricalReviewAction.requireEvidence, 'Evidence required for review.'),
                      child: const Text('Require Evidence'),
                    ),
                    ElevatedButton(
                      onPressed: () => onAction?.call(review, HistoricalReviewAction.approveForFutureRepair, 'Approved for future repair only; no repair executed.'),
                      child: const Text('Approve for Future Repair'),
                    ),
                    ElevatedButton(
                      onPressed: () => onAction?.call(review, HistoricalReviewAction.reject, 'Rejected after review.'),
                      child: const Text('Reject'),
                    ),
                    ElevatedButton(
                      onPressed: () => onAction?.call(review, HistoricalReviewAction.defer, 'Deferred pending additional evidence.'),
                      child: const Text('Defer'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
