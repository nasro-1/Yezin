import 'package:bayaa_pos/features/products/data/models/product_model.dart';
import 'package:bayaa_pos/features/products/data/models/selling_unit_model.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../../../../core/components/empty_state.dart';
import '../../../../core/components/local_image_view.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/security/permission_guard.dart';
import '../../../../l10n/app_localizations.dart';
import '../../../auth/data/models/user_model.dart';

class ProductsTableView extends StatelessWidget {
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
  final bool isManager;
  final User currentUser;
  final Map<String, List<SellingUnit>> packagedDisplayUnits;

  const ProductsTableView({
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
    this.isManager = false,
    required this.currentUser,
    this.packagedDisplayUnits = const {},
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final canViewPricing =
        PermissionGuard.canViewWholesaleAndMinimumPrices(currentUser);
    if (products.isEmpty) {
      return EmptyState(
        variant: EmptyStateVariant.products,
        title: emptyTitle ?? l10n.noProducts,
        message: emptyMessage ?? l10n.addProductsHint,
        icon: Icons.search,
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        return Align(
          alignment: AlignmentDirectional.topStart,
          child: SingleChildScrollView(
            controller: scrollController,
            scrollDirection: Axis.vertical,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: ConstrainedBox(
                constraints: BoxConstraints(minWidth: constraints.maxWidth),
                child: Theme(
                  data: Theme.of(context).copyWith(
                    dividerColor: Colors.grey.withOpacity(0.2),
                  ),
                  child: DataTable(
                    horizontalMargin: 20,
                    columnSpacing: 20,
                    headingRowHeight: 52,
                    headingRowColor: MaterialStateProperty.all(
                      AppColors.primaryColor.withOpacity(0.08),
                    ),
                    dataRowHeight: 60,
                    dataRowColor: MaterialStateProperty.resolveWith((states) {
                      if (states.contains(MaterialState.hovered)) {
                        return AppColors.primaryColor.withOpacity(0.02);
                      }
                      return Colors.white;
                    }),
                    border: TableBorder(
                      horizontalInside: BorderSide(
                        color: Colors.grey.withOpacity(0.15),
                        width: 1,
                      ),
                      bottom: BorderSide(
                        color: Colors.grey.withOpacity(0.2),
                        width: 1,
                      ),
                    ),
                    columns: [
                      DataColumn(
                          label: Text(l10n.productName,
                              style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 13,
                                  color: AppColors.primaryColor))),
                      DataColumn(
                          label: Text(l10n.barcode,
                              style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 13,
                                  color: AppColors.primaryColor))),
                      DataColumn(
                          label: Text(l10n.category,
                              style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 13,
                                  color: AppColors.primaryColor))),
                      DataColumn(
                          label: Text(l10n.price,
                              style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 13,
                                  color: AppColors.primaryColor))),
                      if (canViewPricing) ...[
                        DataColumn(
                            label: Text(l10n.wholesalePrice,
                                style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 13,
                                    color: AppColors.primaryColor))),
                        DataColumn(
                            label: Text(l10n.minPriceColumn,
                                style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 13,
                                    color: AppColors.primaryColor))),
                      ],
                      DataColumn(
                          label: Text(l10n.quantity,
                              style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 13,
                                  color: AppColors.primaryColor))),
                      DataColumn(
                          label: Text(l10n.status,
                              style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 13,
                                  color: AppColors.primaryColor))),
                      if (isManager)
                        DataColumn(
                            label: Text(l10n.actions,
                                style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 13,
                                    color: AppColors.primaryColor))),
                    ],
                    rows: [
                      ...products.map((product) {
                        final categoryName = product.displayCategoryName.isEmpty
                            ? l10n.generalCategory
                            : product.displayCategoryName;
                        final packagedUnits =
                            packagedDisplayUnits[product.id] ?? const [];
                        final packagedUnit = packagedUnits.isEmpty
                            ? null
                            : packagedUnits.firstWhere(
                                (unit) => unit.isDefault,
                                orElse: () => packagedUnits.first,
                              );
                        final double? sellingPrice =
                            product.productType == ProductType.packaged
                                ? packagedUnit?.sellingPrice
                                : product.price;
                        final double? wholesalePrice =
                            product.productType == ProductType.packaged
                                ? packagedUnit?.wholesalePrice
                                : product.wholesalePrice;
                        final minPrice =
                            product.productType == ProductType.packaged
                                ? null
                                : product.minPrice;
                        final priceUnit = packagedUnit?.name;
                        final statusColor = statusColorFn(
                            product.quantity, product.effectiveMinimumStock);
                        final statusText = statusTextFn(
                            product.quantity, product.effectiveMinimumStock);

                        return DataRow(cells: [
                          DataCell(
                            Row(
                              children: [
                                LocalImageView(
                                  path: product.imagePath,
                                  width: 38,
                                  height: 38,
                                  borderRadius: 9,
                                  fallback: Container(
                                    color:
                                        AppColors.primaryColor.withOpacity(.08),
                                    alignment: Alignment.center,
                                    child: const Icon(
                                        Icons.inventory_2_outlined,
                                        size: 18,
                                        color: AppColors.primaryColor),
                                  ),
                                ),
                                const SizedBox(width: 9),
                                Flexible(
                                  child: Text(
                                    product.name,
                                    style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 13),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          DataCell(Text(product.barcode,
                              style: const TextStyle(
                                  fontWeight: FontWeight.w700, fontSize: 13))),
                          DataCell(
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(
                                color: AppColors.primaryColor.withOpacity(0.05),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(categoryName,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 12,
                                      color: AppColors.primaryColor)),
                            ),
                          ),
                          DataCell(product.productType == ProductType.packaged
                              ? _buildPackagedSellingPrices(
                                  packagedUnits, l10n)
                              : Text(
                                  '${sellingPrice?.toStringAsFixed(2) ?? '—'} ${l10n.currencyEg}'
                                  '${priceUnit == null ? '' : ' / $priceUnit'}',
                                  style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 13))),
                          if (canViewPricing) ...[
                            DataCell(product.productType == ProductType.packaged
                                ? _buildPackagedWholesalePrices(
                                    packagedUnits,
                                    l10n,
                                  )
                                : Text(
                                    '${wholesalePrice?.toStringAsFixed(2) ?? '—'} ${l10n.currencyEg}',
                                    style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 13,
                                        color: Colors.blueGrey))),
                            DataCell(product.productType == ProductType.packaged
                                ? const Text('—')
                                : Text(
                                    minPrice == null
                                        ? '—'
                                        : '${minPrice.toStringAsFixed(2)} ${l10n.currencyEg}',
                                    style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 13,
                                        color: Colors.deepOrange))),
                          ],
                          DataCell(Text(
                              product.productType == ProductType.packaged
                                  ? product.quantityWithBaseUnit
                                  : product.formattedQuantity,
                              style: const TextStyle(
                                  fontWeight: FontWeight.bold, fontSize: 14))),
                          DataCell(
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: statusColor.withOpacity(0.1),
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(
                                    color: statusColor.withOpacity(0.3)),
                              ),
                              child: Text(
                                statusText,
                                style: TextStyle(
                                  color: statusColor,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          ),
                          if (isManager)
                            DataCell(
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    icon: const Icon(Icons.add, size: 18),
                                    color: AppColors.successColor,
                                    onPressed: () => onAdjustStock(product),
                                    tooltip: l10n.adjustStock,
                                  ),
                                  IconButton(
                                    icon: const Icon(LucideIcons.pencil,
                                        size: 18),
                                    color: AppColors.primaryColor,
                                    onPressed: () => onEdit(product),
                                    tooltip: l10n.edit,
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.visibility_outlined,
                                        size: 18),
                                    color: AppColors.secondaryColor,
                                    onPressed: () => onView(product),
                                    tooltip: 'View',
                                  ),
                                  IconButton(
                                    icon: const Icon(LucideIcons.trash2,
                                        size: 18),
                                    color: AppColors.errorColor,
                                    onPressed: () => onDelete(product),
                                    tooltip: l10n.delete,
                                  ),
                                ],
                              ),
                            ),
                        ]);
                      }),
                      if (isLoadingMore)
                        DataRow(
                          cells: List<DataCell>.generate(
                            6 + (canViewPricing ? 2 : 0) + (isManager ? 1 : 0),
                            (index) => DataCell(
                              index == 0
                                  ? const Center(
                                      child: SizedBox(
                                        width: 22,
                                        height: 22,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      ),
                                    )
                                  : const SizedBox.shrink(),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildPackagedWholesalePrices(
    List<SellingUnit> units,
    AppLocalizations l10n,
  ) {
    final wholesaleUnits = units.where(
      (unit) =>
          unit.wholesalePrice != null &&
          (unit.name.trim().toLowerCase() == 'pack' ||
              unit.name.trim().toLowerCase() == 'box'),
    );
    if (wholesaleUnits.isEmpty) {
      return Text('— ${l10n.currencyEg}');
    }
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: wholesaleUnits
          .map(
            (unit) => Text(
              '${unit.name}: ${unit.wholesalePrice!.toStringAsFixed(2)} ${l10n.currencyEg}',
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 12,
                color: Colors.blueGrey,
              ),
            ),
          )
          .toList(),
    );
  }

  Widget _buildPackagedSellingPrices(
    List<SellingUnit> units,
    AppLocalizations l10n,
  ) {
    if (units.isEmpty) {
      return Text('— ${l10n.currencyEg}');
    }
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: units.map((unit) {
        return Text(
          '${unit.name}: ${unit.sellingPrice.toStringAsFixed(2)} ${l10n.currencyEg}',
          style: const TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 12,
          ),
        );
      }).toList(),
    );
  }

}
