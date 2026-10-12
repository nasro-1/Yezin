// sale_model.dart

// Removed Hive dependencies

class Sale {
  final String id;
  final double total;
  final int items;
  final DateTime date;
  final List<SaleItem> saleItems;
  final String? cashierName; // NEW: Who made the sale
  final String? cashierUsername; // NEW: Username for reference
  final String? sessionId;
  final String? customerId;
  final String? customerName;
  final String? customerCode;
  final int invoiceTypeIndex; // 0: Sale, 1: Refund
  final String? refundOriginalInvoiceId;
  final String? refundOriginalInvoiceReference;
  final String paymentMethod;
  final String? referenceNumber;
  final double discount;
  final double refundedTotal;
  final String? replacementInvoiceReference;

  Sale({
    required this.id,
    required this.total,
    required this.items,
    required this.date,
    required this.saleItems,
    required this.cashierName,
    this.cashierUsername,
    this.sessionId,
    this.customerId,
    this.customerName,
    this.customerCode,
    this.invoiceTypeIndex = 0,
    this.refundOriginalInvoiceId,
    this.refundOriginalInvoiceReference,
    this.paymentMethod = 'cash',
    this.referenceNumber,
    this.discount = 0,
    this.refundedTotal = 0,
    this.replacementInvoiceReference,
  });

  Sale copyWith({
    String? replacementInvoiceReference,
  }) {
    return Sale(
      id: id,
      total: total,
      items: items,
      date: date,
      saleItems: saleItems,
      cashierName: cashierName,
      cashierUsername: cashierUsername,
      sessionId: sessionId,
      customerId: customerId,
      customerName: customerName,
      customerCode: customerCode,
      invoiceTypeIndex: invoiceTypeIndex,
      refundOriginalInvoiceId: refundOriginalInvoiceId,
      refundOriginalInvoiceReference: refundOriginalInvoiceReference,
      paymentMethod: paymentMethod,
      referenceNumber: referenceNumber,
      discount: discount,
      refundedTotal: refundedTotal,
      replacementInvoiceReference:
          replacementInvoiceReference ?? this.replacementInvoiceReference,
    );
  }

  bool get isRefund => invoiceTypeIndex == 1;
  bool get canBeRefunded => !isRefund;
  double get remainingRefundableQuantity => saleItems.fold<double>(
        0,
        (total, item) {
          final remaining = (item.sellingQuantity ?? item.quantity) -
              item.refundedQuantity -
              item.exchangedQuantity;
          return total + (remaining > 0 ? remaining : 0);
        },
      );
  bool get hasRefundedItems =>
      !isRefund && saleItems.any((item) => item.refundedQuantity > 0);
  bool get hasExchangedItems =>
      !isRefund && saleItems.any((item) => item.exchangedQuantity > 0);
  bool get hasReturnedItems => hasRefundedItems || hasExchangedItems;
  double get remainingRefundQuantity => saleItems.fold<double>(
        0,
        (total, item) {
          final remaining =
              (item.sellingQuantity ?? item.quantity) - item.refundedQuantity;
          return total + (remaining > 0 ? remaining : 0);
        },
      );
  bool get isFullyRefunded =>
      !isRefund && hasRefundedItems && remainingRefundQuantity <= 0;
  bool get isPartiallyRefunded =>
      !isRefund && hasRefundedItems && remainingRefundQuantity > 0;
  bool get isExchanged => !isRefund && hasExchangedItems;
  double get effectiveRefundedTotal {
    if (refundedTotal > 0) return refundedTotal;
    return saleItems.fold<double>(
      0,
      (sum, item) => sum + item.refundedQuantity * item.price,
    );
  }

  double get effectiveExchangedTotal => saleItems.fold<double>(
        0,
        (sum, item) => sum + item.exchangedQuantity * item.price,
      );

  double get remainingFinancialTotal =>
      (total - effectiveRefundedTotal - effectiveExchangedTotal)
          .clamp(0, double.infinity);

  double get accountingContribution => isRefund
      ? -total
      : total - effectiveRefundedTotal - effectiveExchangedTotal;

  double get invoiceCardDisplayAmount {
    if (isRefund) return total;
    if (isFullyRefunded) return effectiveRefundedTotal;
    if (isPartiallyRefunded) return remainingFinancialTotal;
    return isExchanged ? currentDisplayTotal : total;
  }

  bool get invoiceCardUsesRefundVisuals => isRefund || isFullyRefunded;

  double get currentDisplayTotal {
    if (isRefund || !hasReturnedItems) return total;
    return saleItems.fold<double>(
      0,
      (sum, item) => sum + item.remainingDisplayTotal,
    );
  }

  List<SaleItem> get currentDisplayItems => saleItems;

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'total': total,
      'items': items,
      'date': date.toIso8601String(),
      'cashierName': cashierName,
      'cashierUsername': cashierUsername,
      'sessionId': sessionId,
      'customerId': customerId,
      'invoiceTypeIndex': invoiceTypeIndex,
      'refundOriginalInvoiceId': refundOriginalInvoiceId,
      'paymentMethod': paymentMethod,
      'discount': discount,
      'refundedTotal': refundedTotal,
      'replacementInvoiceReference': replacementInvoiceReference,
      'saleItems': saleItems.map((x) => x.toMap()).toList(),
    };
  }
}

class SaleItem {
  final String? saleItemId;
  final String productId;
  final String name;
  final double price;
  final double quantity;
  final double total;
  final double wholesalePrice;
  final double? historicalCost;
  final String? sellingUnitId;
  final double? sellingQuantity;
  final double? baseQuantity;
  final double? conversionFactorSnapshot;
  final String? sellingUnitNameSnapshot;
  final String? baseUnitSnapshot;
  double refundedQuantity; // Track refunded quantity permanently
  double exchangedQuantity;

  SaleItem({
    this.saleItemId,
    required this.productId,
    required this.name,
    required this.price,
    required this.quantity,
    required this.total,
    required this.wholesalePrice,
    this.historicalCost,
    this.sellingUnitId,
    this.sellingQuantity,
    this.baseQuantity,
    this.conversionFactorSnapshot,
    this.sellingUnitNameSnapshot,
    this.baseUnitSnapshot,
    this.refundedQuantity = 0,
    this.exchangedQuantity = 0,
  });

  bool get isUnitAware =>
      sellingUnitId != null ||
      sellingQuantity != null ||
      baseQuantity != null ||
      conversionFactorSnapshot != null ||
      sellingUnitNameSnapshot != null ||
      baseUnitSnapshot != null;

  double get effectiveBaseQuantity =>
      baseQuantity ??
      ((sellingQuantity != null && conversionFactorSnapshot != null)
          ? sellingQuantity! * conversionFactorSnapshot!
          : quantity);

  double get remainingDisplayQuantity {
    final originalQuantity = sellingQuantity ?? quantity;
    return (originalQuantity - refundedQuantity - exchangedQuantity)
        .clamp(0, double.infinity);
  }

  double get remainingDisplayTotal => remainingDisplayQuantity * price;

  Map<String, dynamic> toMap() {
    return {
      'saleItemId': saleItemId,
      'productId': productId,
      'name': name,
      'price': price,
      'quantity': quantity,
      'total': total,
      'wholesalePrice': wholesalePrice,
      'historicalCost': historicalCost,
      'sellingUnitId': sellingUnitId,
      'sellingQuantity': sellingQuantity ?? quantity,
      'baseQuantity': baseQuantity ?? effectiveBaseQuantity,
      'conversionFactorSnapshot': conversionFactorSnapshot,
      'sellingUnitNameSnapshot': sellingUnitNameSnapshot,
      'baseUnitSnapshot': baseUnitSnapshot,
      'refundedQuantity': refundedQuantity,
      'exchangedQuantity': exchangedQuantity,
    };
  }
}
