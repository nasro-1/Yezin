import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../../../../core/di/dependency_injection.dart';
import '../../../../core/data/services/persistence_initializer.dart';
import '../../../../core/security/permission_guard.dart';
import '../../../../core/network/backend_api_config.dart';
import '../../../../l10n/app_localizations.dart';
import '../../../auth/presentation/cubit/user_cubit.dart';
import '../../../purchases/data/repository/purchase_repository_impl.dart';
import '../../../stock/data/models/stock_adjustment_model.dart';
import '../../../stock/services/stock_adjustment_service.dart';
import '../../data/models/product_model.dart';
import '../../data/models/selling_unit_model.dart';
import '../../domain/product_catalog_service.dart';

List<({String value, String label})> stockAdjustmentReasonOptions(
  AppLocalizations l10n,
) =>
    [
      (
        value: 'initial_inventory',
        label: l10n.stockAdjustmentReasonInitialInventory
      ),
      (value: 'physical_count', label: l10n.stockAdjustmentReasonPhysicalCount),
      (value: 'damaged_goods', label: l10n.stockAdjustmentReasonDamagedGoods),
      (value: 'lost_goods', label: l10n.stockAdjustmentReasonLostGoods),
      (value: 'found_goods', label: l10n.stockAdjustmentReasonFoundGoods),
      (
        value: 'data_correction',
        label: l10n.stockAdjustmentReasonDataCorrection
      ),
      (value: 'other', label: l10n.stockAdjustmentReasonOther),
    ];

class ProductStockAdjustmentDialog extends StatefulWidget {
  final Product product;
  final String productId;

  const ProductStockAdjustmentDialog({
    super.key,
    required this.product,
    required this.productId,
  });

  @override
  State<ProductStockAdjustmentDialog> createState() =>
      _ProductStockAdjustmentDialogState();
}

class _ProductStockAdjustmentDialogState
    extends State<ProductStockAdjustmentDialog> {
  final _countedController = TextEditingController();
  final _costController = TextEditingController();
  final _otherReasonController = TextEditingController();
  final _notesController = TextEditingController();
  final _service = getIt<StockAdjustmentService>();
  List<SellingUnit> _sellingUnits = const [];
  SellingUnit? _selectedUnit;
  bool _posting = false;
  bool _adding = true;
  String? _selectedReason;
  bool _loadingCost = true;
  double? _loadedBaseCost;

  double? get _quantity => double.tryParse(_countedController.text.trim());
  double get _current => widget.product.quantity.toDouble();
  double? get _delta {
    final quantity = _quantity;
    if (quantity == null) return null;
    final conversion = _selectedUnit?.conversionToBase ?? 1;
    return (_adding ? quantity : -quantity) * conversion;
  }

  double? get _newStock {
    final delta = _delta;
    return delta == null ? null : _current + delta;
  }

  @override
  void initState() {
    super.initState();
    _loadPurchaseCost();
    if (widget.product.productType == ProductType.packaged) {
      if (BackendApiConfig.productWriteMode == ProductWriteMode.server) {
        _sellingUnits = widget.product.sellingUnits;
        final defaults =
            _sellingUnits.where((unit) => unit.isDefault).toList();
        _selectedUnit = defaults.isEmpty
            ? (_sellingUnits.isEmpty ? null : _sellingUnits.first)
            : defaults.first;
        return;
      }
      SellingUnitRepository(
        getIt<StockAdjustmentService>().sqliteManager ??
            PersistenceInitializer.persistenceManager!.sqliteManager,
      ).listByProduct(widget.product.id, activeOnly: true).then((units) {
        if (mounted) {
          final defaults = units.where((unit) => unit.isDefault).toList();
          setState(() {
            _sellingUnits = units;
            _selectedUnit = defaults.isEmpty
                ? (units.isEmpty ? null : units.first)
                : defaults.first;
            if (_loadedBaseCost != null && _selectedUnit != null) {
              _costController.text = _formatCost(
                _loadedBaseCost! * _selectedUnit!.conversionToBase,
              );
            }
          });
        }
      });
    }
  }

  Future<void> _loadPurchaseCost() async {
    final result = await getIt<PurchaseRepository>()
        .getLatestProductPurchaseCost(widget.product.id);
    if (!mounted) return;
    result.fold(
      (_) => setState(() => _loadingCost = false),
      (row) {
        final rawCost = (row?['unit_cost'] as num?)?.toDouble() ??
            (row?['cost'] as num?)?.toDouble();
        final conversion =
            (row?['conversion_factor_snapshot'] as num?)?.toDouble();
        final sellingQuantity = (row?['selling_quantity'] as num?)?.toDouble();
        final baseQuantity = (row?['base_quantity'] as num?)?.toDouble();
        final cost =
            rawCost == null || (row?['unit_cost'] == null && rawCost <= 0)
                ? null
                : conversion != null && conversion > 0
                    ? rawCost / conversion
                    : sellingQuantity != null &&
                            sellingQuantity > 0 &&
                            baseQuantity != null &&
                            baseQuantity > 0
                        ? rawCost * sellingQuantity / baseQuantity
                        : rawCost;
        setState(() {
          _loadingCost = false;
          _loadedBaseCost = cost;
        });
        if (cost != null && _costController.text.trim().isEmpty) {
          _costController.text = _formatCost(
            cost * (_selectedUnit?.conversionToBase ?? 1),
          );
        }
      },
    );
  }

  @override
  void dispose() {
    _countedController.dispose();
    _costController.dispose();
    _otherReasonController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  Future<void> _post() async {
    final l10n = AppLocalizations.of(context);
    final quantity = _quantity;
    if (quantity == null || quantity <= 0) {
      _showMessage(l10n.stockAdjustmentInvalidQuantity);
      return;
    }
    final enteredCost = double.tryParse(_costController.text.trim());
    if (_adding && (enteredCost == null || enteredCost < 0)) {
      _showMessage('Enter a valid non-negative cost price.');
      return;
    }
    final cost = _adding ? enteredCost! : 0.0;
    final newStock = _newStock!;
    if (newStock < 0) {
      _showMessage(l10n.stockAdjustmentNegativeResult);
      return;
    }
    if (_selectedReason == null) {
      _showMessage(l10n.stockAdjustmentReasonRequired);
      return;
    }
    final reason = _selectedReason == 'other'
        ? _otherReasonController.text.trim()
        : _reasonLabel(l10n, _selectedReason!);
    if (reason.isEmpty) {
      _showMessage(l10n.stockAdjustmentOtherReasonRequired);
      return;
    }
    final user = getIt<UserCubit>().currentUser;
    if (!PermissionGuard.canAdjustStock(user)) {
      _showMessage(l10n.stockAdjustmentPermissionDenied);
      return;
    }

    setState(() => _posting = true);
    try {
      await _service.post(
        idempotencyKey: const Uuid().v4(),
        user: user,
        reason: reason,
        notes: _notesController.text,
        lines: [
          StockAdjustmentLineInput(
            productId: widget.productId,
            countedQuantity: newStock,
            unitCost: cost,
            unit: _selectedUnit?.name ?? widget.product.baseUnit,
            operation: _adding ? 'add' : 'remove',
          ),
        ],
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (error) {
      if (mounted) {
        setState(() => _posting = false);
        _showMessage(error.toString());
      }
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final delta = _delta;
    final newStock = _newStock;

    return AlertDialog(
      title: Text('${l10n.stockAdjustment}: ${widget.product.name}'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _ValueRow(
                label: 'Current stock (${widget.product.baseUnit})',
                value: '${_format(_current)} ${widget.product.baseUnit}',
              ),
              const SizedBox(height: 4),
              Text(
                l10n.stockAdjustmentOperation,
                style: Theme.of(context).textTheme.labelLarge,
              ),
              const SizedBox(height: 4),
              SegmentedButton<bool>(
                segments: [
                  ButtonSegment(
                    value: true,
                    label: Text(l10n.stockAdjustmentAdd),
                  ),
                  ButtonSegment(
                    value: false,
                    label: Text(l10n.stockAdjustmentRemove),
                  ),
                ],
                selected: {_adding},
                onSelectionChanged: (selection) =>
                    setState(() => _adding = selection.first),
              ),
              const SizedBox(height: 8),
              if (_sellingUnits.isNotEmpty)
                DropdownButtonFormField<SellingUnit>(
                  value: _selectedUnit,
                  decoration: InputDecoration(
                    labelText: 'Adjustment unit',
                  ),
                  items: _sellingUnits
                      .map((unit) => DropdownMenuItem(
                            value: unit,
                            child: Text(
                                '${unit.name} (${unit.conversionToBase} ${widget.product.baseUnit})'),
                          ))
                      .toList(),
                  onChanged: (unit) {
                    setState(() {
                      _selectedUnit = unit;
                      if (_loadedBaseCost != null) {
                        _costController.text = _formatCost(
                          _loadedBaseCost! *
                              (unit?.conversionToBase ?? 1),
                        );
                      }
                    });
                  },
                ),
              TextField(
                controller: _countedController,
                autofocus: true,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText:
                      'Quantity (${_selectedUnit?.name ?? widget.product.baseUnit})',
                ),
              ),
              const SizedBox(height: 8),
              if (_adding)
                TextField(
                  controller: _costController,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(
                    labelText:
                        'Cost price / ${_selectedUnit?.name.toLowerCase() ?? widget.product.baseUnit.toLowerCase()}',
                    hintText: _loadingCost ? 'Loading...' : null,
                  ),
                ),
              const SizedBox(height: 8),
              _ValueRow(
                label: l10n.stockAdjustmentDelta,
                value: delta == null
                    ? '-'
                    : '${_signed(delta)} ${widget.product.baseUnit}',
              ),
              _ValueRow(
                label: l10n.stockAdjustmentNewStock,
                value: newStock == null
                    ? '-'
                    : '${_format(newStock)} ${widget.product.baseUnit}',
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                value: _selectedReason,
                decoration: InputDecoration(
                  labelText: l10n.stockAdjustmentReason,
                ),
                hint: Text(l10n.stockAdjustmentSelectReason),
                items: stockAdjustmentReasonOptions(l10n)
                    .map((reason) => DropdownMenuItem(
                          value: reason.value,
                          child: Text(reason.label),
                        ))
                    .toList(),
                onChanged: (value) => setState(() => _selectedReason = value),
              ),
              if (_selectedReason == 'other') ...[
                const SizedBox(height: 8),
                TextField(
                  controller: _otherReasonController,
                  decoration: InputDecoration(
                    labelText: l10n.stockAdjustmentOtherReason,
                  ),
                ),
              ],
              const SizedBox(height: 8),
              TextField(
                controller: _notesController,
                maxLines: 2,
                decoration:
                    InputDecoration(labelText: l10n.stockAdjustmentNotes),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _posting ? null : () => Navigator.of(context).pop(),
          child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
        ),
        FilledButton(
          onPressed: _posting ? null : _post,
          child: _posting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(l10n.stockAdjustmentPost),
        ),
      ],
    );
  }

  String _format(double value) => value == value.truncateToDouble()
      ? value.toInt().toString()
      : value.toStringAsFixed(2);

  String _formatCost(double value) => value.toStringAsFixed(2);

  String _signed(double value) =>
      value > 0 ? '+${_format(value)}' : _format(value);

  String _reasonLabel(AppLocalizations l10n, String value) => switch (value) {
        'initial_inventory' => l10n.stockAdjustmentReasonInitialInventory,
        'physical_count' => l10n.stockAdjustmentReasonPhysicalCount,
        'damaged_goods' => l10n.stockAdjustmentReasonDamagedGoods,
        'lost_goods' => l10n.stockAdjustmentReasonLostGoods,
        'found_goods' => l10n.stockAdjustmentReasonFoundGoods,
        'data_correction' => l10n.stockAdjustmentReasonDataCorrection,
        _ => value,
      };
}

class _ValueRow extends StatelessWidget {
  final String label;
  final String value;

  const _ValueRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label),
          Text(value, style: const TextStyle(fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }
}
