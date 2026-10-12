import 'package:flutter_test/flutter_test.dart';

import 'package:bayaa_pos/features/products/data/models/product_model.dart';
import 'package:bayaa_pos/features/products/data/models/selling_unit_model.dart';
import 'package:bayaa_pos/features/sales/presentation/sales_cart_line.dart';

void main() {
  final pack = SellingUnit(
    id: 'pack',
    productId: 'p',
    name: 'Pack',
    conversionToBase: 6,
    sellingPrice: 500,
  );

  Product product({bool partial = false}) => Product(
        id: 'p',
        name: 'Coca-Cola',
        productType: ProductType.packaged,
        baseUnit: 'piece',
        allowPartialPackageSale: partial,
        price: 120,
        minPrice: 100,
        wholesalePrice: 110,
        quantity: 25,
        minQuantity: 0,
        category: 'General',
        sellingUnits: [pack],
      );

  test('packaged stock limit uses base quantity', () {
    final item = createSalesCartLine(
      product: product(),
      sellingUnit: pack,
      date: DateTime.now(),
    );
    expect(maxSellingQuantity(item), closeTo(25 / 6, 0.000001));
    expect(isValidCartQuantity(item, 1), isTrue);
    expect(isValidCartQuantity(item, 4), isTrue);
    expect(isValidCartQuantity(item, 5), isFalse);
  });

  test('partial package policy rejects or accepts fractional packages', () {
    final rejected = createSalesCartLine(
      product: product(),
      sellingUnit: pack,
      date: DateTime.now(),
    );
    expect(isValidCartQuantity(rejected, 0.5), isFalse);

    final allowed = createSalesCartLine(
      product: product(partial: true),
      sellingUnit: pack,
      date: DateTime.now(),
    );
    expect(isValidCartQuantity(allowed, 0.5), isTrue);
    expect(allowed['baseQuantity'], 6.0);
    allowed['qty'] = 0.5;
    allowed['baseQuantity'] = 0.5 * pack.conversionToBase;
    expect(allowed['baseQuantity'], 3.0);
  });
}
