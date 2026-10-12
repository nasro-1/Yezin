import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bayaa_pos/core/presentation/widgets/transaction_status_panel.dart';

void main() {
  testWidgets('processing status explains that the transaction is in progress',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: TransactionStatusPanel(
          status: TransactionStatus.processing,
          message: 'Posting purchase...',
        ),
      ),
    ));

    expect(find.text('Posting purchase...'), findsOneWidget);
    expect(find.byIcon(Icons.hourglass_top_rounded), findsOneWidget);
  });

  testWidgets('completed status displays persisted result details',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: TransactionStatusPanel(
          status: TransactionStatus.completed,
          message: 'Payment recorded successfully.',
          details: ['Reference: PAY-1', 'Amount: 100,00 DA'],
        ),
      ),
    ));

    expect(find.text('Payment recorded successfully.'), findsOneWidget);
    expect(find.text('Reference: PAY-1'), findsOneWidget);
    expect(find.text('Amount: 100,00 DA'), findsOneWidget);
  });
}
