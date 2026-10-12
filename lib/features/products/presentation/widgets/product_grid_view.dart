import 'package:bayaa_pos/features/products/data/models/product_model.dart';
import 'package:bayaa_pos/features/products/data/models/selling_unit_model.dart';
import 'package:flutter/material.dart';
import '../../../../core/components/empty_state.dart';
import '../../../../l10n/app_localizations.dart';
import 'enhanced_product_card.dart';

class ProductsGridView extends StatelessWidget {
  final List<Product> products;
  final void Function(Product) onDelete;
  final void Function(Product) onEdit;
  final void Function(Product) onAdjustStock;
  final void Function(Product) onStockHistory;
  final void Function(Product) onView;
  final Color Function(num, num) statusColorFn;
  final String Function(num, num) statusTextFn;

  final ScrollController? scrollController;
  final bool isLoadingMore;
  final String? emptyTitle;
  final String? emptyMessage;
  final Map<String, List<SellingUnit>> packagedDisplayUnits;

  const ProductsGridView({
    super.key,
    required this.products,
    required this.onDelete,
    required this.onEdit,
    required this.onAdjustStock,
    required this.onStockHistory,
    required this.onView,
    required this.statusColorFn,
    required this.statusTextFn,
    this.scrollController,
    this.isLoadingMore = false,
    this.emptyTitle,
    this.emptyMessage,
    this.packagedDisplayUnits = const {},
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    if (products.isEmpty) {
      return EmptyState(
        variant: EmptyStateVariant.products,
        title: emptyTitle ?? l10n.noProducts,
        message: emptyMessage ?? l10n.addProductsHint,
        icon: Icons.search,
      );
    }

    return ListView.builder(
      controller: scrollController,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      itemCount: products.length + (isLoadingMore ? 1 : 0),
      itemBuilder: (context, index) {
        if (index == products.length) {
          return const Padding(
            padding: EdgeInsets.all(16.0),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        final product = products[index];
        final qty = product.quantity;
        final min = product.effectiveMinimumStock;
        return EnhancedProductCard(
          product: product,
          onDelete: () => onDelete(product),
          onEdit: () => onEdit(product),
          onAdjustStock: () => onAdjustStock(product),
          onStockHistory: () => onStockHistory(product),
          onView: () => onView(product),
          statusColor: statusColorFn(qty, min),
          statusText: statusTextFn(qty, min),
          packagedUnits: packagedDisplayUnits[product.id] ?? const [],
        );
      },
    );
  }
}
