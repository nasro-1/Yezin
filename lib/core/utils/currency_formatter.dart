class CurrencyFormatter {
  static const String code = 'DZD';
  static const String symbol = 'DA';

  static String format(num value, {bool includeSymbol = true}) {
    final fixed = value.toDouble().toStringAsFixed(2);
    final parts = fixed.split('.');
    final integer = parts[0];
    final sign = integer.startsWith('-') ? '-' : '';
    final digits = sign.isEmpty ? integer : integer.substring(1);
    final grouped = digits.replaceAllMapped(
      RegExp(r'(\d)(?=(\d{3})+(?!\d))'),
      (match) => '${match.group(1)} ',
    );
    final result = '$sign$grouped,${parts[1]}';
    return includeSymbol ? '$result $symbol' : result;
  }
}
