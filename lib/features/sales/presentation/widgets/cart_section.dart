import 'package:flutter/material.dart';
import 'package:bayaa_pos/l10n/app_localizations.dart';

import '../../../../core/constants/app_colors.dart';
import 'cart_item.dart';
import '../sales_cart_line.dart';
import '../../../products/data/models/selling_unit_model.dart';

class CartSection extends StatelessWidget {
  final List<Map<String, dynamic>> cartItems;
  final Function(int)? onRemoveItem;
  final Function(int)? onIncreaseQty;
  final Function(int)? onDecreaseQty;
  final Function(int, double)? onEditPrice;
  final Function(int, double)? onEditQuantity;
  final Function(int, SellingUnit)? onSellingUnitChanged;

  const CartSection({
    super.key,
    required this.cartItems,
    this.onRemoveItem,
    this.onIncreaseQty,
    this.onDecreaseQty,
    this.onEditPrice,
    this.onEditQuantity,
    this.onSellingUnitChanged,
  });

  num _calculateRemainingQuantity(Map<String, dynamic> item) {
    return calculateCartRemaining(item);
  }

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 700;
    return TweenAnimationBuilder(
      duration: const Duration(milliseconds: 1000),
      tween: Tween(begin: 0.0, end: 1.0),
      curve: Curves.easeOutCubic,
      builder: (context, value, child) {
        return Opacity(
          opacity: value,
          child: Transform.scale(
            scale: 0.95 + (0.05 * value),
            child: child,
          ),
        );
      },
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.kCardBackground,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.borderColor, width: 1),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.04),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          children: [
            Padding(
                padding: const EdgeInsets.all(20),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: AppColors.primaryColor.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(
                        Icons.shopping_cart_outlined,
                        color: AppColors.primaryColor,
                        size: 22,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      AppLocalizations.of(context).cartProductList,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: AppColors.secondaryColor,
                            fontSize: compact ? 16 : null,
                          ),
                    ),
                    const SizedBox(width: 10),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 4),
                      decoration: BoxDecoration(
                        color: AppColors.surfaceColor,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        '(${cartItems.length})',
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            Divider(height: 1, color: AppColors.borderColor),
            Expanded(
              child: cartItems.isEmpty
                  ? _buildEmptyState(context)
                  : ListView.separated(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      itemCount: cartItems.length,
                      separatorBuilder: (_, __) => Divider(
                        indent: 20,
                        endIndent: 20,
                        color: AppColors.borderColor.withOpacity(0.5),
                      ),
                      itemBuilder: (context, index) {
                        final item = cartItems[index];
                        return CartItemRow(
                          name: item['name'],
                          id: item['displayCode'] as String? ?? '',
                          price: item['price'],
                          quantity: item['qty'],
                          remainingQuantity: _calculateRemainingQuantity(item),
                          date: item['date'],
                          minPrice: item['minPrice'] ?? 0.0,
                          productType: item['productType'] ?? 'standard',
                          baseUnit: item['baseUnitSnapshot'] ?? 'piece',
                          sellingUnitName:
                              item['sellingUnitNameSnapshot'] as String?,
                          sellingUnitId: item['sellingUnitId'] as String?,
                          sellingUnitIconKey:
                              item['sellingUnitIconKey'] as String?,
                          sellingUnits: (item['sellingUnits'] as List?)
                              ?.whereType<SellingUnit>()
                              .toList(),
                          onSellingUnitChanged: (unit) =>
                              onSellingUnitChanged?.call(index, unit),
                          onRemove: () => onRemoveItem?.call(index),
                          onIncrease: () => onIncreaseQty?.call(index),
                          onDecrease: () => onDecreaseQty?.call(index),
                          onEditPrice: (newPrice) =>
                              onEditPrice?.call(index, newPrice),
                          onEditQuantity: (newQuantity) =>
                              onEditQuantity?.call(index, newQuantity),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: AppColors.surfaceColor,
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.shopping_cart_outlined,
                size: 64,
                color: AppColors.mutedColor,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              AppLocalizations.of(context).cartEmptyTitle,
              style: TextStyle(
                color: AppColors.mutedColor,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              AppLocalizations.of(context).cartEmptySubtitle,
              style: TextStyle(
                color: AppColors.mutedColor.withOpacity(0.7),
                fontSize: 14,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
