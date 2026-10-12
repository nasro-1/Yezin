import 'package:flutter_test/flutter_test.dart';
import 'package:bayaa_pos/core/utils/amount_to_words.dart';
import 'package:bayaa_pos/core/utils/currency_formatter.dart';

void main() {
  test('formats Algerian dinars with French separators', () {
    expect(CurrencyFormatter.format(0), '0,00 DA');
    expect(CurrencyFormatter.format(100), '100,00 DA');
    expect(CurrencyFormatter.format(1000), '1 000,00 DA');
    expect(CurrencyFormatter.format(28000), '28 000,00 DA');
    expect(CurrencyFormatter.format(62500), '62 500,00 DA');
    expect(CurrencyFormatter.format(142000), '142 000,00 DA');
    expect(CurrencyFormatter.format(142000.50), '142 000,50 DA');
  });

  test('writes common DZD amounts in French', () {
    expect(AmountToWords.frenchDinars(0), 'zéro dinars algériens');
    expect(AmountToWords.frenchDinars(1), 'un dinar algérien');
    expect(
      AmountToWords.frenchDinars(142000),
      'cent quarante-deux mille dinars algériens',
    );
    expect(
      AmountToWords.frenchDinars(142000.50),
      'cent quarante-deux mille dinars algériens et cinquante centimes',
    );
  });
}
