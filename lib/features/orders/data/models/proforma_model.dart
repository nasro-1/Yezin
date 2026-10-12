import 'dart:collection';

enum ProformaStatus { draft, confirmed, cancelled, converted }

ProformaStatus proformaStatusFromName(String? value) =>
    ProformaStatus.values.firstWhere(
      (status) => status.name == value,
      orElse: () => ProformaStatus.draft,
    );

class ProformaLine {
  const ProformaLine({
    required this.productId,
    required this.productName,
    required this.productBarcode,
    required this.quantity,
    required this.unitPrice,
    this.wholesalePrice = 0,
  });

  final String productId;
  final String productName;
  final String productBarcode;
  final double quantity;
  final double unitPrice;
  final double wholesalePrice;

  double get lineTotal => quantity * unitPrice;

  Map<String, dynamic> toMap() => {
        'productId': productId,
        'productName': productName,
        'productBarcode': productBarcode,
        'quantity': quantity,
        'unitPrice': unitPrice,
        'wholesalePrice': wholesalePrice,
      };
}

class Proforma {
  Proforma({
    required this.id,
    required this.referenceNumber,
    required this.proformaDate,
    required List<ProformaLine> lines,
    this.customerId,
    this.notes,
    this.status = ProformaStatus.draft,
    this.createdBy,
    this.convertedSaleId,
  }) : lines = UnmodifiableListView(lines);

  final String id;
  final String referenceNumber;
  final String? customerId;
  final DateTime proformaDate;
  final List<ProformaLine> lines;
  final String? notes;
  final ProformaStatus status;
  final String? createdBy;
  final String? convertedSaleId;

  double get subtotal => lines.fold(0, (sum, line) => sum + line.lineTotal);
  double get total => subtotal;
}
