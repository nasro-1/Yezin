class SupplierPayment {
  const SupplierPayment({
    required this.id,
    required this.supplierId,
    required this.amount,
    required this.paymentDate,
    required this.paymentMethod,
    required this.reference,
    required this.createdBy,
    this.notes,
    this.status = 'confirmed',
  });

  final String id;
  final String supplierId;
  final double amount;
  final DateTime paymentDate;
  final String paymentMethod;
  final String reference;
  final String? notes;
  final String createdBy;
  final String status;
}
