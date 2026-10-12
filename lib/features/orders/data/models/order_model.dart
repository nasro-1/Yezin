import 'dart:collection';

enum OrderStatus { draft, confirmed, cancelled, converted }

OrderStatus orderStatusFromName(String? value) => OrderStatus.values.firstWhere(
      (status) => status.name == value,
      orElse: () => OrderStatus.draft,
    );

class OrderLine {
  const OrderLine({
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

class Order {
  Order({
    required this.id,
    required this.referenceNumber,
    required this.orderDate,
    required List<OrderLine> lines,
    this.customerId,
    this.notes,
    this.status = OrderStatus.draft,
    this.createdBy,
    this.convertedSaleId,
  }) : lines = UnmodifiableListView(lines);

  final String id;
  final String referenceNumber;
  final String? customerId;
  final DateTime orderDate;
  final List<OrderLine> lines;
  final String? notes;
  final OrderStatus status;
  final String? createdBy;
  final String? convertedSaleId;

  double get subtotal => lines.fold(0, (sum, line) => sum + line.lineTotal);
  double get total => subtotal;
}
