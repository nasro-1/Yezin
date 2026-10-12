import 'package:flutter/material.dart';
import 'package:bayaa_pos/l10n/app_localizations.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/components/local_image_view.dart';
import '../../../products/data/models/product_model.dart';

class ProductSearchOverlay extends StatelessWidget {
  final List<Product> products;
  final Function(Product) onProductSelected;
  final bool expandToAvailableSpace;

  const ProductSearchOverlay({
    super.key,
    required this.products,
    required this.onProductSelected,
    this.expandToAvailableSpace = false,
  });

  @override
  Widget build(BuildContext context) {
    if (products.isEmpty) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.only(top: 4),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 20,
            offset: const Offset(0, 10),
          ),
        ],
        border: Border.all(color: AppColors.borderColor, width: 1),
      ),
      constraints: expandToAvailableSpace
          ? const BoxConstraints()
          : const BoxConstraints(maxHeight: 300),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: ListView.separated(
          shrinkWrap: !expandToAvailableSpace,
          padding: const EdgeInsets.all(8),
          itemCount: products.length,
          separatorBuilder: (context, index) =>
              Divider(color: AppColors.borderColor, height: 1),
          itemBuilder: (context, index) {
            final product = products[index];

            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ListTile(
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  leading: LocalImageView(
                    path: product.imagePath,
                    width: 42,
                    height: 42,
                    borderRadius: 9,
                    fallback: Container(
                      color: AppColors.kPrimaryBlue.withOpacity(0.1),
                      alignment: Alignment.center,
                      child: const Icon(Icons.inventory_2_outlined,
                          color: AppColors.kPrimaryBlue, size: 20),
                    ),
                  ),
                  title: Text(
                    product.name,
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                      color: product.quantity <= 0 ? Colors.grey : Colors.black,
                      decoration: product.quantity <= 0
                          ? TextDecoration.lineThrough
                          : null,
                    ),
                  ),
                  subtitle: Text(
                    '${product.internalReference ?? product.barcode} | '
                    '${product.displayCategoryName.isEmpty ? AppLocalizations.of(context).generalCategory : product.displayCategoryName}',
                    style: TextStyle(color: AppColors.mutedColor, fontSize: 12),
                  ),
                  trailing: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        '${product.price.toStringAsFixed(2)} ${AppLocalizations.of(context).currencyEg}',
                        style: TextStyle(
                          color: AppColors.kPrimaryBlue,
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                      Text(
                        AppLocalizations.of(context)
                            .stockLabel(product.quantity),
                        style: TextStyle(
                          color:
                              product.quantity <= product.effectiveMinimumStock
                                  ? Colors.red
                                  : Colors.green,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                  tileColor: product.quantity <= 0
                      ? Colors.grey.withOpacity(0.1)
                      : null,
                  enabled: product.quantity > 0,
                  onTap: product.quantity > 0
                      ? () => onProductSelected(product)
                      : null,
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
