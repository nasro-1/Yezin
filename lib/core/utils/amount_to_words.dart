class AmountToWords {
  static const _units = <String>[
    '',
    'un',
    'deux',
    'trois',
    'quatre',
    'cinq',
    'six',
    'sept',
    'huit',
    'neuf',
    'dix',
    'onze',
    'douze',
    'treize',
    'quatorze',
    'quinze',
    'seize',
  ];

  static String frenchDinars(num amount) {
    final cents = ((amount.abs() * 100).round() % 100);
    final whole = amount.abs().floor();
    final prefix = amount < 0 ? 'moins ' : '';
    final wholeText = _underBillion(whole);
    final currency = whole == 1 ? 'dinar algérien' : 'dinars algériens';
    final decimalText = cents == 0
        ? ''
        : ' et ${_underHundred(cents)} centime${cents == 1 ? '' : 's'}';
    return '$prefix$wholeText $currency$decimalText';
  }

  static String _underBillion(int value) {
    if (value == 0) return 'zéro';
    final millions = value ~/ 1000000;
    final thousands = (value % 1000000) ~/ 1000;
    final rest = value % 1000;
    final parts = <String>[];
    if (millions > 0) {
      parts
          .add('${_underHundred(millions)} million${millions == 1 ? '' : 's'}');
    }
    if (thousands > 0) {
      parts.add('${thousands == 1 ? '' : '${_underHundred(thousands)} '}mille');
    }
    if (rest > 0) parts.add(_underHundred(rest));
    return parts.join(' ');
  }

  static String _underHundred(int value) {
    if (value < 17) return _units[value];
    if (value < 20) return 'dix-${_units[value - 10]}';
    if (value < 70) {
      final tens = value ~/ 10;
      final rest = value % 10;
      const names = [
        '',
        '',
        'vingt',
        'trente',
        'quarante',
        'cinquante',
        'soixante'
      ];
      return _joinTens(names[tens], rest);
    }
    if (value < 80) {
      return value == 71
          ? 'soixante et onze'
          : 'soixante-${_underHundred(value - 60)}';
    }
    if (value < 100) {
      return value == 80
          ? 'quatre-vingts'
          : 'quatre-vingt-${_underHundred(value - 80)}';
    }
    final hundreds = value ~/ 100;
    final rest = value % 100;
    final head = hundreds == 1 ? 'cent' : '${_units[hundreds]} cent';
    if (rest == 0) return hundreds == 1 ? head : '$head s';
    return '$head ${_underHundred(rest)}';
  }

  static String _joinTens(String tens, int rest) {
    if (rest == 0) return tens;
    if (rest == 1) return '$tens et un';
    return '$tens-${_units[rest]}';
  }
}
