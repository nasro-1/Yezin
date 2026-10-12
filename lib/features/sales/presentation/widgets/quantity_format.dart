String formatQuantity(num value, {int decimalPlaces = 3}) {
  final normalized = value.toDouble().toStringAsFixed(decimalPlaces);
  return normalized
      .replaceFirst(RegExp(r'\.?0+$'), '')
      .replaceFirst(RegExp(r'\.$'), '');
}
