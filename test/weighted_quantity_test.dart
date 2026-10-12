import 'package:bayaa_pos/features/sales/presentation/widgets/cart_item.dart';
import 'package:bayaa_pos/features/sales/presentation/widgets/quantity_format.dart';
import 'package:bayaa_pos/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('weighted quantities are formatted without floating-point artifacts', () {
    expect(formatQuantity(0.40000000000000013), '0.4');
    expect(formatQuantity(1.25), '1.25');
    expect(formatQuantity(1.0), '1');
  });

  testWidgets('weighted quantity input commits a decimal value', (tester) async {
    double? editedQuantity;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: CartItemRow(
            name: 'Rice',
            id: 'rice',
            price: 10,
            quantity: 0.4,
            remainingQuantity: 9.6,
            date: DateTime(2024),
            minPrice: 0,
            productType: 'weighted',
            baseUnit: 'kg',
            onEditQuantity: (value) => editedQuantity = value,
          ),
        ),
      ),
    );

    final quantityField = find.byType(TextField);
    expect(find.text('0.4'), findsOneWidget);
    await tester.tap(quantityField);
    await tester.enterText(quantityField, '1.25');
    tester.binding.focusManager.primaryFocus?.unfocus();
    await tester.pump();

    expect(editedQuantity, 1.25);
  });
}
