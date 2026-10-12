import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../products/data/models/selling_unit_model.dart';
import '../../../products/presentation/widgets/selling_unit_icon.dart';

class SellingUnitSelectorDialog extends StatelessWidget {
  final List<SellingUnit> units;

  const SellingUnitSelectorDialog({super.key, required this.units});

  String _formatConversion(double conversion) {
    final formatted =
        conversion.toStringAsFixed(2).replaceFirst(RegExp(r'\.?0+$'), '');
    return '$formatted × base';
  }

  @override
  Widget build(BuildContext context) {
    final width = math.min(MediaQuery.sizeOf(context).width - 48, 720.0);
    final columns = width >= 620
        ? units.length.clamp(1, 3) as int
        : width >= 380
            ? 2
            : 1;
    const spacing = 12.0;
    final cardWidth = (width - ((columns - 1) * spacing)) / columns;

    return AlertDialog(
      title: const Text('Select selling unit'),
      content: SizedBox(
        width: width,
        child: Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: units.map((unit) {
            return SizedBox(
              width: cardWidth,
              child: InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: () => Navigator.of(context).pop(unit),
                child: Card(
                  elevation: unit.isDefault ? 4 : 1,
                  color: unit.isDefault
                      ? AppColors.primaryColor.withOpacity(0.08)
                      : null,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                    side: BorderSide(
                      color: unit.isDefault
                          ? AppColors.primaryColor
                          : AppColors.borderColor,
                      width: unit.isDefault ? 2 : 1,
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 18,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          sellingUnitIconData(unit.iconKey,
                              unitName: unit.name),
                          size: 40,
                          color: AppColors.primaryColor,
                        ),
                        const SizedBox(height: 10),
                        Text(
                          unit.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '${unit.sellingPrice.toStringAsFixed(2)} DA',
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _formatConversion(unit.conversionToBase),
                          style: const TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}
