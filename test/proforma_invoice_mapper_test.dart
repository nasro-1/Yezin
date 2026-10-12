import 'package:flutter_test/flutter_test.dart';
import 'package:bayaa_pos/features/invoice/domain/invoice_mapper.dart';
import 'package:bayaa_pos/features/orders/data/models/proforma_model.dart';

void main() {
  test('maps a proforma to the reusable printable invoice model', () {
    final proforma = Proforma(
      id: 'internal-id',
      referenceNumber: '172 / 2026',
      proformaDate: DateTime(2026, 9, 24),
      notes: 'Conditions de Vente',
      lines: const [
        ProformaLine(
          productId: 'p1',
          productName: 'Produit',
          productBarcode: '123',
          quantity: 2,
          unitPrice: 1250,
        ),
      ],
    );

    final document = InvoiceMapper.fromProforma(
      proforma: proforma,
      storeName: 'Bayaa',
      storeAddress: '',
      storePhone: '',
    );

    expect(document.invoiceId, '172 / 2026');
    expect(document.documentTitle, 'FACTURE PROFORMA');
    expect(document.lines.single.qty, 2);
    expect(document.grandTotal, 2500);
    expect(document.footerNote, 'Conditions de Vente');
  });
}
