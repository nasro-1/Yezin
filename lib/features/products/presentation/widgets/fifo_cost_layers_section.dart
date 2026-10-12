import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../../../../core/di/dependency_injection.dart';
import '../../../../core/network/authority_context.dart';
import '../../../../core/security/permission_guard.dart';
import '../../../auth/presentation/cubit/user_cubit.dart';
import '../../data/models/product_model.dart';
import '../../data/repository/product_api_repository.dart';

class FifoCostLayerCostEditor extends StatefulWidget {
  final Product product;
  final Map<String, dynamic> layer;
  final VoidCallback onCorrected;
  final AuthorityContext authorityContext;

  const FifoCostLayerCostEditor({
    super.key,
    required this.product,
    required this.layer,
    required this.onCorrected,
    required this.authorityContext,
  });

  @override
  State<FifoCostLayerCostEditor> createState() =>
      _FifoCostLayerCostEditorState();
}

class _FifoCostLayerCostEditorState extends State<FifoCostLayerCostEditor> {
  late final TextEditingController _costController;
  bool _editing = false;
  bool _posting = false;

  bool get _canCorrect =>
      widget.authorityContext.readsFromServer &&
      widget.authorityContext.writesToServer &&
      PermissionGuard.canAdjustStock(getIt<UserCubit>().currentUser);

  double get _currentCost =>
      (widget.layer['current_unit_cost'] as num).toDouble();

  double? get _previousCost =>
      (widget.layer['correction_old_unit_cost'] as num?)?.toDouble();

  DateTime? get _correctionDate {
    final value = widget.layer['correction_created_at'];
    return value == null ? null : DateTime.tryParse(value.toString());
  }

  @override
  void initState() {
    super.initState();
    _costController =
        TextEditingController(text: _currentCost.toStringAsFixed(2));
  }

  @override
  void didUpdateWidget(covariant FifoCostLayerCostEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.layer['current_unit_cost'] !=
        widget.layer['current_unit_cost']) {
      _costController.text = _currentCost.toStringAsFixed(2);
      _editing = false;
    }
  }

  @override
  void dispose() {
    _costController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final newCost = double.tryParse(_costController.text.trim());
    if (newCost == null || !newCost.isFinite || newCost < 0) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(content: Text('Enter a valid non-negative cost.')),
        );
      return;
    }
    setState(() => _posting = true);
    final result =
        await getIt<ProductApiRepository>().correctProductFifoLayerCost(
      productId: widget.product.id,
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
      (_) {
        setState(() {
          _posting = false;
          _editing = false;
        });
        widget.onCorrected();
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final quantity = (widget.layer['remaining_quantity'] as num).toDouble();
    final total = quantity * _currentCost;
    final previousCost = _previousCost;
    final correctionDate = _correctionDate;
    if (!_editing) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Text(
                  'Quantity: ${quantity.toStringAsFixed(3)} '
                  '${widget.product.baseUnit}\n'
                  'Cost: ${_currentCost.toStringAsFixed(2)} '
                  'DA/${widget.product.baseUnit}\n'
                  'Total: ${total.toStringAsFixed(2)} DA',
                ),
              ),
              if (_canCorrect)
                IconButton(
                  tooltip: 'Edit cost',
                  visualDensity: VisualDensity.compact,
                  onPressed: () {
                    _costController.text = _currentCost.toStringAsFixed(2);
                    setState(() => _editing = true);
                  },
                  icon: const Icon(Icons.edit_outlined, size: 18),
                ),
            ],
          ),
          if (previousCost != null && correctionDate != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Cost corrected: ${previousCost.toStringAsFixed(2)} '
                '→ ${_currentCost.toStringAsFixed(2)} '
                'DA/${widget.product.baseUnit}\n'
                'Date: ${_formatCorrectionDate(correctionDate)}',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.primary,
                  fontSize: 12,
                ),
              ),
            ),
        ],
      );
    }
    return Row(
      children: [
        Expanded(
          child: TextField(
            autofocus: true,
            controller: _costController,
            enabled: !_posting,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              isDense: true,
              labelText: 'Cost',
              suffixText: 'DA/${widget.product.baseUnit}',
            ),
          ),
        ),
        IconButton(
          tooltip: 'Save',
          onPressed: _posting ? null : _save,
          icon: _posting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.check, color: Colors.green),
        ),
        IconButton(
          tooltip: 'Cancel',
          onPressed: _posting
              ? null
              : () {
                  _costController.text = _currentCost.toStringAsFixed(2);
                  setState(() => _editing = false);
                },
          icon: const Icon(Icons.close),
        ),
      ],
    );
  }

  String _formatCorrectionDate(DateTime date) {
    final local = date.toLocal();
    String twoDigits(int value) => value.toString().padLeft(2, '0');
    return '${twoDigits(local.day)}/${twoDigits(local.month)}/'
        '${local.year} ${twoDigits(local.hour)}:${twoDigits(local.minute)}';
  }
}
