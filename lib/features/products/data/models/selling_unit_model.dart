import 'package:uuid/uuid.dart';

String defaultSellingUnitIconKey(String name) {
  switch (name.trim().toLowerCase()) {
    case 'piece':
      return 'package';
    case 'box':
      return 'box';
    case 'bottle':
      return 'bottle';
    case 'can':
      return 'can';
    case 'pack':
      return 'pack';
    case 'carton':
      return 'carton';
    default:
      return 'package';
  }
}

class SellingUnit {
  final String id;
  final String productId;
  final String name;
  final String iconKey;
  final double conversionToBase;
  final double sellingPrice;
  final double cost;
  final double? wholesalePrice;
  final double minimumStock;
  @Deprecated(
      'Selling-unit barcodes are retained only for database compatibility.')
  final String? barcode;
  final bool isDefault;
  final bool isActive;
  final DateTime createdAt;
  final DateTime updatedAt;

  SellingUnit({
    String? id,
    required this.productId,
    required this.name,
    String? iconKey,
    required this.conversionToBase,
    required this.sellingPrice,
    this.cost = 0.0,
    this.wholesalePrice,
    this.minimumStock = 0,
    this.barcode,
    this.isDefault = false,
    this.isActive = true,
    DateTime? createdAt,
    DateTime? updatedAt,
  })  : id = id ?? 'unit-${const Uuid().v4()}',
        iconKey = defaultSellingUnitIconKey(name),
        createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now() {
    if (conversionToBase <= 0) {
      throw ArgumentError.value(conversionToBase, 'conversionToBase',
          'conversionToBase must be greater than zero');
    }
    if (sellingPrice < 0) {
      throw ArgumentError.value(
          sellingPrice, 'sellingPrice', 'sellingPrice cannot be negative');
    }
    if (cost < 0) {
      throw ArgumentError.value(cost, 'cost', 'cost cannot be negative');
    }
    if (wholesalePrice != null && wholesalePrice! < 0) {
      throw ArgumentError.value(wholesalePrice, 'wholesalePrice',
          'wholesalePrice cannot be negative');
    }
    if (minimumStock < 0) {
      throw ArgumentError.value(
          minimumStock, 'minimumStock', 'minimumStock cannot be negative');
    }
    if (name.trim().isEmpty) {
      throw ArgumentError.value(name, 'name', 'Selling unit name is required');
    }
  }

  factory SellingUnit.fromMap(Map<String, dynamic> map) {
    return SellingUnit(
      id: map['id']?.toString(),
      productId:
          map['product_id']?.toString() ?? map['productId']?.toString() ?? '',
      name: map['name']?.toString() ?? '',
      iconKey: map['icon_key']?.toString() ?? map['iconKey']?.toString(),
      conversionToBase:
          ((map['conversion_to_base'] ?? map['conversionToBase'] ?? 1.0) as num)
              .toDouble(),
      sellingPrice:
          ((map['selling_price'] ?? map['sellingPrice'] ?? 0.0) as num)
              .toDouble(),
      cost: ((map['cost_price'] ?? map['cost'] ?? 0.0) as num).toDouble(),
      wholesalePrice: map['wholesale_price'] != null
          ? (map['wholesale_price'] as num).toDouble()
          : map['wholesalePrice'] != null
              ? (map['wholesalePrice'] as num).toDouble()
              : null,
      minimumStock:
          ((map['minimum_stock'] ?? map['min_stock'] ?? 0) as num).toDouble(),
      barcode: map['barcode']?.toString(),
      isDefault: (map['is_default'] ?? map['isDefault'] ?? 0) == 1 ||
          (map['is_default'] ?? map['isDefault']) == true,
      isActive: (map['is_active'] ?? map['isActive'] ?? 1) == 1 ||
          (map['is_active'] ?? map['isActive']) == true,
      createdAt: map['created_at'] != null
          ? DateTime.tryParse(map['created_at'].toString()) ?? DateTime.now()
          : DateTime.now(),
      updatedAt: map['updated_at'] != null
          ? DateTime.tryParse(map['updated_at'].toString()) ?? DateTime.now()
          : DateTime.now(),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'product_id': productId,
      'name': name,
      'icon_key': iconKey,
      'conversion_to_base': conversionToBase,
      'selling_price': sellingPrice,
      'cost_price': cost,
      'wholesale_price': wholesalePrice,
      'minimum_stock': minimumStock,
      'barcode': barcode,
      'is_default': isDefault ? 1 : 0,
      'is_active': isActive ? 1 : 0,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  SellingUnit copyWith({
    String? id,
    String? productId,
    String? name,
    String? iconKey,
    double? conversionToBase,
    double? sellingPrice,
    double? cost,
    double? wholesalePrice,
    double? minimumStock,
    String? barcode,
    bool? isDefault,
    bool? isActive,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return SellingUnit(
      id: id ?? this.id,
      productId: productId ?? this.productId,
      name: name ?? this.name,
      iconKey: iconKey ?? this.iconKey,
      conversionToBase: conversionToBase ?? this.conversionToBase,
      sellingPrice: sellingPrice ?? this.sellingPrice,
      cost: cost ?? this.cost,
      wholesalePrice: wholesalePrice ?? this.wholesalePrice,
      minimumStock: minimumStock ?? this.minimumStock,
      barcode: barcode ?? this.barcode,
      isDefault: isDefault ?? this.isDefault,
      isActive: isActive ?? this.isActive,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
