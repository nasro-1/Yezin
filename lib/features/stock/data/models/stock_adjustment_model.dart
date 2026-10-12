enum StockAdjustmentStatus { posted }

class StockAdjustmentLineInput {
  final String productId;
  final double countedQuantity;
  final double unitCost;
  final String? unit;
  final String? operation;

  const StockAdjustmentLineInput({
    required this.productId,
    required this.countedQuantity,
    this.unitCost = 0,
    this.unit,
    this.operation,
  });
}

typedef StockAdjustmentItemInput = StockAdjustmentLineInput;

class StockAdjustmentLine {
  final String id;
  final String documentId;
  final String productId;
  final String? productBarcode;
  final String productName;
  final double currentQuantity;
  final double countedQuantity;
  final double quantityChange;
  final double unitCost;
  final double lineTotal;
  final DateTime createdAt;

  const StockAdjustmentLine({
    required this.id,
    required this.documentId,
    required this.productId,
    required this.productBarcode,
    required this.productName,
    required this.currentQuantity,
    required this.countedQuantity,
    required this.quantityChange,
    required this.unitCost,
    required this.lineTotal,
    required this.createdAt,
  });

  double get delta => quantityChange;

  factory StockAdjustmentLine.fromMap(Map<String, dynamic> map) {
    return StockAdjustmentLine(
      id: map['id'] as String,
      documentId: map['document_id'] as String,
      productId: map['product_id'] as String,
      productBarcode: map['product_barcode'] as String?,
      productName: map['product_name'] as String,
      currentQuantity: (map['current_quantity'] as num).toDouble(),
      countedQuantity: (map['counted_quantity'] as num).toDouble(),
      quantityChange:
          ((map['delta'] ?? map['quantity_change']) as num).toDouble(),
      unitCost: (map['unit_cost'] as num?)?.toDouble() ?? 0,
      lineTotal: (map['line_total'] as num?)?.toDouble() ?? 0,
      createdAt: DateTime.parse(map['created_at'] as String),
    );
  }
}

typedef StockAdjustmentItem = StockAdjustmentLine;

class StockAdjustmentDocument {
  final String id;
  final String referenceNumber;
  final String idempotencyKey;
  final StockAdjustmentStatus status;
  final DateTime adjustmentDate;
  final String? reason;
  final String? notes;
  final DateTime postedAt;
  final String postedBy;
  final DateTime createdAt;
  final List<StockAdjustmentLine> lines;

  const StockAdjustmentDocument({
    required this.id,
    required this.referenceNumber,
    required this.idempotencyKey,
    required this.status,
    required this.adjustmentDate,
    required this.reason,
    required this.notes,
    required this.postedAt,
    required this.postedBy,
    required this.createdAt,
    required this.lines,
  });

  List<StockAdjustmentLine> get items => lines;

  factory StockAdjustmentDocument.fromMap(
    Map<String, dynamic> map, {
    List<StockAdjustmentLine> lines = const [],
  }) {
    return StockAdjustmentDocument(
      id: map['id'] as String,
      referenceNumber: map['reference_number'] as String,
      idempotencyKey: map['idempotency_key'] as String? ?? map['id'] as String,
      status: StockAdjustmentStatus.values.firstWhere(
        (value) => value.name == map['status'],
        orElse: () => StockAdjustmentStatus.posted,
      ),
      adjustmentDate: DateTime.parse(map['adjustment_date'] as String),
      reason: map['reason'] as String?,
      notes: map['notes'] as String?,
      postedAt: DateTime.parse(map['posted_at'] as String),
      postedBy: map['posted_by'] as String,
      createdAt: DateTime.parse(map['created_at'] as String),
      lines: List.unmodifiable(lines),
    );
  }
}
