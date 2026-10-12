import 'package:flutter/material.dart';

IconData sellingUnitIconData(String iconKey, {String? unitName}) {
  final key = iconKey.trim().toLowerCase();
  switch (key) {
    case 'package':
      return Icons.inventory_2_outlined;
    case 'box':
    case 'carton':
      return Icons.all_inbox_outlined;
    case 'bottle':
      return Icons.local_drink_outlined;
    case 'can':
      return Icons.liquor_outlined;
    case 'pack':
      return Icons.layers_outlined;
    default:
      return Icons.category_outlined;
  }
}
