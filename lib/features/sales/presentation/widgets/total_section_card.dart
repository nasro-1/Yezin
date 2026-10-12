import 'package:flutter/material.dart';
import 'package:bayaa_pos/l10n/app_localizations.dart';
import '../../../../core/constants/app_colors.dart';

class TotalSectionCard extends StatelessWidget {
  final double totalAmount;
  final int itemCount;
  final VoidCallback? onCheckout;
  final VoidCallback? onClearCart;

  const TotalSectionCard({
    super.key,
    required this.totalAmount,
    required this.itemCount,
    this.onCheckout,
    this.onClearCart,
  });

  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final compact = MediaQuery.sizeOf(context).width < 700;
    return TweenAnimationBuilder<double>(
      duration: const Duration(milliseconds: 600),
      tween: Tween(begin: 0.0, end: 1.0),
      curve: Curves.easeOutCubic,
      builder: (context, value, child) {
        return Opacity(
          opacity: value,
          child: Transform.translate(
            offset: Offset(0, 20 * (1 - value)),
            child: child,
          ),
        );
      },
      child: Container(
        padding: EdgeInsets.all(compact ? 12 : 20),
        decoration: BoxDecoration(
          color: AppColors.kCardBackground,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.borderColor, width: 1),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.02),
              blurRadius: 15,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.invoiceSummaryTitle,
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
            SizedBox(height: compact ? 8 : 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  l10n.itemCountLabel,
                  style: const TextStyle(
                    color: AppColors.mutedColor,
                    fontSize: 13,
                  ),
                ),
                Text(
                  l10n.itemCountValue(itemCount),
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  l10n.subtotalLabel,
                  style: const TextStyle(
                    color: AppColors.mutedColor,
                    fontSize: 13,
                  ),
                ),
                Text(
                  l10n.priceWithCurrency(
                      totalAmount.toStringAsFixed(2), l10n.currencyEg),
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            Padding(
              padding: EdgeInsets.symmetric(vertical: compact ? 8 : 12),
              child: Divider(color: AppColors.borderColor),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  l10n.grandTotalLabel,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  l10n.priceWithCurrency(
                      totalAmount.toStringAsFixed(2), l10n.currencyEg),
                  style: TextStyle(
                    color: AppColors.primaryColor,
                    fontSize: compact ? 18 : 22,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            SizedBox(height: compact ? 10 : 20),
            ElevatedButton.icon(
              onPressed: onCheckout,
              icon: const Icon(Icons.check_circle_outline, size: 20),
              label: Text(
                l10n.checkoutBtn,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                ),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.kSuccessGreen,
                foregroundColor: Colors.white,
                padding: EdgeInsets.symmetric(vertical: compact ? 11 : 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                elevation: 0,
              ),
            ),
            SizedBox(height: compact ? 6 : 10),
            OutlinedButton.icon(
              onPressed: onClearCart,
              icon: const Icon(Icons.delete_outline, size: 18),
              label: Text(
                l10n.clearCartBtn,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.kDangerRed,
                side: const BorderSide(color: AppColors.kDangerRed, width: 1),
                padding: EdgeInsets.symmetric(vertical: compact ? 8 : 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
