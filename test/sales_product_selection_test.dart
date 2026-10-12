import 'package:bayaa_pos/features/products/data/models/product_model.dart';
import 'package:bayaa_pos/features/sales/presentation/widgets/product_search_overlay.dart';
import 'package:bayaa_pos/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'search selection returns the resolved Product instead of its display code',
    (tester) async {
      final product = Product(
        id: 'product-123',
        name: 'Notebook',
        barcode: 'LEGACY-SALE',
        internalReference: 'LEGACY-SALE',
        price: 25,
        minPrice: 0,
        wholesalePrice: 20,
        quantity: 8,
        minQuantity: 0,
        category: 'sales-category',
      );
      Product? selected;

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: ProductSearchOverlay(
              products: [product],
              onProductSelected: (value) => selected = value,
            ),
          ),
        ),
      );

      await tester.tap(find.text('Notebook'));

      expect(selected, same(product));
      expect(selected!.id, 'product-123');
      expect(selected!.barcode, 'LEGACY-SALE');
    },
  );
}
