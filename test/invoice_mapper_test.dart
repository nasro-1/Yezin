import 'package:bayaa_pos/features/invoice/domain/invoice_mapper.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('invoice mapping preserves weighted quantities', () {
    final invoice = InvoiceMapper.fromCart(
      invoiceId: 'INV-1',
      date: DateTime(2026, 9, 8),
      storeName: 'Bayaa',
      storeAddress: '',
      storePhone: '',
      cashierName: 'Cashier',
      cartMaps: const [
        {'id': 'P-300', 'name': 'Potato', 'price': 300.0, 'qty': 0.300},
        {'id': 'P-1250', 'name': 'Potato', 'price': 300.0, 'qty': 1.250},
        {'id': 'P-12500', 'name': 'Potato', 'price': 300.0, 'qty': 12.500},
      ],
    );

    expect(invoice.lines.map((line) => line.qty), [0.300, 1.250, 12.500]);
    expect(invoice.lines.map((line) => line.total), [90.0, 375.0, 3750.0]);
  });
}
