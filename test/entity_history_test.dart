import 'package:flutter_test/flutter_test.dart';

import 'package:bayaa_pos/features/customers/presentation/entity_history_dialog.dart';

void main() {
  final newest = EntityHistoryEntry(
    kind: EntityHistoryKind.payments,
    reference: 'PAY-2',
    date: DateTime(2026, 9, 15),
    amount: 600,
    status: 'confirmed',
    description: 'Supplier Payment',
    data: const {},
  );
  final older = EntityHistoryEntry(
    kind: EntityHistoryKind.purchases,
    reference: 'PUR-1',
    date: DateTime(2026, 9, 14),
    amount: 2000,
    status: 'confirmed',
    description: 'Purchase',
    data: const {},
  );

  test('entity history returns all entries newest first', () {
    final result = filterEntityHistory([older, newest], EntityHistoryKind.all);

    expect(result.map((entry) => entry.reference), ['PAY-2', 'PUR-1']);
  });

  test('entity history filters by transaction type', () {
    final result =
        filterEntityHistory([older, newest], EntityHistoryKind.payments);

    expect(result, hasLength(1));
    expect(result.single.reference, 'PAY-2');
  });
}
