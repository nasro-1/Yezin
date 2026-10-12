class PurchaseLine {
  const PurchaseLine({
    required this.productId,
    required this.productName,
    required this.productBarcode,
    required this.quantity,
    required this.unitCost,
    this.currentStock = 0.0,
    this.sellingUnitId,
    this.sellingUnitName,
    this.conversionFactor,
    this.baseQuantity,
  });

  final String productId;
  final String productName;
  final String productBarcode;
  final double quantity;
  final double unitCost;
  final double currentStock;
  final String? sellingUnitId;
  final String? sellingUnitName;
  final double? conversionFactor;
  final double? baseQuantity;

  double get lineTotal => quantity * unitCost;
  double get resultingStock => currentStock + (baseQuantity ?? quantity);
  String get identityKey => '$productId|${sellingUnitId ?? 'base'}';
}

class Purchase {
  const Purchase({
    required this.id,
    required this.referenceNumber,
    required this.supplierId,
    required this.purchaseDate,
    required this.lines,
    this.notes,
    this.status = 'confirmed',
    this.createdBy,
  });

  final String id;
  final String referenceNumber;
  final String supplierId;
  final DateTime purchaseDate;
  final List<PurchaseLine> lines;
  final String? notes;
  final String status;
  final String? createdBy;

  double get subtotal => lines.fold(0, (sum, line) => sum + line.lineTotal);
}
