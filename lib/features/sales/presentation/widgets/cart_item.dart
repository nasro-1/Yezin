import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
// HID suppression handled by SalesScreen via focus checks; don't directly
// remove global listeners from widgets.
import 'package:bayaa_pos/l10n/app_localizations.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../products/presentation/widgets/selling_unit_icon.dart';
import '../../../products/data/models/selling_unit_model.dart';
import 'quantity_format.dart';

class CartItemRow extends StatefulWidget {
  final String name;
  final String id;
  final double price;
  final num quantity;
  final num remainingQuantity;
  final DateTime date;
  final double minPrice;
  final String productType;
  final String baseUnit;
  final String? sellingUnitName;
  final String? sellingUnitId;
  final String? sellingUnitIconKey;
  final List<SellingUnit>? sellingUnits;
  final Function(SellingUnit)? onSellingUnitChanged;
  final VoidCallback? onRemove;
  final VoidCallback? onIncrease;
  final VoidCallback? onDecrease;
  final Function(double)? onEditPrice;
  final Function(double)? onEditQuantity;

  const CartItemRow({
    super.key,
    required this.name,
    required this.id,
    required this.price,
    required this.quantity,
    required this.remainingQuantity,
    required this.date,
    required this.minPrice,
    this.productType = 'standard',
    this.baseUnit = 'piece',
    this.sellingUnitName,
    this.sellingUnitId,
    this.sellingUnitIconKey,
    this.sellingUnits,
    this.onSellingUnitChanged,
    this.onRemove,
    this.onIncrease,
    this.onDecrease,
    this.onEditPrice,
    this.onEditQuantity,
  });

  @override
  State<CartItemRow> createState() => _CartItemRowState();
}

class _CartItemRowState extends State<CartItemRow> {
  late TextEditingController _priceController;
  late TextEditingController _quantityController;
  late FocusNode _quantityFocusNode;

  @override
  void initState() {
    super.initState();
    _priceController =
        TextEditingController(text: widget.price.toStringAsFixed(2));
    _quantityController =
        TextEditingController(text: formatQuantity(widget.quantity));
    _quantityFocusNode = FocusNode()..addListener(_handleQuantityFocusChange);
  }

  @override
  void dispose() {
    _priceController.dispose();
    _quantityController.dispose();
    _quantityFocusNode
      ..removeListener(_handleQuantityFocusChange)
      ..dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant CartItemRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_quantityFocusNode.hasFocus && oldWidget.quantity != widget.quantity) {
      _quantityController.text = formatQuantity(widget.quantity);
    }
  }

  void _handleQuantityFocusChange() {
    if (!_quantityFocusNode.hasFocus) {
      _commitQuantity();
    } else {
      _quantityController.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _quantityController.text.length,
      );
    }
  }

  void _commitQuantity() {
    final quantity = double.tryParse(_quantityController.text.trim());
    if (quantity == null || quantity <= 0) {
      _quantityController.text = formatQuantity(widget.quantity);
      return;
    }
    widget.onEditQuantity?.call(quantity);
    _quantityController.text = formatQuantity(widget.quantity);
  }

  Future<void> _showEditPriceDialog() async {
    _priceController.text = widget.price.toStringAsFixed(2);

    // Rely on focus-based suppression in SalesScreen; do not remove global listeners here.

    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(AppLocalizations.of(context).editPriceTitle),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                AppLocalizations.of(context).minPriceLabel(
                    widget.minPrice.toStringAsFixed(2),
                    AppLocalizations.of(context).currencyEg),
                style: TextStyle(
                  color: AppColors.warningColor,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _priceController,
                autofocus: true,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                // Allow progressive typing: empty, integers, or decimals up to 2 places.
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,2}$')),
                ],
                decoration: InputDecoration(
                  labelText: AppLocalizations.of(context).newPriceLabel,
                  suffixText: AppLocalizations.of(context).currencyEg,
                  border: const OutlineInputBorder(),
                  filled: true,
                  fillColor: AppColors.surfaceColor,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(AppLocalizations.of(context).cancelBtn),
            ),
            ElevatedButton(
              onPressed: () {
                final newPrice = double.tryParse(_priceController.text);
                if (newPrice != null && newPrice >= widget.minPrice) {
                  widget.onEditPrice?.call(newPrice);
                  Navigator.pop(context);
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        AppLocalizations.of(context).priceValidationError(
                            widget.minPrice.toStringAsFixed(2),
                            AppLocalizations.of(context).currencyEg),
                      ),
                      backgroundColor: AppColors.kDangerRed,
                    ),
                  );
                }
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.kPrimaryBlue,
              ),
              child: Text(AppLocalizations.of(context).saveBtn),
            ),
          ],
        );
      },
    );

    // No-op: HID listener reattachment handled centrally by SalesScreen focus logic.
  }

  // Get color for remaining quantity indicator
  Color _getRemainingQuantityColor() {
    if (widget.remainingQuantity <= 5) {
      return AppColors.kDangerRed;
    } else if (widget.remainingQuantity <= 20) {
      return AppColors.warningColor;
    } else {
      return AppColors.kSuccessGreen;
    }
  }

  @override
  Widget build(BuildContext context) {
    final total = widget.price * widget.quantity.toDouble();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final isWide = constraints.maxWidth > 600;
          if (!isWide) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline, size: 20),
                      onPressed: widget.onRemove ?? () {},
                      style: IconButton.styleFrom(
                        backgroundColor: AppColors.kDangerRed,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.all(6),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                if (widget.id.trim().isNotEmpty)
                  Text(
                    AppLocalizations.of(context).codeLabel(widget.id),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppColors.mutedColor,
                      fontSize: 11,
                    ),
                  ),
                if (widget.sellingUnits != null &&
                    widget.sellingUnits!.length > 1) ...[
                  const SizedBox(height: 8),
                  _buildSellingUnitSelector(),
                ],
                const SizedBox(height: 8),
                Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    GestureDetector(
                      onTap: _showEditPriceDialog,
                      child: Text(
                        AppLocalizations.of(context).priceWithCurrency(
                          widget.price.toStringAsFixed(0),
                          AppLocalizations.of(context).currencyEg,
                        ),
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _buildQtyButton(Icons.remove, widget.onDecrease),
                        if (widget.productType == 'weighted')
                          SizedBox(
                            width: 64,
                            child: TextField(
                              controller: _quantityController,
                              focusNode: _quantityFocusNode,
                              textAlign: TextAlign.center,
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                decimal: true,
                              ),
                              inputFormatters: [
                                FilteringTextInputFormatter.allow(
                                  RegExp(r'^\d*\.?\d{0,3}$'),
                                ),
                              ],
                              onSubmitted: (_) {
                                _commitQuantity();
                                _quantityFocusNode.unfocus();
                              },
                              decoration: InputDecoration(
                                isDense: true,
                                suffixText: widget.baseUnit,
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                  vertical: 6,
                                ),
                                border: const OutlineInputBorder(),
                              ),
                            ),
                          )
                        else
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            child: Text(
                              formatQuantity(widget.quantity, decimalPlaces: 0),
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 16,
                              ),
                            ),
                          ),
                        _buildQtyButton(Icons.add, widget.onIncrease),
                      ],
                    ),
                    Text(
                      AppLocalizations.of(context).priceWithCurrency(
                        total.toStringAsFixed(0),
                        AppLocalizations.of(context).currencyEg,
                      ),
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ],
            );
          }
          return Row(
            children: [
              Expanded(
                flex: isWide ? 4 : 3,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.name,
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                      ),
                    ),
                    if (widget.id.trim().isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          AppLocalizations.of(context).codeLabel(widget.id),
                          style: TextStyle(
                            color: AppColors.mutedColor,
                            fontSize: 11,
                          ),
                        ),
                      ),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          AppLocalizations.of(context).dateLabel(
                              '${widget.date.year}/${widget.date.month}/${widget.date.day}'),
                          style: TextStyle(
                            color: AppColors.mutedColor,
                            fontSize: 12,
                          ),
                        ),
                        // Remaining quantity indicator
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color:
                                _getRemainingQuantityColor().withOpacity(0.1),
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(
                              color:
                                  _getRemainingQuantityColor().withOpacity(0.3),
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.inventory_2_outlined,
                                size: 12,
                                color: _getRemainingQuantityColor(),
                              ),
                              const SizedBox(width: 4),
                              Text(
                                AppLocalizations.of(context)
                                    .remainingLabel(widget.remainingQuantity),
                                style: TextStyle(
                                  color: _getRemainingQuantityColor(),
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    if (widget.sellingUnits != null &&
                        widget.sellingUnits!.length > 1) ...[
                      const SizedBox(height: 8),
                      _buildSellingUnitSelector(),
                    ],
                  ],
                ),
              ),
              if (isWide) const SizedBox(width: 12),
              Expanded(
                flex: isWide ? 2 : 2,
                child: GestureDetector(
                  onTap: _showEditPriceDialog,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: AppColors.surfaceColor,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: AppColors.borderColor),
                    ),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            AppLocalizations.of(context).priceWithCurrency(
                                widget.price.toStringAsFixed(0),
                                AppLocalizations.of(context).currencyEg),
                            textAlign: TextAlign.center,
                            style: const TextStyle(fontSize: 14),
                          ),
                          const SizedBox(width: 4),
                          Icon(
                            Icons.edit,
                            size: 14,
                            color: AppColors.primaryColor,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              Expanded(
                flex: isWide ? 3 : 3,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _buildQtyButton(Icons.remove, widget.onDecrease),
                    if (widget.productType == 'weighted')
                      SizedBox(
                        width: isWide ? 72 : 58,
                        child: TextField(
                          controller: _quantityController,
                          focusNode: _quantityFocusNode,
                          textAlign: TextAlign.center,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          inputFormatters: [
                            FilteringTextInputFormatter.allow(
                              RegExp(r'^\d*\.?\d{0,3}$'),
                            ),
                          ],
                          onSubmitted: (_) {
                            _commitQuantity();
                            _quantityFocusNode.unfocus();
                          },
                          decoration: InputDecoration(
                            isDense: true,
                            suffixText: widget.baseUnit,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 4,
                              vertical: 6,
                            ),
                            border: const OutlineInputBorder(),
                          ),
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                      )
                    else
                      Padding(
                        padding:
                            EdgeInsets.symmetric(horizontal: isWide ? 12 : 6),
                        child: Text(
                          formatQuantity(widget.quantity, decimalPlaces: 0),
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                      ),
                    _buildQtyButton(Icons.add, widget.onIncrease),
                  ],
                ),
              ),
              if (isWide) const SizedBox(width: 12),
              Expanded(
                flex: isWide ? 2 : 2,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    AppLocalizations.of(context).priceWithCurrency(
                        total.toStringAsFixed(0),
                        AppLocalizations.of(context).currencyEg),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                icon: const Icon(Icons.delete_outline, size: 20),
                onPressed: widget.onRemove ?? () {},
                style: IconButton.styleFrom(
                  backgroundColor: AppColors.kDangerRed,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  padding: const EdgeInsets.all(8),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildSellingUnitSelector() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (var index = 0; index < widget.sellingUnits!.length; index++) ...[
            if (index > 0) const SizedBox(width: 5),
            _buildSellingUnitChip(widget.sellingUnits![index]),
          ],
        ],
      ),
    );
  }

  Widget _buildSellingUnitChip(SellingUnit unit) {
    final selected = widget.sellingUnitId != null
        ? unit.id == widget.sellingUnitId
        : unit.name == widget.sellingUnitName;
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      selected: selected,
      label: '${unit.name}, ${unit.sellingPrice.toStringAsFixed(2)} DA',
      child: InkWell(
        onTap: selected ? null : () => widget.onSellingUnitChanged?.call(unit),
        borderRadius: BorderRadius.circular(7),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          constraints: const BoxConstraints(minHeight: 34, maxHeight: 38),
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
          decoration: BoxDecoration(
            color: selected ? colors.primary.withOpacity(0.12) : colors.surface,
            borderRadius: BorderRadius.circular(7),
            border: Border.all(
              color: selected ? colors.primary : AppColors.borderColor,
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                sellingUnitIconData(unit.iconKey, unitName: unit.name),
                size: 14,
                color: selected ? colors.primary : AppColors.mutedColor,
              ),
              const SizedBox(width: 4),
              Text(
                unit.name,
                style: TextStyle(
                  color: selected ? colors.primary : AppColors.textPrimary,
                  fontSize: 11,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                ),
              ),
              const SizedBox(width: 3),
              Text(
                '· ${unit.sellingPrice.toStringAsFixed(0)} DA',
                style: TextStyle(
                  color: selected ? colors.primary : AppColors.textSecondary,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (selected) ...[
                const SizedBox(width: 3),
                Icon(Icons.check, size: 12, color: colors.primary),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildQtyButton(IconData icon, VoidCallback? onPressed) {
    return InkWell(
      onTap: onPressed ?? () {},
      child: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: AppColors.surfaceColor,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.borderColor),
        ),
        child: Icon(icon, size: 16, color: AppColors.secondaryColor),
      ),
    );
  }
}
