import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bayaa_pos/core/presentation/widgets/searchable_selection_dialog.dart';

void main() {
  Widget buildDialog() {
    return MaterialApp(
      home: Scaffold(
        body: SearchableSelectionDialog<(String, String, String, String)>(
          title: 'Select supplier',
          searchHint: 'Search supplier...',
          items: const [
            ('supplier-1', 'Nasro', 'SUP-000001', '0671688588'),
            ('supplier-2', 'ABC Trading', 'SUP-000002', '0554444444'),
          ],
          filter: (item, query) => [
            item.$2,
            item.$3,
            item.$4,
          ].any((value) => value.toLowerCase().contains(query)),
          itemBuilder: (_, item) => ListTile(
            title: Text(item.$2),
            subtitle: Text('${item.$3} · ${item.$4}'),
          ),
          emptyMessage: 'No suppliers available.',
          noResultsMessage: 'No suppliers found.',
          searchIcon: Icons.search,
        ),
      ),
    );
  }

  testWidgets('filters by name, code, phone, and whitespace', (tester) async {
    await tester.pumpWidget(buildDialog());

    final search = find.byType(TextField);
    await tester.enterText(search, '  000002 ');
    await tester.pump();
    expect(find.text('ABC Trading'), findsOneWidget);
    expect(find.text('Nasro'), findsNothing);

    await tester.enterText(search, '0671');
    await tester.pump();
    expect(find.text('Nasro'), findsOneWidget);
    expect(find.text('ABC Trading'), findsNothing);
  });

  testWidgets('shows no-result state and returns the original item',
      (tester) async {
    await tester.pumpWidget(buildDialog());
    await tester.enterText(find.byType(TextField), 'unknown');
    await tester.pump();
    expect(find.text('No suppliers found.'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'nas');
    await tester.pump();
    await tester.tap(find.text('Nasro'));
    await tester.pumpAndSettle();
    expect(find.text('Nasro'), findsNothing);
  });
}
