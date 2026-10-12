import 'package:equatable/equatable.dart';

enum SaleDraftStatus { open, held }
enum SaleDraftVisibility { private, shared }

SaleDraftStatus saleDraftStatusFromJson(Object? value) {
  final status = value?.toString().toLowerCase();
  return status == 'held' || status == 'on_hold' || status == 'on-hold'
      ? SaleDraftStatus.held
      : SaleDraftStatus.open;
}

SaleDraftVisibility saleDraftVisibilityFromJson(Object? value) {
  final visibility = value?.toString().toUpperCase();
  return visibility == 'SHARED' ? SaleDraftVisibility.shared : SaleDraftVisibility.private;
}

class SaleDraftItem extends Equatable {
  const SaleDraftItem({
    required this.productId,
    required this.name,
    required this.quantity,
    required this.unitPrice,
    this.id,
    this.unit = 'piece',
    this.baseQuantity,
    this.conversionFactor,
    this.sellingUnitId,
    this.productType,
    this.iconKey,
    this.code,
    this.barcode,
    this.stock,
  });

  final String productId;
  final String name;
  final String? id;
  final double quantity;
  final double unitPrice;
  final String unit;
  final double? baseQuantity;
  final double? conversionFactor;
  final String? sellingUnitId;
  final String? productType;
  final String? iconKey;
  final String? code;
  final String? barcode;
  final double? stock;

  double get lineTotal => quantity * unitPrice;

  Map<String, dynamic> toJson() => {
        if (id != null) 'id': id,
        'product_id': productId,
        'name': name,
        'quantity': quantity,
        'unit_price': unitPrice,
        'unit': unit,
        if (baseQuantity != null) 'base_quantity': baseQuantity,
        if (conversionFactor != null) 'conversion_factor': conversionFactor,
        if (sellingUnitId != null) 'selling_unit_id': sellingUnitId,
        if (productType != null) 'product_type': productType,
        if (iconKey != null) 'icon_key': iconKey,
      };

  Map<String, dynamic> toMap() => toJson();

  factory SaleDraftItem.fromMap(Map<String, dynamic> map) =>
      SaleDraftItem.fromJson(map);

  factory SaleDraftItem.fromJson(Map<String, dynamic> json) {
    double number(Object? value, [double fallback = 0]) =>
        value is num ? value.toDouble() : double.tryParse('$value') ?? fallback;
    String? string(Object? value) => value == null ? null : '$value';

    return SaleDraftItem(
      productId:
          string(json['product_id'] ?? json['productId'] ?? json['id']) ?? '',
      name: string(json['name'] ?? json['product_name']) ?? '',
      id: string(json['id']),
      quantity: number(json['quantity'] ?? json['qty']),
      unitPrice:
          number(json['unit_price'] ?? json['unitPrice'] ?? json['price']),
      unit: string(json['unit'] ?? json['unit_name']) ?? 'piece',
      baseQuantity:
          json['base_quantity'] == null && json['baseQuantity'] == null
              ? null
              : number(json['base_quantity'] ?? json['baseQuantity']),
      conversionFactor:
          json['conversion_factor'] == null && json['conversionFactor'] == null
              ? null
              : number(json['conversion_factor'] ?? json['conversionFactor']),
      sellingUnitId: string(json['selling_unit_id'] ?? json['sellingUnitId']),
      productType: string(json['product_type'] ?? json['productType']),
      iconKey: string(json['icon_key'] ?? json['iconKey']),
      code: string(json['code']),
      barcode: string(json['barcode']),
      stock: json['stock'] == null ? null : number(json['stock']),
    );
  }

  @override
  List<Object?> get props => [
        productId,
        name,
        id,
        quantity,
        unitPrice,
        unit,
        baseQuantity,
        conversionFactor,
        sellingUnitId,
        productType,
        iconKey,
        code,
        barcode,
        stock,
      ];
}

class SaleDraft extends Equatable {
  const SaleDraft({
    required this.id,
    required this.version,
    this.saleNumber = 0,
    required this.status,
    required this.items,
    this.createdAt,
    this.updatedAt,
    this.customerId,
    this.customerName,
    this.paymentMethod = 'cash',
    this.discount = 0,
    this.title,
    this.visibility = SaleDraftVisibility.private,
    this.ownerId,
    this.ownerName,
  });

  final String id;
  final int saleNumber;
  final int version;
  final SaleDraftStatus status;
  final SaleDraftVisibility visibility;
  final List<SaleDraftItem> items;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final String? customerId;
  final String? customerName;
  final String paymentMethod;
  final double discount;
  final String? title;
  final String? ownerId;
  final String? ownerName;

  bool get isHeld => status == SaleDraftStatus.held;
  bool get isOpen => !isHeld;
  List<SaleDraftItem> get lines => items;
  double get subtotal =>
      items.fold<double>(0, (total, item) => total + item.lineTotal);
  double get total => subtotal - discount;

  SaleDraft copyWith({
    String? id,
    int? version,
    int? saleNumber,
    SaleDraftStatus? status,
    SaleDraftVisibility? visibility,
    List<SaleDraftItem>? items,
    DateTime? createdAt,
    DateTime? updatedAt,
    String? customerId,
    String? customerName,
    String? paymentMethod,
    double? discount,
    String? title,
    String? ownerId,
    String? ownerName,
  }) =>
      SaleDraft(
        id: id ?? this.id,
        saleNumber: saleNumber ?? this.saleNumber,
        version: version ?? this.version,
        status: status ?? this.status,
        visibility: visibility ?? this.visibility,
        items: List.unmodifiable(items ?? this.items),
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        customerId: customerId ?? this.customerId,
        customerName: customerName ?? this.customerName,
        paymentMethod: paymentMethod ?? this.paymentMethod,
        discount: discount ?? this.discount,
        title: title ?? this.title,
        ownerId: ownerId ?? this.ownerId,
        ownerName: ownerName ?? this.ownerName,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'sale_number': saleNumber,
        'version': version,
        'status': status.name,
        'visibility': visibility.name.toUpperCase(),
        'items': items.map((item) => item.toJson()).toList(),
        if (createdAt != null) 'created_at': createdAt!.toIso8601String(),
        if (updatedAt != null) 'updated_at': updatedAt!.toIso8601String(),
        if (customerId != null) 'customer_id': customerId,
        if (customerName != null) 'customer_name': customerName,
        'payment_method': paymentMethod,
        'discount': discount,
        if (title != null) 'title': title,
        if (ownerId != null) 'owner_id': ownerId,
        if (ownerName != null) 'owner_name': ownerName,
      };

  Map<String, dynamic> toMap() => toJson();

  factory SaleDraft.fromMap(Map<String, dynamic> map) =>
      SaleDraft.fromJson(map);

  factory SaleDraft.fromJson(Map<String, dynamic> raw) {
    final json = raw['draft'] is Map
        ? Map<String, dynamic>.from(raw['draft'] as Map)
        : raw;
    final rawItems = json['items'] ?? json['lines'] ?? const [];
    final items = rawItems is List
        ? rawItems
            .whereType<Map>()
            .map((item) =>
                SaleDraftItem.fromJson(Map<String, dynamic>.from(item)))
            .toList()
        : <SaleDraftItem>[];
    DateTime? date(Object? value) =>
        value == null ? null : DateTime.tryParse(value.toString());
    double decimal(Object? value) =>
        value is num ? value.toDouble() : double.tryParse('$value') ?? 0;

    return SaleDraft(
      id: '${json['id'] ?? json['draft_id'] ?? ''}',
      saleNumber: json['sale_number'] is num
          ? (json['sale_number'] as num).toInt()
          : int.tryParse('${json['sale_number'] ?? 0}') ?? 0,
      version: json['version'] is num
          ? (json['version'] as num).toInt()
          : int.tryParse('${json['version'] ?? json['revision'] ?? 0}') ?? 0,
      status: saleDraftStatusFromJson(json['status']),
      visibility: saleDraftVisibilityFromJson(
        json['visibility'] ?? json['draft_visibility'],
      ),
      items: List.unmodifiable(items),
      createdAt: date(json['created_at'] ?? json['createdAt']),
      updatedAt: date(json['updated_at'] ?? json['updatedAt']),
      customerId:
          json['customer_id']?.toString() ?? json['customerId']?.toString(),
      customerName:
          json['customer_name']?.toString() ?? json['customerName']?.toString(),
      paymentMethod:
          '${json['payment_method'] ?? json['paymentMethod'] ?? 'cash'}',
      discount: decimal(json['discount']),
      title: json['title']?.toString(),
      ownerId: json['owner_id']?.toString() ?? json['ownerId']?.toString(),
      ownerName: json['owner_name']?.toString() ?? json['ownerName']?.toString(),
    );
  }

  @override
  List<Object?> get props => [
        id,
        saleNumber,
        version,
        status,
        visibility,
        items,
        createdAt,
        updatedAt,
        customerId,
        customerName,
        paymentMethod,
        discount,
        title,
        ownerId,
        ownerName,
      ];
}
