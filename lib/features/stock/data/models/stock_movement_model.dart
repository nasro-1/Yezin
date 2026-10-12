class StockMovement {
  final String id;
  final String productId;
  final String productBarcode;
  final String productName;
  final String movementType;
  final double quantityChange;
  final double unitCost;
  final double lineTotal;
  final double runningStock;
  final String? referenceType;
  final String? referenceId;
  final String? referenceLineId;
  final String? lineageId;
  final String? notes;
  final String? sourceDescription;
  final String? userId;
  final DateTime createdAt;
  final double? correctionQuantity;
  final double? oldUnitCost;
  final double? newUnitCost;
  final double? valueDifference;
  final String? correctionUser;

  const StockMovement({
    required this.id,
    required this.productId,
    required this.productBarcode,
    required this.productName,
    required this.movementType,
    required this.quantityChange,
    required this.unitCost,
    this.lineTotal = 0,
    required this.runningStock,
    this.referenceType,
    this.referenceId,
    this.referenceLineId,
    this.lineageId,
    this.notes,
    this.sourceDescription,
    this.userId,
    required this.createdAt,
    this.correctionQuantity,
    this.oldUnitCost,
    this.newUnitCost,
    this.valueDifference,
    this.correctionUser,
  });

  factory StockMovement.fromMap(Map<String, dynamic> map) {
    return StockMovement(
      id: map['id'] as String,
      productId: map['product_id'] as String,
      productBarcode: (map['product_barcode'] as String?) ?? '',
      productName: map['product_name'] as String,
      movementType: map['movement_type'] as String,
      quantityChange: (map['quantity_change'] as num).toDouble(),
      unitCost: (map['unit_cost'] as num?)?.toDouble() ?? 0.0,
      lineTotal: (map['line_total'] as num?)?.toDouble() ?? 0.0,
      runningStock: (map['running_stock'] as num).toDouble(),
      referenceType: map['reference_type'] as String?,
      referenceId: map['reference_id'] as String?,
      referenceLineId: map['reference_line_id'] as String?,
      lineageId: map['lineage_id'] as String?,
      notes: map['notes'] as String?,
      sourceDescription: map['source_description'] as String?,
      userId: map['user_id'] as String?,
      createdAt: DateTime.parse(map['created_at'] as String),
      correctionQuantity: (map['correction_quantity'] as num?)?.toDouble(),
      oldUnitCost: (map['old_unit_cost'] as num?)?.toDouble(),
      newUnitCost: (map['new_unit_cost'] as num?)?.toDouble(),
      valueDifference: (map['value_difference'] as num?)?.toDouble(),
      correctionUser: map['correction_user'] as String?,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'product_id': productId,
      'product_barcode': productBarcode,
      'product_name': productName,
      'movement_type': movementType,
      'quantity_change': quantityChange,
      'unit_cost': unitCost,
      'line_total': lineTotal,
      'running_stock': runningStock,
      'reference_type': referenceType,
      'reference_id': referenceId,
      'reference_line_id': referenceLineId,
      'lineage_id': lineageId,
      'notes': notes,
      'source_description': sourceDescription,
      'user_id': userId,
      'created_at': createdAt.toIso8601String(),
      'correction_quantity': correctionQuantity,
      'old_unit_cost': oldUnitCost,
      'new_unit_cost': newUnitCost,
      'value_difference': valueDifference,
      'correction_user': correctionUser,
    };
  }
}
