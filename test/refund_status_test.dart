import 'package:bayaa_pos/features/invoice/data/invoice_models.dart';
import 'package:bayaa_pos/features/invoice/domain/refund_calculation_service.dart';
import 'package:bayaa_pos/features/invoice/presentation/widgets/partial_refund_dialog.dart';
import 'package:bayaa_pos/features/invoice/presentation/cubit/invoice_cubit.dart';
import 'package:bayaa_pos/features/invoice/presentation/cubit/invoice_state.dart';
import 'package:bayaa_pos/features/sales/data/models/sale_model.dart';
import 'package:flutter_test/flutter_test.dart';

Sale _sale({double refunded = 0, double exchanged = 0}) => Sale(
      id: 'sale-1',
      total: 500,
      items: 1,
      date: DateTime.utc(2026, 9, 23),
      cashierName: 'Cashier',
      referenceNumber: 'INV-2026-000123',
      saleItems: [
        SaleItem(
          saleItemId: 'line-1',
          productId: 'product-1',
          name: 'Product X',
          price: 100,
          quantity: 5,
          total: 500,
          wholesalePrice: 60,
          refundedQuantity: refunded,
          exchangedQuantity: exchanged,
        ),
      ],
    );

void main() {
  Sale _refundDocument() => Sale(
        id: 'refund-1',
        total: 200,
        items: 1,
        date: DateTime.utc(2026, 9, 23),
        cashierName: 'Cashier',
        referenceNumber: 'CR-809FF9B3E9E6',
        invoiceTypeIndex: 1,
        refundOriginalInvoiceId: 'sale-1',
        saleItems: [
          SaleItem(
            saleItemId: 'line-1',
            productId: 'product-1',
            name: 'Product X',
            price: 100,
            quantity: 2,
            total: 200,
            wholesalePrice: 60,
          ),
        ],
      );

  test('All and Sales show one original row while Refunds show CR document',
      () {
    final documents = [_sale(refunded: 2), _refundDocument()];

    expect(
      InvoiceCubit.documentsForFilter(documents, InvoiceFilterType.all),
      hasLength(1),
    );
    expect(
      InvoiceCubit.documentsForFilter(documents, InvoiceFilterType.sales),
      hasLength(1),
    );
    final refunds =
        InvoiceCubit.documentsForFilter(documents, InvoiceFilterType.refunded);
    expect(refunds, hasLength(1));
    expect(refunds.single.referenceNumber, startsWith('CR-'));
  });

  test('Exchanges filter shows exchanged original invoices only', () {
    final exchanged = _sale(exchanged: 1);
    final normal = _sale();
    final refund = _refundDocument();

    final results = InvoiceCubit.documentsForFilter(
      [exchanged, normal, refund],
      InvoiceFilterType.exchanges,
    );

    expect(results, hasLength(1));
    expect(results.single.id, exchanged.id);
    expect(results.single.saleItems.single.exchangedQuantity, 1);
  });

  test('partial refund preserves sold quantity and exposes remaining quantity',
      () {
    final sale = _sale(refunded: 2);

    expect(sale.saleItems.single.quantity, 5);
    expect(sale.saleItems.single.refundedQuantity, 2);
    expect(sale.remainingRefundableQuantity, 3);
    expect(sale.isPartiallyRefunded, isTrue);
    expect(sale.isFullyRefunded, isFalse);
    expect(sale.total, 500);
    expect(sale.effectiveRefundedTotal, 200);
    expect(sale.remainingFinancialTotal, 300);
    expect(sale.currentDisplayTotal, 300);
    expect(sale.isPartiallyRefunded ? 'PARTIALLY REFUNDED' : 'NOT REFUNDED',
        'PARTIALLY REFUNDED');
  });

  test('partial refund presentation uses remaining line quantity and total',
      () {
    final sale = Sale(
      id: 'sale-remaining',
      total: 300,
      items: 1,
      date: DateTime.utc(2026, 9, 23),
      cashierName: 'Cashier',
      saleItems: [
        SaleItem(
          saleItemId: 'line-remaining',
          productId: 'product-1',
          name: 'Product X',
          price: 100,
          quantity: 3,
          total: 300,
          wholesalePrice: 60,
          refundedQuantity: 2,
        ),
      ],
    );

    expect(sale.saleItems.single.quantity, 3);
    expect(sale.total, 300);
    expect(sale.saleItems.single.remainingDisplayQuantity, 1);
    expect(sale.currentDisplayItems.single.quantity, 3);
    expect(sale.currentDisplayTotal, 100);
    expect(sale.effectiveRefundedTotal, 200);

    final preview = InvoiceData(
      invoiceId: sale.id,
      date: sale.date,
      storeName: 'Bayaa',
      storeAddress: '',
      storePhone: '',
      cashierName: sale.cashierName!,
      lines: sale.currentDisplayItems
          .map((item) => InvoiceLine(
                name: item.name,
                price: item.price,
                qty: item.remainingDisplayQuantity,
                qtyDisplay:
                    '${item.quantity.toInt()} / ${item.remainingDisplayQuantity.toInt()}',
              ))
          .toList(),
      subtotal: sale.currentDisplayTotal,
      discount: 0,
      tax: 0,
      grandTotal: sale.currentDisplayTotal,
    );
    expect(preview.lines.single.qty, 1);
    expect(preview.lines.single.displayedQuantity, '3 / 1');
    expect(preview.lines.single.total, 100);
    expect(preview.grandTotal, 100);
  });

  test('normal and full refund quantities remain visually distinct', () {
    const normal = InvoiceLine(name: 'Product X', price: 100, qty: 3);
    expect(normal.displayedQuantity, '3');

    const full = InvoiceLine(
      name: 'Product X',
      price: 100,
      qty: 0,
      qtyDisplay: '3 / 0',
    );
    expect(full.displayedQuantity, '3 / 0');
  });

  test('full refund presentation shows original and zero remaining quantity',
      () {
    final sale = _sale(refunded: 5);

    expect(sale.currentDisplayItems.single.remainingDisplayQuantity, 0);
    expect(sale.currentDisplayTotal, 0);
    expect(sale.isFullyRefunded, isTrue);
  });

  test('full refund status is reached only when no quantity remains', () {
    expect(_sale(refunded: 4).isPartiallyRefunded, isTrue);
    expect(_sale(refunded: 4).isFullyRefunded, isFalse);
    expect(_sale(refunded: 5).isFullyRefunded, isTrue);
    expect(_sale(refunded: 5).remainingRefundableQuantity, 0);
    expect(
      _sale(refunded: 5).isFullyRefunded
          ? 'FULLY REFUNDED'
          : 'PARTIALLY REFUNDED',
      'FULLY REFUNDED',
    );
  });

  test('normal sale has no refund status while partial and full do', () {
    expect(_sale().hasReturnedItems, isFalse);
    expect(_sale(refunded: 2).isPartiallyRefunded, isTrue);
    expect(_sale(refunded: 5).isFullyRefunded, isTrue);
    expect(
      _sale(refunded: 2).isPartiallyRefunded
          ? 'PARTIALLY REFUNDED'
          : 'Refunded',
      'PARTIALLY REFUNDED',
    );
    expect(
      _sale(refunded: 5).isFullyRefunded ? 'Refunded' : 'PARTIALLY REFUNDED',
      'Refunded',
    );
    expect(_sale().hasReturnedItems ? 'Refunded' : '', '');
  });

  test('refund visual treatment applies only to refund and full-refund cards',
      () {
    expect(_sale().invoiceCardUsesRefundVisuals, isFalse);
    expect(_sale(refunded: 2).invoiceCardUsesRefundVisuals, isFalse);
    expect(_sale(refunded: 5).invoiceCardUsesRefundVisuals, isTrue);
    expect(_refundDocument().invoiceCardUsesRefundVisuals, isTrue);
  });

  test('exchange-only state stays distinct from refunds', () {
    final sale = Sale(
      id: 'sale-exchange',
      total: 400,
      items: 2,
      date: DateTime.utc(2026, 9, 23),
      cashierName: 'Cashier',
      saleItems: [
        SaleItem(
          saleItemId: 'line-exchange',
          productId: 'product-1',
          name: 'Product X',
          price: 100,
          quantity: 3,
          total: 300,
          wholesalePrice: 60,
          exchangedQuantity: 1,
        ),
        SaleItem(
          saleItemId: 'line-unchanged',
          productId: 'product-2',
          name: 'Product Y',
          price: 100,
          quantity: 1,
          total: 100,
          wholesalePrice: 60,
        ),
      ],
    );

    expect(sale.hasRefundedItems, isFalse);
    expect(sale.hasExchangedItems, isTrue);
    expect(sale.isPartiallyRefunded, isFalse);
    expect(sale.isExchanged, isTrue);
    expect(sale.effectiveRefundedTotal, 0);
    expect(sale.effectiveExchangedTotal, 100);
    expect(sale.remainingFinancialTotal, 300);
    expect(sale.currentDisplayTotal, 300);
    expect(sale.invoiceCardDisplayAmount, 300);
    expect(sale.saleItems.first.remainingDisplayQuantity, 2);
  });

  test('refund and exchange totals remain separate', () {
    final sale = _sale(refunded: 1, exchanged: 1);

    expect(sale.effectiveRefundedTotal, 100);
    expect(sale.effectiveExchangedTotal, 100);
    expect(sale.remainingFinancialTotal, 300);
    expect(sale.isPartiallyRefunded, isTrue);
    expect(sale.isExchanged, isTrue);
  });

  test('invoice card amount follows document refund state', () {
    final fullSale = Sale(
      id: 'sale-full',
      total: 200,
      items: 1,
      date: DateTime.utc(2026, 9, 23),
      cashierName: 'Cashier',
      saleItems: [
        SaleItem(
          saleItemId: 'line-full',
          productId: 'product-1',
          name: 'Product X',
          price: 100,
          quantity: 2,
          total: 200,
          wholesalePrice: 60,
          refundedQuantity: 2,
        ),
      ],
    );

    expect(fullSale.effectiveRefundedTotal, 200);
    expect(fullSale.remainingFinancialTotal, 0);
    expect(fullSale.invoiceCardDisplayAmount, 200);
    expect(fullSale.invoiceCardUsesRefundVisuals, isTrue);
    expect(_sale(refunded: 2).invoiceCardDisplayAmount, 300);
    expect(_sale().invoiceCardDisplayAmount, 500);
    expect(_refundDocument().invoiceCardDisplayAmount, 200);
  });

  test('refund print data carries the new refund and original references', () {
    const line = InvoiceLine(
      name: 'Product X',
      price: 100,
      qty: 2,
    );
    final data = InvoiceData(
      invoiceId: 'CR-2026-000456',
      date: DateTime.utc(2026, 9, 23),
      storeName: 'Bayaa',
      storeAddress: '',
      storePhone: '',
      cashierName: 'Cashier',
      lines: [line],
      subtotal: 200,
      discount: 0,
      tax: 0,
      grandTotal: 200,
      documentTitle: 'Refund Invoice',
      originalInvoiceReference: 'INV-2026-000123',
    );

    expect(data.invoiceId, 'CR-2026-000456');
    expect(data.originalInvoiceReference, 'INV-2026-000123');
    expect(data.lines.single.qty, 2);
    expect(data.lines.single.total, 200);
  });

  test('selected refund quantity replaces original selling quantity', () {
    final item = RefundableItem(
      saleItemId: 'line-1',
      productId: 'product-1',
      productName: 'Product X',
      originalQuantity: 3,
      refundedQuantity: 0,
      unitPrice: 100,
      wholesalePrice: 60,
      sellingQuantity: 3,
      baseQuantity: 3,
    );
    final selected = RefundItem.fromSelection(item: item, quantity: 2);

    expect(selected.quantity, 2);
    expect(selected.sellingQuantity, 2);
    expect(selected.total, 200);
  });
}
