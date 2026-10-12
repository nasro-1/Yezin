enum OpeningStockStatus { posted }

class OpeningStockLineInput {
  final String productId;
  final double quantity;
  final double unitCost;

  const OpeningStockLineInput({
    required this.productId,
    required this.quantity,
    this.unitCost = 0,
  });
}

class OpeningStockLine {
  final String id;
  final String documentId;
  final String productId;
  final String? productBarcode;
  final String productName;
  final double quantity;
  final double unitCost;
  final double lineTotal;
  final DateTime createdAt;

  const OpeningStockLine({
    required this.id,
    required this.documentId,
    required this.productId,
    required this.productBarcode,
    required this.productName,
    required this.quantity,
    required this.unitCost,
    required this.lineTotal,
    required this.createdAt,
  });

  factory OpeningStockLine.fromMap(Map<String, dynamic> map) {
    return OpeningStockLine(
      id: map['id'] as String,
      documentId: map['document_id'] as String,
      productId: map['product_id'] as String,
      productBarcode: map['product_barcode'] as String?,
      productName: map['product_name'] as String,
      quantity: (map['quantity'] as num).toDouble(),
      unitCost: (map['unit_cost'] as num?)?.toDouble() ?? 0,
      lineTotal: (map['line_total'] as num?)?.toDouble() ?? 0,
      createdAt: DateTime.parse(map['created_at'] as String),
    );
  }
}

class OpeningStockDocument {
  final String id;
  final String referenceNumber;
  final OpeningStockStatus status;
  final DateTime openingDate;
  final String? reason;
  final String? notes;
  final DateTime postedAt;
  final String postedBy;
  final DateTime createdAt;
  final List<OpeningStockLine> lines;

  const OpeningStockDocument({
    required this.id,
    required this.referenceNumber,
    required this.status,
    required this.openingDate,
    required this.reason,
    required this.notes,
    required this.postedAt,
    required this.postedBy,
    required this.createdAt,
    required this.lines,
  });

  factory OpeningStockDocument.fromMap(
    Map<String, dynamic> map, {
    List<OpeningStockLine> lines = const [],
  }) {
    return OpeningStockDocument(
      id: map['id'] as String,
      referenceNumber: map['reference_number'] as String,
      status: OpeningStockStatus.values.firstWhere(
        (value) => value.name == map['status'],
        orElse: () => OpeningStockStatus.posted,
      ),
      openingDate: DateTime.parse(map['opening_date'] as String),
      reason: map['reason'] as String?,
      notes: map['notes'] as String?,
      postedAt: DateTime.parse(map['posted_at'] as String),
      postedBy: map['posted_by'] as String,
      createdAt: DateTime.parse(map['created_at'] as String),
      lines: List.unmodifiable(lines),
    );
  }
}
