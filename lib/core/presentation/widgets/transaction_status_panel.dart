import 'package:flutter/material.dart';

enum TransactionStatus { ready, processing, success, error, completed }

class TransactionStatusPanel extends StatelessWidget {
  const TransactionStatusPanel({
    super.key,
    required this.status,
    required this.message,
    this.details = const [],
  });

  final TransactionStatus status;
  final String message;
  final List<String> details;

  @override
  Widget build(BuildContext context) {
    if (status == TransactionStatus.ready) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final color = switch (status) {
      TransactionStatus.processing => theme.colorScheme.primary,
      TransactionStatus.success || TransactionStatus.completed => Colors.green,
      TransactionStatus.error => theme.colorScheme.error,
      TransactionStatus.ready => theme.colorScheme.outline,
    };
    final icon = switch (status) {
      TransactionStatus.processing => Icons.hourglass_top_rounded,
      TransactionStatus.success ||
      TransactionStatus.completed =>
        Icons.check_circle_outline,
      TransactionStatus.error => Icons.error_outline,
      TransactionStatus.ready => Icons.info_outline,
    };
    return Card(
      color: color.withValues(alpha: 0.08),
      margin: const EdgeInsets.only(top: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: color),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(message,
                      style:
                          TextStyle(color: color, fontWeight: FontWeight.w700)),
                  for (final detail in details)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(detail),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
