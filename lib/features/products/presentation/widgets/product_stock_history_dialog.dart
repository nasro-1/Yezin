import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../../../../core/di/dependency_injection.dart';
import '../../../../core/network/backend_api_config.dart';
import '../../../../core/security/permission_guard.dart';
import '../../../../l10n/app_localizations.dart';
import '../../../auth/presentation/cubit/user_cubit.dart';
import '../../../stock/data/models/stock_movement_model.dart';
import '../../../stock/data/repository/stock_movement_repository.dart';
import '../../data/models/product_model.dart';
import '../../data/repository/product_api_repository.dart';

class ProductStockHistoryDialog extends StatefulWidget {
  final Product product;
  final String productId;

  const ProductStockHistoryDialog({
    super.key,
    required this.product,
    required this.productId,
  });

  @override
  State<ProductStockHistoryDialog> createState() =>
      _ProductStockHistoryDialogState();
}

class _ProductStockHistoryDialogState extends State<ProductStockHistoryDialog> {
  late Future<List<StockMovement>> _movements;
  Future<List<Map<String, dynamic>>>? _layers;
  bool _costCorrected = false;

  bool get _serverCostCorrectionEnabled =>
      BackendApiConfig.productReadMode == ProductReadMode.server &&
      BackendApiConfig.productWriteMode == ProductWriteMode.server;

  bool get _serverFifoLayersEnabled => BackendApiConfig.serverAuthEnabled;

  bool get _canCorrectCost =>
      _serverCostCorrectionEnabled &&
      PermissionGuard.canAdjustStock(getIt<UserCubit>().currentUser);

  @override
  void initState() {
    super.initState();
    _movements = _loadMovements();
    if (_serverFifoLayersEnabled) {
      _layers = _loadLayers();
    }
  }

  Future<List<StockMovement>> _loadMovements() async {
    if (BackendApiConfig.productReadMode == ProductReadMode.server) {
      final result = await getIt<ProductApiRepository>()
          .getProductStockMovements(widget.productId);
      return result.fold(
        (failure) => throw StateError(failure.message),
        (rows) => rows,
      );
    }
    return getIt<StockMovementRepository>()
        .getProductMovements(widget.productId);
  }

  Future<List<Map<String, dynamic>>> _loadLayers() async {
    final result = await getIt<ProductApiRepository>()
        .getProductFifoLayers(widget.productId);
    return result.fold(
      (failure) => throw StateError(failure.message),
      (rows) => rows,
    );
  }

  Future<void> _correctLayer(Map<String, dynamic> layer) async {
    final corrected = await showDialog<bool>(
      context: context,
      builder: (_) => _FifoCostCorrectionDialog(
        product: widget.product,
        productId: widget.productId,
        layer: layer,
      ),
    );
    if (!mounted || corrected != true) return;
    setState(() {
      _costCorrected = true;
      _movements = _loadMovements();
      _layers = _loadLayers();
    });
  }

  Widget _buildFifoLayers(bool canCorrect) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Text(
            'FIFO Cost Layers',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
        ),
        SizedBox(
          height: 180,
          child: FutureBuilder<List<Map<String, dynamic>>>(
            future: _layers,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snapshot.hasError) {
                return Center(child: Text(snapshot.error.toString()));
              }
              final layers = snapshot.data ?? const [];
              if (layers.isEmpty) {
                return const Center(child: Text('No remaining FIFO layers.'));
              }
              return ListView.separated(
                itemCount: layers.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final layer = layers[index];
                  final quantity =
                      (layer['remaining_quantity'] as num).toDouble();
                  final unitCost =
                      (layer['current_unit_cost'] as num).toDouble();
                  final totalValue = quantity * unitCost;
                  final reference =
                      layer['acquisition_reference']?.toString() ?? '-';
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(reference),
                    subtitle: Text(
                      'Quantity: ${quantity.toStringAsFixed(3)} '
                      '${widget.product.baseUnit}  |  '
                      'Unit Cost: ${unitCost.toStringAsFixed(2)} DA  |  '
                      'Total: ${totalValue.toStringAsFixed(2)} DA',
                    ),
                    trailing: canCorrect
                        ? TextButton(
                            onPressed: () => _correctLayer(layer),
                            child: const Text('Correct Cost'),
                          )
                        : null,
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final showLayers = _serverFifoLayersEnabled;
    final canCorrect = _canCorrectCost;
    return AlertDialog(
      title: Text('${l10n.stockAdjustmentHistory}: ${widget.product.name}'),
      content: SizedBox(
        width: 680,
        height: 500,
        child: Column(
          children: [
            if (showLayers) ...[
              _buildFifoLayers(canCorrect),
              const Divider(height: 1),
              const SizedBox(height: 8),
            ],
            Expanded(
              child: FutureBuilder<List<StockMovement>>(
                future: _movements,
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (snapshot.hasError) {
                    return Center(child: Text(snapshot.error.toString()));
                  }
                  final movements = snapshot.data ?? const [];
                  if (movements.isEmpty) {
                    return Center(child: Text(l10n.stockAdjustmentNoHistory));
                  }
                  return ListView.separated(
                    itemCount: movements.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, index) => _MovementTile(
                      movement: movements[index],
                      baseUnit: widget.product.baseUnit,
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(_costCorrected),
          child: Text(MaterialLocalizations.of(context).closeButtonLabel),
        ),
      ],
    );
  }
}

class _MovementTile extends StatelessWidget {
  final StockMovement movement;
  final String baseUnit;

  const _MovementTile({
    required this.movement,
    required this.baseUnit,
  });

  @override
  Widget build(BuildContext context) {
    final reference = movement.sourceDescription ??
        movement.referenceId ??
        movement.referenceType ??
        '-';
    final isCorrection = movement.movementType == 'cost_correction';
    final subtitle = isCorrection
        ? '${movement.createdAt.toLocal()}  |  $reference\n'
            'Quantity: ${_number(movement.correctionQuantity)} $baseUnit\n'
            'Old Cost: ${_money(movement.oldUnitCost)} DA  '
            'New Cost: ${_money(movement.newUnitCost)} DA\n'
            'Difference: ${_money(movement.valueDifference)} DA\n'
            'Reason: ${movement.notes ?? '-'}\n'
            'User: ${movement.correctionUser ?? movement.userId ?? '-'}'
        : '${movement.createdAt.toLocal()}  |  $reference'
            '${movement.notes == null || movement.notes!.isEmpty ? '' : '\n${movement.notes}'}';
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(_movementLabel(movement.movementType)),
      subtitle: Text(subtitle),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!isCorrection)
            Text(
              movement.quantityChange > 0
                  ? '+${movement.quantityChange}'
                  : '${movement.quantityChange}',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          Text('After: ${movement.runningStock}'),
        ],
      ),
    );
  }

  String _movementLabel(String type) => switch (type) {
        'stock_adjustment' => 'Stock Adjustment',
        'opening_stock' => 'Opening Stock',
        'customer_return' => 'Customer Return',
        'supplier_return' => 'Supplier Return',
        'purchase' => 'Purchase',
        'sale' => 'Sale',
        'cost_correction' => 'Cost Correction',
        _ => type,
      };

  String _money(double? value) => value?.toStringAsFixed(2) ?? '-';

  String _number(double? value) =>
      value == null ? '-' : value.toStringAsFixed(3);
}

class _FifoCostCorrectionDialog extends StatefulWidget {
  final Product product;
  final String productId;
  final Map<String, dynamic> layer;

  const _FifoCostCorrectionDialog({
    required this.product,
    required this.productId,
    required this.layer,
  });

  @override
  State<_FifoCostCorrectionDialog> createState() =>
      _FifoCostCorrectionDialogState();
}

class _FifoCostCorrectionDialogState extends State<_FifoCostCorrectionDialog> {
  final _costController = TextEditingController();
  bool _posting = false;

  double get _currentCost =>
      (widget.layer['current_unit_cost'] as num).toDouble();

  double get _available =>
      (widget.layer['remaining_quantity'] as num).toDouble();

  @override
  void dispose() {
    _costController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final newCost = double.tryParse(_costController.text.trim());
    if (newCost == null || !newCost.isFinite || newCost < 0) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text(
              'Enter a non-negative cost.',
            ),
          ),
        );
      return;
    }
    setState(() => _posting = true);
    final result =
        await getIt<ProductApiRepository>().correctProductFifoLayerCost(
      productId: widget.productId,
      layerId: widget.layer['layer_id'] as String,
      newUnitCost: newCost,
      idempotencyKey: const Uuid().v4(),
    );
    if (!mounted) return;
    result.fold(
      (failure) {
        setState(() => _posting = false);
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(failure.message)));
      },
      (_) => Navigator.of(context).pop(true),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Correct FIFO Cost: ${widget.product.name}'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Current Cost: ${_currentCost.toStringAsFixed(2)} DA/'
                '${widget.product.baseUnit}',
              ),
              Text(
                'Remaining Quantity: ${_available.toStringAsFixed(3)} '
                '${widget.product.baseUnit}',
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _costController,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'New Cost (DA)'),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _posting ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _posting ? null : _submit,
          child: _posting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Apply Correction'),
        ),
      ],
    );
  }
}
