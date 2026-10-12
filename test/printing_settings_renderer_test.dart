import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:bayaa_pos/core/data/models/store_settings_model.dart';
import 'package:bayaa_pos/features/invoice/data/invoice_models.dart';
import 'package:bayaa_pos/features/invoice/domain/invoice_pdf_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final data = InvoiceData(
    invoiceId: 'INV-2026-000001',
    date: DateTime(2026, 9, 24, 20, 0),
    storeName: 'Bayaa POS',
    storeAddress: 'Long store address',
    storePhone: '0555000000',
    cashierName: 'Cashier',
    customerName: 'Long customer name',
    lines: const [
      InvoiceLine(name: 'Long product designation', price: 1000, qty: 2),
    ],
    subtotal: 2000,
    discount: 0,
    tax: 190,
    grandTotal: 2190,
    paymentMethod: 'cash',
  );

  StoreSettingsModel settings({
    bool logo = true,
    bool vat = true,
    bool words = true,
    bool barcode = true,
  }) {
    return StoreSettingsModel(
      storeName: 'Bayaa POS',
      showLogo: logo,
      showVat: vat,
      showAmountInWords: words,
      showBarcode: barcode,
    );
  }

  Future<List<int>> render(StoreSettingsModel value) {
    return InvoicePdfService.buildA4(
      data,
      locale: const Locale('en'),
      printSettingsOverride: value,
    );
  }

  test('printing settings have enabled defaults and survive SQLite mapping',
      () {
    final defaults = StoreSettingsModel.defaultSettings();
    expect(defaults.showLogo, isTrue);
    expect(defaults.showVat, isTrue);
    expect(defaults.showAmountInWords, isTrue);
    expect(defaults.showBarcode, isTrue);

    final saved = defaults.copyWith(
      showLogo: false,
      showVat: false,
      showAmountInWords: false,
      showBarcode: false,
    );
    final restored = StoreSettingsModel.fromSQLite(saved.toSQLite());

    expect(restored.showLogo, isFalse);
    expect(restored.showVat, isFalse);
    expect(restored.showAmountInWords, isFalse);
    expect(restored.showBarcode, isFalse);
  });

  test('each printing setting changes the rendered A4 document independently',
      () async {
    final all = await render(settings());
    final withoutLogo = await render(settings(logo: false));
    final withoutVat = await render(settings(vat: false));
    final withoutWords = await render(settings(words: false));
    final withoutBarcode = await render(settings(barcode: false));

    expect(all, isNotEmpty);
    expect(withoutLogo, isNot(equals(all)));
    expect(withoutVat, isNot(equals(all)));
    expect(withoutWords, isNot(equals(all)));
    expect(withoutBarcode, isNot(equals(all)));
  });

  test('printing settings combinations produce distinct renderer output',
      () async {
    final outputs = <String>{
      (await render(settings())).toString(),
      (await render(
              settings(logo: false, vat: false, words: false, barcode: false)))
          .toString(),
      (await render(settings(logo: false))).toString(),
      (await render(settings(vat: false))).toString(),
      (await render(settings(words: false))).toString(),
      (await render(settings(barcode: false))).toString(),
    };

    expect(outputs, hasLength(6));
  });

  test('receipt renderer also honors all printing settings', () async {
    final all = await InvoicePdfService.buildReceipt80mm(
      data,
      locale: const Locale('en'),
      printSettingsOverride: settings(),
    );
    final none = await InvoicePdfService.buildReceipt80mm(
      data,
      locale: const Locale('en'),
      printSettingsOverride:
          settings(logo: false, vat: false, words: false, barcode: false),
    );

    expect(all, isNot(equals(none)));
  });
}
