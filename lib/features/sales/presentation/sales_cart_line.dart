import 'package:bayaa_pos/features/products/data/models/product_model.dart';
import 'package:bayaa_pos/features/products/data/models/selling_unit_model.dart';

Map<String, dynamic> createSalesCartLine({
  required Product product,
  SellingUnit? sellingUnit,
  required DateTime date,
}) {
  final quantity = 1.0;
  final conversion = sellingUnit?.conversionToBase ?? 1.0;

  return {
    'lineKey':
        sellingUnit == null ? product.id : '${product.id}:${sellingUnit.id}',
    'id': product.id,
    'displayCode': _displayCode(product),
    'productId': product.id,
    'name': product.name,
    'price': sellingUnit?.sellingPrice ?? product.price,
    'qty': quantity,
    'quantity': product.quantity,
    'stock': product.quantity,
    'wholesalePrice': product.wholesalePrice,
    'date': date,
    'minPrice': product.minPrice,
    'productType': product.productType.name,
    'allowPartialPackageSale': product.allowPartialPackageSale,
    'sellingUnitId': sellingUnit?.id,
    'sellingQuantity': quantity,
    'baseQuantity': quantity * conversion,
    'conversionFactorSnapshot': conversion,
    'sellingUnitNameSnapshot': sellingUnit?.name,
    'sellingUnitIconKey': sellingUnit?.iconKey,
    'baseUnitSnapshot': product.baseUnit,
    'sellingUnits': product.sellingUnits
        .where((unit) => unit.isActive)
        .toList(growable: false),
  };
}

double calculateCartRemaining(Map<String, dynamic> item) {
  final stock = (item['stock'] as num?)?.toDouble() ?? 0.0;
  final baseQuantity = (item['baseQuantity'] as num?)?.toDouble() ??
      (item['qty'] as num?)?.toDouble() ??
      0.0;
  return stock - baseQuantity;
}

double maxSellingQuantity(Map<String, dynamic> item) {
  final stock = (item['stock'] as num?)?.toDouble() ??
      (item['quantity'] as num?)?.toDouble() ??
      0.0;
  final conversion =
      (item['conversionFactorSnapshot'] as num?)?.toDouble() ?? 1.0;
  return conversion > 0 ? stock / conversion : stock;
}

bool isValidCartQuantity(Map<String, dynamic> item, double quantity) {
  if (quantity <= 0 || quantity > maxSellingQuantity(item)) return false;
  if (item['productType'] == ProductType.packaged.name &&
      item['allowPartialPackageSale'] != true) {
    return quantity == quantity.roundToDouble();
  }
  return true;
}

Map<String, dynamic> switchCartSellingUnit(
  Map<String, dynamic> item,
  SellingUnit unit,
) {
  final quantity = (item['qty'] as num).toDouble();
  return {
    ...item,
    'lineKey': '${item['productId'] ?? item['id']}:${unit.id}',
    'price': unit.sellingPrice,
    'sellingUnitId': unit.id,
    'sellingUnitNameSnapshot': unit.name,
    'sellingUnitIconKey': unit.iconKey,
    'conversionFactorSnapshot': unit.conversionToBase,
    'qty': quantity,
    'sellingQuantity': quantity,
    'baseQuantity': quantity * unit.conversionToBase,
  };
}

String _displayCode(Product product) {
  final code = product.code?.trim();
  return code ?? '';
}
