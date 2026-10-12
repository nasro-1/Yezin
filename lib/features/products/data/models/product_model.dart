import 'selling_unit_model.dart';

class OpeningStockLine {
  final String unit;
  final double quantity;
  final double unitCost;

  const OpeningStockLine({
    required this.unit,
    required this.quantity,
    required this.unitCost,
  });
}

enum ProductType {
  standard,
  weighted,
  packaged;

  static ProductType fromValue(Object? value) {
    final normalized = (value ?? '').toString().toUpperCase();
    switch (normalized) {
      case 'STANDARD':
        return ProductType.standard;
      case 'WEIGHTED':
        return ProductType.weighted;
      case 'PACKAGED':
        return ProductType.packaged;
      default:
        return ProductType.standard;
    }
  }

  String get value => name.toUpperCase();
}

class Product {
  final String id;
  final String name;
  final String? code;
  final String barcode;
  final String? internalReference;
  final ProductType productType;
  final String baseUnit;
  final int quantityPrecision;
  final bool allowPartialPackageSale;
  double price;
  double minPrice;
  double wholesalePrice;
  double cost;
  double quantity;
  final int minQuantity;
  final String category;
  final String? categoryName;
  final String? imagePath;
  final bool isActive;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final List<SellingUnit> sellingUnits;
  final String? matchedSellingUnitId;
  final String? matchedSellingUnitName;

  Product({
    String? id,
    required this.name,
    this.code,
    String? barcode,
    this.internalReference,
    ProductType? productType,
    String? baseUnit,
    int? quantityPrecision,
    bool? allowPartialPackageSale,
    required this.price,
    required this.minPrice,
    required this.wholesalePrice,
    this.cost = 0.0,
    required this.quantity,
    required this.minQuantity,
    required this.category,
    this.categoryName,
    this.imagePath,
    this.isActive = true,
    this.createdAt,
    this.updatedAt,
    this.sellingUnits = const [],
    this.matchedSellingUnitId,
    this.matchedSellingUnitName,
  })  : id = id ??
            (barcode ?? 'product-${DateTime.now().microsecondsSinceEpoch}'),
        barcode = barcode ?? '',
        productType = productType ?? ProductType.standard,
        baseUnit = baseUnit ?? 'piece',
        quantityPrecision = quantityPrecision ?? 3,
        allowPartialPackageSale = allowPartialPackageSale ?? false;

  factory Product.fromMap(Map<String, dynamic> map) {
    return Product(
      id: map['id']?.toString() ?? '',
      name: map['name']?.toString() ?? '',
      code: map['code']?.toString(),
      barcode: map['barcode']?.toString(),
      internalReference: map['internal_reference']?.toString(),
      productType:
          ProductType.fromValue(map['product_type'] ?? map['productType']),
      baseUnit: map['base_unit']?.toString() ??
          map['baseUnit']?.toString() ??
          'piece',
      quantityPrecision:
          (map['quantity_precision'] ?? map['quantityPrecision'] ?? 3) as int,
      allowPartialPackageSale: (map['allow_partial_package_sale'] ??
                  map['allowPartialPackageSale'] ??
                  0) ==
              1 ||
          (map['allow_partial_package_sale'] ??
                  map['allowPartialPackageSale']) ==
              true,
      price: (map['price'] as num?)?.toDouble() ?? 0.0,
      minPrice:
          ((map['min_price'] ?? map['minPrice'] ?? 0.0) as num).toDouble(),
      wholesalePrice:
          ((map['wholesale_price'] ?? map['wholesalePrice'] ?? 0.0) as num)
              .toDouble(),
      cost: ((map['cost'] ?? 0.0) as num).toDouble(),
      quantity: ((map['quantity'] ?? map['stock'] ?? 0) as num).toDouble(),
      minQuantity:
          ((map['min_quantity'] ?? map['min_stock'] ?? 0) as num).toInt(),
      category: map['category']?.toString() ??
          map['category_id']?.toString() ??
          'General',
      categoryName: map['category_name']?.toString(),
      imagePath: map['image_path']?.toString() ?? map['imagePath']?.toString(),
      isActive: _readBool(map['is_active'], defaultValue: true),
      createdAt: map['created_at'] != null
          ? DateTime.tryParse(map['created_at'].toString())
          : null,
      updatedAt: map['updated_at'] != null
          ? DateTime.tryParse(map['updated_at'].toString())
          : null,
      sellingUnits: (map['selling_units'] is List)
          ? (map['selling_units'] as List)
              .map((unit) {
                if (unit is SellingUnit) return unit;
                if (unit is Map) {
                  return SellingUnit.fromMap(
                    Map<String, dynamic>.from(unit),
                  );
                }
                return null;
              })
              .whereType<SellingUnit>()
              .where((unit) => unit.isActive)
              .toList()
          : const [],
      matchedSellingUnitId: map['matched_selling_unit_id']?.toString(),
      matchedSellingUnitName: map['matched_selling_unit_name']?.toString(),
    );
  }

  static bool _readBool(Object? value, {required bool defaultValue}) {
    if (value == null) return defaultValue;
    if (value is bool) return value;
    if (value is num) return value == 1;
    return value.toString().toLowerCase() == 'true';
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'barcode': barcode.trim().isEmpty ? null : barcode.trim(),
      'internal_reference': internalReference,
      'product_type': productType.value,
      'base_unit': baseUnit,
      'quantity_precision': quantityPrecision,
      'allow_partial_package_sale': allowPartialPackageSale ? 1 : 0,
      'price': price,
      'min_price': minPrice,
      'wholesale_price': wholesalePrice,
      'cost': cost,
      'stock': quantity,
      'min_stock': minQuantity,
      'category_id': category,
      'image_path': imagePath,
      'is_active': isActive ? 1 : 0,
      'created_at': createdAt?.toIso8601String(),
      'updated_at': updatedAt?.toIso8601String(),
    };
  }

  String get formattedQuantity => _formatQuantity(quantity);

  String get quantityWithBaseUnit => '$formattedQuantity $baseUnit';

  String get displayCategoryName {
    final name = categoryName?.trim();
    if (name != null && name.isNotEmpty && !_isCategoryIdentifier(name)) {
      return name;
    }
    final value = category.trim();
    if (_isCategoryIdentifier(value)) return '';
    return value;
  }

  static bool _isCategoryIdentifier(String value) =>
      value.startsWith('category-') ||
      RegExp(
        r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
      ).hasMatch(value);

  static String _formatQuantity(num value) {
    final normalized = value.toDouble().toStringAsFixed(3);
    return normalized
        .replaceFirst(RegExp(r'\.?0+$'), '')
        .replaceFirst(RegExp(r'\.$'), '');
  }

  String get status {
    if (quantity == 0) return 'outOfStock';
    if (quantity <= effectiveMinimumStock) return 'lowStock';
    return 'available';
  }

  /// Returns the single base-unit threshold used for product low-stock status.
  ///
  /// Each active selling-unit threshold is converted to base units before
  /// comparison. The highest converted threshold wins over the product-level
  /// base-unit minimum; stock itself remains one base-unit quantity.
  double get effectiveMinimumStock {
    final unitThreshold = sellingUnits
        .where((unit) => unit.isActive && unit.minimumStock > 0)
        .fold<double>(
          0,
          (threshold, unit) =>
              threshold > unit.minimumStock * unit.conversionToBase
                  ? threshold
                  : unit.minimumStock * unit.conversionToBase,
        );
    return unitThreshold > minQuantity ? unitThreshold : minQuantity.toDouble();
  }

  String get priority {
    if (quantity == 0) return 'veryHigh';
    final diff = effectiveMinimumStock - quantity;
    if (diff >= 3) return 'high';
    if (diff == 1 || diff == 2) return 'medium';
    return 'low';
  }

  Product copyWith({
    String? id,
    String? name,
    String? code,
    String? barcode,
    String? internalReference,
    ProductType? productType,
    String? baseUnit,
    int? quantityPrecision,
    bool? allowPartialPackageSale,
    double? price,
    double? minPrice,
    double? wholesalePrice,
    double? cost,
    double? quantity,
    int? minQuantity,
    String? category,
    String? categoryName,
    String? imagePath,
    bool? isActive,
    DateTime? createdAt,
    DateTime? updatedAt,
    String? matchedSellingUnitId,
    String? matchedSellingUnitName,
  }) {
    return Product(
      id: id ?? this.id,
      name: name ?? this.name,
      code: code ?? this.code,
      barcode: barcode ?? this.barcode,
      internalReference: internalReference ?? this.internalReference,
      productType: productType ?? this.productType,
      baseUnit: baseUnit ?? this.baseUnit,
      quantityPrecision: quantityPrecision ?? this.quantityPrecision,
      allowPartialPackageSale:
          allowPartialPackageSale ?? this.allowPartialPackageSale,
      price: price ?? this.price,
      minPrice: minPrice ?? this.minPrice,
      wholesalePrice: wholesalePrice ?? this.wholesalePrice,
      cost: cost ?? this.cost,
      quantity: quantity ?? this.quantity,
      minQuantity: minQuantity ?? this.minQuantity,
      category: category ?? this.category,
      categoryName: categoryName ?? this.categoryName,
      imagePath: imagePath ?? this.imagePath,
      isActive: isActive ?? this.isActive,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      sellingUnits: sellingUnits,
      matchedSellingUnitId: matchedSellingUnitId ?? this.matchedSellingUnitId,
      matchedSellingUnitName:
          matchedSellingUnitName ?? this.matchedSellingUnitName,
    );
  }
}
