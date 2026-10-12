import 'package:bayaa_pos/features/products/data/models/selling_unit_model.dart';
import 'package:bayaa_pos/features/products/data/models/product_model.dart';
import 'package:bayaa_pos/features/sales/presentation/sales_cart_line.dart';
import 'package:bayaa_pos/features/sales/presentation/widgets/selling_unit_selector_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final piece = SellingUnit(
    id: 'unit-piece',
    productId: 'product-water',
    name: 'Piece',
    conversionToBase: 1,
    sellingPrice: 20,
    isDefault: true,
  );
  final pack = SellingUnit(
    id: 'unit-pack',
    productId: 'product-water',
    name: 'Pack',
    conversionToBase: 30,
    sellingPrice: 290,
  );

  testWidgets('Piece card returns Piece selling unit', (tester) async {
    late Future<SellingUnit?> resultFuture;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () {
                resultFuture = showDialog<SellingUnit>(
                  context: context,
                  builder: (_) =>
                      SellingUnitSelectorDialog(units: [piece, pack]),
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Piece'));
    await tester.pumpAndSettle();

    final selected = await resultFuture;
    expect(selected, same(piece));
    expect(selected!.id, 'unit-piece');
    expect(selected.conversionToBase, 1.0);
    expect(selected.sellingPrice, 20.0);
  });

  testWidgets('Pack card returns Pack selling unit', (tester) async {
    late Future<SellingUnit?> resultFuture;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () {
                resultFuture = showDialog<SellingUnit>(
                  context: context,
                  builder: (_) =>
                      SellingUnitSelectorDialog(units: [piece, pack]),
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pack'));
    await tester.pumpAndSettle();

    final selected = await resultFuture;
    expect(selected, same(pack));
    expect(selected!.id, 'unit-pack');
    expect(selected.conversionToBase, 30.0);
    expect(selected.sellingPrice, 290.0);
  });

  test('Piece and Pack selections create distinct canonical cart lines', () {
    final product = Product(
      id: 'product-water',
      name: 'Water',
      barcode: 'WATER',
      price: 20,
      minPrice: 0,
      wholesalePrice: 18,
      quantity: 300,
      minQuantity: 0,
      category: 'Drinks',
      productType: ProductType.packaged,
    );
    final date = DateTime(2026);

    final pieceLine = createSalesCartLine(
      product: product,
      sellingUnit: piece,
      date: date,
    );
    expect(pieceLine['productId'], 'product-water');
    expect(pieceLine['sellingUnitId'], 'unit-piece');
    expect(pieceLine['sellingUnitNameSnapshot'], 'Piece');
    expect(pieceLine['conversionFactorSnapshot'], 1.0);
    expect(pieceLine['baseQuantity'], pieceLine['sellingQuantity']);
    expect(pieceLine['price'], 20.0);

    final packLine = createSalesCartLine(
      product: product,
      sellingUnit: pack,
      date: date,
    );
    expect(packLine['productId'], 'product-water');
    expect(packLine['sellingUnitId'], 'unit-pack');
    expect(packLine['sellingUnitNameSnapshot'], 'Pack');
    expect(packLine['conversionFactorSnapshot'], 30.0);
    expect(
      packLine['baseQuantity'],
      (packLine['sellingQuantity'] as num) * 30.0,
    );
    expect(packLine['price'], 290.0);
  });

  test('configured selling units stay available when selected unit changes', () {
    final product = Product(
      id: 'product-water',
      name: 'Water',
      price: 30,
      minPrice: 0,
      wholesalePrice: 25,
      quantity: 104,
      minQuantity: 0,
      category: 'Drinks',
      productType: ProductType.packaged,
      sellingUnits: [piece, pack],
    );
    final pieceLine = createSalesCartLine(
      product: product,
      sellingUnit: piece,
      date: DateTime(2026),
    );
    final packLine = createSalesCartLine(
      product: product,
      sellingUnit: pack,
      date: DateTime(2026),
    );

    expect((pieceLine['sellingUnits'] as List).map((unit) => unit.name),
        ['Piece', 'Pack']);
    expect((packLine['sellingUnits'] as List).map((unit) => unit.name),
        ['Piece', 'Pack']);
    expect(pieceLine['sellingUnitId'], 'unit-piece');
    expect(packLine['sellingUnitId'], 'unit-pack');
    expect(calculateCartRemaining(pieceLine), 103);
    expect(calculateCartRemaining(packLine), 74);
  });

  test('single configured selling unit remains a single stable option', () {
    final product = Product(
      id: 'product-single',
      name: 'Single',
      price: 30,
      minPrice: 0,
      wholesalePrice: 25,
      quantity: 104,
      minQuantity: 0,
      category: 'Drinks',
      sellingUnits: [piece],
    );
    final line = createSalesCartLine(
      product: product,
      sellingUnit: piece,
      date: DateTime(2026),
    );
    expect((line['sellingUnits'] as List).length, 1);
  });

  test('switching units preserves selling quantity and recalculates base data', () {
    final piece30 = piece.copyWith(sellingPrice: 30);
    final pack240 = pack.copyWith(sellingPrice: 240);
    final product = Product(
      id: 'product-water',
      name: 'Water',
      price: 30,
      minPrice: 0,
      wholesalePrice: 25,
      quantity: 900,
      minQuantity: 0,
      category: 'Drinks',
      productType: ProductType.packaged,
      sellingUnits: [piece30, pack240],
    );
    var line = createSalesCartLine(
      product: product,
      sellingUnit: piece30,
      date: DateTime(2026),
    );
    expect(line['qty'], 1.0);
    expect(line['baseQuantity'], 1.0);
    expect(calculateCartRemaining(line), 899);
    expect(line['price'], 30.0);

    line = switchCartSellingUnit(line, pack240);
    expect(line['qty'], 1.0);
    expect(line['conversionFactorSnapshot'], 30.0);
    expect(line['baseQuantity'], 30.0);
    expect(calculateCartRemaining(line), 870);
    expect(line['price'], 240.0);

    line['qty'] = 2.0;
    line['sellingQuantity'] = 2.0;
    line['baseQuantity'] = 60.0;
    expect(calculateCartRemaining(line), 840);
    line['qty'] = 3.0;
    line['sellingQuantity'] = 3.0;
    line['baseQuantity'] = 90.0;
    expect(calculateCartRemaining(line), 810);
    expect(maxSellingQuantity(line), 30);

    line = switchCartSellingUnit(line, piece30);
    expect(line['qty'], 3.0);
    expect(line['baseQuantity'], 3.0);
    expect(calculateCartRemaining(line), 897);
    expect(maxSellingQuantity(line), 900);
    line = switchCartSellingUnit(line, pack240);
    expect(line['qty'], 3.0);
    expect(line['baseQuantity'], 90.0);
    expect((line['sellingUnits'] as List).length, 2);
  });

  test('switching one piece to a pack is valid when stock covers the new base quantity',
      () {
    final piece30 = piece.copyWith(sellingPrice: 30);
    final pack240 = pack.copyWith(sellingPrice: 240);
    final product = Product(
      id: 'product-water',
      name: 'Water',
      price: 30,
      minPrice: 0,
      wholesalePrice: 25,
      quantity: 900,
      minQuantity: 0,
      category: 'Drinks',
      productType: ProductType.packaged,
      sellingUnits: [piece30, pack240],
    );
    var line = createSalesCartLine(
      product: product,
      sellingUnit: piece30,
      date: DateTime(2026),
    );
    line = switchCartSellingUnit(line, pack240);
    expect(line['qty'], 1.0);
    expect(line['baseQuantity'], 30.0);
    expect(isValidCartQuantity(line, line['qty'] as double), isTrue);
  });

  test('cart line uses persisted product code instead of internal id', () {
    final product = Product(
      id: 'product-generated-id',
      code: 'WATER-001',
      name: 'Water',
      barcode: '987654321',
      price: 20,
      minPrice: 0,
      wholesalePrice: 18,
      quantity: 104,
      minQuantity: 0,
      category: 'Drinks',
    );

    final line = createSalesCartLine(
      product: product,
      date: DateTime(2026),
    );

    expect(line['displayCode'], 'WATER-001');
    expect(line['displayCode'], isNot('product-generated-id'));
  });

  test('packaged cart stock uses base quantity for remaining stock', () {
    final product = Product(
      id: 'product-water',
      code: 'WATER-001',
      name: 'Water',
      barcode: '987654321',
      price: 20,
      minPrice: 0,
      wholesalePrice: 18,
      quantity: 104,
      minQuantity: 0,
      category: 'Drinks',
      productType: ProductType.packaged,
    );
    final line = createSalesCartLine(
      product: product,
      sellingUnit: pack,
      date: DateTime(2026),
    );

    expect(line['quantity'], 104);
    expect(line['baseQuantity'], 30);
    expect((line['quantity'] as num).toDouble(), isNot(double.maxFinite));
  });

  test('remaining stock uses authoritative stock for standard quantities', () {
    final product = Product(
      id: 'product-pepsi',
      code: 'PEPSI-001',
      barcode: '123456790',
      name: 'Test Pepsi',
      price: 30,
      minPrice: 0,
      wholesalePrice: 25,
      quantity: 104,
      minQuantity: 0,
      category: 'Drinks',
    );
    final line = createSalesCartLine(product: product, date: DateTime(2026));

    expect(calculateCartRemaining(line), 103);
    line['qty'] = 2.0;
    line['sellingQuantity'] = 2.0;
    line['baseQuantity'] = 2.0;
    expect(calculateCartRemaining(line), 102);
    expect(line['stock'], 104);
  });

  test('remaining stock uses packaged base quantity without corrupting stock', () {
    final product = Product(
      id: 'product-water',
      name: 'Water',
      price: 30,
      minPrice: 0,
      wholesalePrice: 25,
      quantity: 104,
      minQuantity: 0,
      category: 'Drinks',
      productType: ProductType.packaged,
    );
    final line = createSalesCartLine(
      product: product,
      sellingUnit: pack,
      date: DateTime(2026),
    );

    expect(calculateCartRemaining(line), 74);
    line['qty'] = 2.0;
    line['sellingQuantity'] = 2.0;
    line['baseQuantity'] = 60.0;
    expect(calculateCartRemaining(line), 44);
    expect(line['stock'], 104);
  });

  test('cart quantity boundaries preserve one and use selling-unit stock', () {
    final product = Product(
      id: 'product-pepsi',
      name: 'Test Pepsi',
      price: 30,
      minPrice: 0,
      wholesalePrice: 25,
      quantity: 2,
      minQuantity: 0,
      category: 'Drinks',
    );
    final line = createSalesCartLine(product: product, date: DateTime(2026));

    expect((line['qty'] as num).toDouble(), 1);
    line['qty'] = 2.0;
    line['baseQuantity'] = 2.0;
    expect(calculateCartRemaining(line), 0);
    line['qty'] = 1.0;
    line['baseQuantity'] = 1.0;
    expect(calculateCartRemaining(line), 1);
    expect(line['stock'], 2);
    expect(isValidCartQuantity(line, 1), isTrue);
    expect(isValidCartQuantity(line, 2), isTrue);
    expect(isValidCartQuantity(line, 3), isFalse);
    expect(isValidCartQuantity(line, 0), isFalse);
  });

  test('packaged maximum is based on base stock and conversion', () {
    final product = Product(
      id: 'product-water',
      name: 'Water',
      price: 30,
      minPrice: 0,
      wholesalePrice: 25,
      quantity: 60,
      minQuantity: 0,
      category: 'Drinks',
      productType: ProductType.packaged,
    );
    final line = createSalesCartLine(
      product: product,
      sellingUnit: pack,
      date: DateTime(2026),
    );

    expect(line['stock'], 60);
    expect(line['conversionFactorSnapshot'], 30.0);
    expect(maxSellingQuantity(line), 2);
    expect(isValidCartQuantity(line, 2), isTrue);
    expect(isValidCartQuantity(line, 3), isFalse);
  });
}
