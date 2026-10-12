import 'dart:typed_data';

class InvoiceLine {
  final String name;
  final String? barcode;
  final double price;
  final double qty;
  final String? qtyDisplay;
  final double total;

  const InvoiceLine({
    required this.name,
    this.barcode,
    required this.price,
    required this.qty,
    this.qtyDisplay,
  }) : total = price * qty;

  String get displayedQuantity {
    if (qtyDisplay != null) return qtyDisplay!;
    return qty == qty.truncateToDouble()
        ? qty.toInt().toString()
        : qty.toString();
  }
}

class InvoiceData {
  final String invoiceId;
  final DateTime date;
  final String storeName;
  final String storeAddress;
  final String storePhone;
  final String cashierName;
  final List<InvoiceLine> lines;
  final double subtotal;
  final double discount;
  final double tax;
  final double grandTotal;
  final String? logoAsset;
  final Uint8List? logoBytes;
  final String? footerNote;
  final String paymentMethod;
  final String? documentTitle;
  final String? originalInvoiceReference;
  final String? customerName;
  final String? customerCode;
  final String? customerAddress;
  final String? customerCommercialRegister;
  final String? customerTaxId;
  final String? customerNis;
  final String? customerAi;
  final String? customerReference;
  final double? previousBalance;
  final double? remainingBalance;
  final double? originalTotal;
  final double? refundedTotal;
  final double? exchangedTotal;
  final double? remainingTotal;

  const InvoiceData({
    required this.invoiceId,
    required this.date,
    required this.storeName,
    required this.storeAddress,
    required this.storePhone,
    required this.cashierName,
    required this.lines,
    required this.subtotal,
    required this.discount,
    required this.tax,
    required this.grandTotal,
    this.footerNote,
    this.logoAsset,
    this.logoBytes,
    this.paymentMethod = 'cash',
    this.documentTitle,
    this.originalInvoiceReference,
    this.customerName,
    this.customerCode,
    this.customerAddress,
    this.customerCommercialRegister,
    this.customerTaxId,
    this.customerNis,
    this.customerAi,
    this.customerReference,
    this.previousBalance,
    this.remainingBalance,
    this.originalTotal,
    this.refundedTotal,
    this.exchangedTotal,
    this.remainingTotal,
  });
}
