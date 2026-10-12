class SupplierReturnLine {
  const SupplierReturnLine({
    required this.purchaseItemId,
    required this.productId,
    required this.quantity,
  });

  final String purchaseItemId;
  final String productId;
  final double quantity;

  SupplierReturnLine copyWith({
    String? purchaseItemId,
    String? productId,
    double? quantity,
  }) {
    return SupplierReturnLine(
      purchaseItemId: purchaseItemId ?? this.purchaseItemId,
      productId: productId ?? this.productId,
      quantity: quantity ?? this.quantity,
    );
  }
}

class SupplierReturn {
  const SupplierReturn({
    required this.id,
    required this.reference,
    required this.supplierId,
    required this.purchaseId,
    required this.returnDate,
    required this.lines,
    required this.createdBy,
    this.notes,
    this.status = 'confirmed',
  });

  final String id;
  final String reference;
  final String supplierId;
  final String purchaseId;
  final DateTime returnDate;
  final List<SupplierReturnLine> lines;
  final String? notes;
  final String createdBy;
  final String status;
}
