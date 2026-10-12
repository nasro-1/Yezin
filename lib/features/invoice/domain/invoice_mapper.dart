import '../../invoice/data/invoice_models.dart';
import '../../orders/data/models/proforma_model.dart';
import '../../customers/data/models/customer_model.dart';

class InvoiceMapper {
  static InvoiceData fromProforma({
    required Proforma proforma,
    required String storeName,
    required String storeAddress,
    required String storePhone,
    String cashierName = '',
    String? footerNote,
    String? logoAsset,
    Customer? customer,
  }) {
    return InvoiceData(
      invoiceId: proforma.referenceNumber,
      date: proforma.proformaDate,
      storeName: storeName,
      storeAddress: storeAddress,
      storePhone: storePhone,
      cashierName: cashierName,
      lines: proforma.lines
          .map((line) => InvoiceLine(
                name: line.productName,
                barcode: line.productBarcode,
                price: line.unitPrice,
                qty: line.quantity,
              ))
          .toList(),
      subtotal: proforma.subtotal,
      discount: 0,
      tax: 0,
      grandTotal: proforma.total,
      footerNote: footerNote ?? proforma.notes,
      logoAsset: logoAsset,
      documentTitle: 'FACTURE PROFORMA',
      customerName: customer?.name,
      customerCode: customer?.code,
      customerAddress: customer?.address,
      customerCommercialRegister: customer?.commercialRegister,
      customerTaxId: customer?.taxId,
      customerNis: customer?.nis,
      customerAi: customer?.ai,
      customerReference: customer?.customerReference,
    );
  }

  static InvoiceData fromCart({
    required String invoiceId,
    required DateTime date,
    required String storeName,
    required String storeAddress,
    required String storePhone,
    required String cashierName,
    required List<Map<String, dynamic>> cartMaps,
    double discount = 0.0,
    double tax = 0.0,
    String? footerNote,
    String? logoAsset,
  }) {
    final lines = cartMaps.map((m) {
      return InvoiceLine(
        name: (m['name'] ?? '').toString(),
        barcode: (m['id'] ?? '').toString(),
        price: (m['price'] as num).toDouble(),
        qty: (m['qty'] as num).toDouble(),
      );
    }).toList();

    final subtotal = lines.fold<double>(0.0, (s, e) => s + e.total);
    final grand = subtotal - discount + tax;

    return InvoiceData(
      invoiceId: invoiceId,
      date: date,
      storeName: storeName,
      storeAddress: storeAddress,
      storePhone: storePhone,
      cashierName: cashierName,
      lines: lines,
      subtotal: subtotal,
      discount: discount,
      tax: tax,
      grandTotal: grand,
      footerNote: footerNote,
      logoAsset: logoAsset,
    );
  }
}
