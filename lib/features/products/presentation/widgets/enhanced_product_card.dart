import 'package:flutter/material.dart';
import 'package:bayaa_pos/features/products/data/models/product_model.dart';
import 'package:bayaa_pos/features/products/data/models/selling_unit_model.dart';
import 'package:bayaa_pos/core/constants/app_colors.dart';
import '../../../../core/security/permission_guard.dart';
import '../../../../core/components/local_image_view.dart';
import '../../../../core/di/dependency_injection.dart';
import '../../../../l10n/app_localizations.dart';
import '../../../auth/data/models/user_model.dart';
import '../../../auth/presentation/cubit/user_cubit.dart';

class EnhancedProductCard extends StatelessWidget {
  final Product product;
  final VoidCallback onDelete;
  final VoidCallback onEdit;
  final VoidCallback onAdjustStock;
  final VoidCallback onStockHistory;
  final VoidCallback onView;
  final Color statusColor;
  final String statusText;
  final List<SellingUnit> packagedUnits;

  const EnhancedProductCard({
    super.key,
    required this.product,
    required this.onDelete,
    required this.onEdit,
    required this.onAdjustStock,
    required this.onStockHistory,
    required this.onView,
    required this.statusColor,
    required this.statusText,
    this.packagedUnits = const [],
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final qty = product.quantity;
    final min = product.effectiveMinimumStock;
    final isLowStock = qty > 0 && qty <= min;
    final isOutOfStock = qty == 0;
    final user = getIt<UserCubit>().currentUser;
    final userType = user.userType;
    final canViewPricing =
        PermissionGuard.canViewWholesaleAndMinimumPrices(user);
    final packagedUnit = packagedUnits.isEmpty
        ? null
        : packagedUnits.firstWhere(
            (unit) => unit.isDefault,
            orElse: () => packagedUnits.first,
          );
    final double? sellingPrice = product.productType == ProductType.packaged
        ? packagedUnit?.sellingPrice
        : product.price;
    final double? wholesalePrice = product.productType == ProductType.packaged
        ? packagedUnit?.wholesalePrice
        : product.wholesalePrice;
    final minPrice =
        product.productType == ProductType.packaged ? null : product.minPrice;
    final priceUnit = packagedUnit?.name;
    final categoryName = product.displayCategoryName.isEmpty
        ? l10n.generalCategory
        : product.displayCategoryName;

    // Fixed font sizes for consistent layout
    const double titleSize = 16;
    const double small = 12;
    const double value = 14;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.surfaceColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isOutOfStock
              ? AppColors.errorColor.withOpacity(0.5)
              : isLowStock
                  ? AppColors.warningColor.withOpacity(0.5)
                  : AppColors.borderColor,
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < 700) {
            return _buildMobileContent(
              context,
              l10n: l10n,
              canViewPricing: canViewPricing,
              sellingPrice: sellingPrice,
              packagedUnits: packagedUnits,
              wholesalePrice: wholesalePrice,
              minPrice: minPrice,
              priceUnit: priceUnit,
              statusColor: statusColor,
              statusText: statusText,
              small: small,
              value: value,
            );
          }

          return Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              LocalImageView(
                path: product.imagePath,
                width: 56,
                height: 56,
                borderRadius: 12,
                fallback: Container(
                  color: AppColors.primaryColor.withOpacity(.08),
                  alignment: Alignment.center,
                  child: const Icon(Icons.inventory_2_outlined,
                      color: AppColors.primaryColor, size: 24),
                ),
              ),
              const SizedBox(width: 14),
              // 🔹 Product Name, Category & Barcode
              Expanded(
                flex: 3,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      product.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: titleSize,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    if (categoryName.isNotEmpty)
                      Text(
                        categoryName,
                        style: TextStyle(
                          fontSize: small,
                          color: AppColors.primaryColor,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    const SizedBox(height: 2),
                    Text(
                      product.barcode,
                      style: TextStyle(
                        fontSize: 11,
                        color: AppColors.mutedColor,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(width: 12),

              // 🔹 Price & Status
              Expanded(
                flex: 2,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (product.productType == ProductType.packaged)
                      _buildPackagedPriceBlock(
                        l10n,
                        packagedUnits,
                        small: small,
                        value: value,
                      )
                    else ...[
                      Row(
                        children: [
                          Icon(Icons.monetization_on_outlined,
                              size: 14, color: AppColors.mutedColor),
                          const SizedBox(width: 4),
                          Text(l10n.sellingPrice,
                              style: TextStyle(
                                  fontSize: small,
                                  color: AppColors.mutedColor)),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        "${sellingPrice?.toStringAsFixed(2) ?? '—'} "
                        "${l10n.currencyEg}"
                        "${priceUnit == null ? '' : ' / $priceUnit'}",
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: value,
                          color: AppColors.successColor,
                        ),
                      ),
                    ],
                    const SizedBox(height: 4),
                    _StatusChip(
                      text: statusText,
                      color: statusColor,
                      font: small,
                    ),
                  ],
                ),
              ),

              const SizedBox(width: 12),

              // 🔹 Quantity & Stock info
              Expanded(
                flex: 2,
                child: Row(
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.inventory_2_outlined,
                                size: 14, color: AppColors.mutedColor),
                            const SizedBox(width: 4),
                            Text(l10n.quantity,
                                style: TextStyle(
                                    fontSize: small,
                                    color: AppColors.mutedColor)),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                            product.productType == ProductType.packaged
                                ? product.quantityWithBaseUnit
                                : product.formattedQuantity,
                            style: TextStyle(
                                fontWeight: FontWeight.bold, fontSize: value)),
                      ],
                    ),
                  ],
                ),
              ),

              if (canViewPricing) ...[
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: Row(
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(l10n.wholesalePrice,
                              style: TextStyle(
                                  fontSize: small,
                                  color: AppColors.mutedColor)),
                          const SizedBox(height: 2),
                          if (product.productType == ProductType.packaged)
                            _buildPackagedWholesalePrices(
                              packagedUnits,
                              l10n,
                              value,
                            )
                          else
                            Text(
                              wholesalePrice?.toStringAsFixed(2) ?? '—',
                              style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: value,
                                  color: AppColors.accentGold),
                            ),
                        ],
                      ),
                      const SizedBox(width: 10),
                      if (product.productType != ProductType.packaged)
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(l10n.minPriceColumn,
                                style: TextStyle(
                                    fontSize: small,
                                    color: AppColors.mutedColor)),
                            const SizedBox(height: 2),
                            Text(
                              minPrice == null
                                  ? '—'
                                  : minPrice.toStringAsFixed(2),
                              style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: value,
                                  color: Colors.deepOrange),
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
              ],

              const SizedBox(width: 8),

              // 🔹 Actions
              if (userType != UserType.cashier)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      onPressed: onAdjustStock,
                      icon:
                          const Icon(Icons.add, color: AppColors.successColor),
                      tooltip: l10n.adjustStock,
                    ),
                    IconButton(
                      onPressed: onEdit,
                      icon: const Icon(Icons.edit_rounded,
                          color: AppColors.primaryColor),
                      tooltip: l10n.edit,
                    ),
                    IconButton(
                      onPressed: onView,
                      icon: const Icon(Icons.visibility_outlined,
                          color: AppColors.secondaryColor),
                      tooltip: 'View',
                    ),
                    IconButton(
                      onPressed: onDelete,
                      icon: const Icon(Icons.delete_rounded,
                          color: AppColors.errorColor),
                      tooltip: l10n.delete,
                    ),
                  ],
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildMobileContent(
    BuildContext context, {
    required AppLocalizations l10n,
    required bool canViewPricing,
    required double? sellingPrice,
    required double? wholesalePrice,
    required double? minPrice,
    required String? priceUnit,
    required Color statusColor,
    required String statusText,
    required double small,
    required double value,
    required List<SellingUnit> packagedUnits,
  }) {
    final categoryName = product.displayCategoryName.isEmpty
        ? l10n.generalCategory
        : product.displayCategoryName;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LocalImageView(
              path: product.imagePath,
              width: 56,
              height: 56,
              borderRadius: 12,
              fallback: Container(
                color: AppColors.primaryColor.withOpacity(.08),
                alignment: Alignment.center,
                child: const Icon(
                  Icons.inventory_2_outlined,
                  color: AppColors.primaryColor,
                  size: 24,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    product.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 16,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  if (categoryName.isNotEmpty)
                    Text(
                      categoryName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: small,
                        color: AppColors.primaryColor,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  if (product.barcode.isNotEmpty)
                    Text(
                      product.barcode,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: AppColors.mutedColor,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 16,
          runSpacing: 8,
          children: [
            if (product.productType == ProductType.packaged)
              _buildPackagedPriceBlock(
                l10n,
                packagedUnits,
                small: small,
                value: value,
              )
            else
              _mobileInfo(
                icon: Icons.monetization_on_outlined,
                label: l10n.sellingPrice,
                value:
                    "${sellingPrice?.toStringAsFixed(2) ?? '—'} ${l10n.currencyEg}"
                    "${priceUnit == null ? '' : ' / $priceUnit'}",
                color: AppColors.successColor,
                small: small,
                valueSize: value,
              ),
            _mobileInfo(
              icon: Icons.inventory_2_outlined,
              label: l10n.quantity,
              value: product.productType == ProductType.packaged
                  ? "${product.quantity} ${product.baseUnit}"
                  : "${product.quantity}",
              small: small,
              valueSize: value,
            ),
            _StatusChip(text: statusText, color: statusColor, font: small),
            if (canViewPricing) ...[
              if (product.productType == ProductType.packaged)
                _buildPackagedWholesaleMobileInfo(
                  packagedUnits,
                  l10n,
                  small,
                  value,
                )
              else
                _mobileInfo(
                  label: l10n.wholesalePrice,
                  value: wholesalePrice?.toStringAsFixed(2) ?? '—',
                  color: AppColors.accentGold,
                  small: small,
                  valueSize: value,
                ),
              if (product.productType != ProductType.packaged)
                _mobileInfo(
                  label: l10n.minPriceColumn,
                  value: minPrice?.toStringAsFixed(2) ?? '—',
                  color: Colors.deepOrange,
                  small: small,
                  valueSize: value,
                ),
            ],
          ],
        ),
        const SizedBox(height: 8),
        Align(
          alignment: AlignmentDirectional.centerEnd,
          child: Wrap(
            spacing: 0,
            children: [
              if (getIt<UserCubit>().currentUser.userType != UserType.cashier)
                IconButton(
                  onPressed: onAdjustStock,
                  icon: const Icon(Icons.add, color: AppColors.successColor),
                  tooltip: l10n.adjustStock,
                ),
              if (getIt<UserCubit>().currentUser.userType != UserType.cashier)
                IconButton(
                  onPressed: onEdit,
                  icon: const Icon(
                    Icons.edit_rounded,
                    color: AppColors.primaryColor,
                  ),
                  tooltip: l10n.edit,
                ),
              if (getIt<UserCubit>().currentUser.userType != UserType.cashier)
                IconButton(
                  onPressed: onView,
                  icon: const Icon(
                    Icons.visibility_outlined,
                    color: AppColors.secondaryColor,
                  ),
                  tooltip: 'View',
                ),
              if (getIt<UserCubit>().currentUser.userType != UserType.cashier)
                IconButton(
                  onPressed: onDelete,
                  icon: const Icon(
                    Icons.delete_rounded,
                    color: AppColors.errorColor,
                  ),
                  tooltip: l10n.delete,
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildPackagedPriceBlock(
    AppLocalizations l10n,
    List<SellingUnit> units, {
    required double small,
    required double value,
  }) {
    if (units.isEmpty) {
      return _mobileInfo(
        icon: Icons.monetization_on_outlined,
        label: l10n.sellingPrice,
        value: '—',
        color: AppColors.successColor,
        small: small,
        valueSize: value,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: units.map((unit) {
        return Text(
          '${_localizedUnitName(unit.name, l10n)}: '
          '${unit.sellingPrice.toStringAsFixed(2)} ${l10n.currencyEg}',
          style: TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: value,
            color: AppColors.successColor,
          ),
        );
      }).toList(),
    );
  }

  Widget _buildPackagedWholesalePrices(
    List<SellingUnit> units,
    AppLocalizations l10n,
    double fontSize,
  ) {
    final wholesaleUnits = units.where(
      (unit) =>
          unit.wholesalePrice != null &&
          (unit.name.trim().toLowerCase() == 'pack' ||
              unit.name.trim().toLowerCase() == 'box'),
    );
    if (wholesaleUnits.isEmpty) {
      return Text(
        '—',
        style: TextStyle(
          fontWeight: FontWeight.bold,
          fontSize: fontSize,
          color: AppColors.accentGold,
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: wholesaleUnits.map((unit) {
        return Text(
          '${_localizedUnitName(unit.name, l10n)}: '
          '${unit.wholesalePrice!.toStringAsFixed(2)} ${l10n.currencyEg}',
          style: TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: fontSize,
            color: AppColors.accentGold,
          ),
        );
      }).toList(),
    );
  }

  Widget _buildPackagedWholesaleMobileInfo(
    List<SellingUnit> units,
    AppLocalizations l10n,
    double small,
    double value,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.wholesalePrice,
          style: TextStyle(fontSize: small, color: AppColors.mutedColor),
        ),
        const SizedBox(height: 2),
        _buildPackagedWholesalePrices(units, l10n, value),
      ],
    );
  }

  String _localizedUnitName(String name, AppLocalizations l10n) {
    if (l10n.localeName != 'ar') return name;
    switch (name.trim().toLowerCase()) {
      case 'piece':
        return 'قطعة';
      case 'pack':
        return 'عبوة';
      case 'box':
        return 'صندوق';
      default:
        return name;
    }
  }

  Widget _mobileInfo({
    IconData? icon,
    required String label,
    required String value,
    required double small,
    required double valueSize,
    Color? color,
  }) {
    return Row(
      children: [
        if (icon != null) ...[
          Icon(icon, size: 14, color: AppColors.mutedColor),
          const SizedBox(width: 4),
        ],
        Flexible(
          flex: 0,
          child: Text(
            '$label: ',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: small, color: AppColors.mutedColor),
          ),
        ),
        Expanded(
          child: Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: valueSize,
              color: color,
            ),
          ),
        ),
      ],
    );
  }
}

class _StatusChip extends StatelessWidget {
  final String text;
  final Color color;
  final double font;
  const _StatusChip({
    required this.text,
    required this.color,
    required this.font,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: color,
          fontSize: font,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class ActionButton extends StatefulWidget {
  final String text;
  final IconData icon;
  final Color baseColor;
  final VoidCallback onPressed;
  final double? fontSize;

  const ActionButton({
    super.key,
    required this.text,
    required this.icon,
    required this.baseColor,
    required this.onPressed,
    this.fontSize,
  });

  @override
  State<ActionButton> createState() => _ActionButtonState();
}

class _ActionButtonState extends State<ActionButton> {
  bool hovering = false;

  @override
  Widget build(BuildContext context) {
    final f = (widget.fontSize ?? 13).clamp(11, 15).toDouble();
    final bgColor = hovering
        ? widget.baseColor.withOpacity(0.9)
        : widget.baseColor.withOpacity(0.12);
    final fgColor = hovering ? Colors.white : widget.baseColor;

    return MouseRegion(
      onEnter: (_) => setState(() => hovering = true),
      onExit: (_) => setState(() => hovering = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 130),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(8),
        ),
        child: InkWell(
          onTap: widget.onPressed,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 6),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(widget.icon, color: fgColor, size: f + 2),
                const SizedBox(width: 5),
                Text(
                  widget.text,
                  style: TextStyle(
                    color: fgColor,
                    fontWeight: FontWeight.w700,
                    fontSize: f,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
