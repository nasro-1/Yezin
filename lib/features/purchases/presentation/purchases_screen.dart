import 'package:flutter/material.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/di/dependency_injection.dart';
import '../../../core/data/services/persistence_initializer.dart';
import '../../../core/presentation/widgets/transaction_status_panel.dart';
import '../../../core/presentation/widgets/searchable_selection_dialog.dart';
import '../../auth/presentation/cubit/user_cubit.dart';
import '../../products/data/models/product_model.dart';
import '../../products/data/models/selling_unit_model.dart';
import '../../products/domain/product_catalog_service.dart';
import '../../products/presentation/cubit/product_cubit.dart';
import '../../suppliers/data/models/supplier_model.dart';
import '../../suppliers/data/repository/supplier_repository_impl.dart';
import '../data/models/purchase_model.dart';
import '../data/repository/purchase_repository_impl.dart';

int _purchaseDraftSequence = 0;

class PurchaseDraftLifecycle {
  String purchaseId = '';
  bool isCompleted = false;
  String? completedReference;
  double? completedTotal;

  void reset() {
    purchaseId =
        '${DateTime.now().microsecondsSinceEpoch}-${++_purchaseDraftSequence}';
    isCompleted = false;
    completedReference = null;
    completedTotal = null;
  }

  void complete({required String reference, required double total}) {
    isCompleted = true;
    completedReference = reference;
    completedTotal = total;
  }
}

class PurchasesScreen extends StatefulWidget {
  const PurchasesScreen({super.key, required this.repository});
  final PurchaseRepository repository;

  @override
  State<PurchasesScreen> createState() => _PurchasesScreenState();
}

class _PurchasesScreenState extends State<PurchasesScreen> {
  Supplier? _supplier;
  final _reference = TextEditingController();
  final _notes = TextEditingController();
  final List<PurchaseLine> _lines = [];
  bool _saving = false;
  TransactionStatus _status = TransactionStatus.ready;
  String? _statusMessage;
  final _draft = PurchaseDraftLifecycle();

  double get _total => _lines.fold(0, (sum, line) => sum + line.lineTotal);

  @override
  void initState() {
    super.initState();
    _startNewPurchase();
  }

  void _startNewPurchase() {
    _draft.reset();
    _reference.text = 'PUR-${_draft.purchaseId}';
    _notes.clear();
    _lines.clear();
    _supplier = null;
    _saving = false;
    _status = TransactionStatus.ready;
    _statusMessage = null;
  }

  void _showMessage(String message, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor: error ? AppColors.errorColor : AppColors.successColor,
    ));
  }

  void _viewPostedPurchase() {
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Posted purchase'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _ReadOnlyValue(
                label: 'Reference',
                value: _draft.completedReference ?? _reference.text),
            _ReadOnlyValue(
              label: 'Purchase total',
              value: '${(_draft.completedTotal ?? 0).toStringAsFixed(2)} DA',
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _selectSupplier() async {
    final result = await getIt<SupplierRepository>().getAllSuppliers();
    if (!mounted) return;
    result.fold(
      (failure) => _showMessage(failure.message, error: true),
      (suppliers) async {
        final selected = await showSearchableSelectionDialog<Supplier>(
          context: context,
          title: 'Select supplier',
          searchHint: 'Search supplier...',
          items: suppliers,
          filter: (item, query) => [
            item.name,
            item.code,
            item.phone,
          ].any((value) => value.toLowerCase().contains(query)),
          itemBuilder: (_, item) => ListTile(
            leading: const Icon(Icons.business_outlined),
            title: Text(item.name),
            subtitle: Text('${item.code} · ${item.phone}'),
          ),
          emptyMessage: 'No suppliers available.',
          noResultsMessage: 'No suppliers found.',
        );
        if (selected != null && mounted) setState(() => _supplier = selected);
      },
    );
  }

  Future<void> _addLine() async {
    final products = getIt<ProductCubit>().allProducts;
    if (products.isEmpty) {
      _showMessage('No products are available to receive.', error: true);
      return;
    }
    final product = await showSearchableSelectionDialog<Product>(
      context: context,
      title: 'Add product to purchase',
      searchHint: 'Search product...',
      items: products,
      filter: (item, query) => [
        item.name,
        item.barcode,
        item.id,
      ].any((value) => value.toLowerCase().contains(query)),
      itemBuilder: (_, item) => ListTile(
        leading: const Icon(Icons.inventory_2_outlined),
        title: Text(item.name),
        subtitle:
            Text('Code: ${item.barcode} · Current stock: ${item.quantity}'),
      ),
      emptyMessage: 'No products available.',
      noResultsMessage: 'No products found.',
    );
    if (!mounted || product == null) return;

    final formKey = GlobalKey<FormState>();
    final sellingUnits = product.productType == ProductType.packaged
        ? await SellingUnitRepository(
            PersistenceInitializer.persistenceManager!.sqliteManager,
          ).listByProduct(product.id)
        : const <SellingUnit>[];
    final result = await showDialog<_ReceiveProductResult>(
      context: context,
      builder: (_) => _ReceiveProductDialog(
        formKey: formKey,
        product: product,
        sellingUnits: sellingUnits,
      ),
    );
    if (result == null) return;

    final candidate = PurchaseLine(
      productId: product.id,
      productName: product.name,
      productBarcode: product.barcode,
      quantity: result.quantity,
      unitCost: result.unitCost,
      currentStock: product.quantity,
      sellingUnitId: result.sellingUnit?.id,
      sellingUnitName: result.sellingUnit?.name,
      conversionFactor: result.sellingUnit?.conversionToBase,
      baseQuantity: result.baseQuantity,
    );
    if (_lines.any((line) => line.identityKey == candidate.identityKey)) {
      _showMessage(
        product.productType == ProductType.packaged
            ? 'This product and purchase unit are already in the purchase.'
            : 'This product is already in the purchase.',
        error: true,
      );
      return;
    }
    setState(() => _lines.add(candidate));
  }

  Future<void> _save() async {
    if (_saving) return;
    if (_draft.isCompleted) {
      _showMessage('This purchase has already been posted.', error: true);
      return;
    }
    if (_supplier == null) {
      setState(() {
        _status = TransactionStatus.error;
        _statusMessage = 'Please select a supplier.';
      });
      _showMessage('Select a supplier before saving.', error: true);
      return;
    }
    if (_lines.isEmpty) {
      setState(() {
        _status = TransactionStatus.error;
        _statusMessage = 'Add at least one product before posting.';
      });
      _showMessage('Add at least one product.', error: true);
      return;
    }
    setState(() {
      _saving = true;
      _status = TransactionStatus.processing;
      _statusMessage = 'Posting purchase...';
    });
    final result = await widget.repository.createPurchase(Purchase(
      id: _draft.purchaseId,
      referenceNumber: _reference.text.trim(),
      supplierId: _supplier!.id,
      purchaseDate: DateTime.now(),
      lines: List.of(_lines),
      notes: _notes.text.trim(),
      createdBy: getIt<UserCubit>().currentUser.username,
    ));
    if (!mounted) return;
    setState(() => _saving = false);
    result.fold(
      (_) {
        setState(() {
          _status = TransactionStatus.error;
          _statusMessage =
              'Unable to post purchase. No changes were saved. Please try again.';
        });
        _showMessage('Unable to post purchase. Please try again.', error: true);
      },
      (_) {
        final postedTotal = _total;
        setState(() {
          _lines.clear();
          _draft.complete(
            reference: _reference.text.trim(),
            total: postedTotal,
          );
          _status = TransactionStatus.completed;
          _statusMessage = 'Purchase posted successfully.';
        });
        _showMessage('Purchase posted successfully.');
      },
    );
  }

  @override
  void dispose() {
    _reference.dispose();
    _notes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_draft.isCompleted) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: _CompletedPurchasePanel(
          reference: _draft.completedReference ?? _reference.text,
          total: _draft.completedTotal ?? 0,
          onViewPurchase: _viewPostedPurchase,
          onNewPurchase: () => setState(_startNewPurchase),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Spacer(),
              FilledButton.icon(
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.check),
                label: const Text('Post purchase'),
              ),
            ],
          ),
          TransactionStatusPanel(
            status: _status,
            message: _statusMessage ?? '',
          ),
          const SizedBox(height: 20),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Wrap(
                spacing: 20,
                runSpacing: 12,
                children: [
                  SizedBox(width: 260, child: _field('Reference', _reference)),
                  SizedBox(width: 260, child: _field('Notes', _notes)),
                  SizedBox(
                    width: 360,
                    child: _supplier == null
                        ? OutlinedButton.icon(
                            onPressed: _selectSupplier,
                            icon: const Icon(Icons.business_outlined),
                            label: const Text('Select supplier'),
                          )
                        : ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(Icons.business,
                                color: AppColors.primaryColor),
                            title: Text(_supplier!.name,
                                style: const TextStyle(
                                    fontWeight: FontWeight.bold)),
                            subtitle: Text(
                                '${_supplier!.code}  |  ${_supplier!.phone}'),
                            trailing: TextButton(
                                onPressed: _selectSupplier,
                                child: const Text('Change')),
                          ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              const Text('Products received',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              const Spacer(),
              OutlinedButton.icon(
                  onPressed: _addLine,
                  icon: const Icon(Icons.add),
                  label: const Text('Add product')),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: ListView(
              children: [
                if (_lines.isEmpty)
                  const _EmptyPanel(
                    icon: Icons.add_shopping_cart_outlined,
                    title: 'No products added',
                    message:
                        'Add products to preview the stock increase before posting.',
                  )
                else
                  ..._lines.map((line) => _PurchaseLineCard(
                        line: line,
                        onRemove: () => setState(() => _lines.remove(line)),
                      )),
                const SizedBox(height: 12),
                _SummaryCard(total: _total),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _field(String label, TextEditingController controller) => TextField(
        controller: controller,
        decoration: InputDecoration(
            labelText: label, border: const OutlineInputBorder()),
      );
}

class _CompletedPurchasePanel extends StatelessWidget {
  const _CompletedPurchasePanel({
    required this.reference,
    required this.total,
    required this.onViewPurchase,
    required this.onNewPurchase,
  });

  final String reference;
  final double total;
  final VoidCallback onViewPurchase;
  final VoidCallback onNewPurchase;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Icon(Icons.check_circle,
                color: AppColors.successColor, size: 52),
            const SizedBox(height: 12),
            const Text(
              'Purchase posted successfully',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 24),
            _ReadOnlyValue(label: 'Reference', value: reference),
            _ReadOnlyValue(
              label: 'Purchase total',
              value: '${total.toStringAsFixed(2)} DA',
            ),
            const SizedBox(height: 24),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 12,
              runSpacing: 12,
              children: [
                OutlinedButton.icon(
                  onPressed: onViewPurchase,
                  icon: const Icon(Icons.history),
                  label: const Text('View Purchase'),
                ),
                FilledButton.icon(
                  onPressed: onNewPurchase,
                  icon: const Icon(Icons.add),
                  label: const Text('New Purchase'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ReceiveProductResult {
  const _ReceiveProductResult({
    required this.quantity,
    required this.unitCost,
    required this.baseQuantity,
    this.sellingUnit,
  });
  final double quantity;
  final double unitCost;
  final double baseQuantity;
  final SellingUnit? sellingUnit;
}

class _ReceiveProductDialog extends StatefulWidget {
  const _ReceiveProductDialog({
    required this.formKey,
    required this.product,
    required this.sellingUnits,
  });

  final GlobalKey<FormState> formKey;
  final dynamic product;
  final List<SellingUnit> sellingUnits;

  @override
  State<_ReceiveProductDialog> createState() => _ReceiveProductDialogState();
}

class _ReceiveProductDialogState extends State<_ReceiveProductDialog> {
  late final TextEditingController _quantityController;
  late final TextEditingController _costController;
  SellingUnit? _selectedUnit;

  @override
  void initState() {
    super.initState();
    _quantityController = TextEditingController();
    _costController = TextEditingController();
    _selectedUnit =
        widget.sellingUnits.isEmpty ? null : widget.sellingUnits.first;
  }

  double? get _quantity => double.tryParse(_quantityController.text.trim());
  double? get _cost => double.tryParse(_costController.text.trim());
  bool get _isPackaged => widget.product.productType == ProductType.packaged;
  bool get _isWeighted => widget.product.productType == ProductType.weighted;
  double get _conversion => _selectedUnit?.conversionToBase ?? 1;
  double get _baseQuantity => (_quantity ?? 0) * _conversion;

  @override
  void dispose() {
    _quantityController.dispose();
    _costController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Receive ${widget.product.name}'),
      content: Form(
        key: widget.formKey,
        child: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _ReadOnlyValue(
                  label: 'Current stock',
                  value:
                      '${widget.product.quantity} ${_isPackaged ? 'pieces' : widget.product.baseUnit}'),
              if (_isPackaged) ...[
                const Text('Purchase Unit',
                    style: TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                DropdownButtonFormField<SellingUnit>(
                  value: _selectedUnit,
                  items: widget.sellingUnits
                      .map((unit) => DropdownMenuItem(
                            value: unit,
                            child: Text(
                                '${unit.name}  •  Contains ${unit.conversionToBase.toInt()} pieces'),
                          ))
                      .toList(),
                  onChanged: (unit) => setState(() => _selectedUnit = unit),
                  validator: (_) =>
                      _selectedUnit == null ? 'Select a purchase unit' : null,
                ),
                const SizedBox(height: 12),
              ] else if (_isWeighted) ...[
                _ReadOnlyValue(label: 'Unit', value: widget.product.baseUnit),
              ],
              TextFormField(
                controller: _quantityController,
                autofocus: true,
                keyboardType: _isWeighted
                    ? const TextInputType.numberWithOptions(decimal: true)
                    : TextInputType.number,
                decoration: InputDecoration(
                    labelText: 'Quantity received',
                    prefixText: '+ ',
                    border: OutlineInputBorder()),
                validator: (value) {
                  final parsed = double.tryParse(value?.trim() ?? '');
                  if (parsed == null ||
                      parsed <= 0 ||
                      (!_isWeighted && parsed != parsed.truncateToDouble()))
                    return 'Enter a quantity greater than zero';
                  return null;
                },
                onChanged: (_) => setState(() {}),
              ),
              if (_isPackaged) ...[
                const SizedBox(height: 8),
                _ReadOnlyValue(
                  label: 'Conversion',
                  value:
                      '${_quantity == null ? 0 : _quantity} ${_selectedUnit?.name ?? 'unit'} = ${_baseQuantity.toStringAsFixed(0)} pieces',
                ),
              ],
              const SizedBox(height: 12),
              TextFormField(
                controller: _costController,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                    labelText: _isPackaged
                        ? 'Purchase Cost / ${_selectedUnit?.name ?? 'unit'}'
                        : _isWeighted
                            ? 'Purchase Cost / ${widget.product.baseUnit}'
                            : 'Unit purchase cost',
                    suffixText: 'DA',
                    border: OutlineInputBorder()),
                validator: (value) {
                  final parsed = double.tryParse(value?.trim() ?? '');
                  if (parsed == null || parsed < 0)
                    return 'Enter a valid non-negative cost';
                  return null;
                },
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 16),
              _ReadOnlyValue(
                label: 'New stock',
                value: _quantity == null
                    ? '-'
                    : '${widget.product.quantity + (_isPackaged ? _baseQuantity : _quantity!)} ${_isPackaged ? 'pieces' : widget.product.baseUnit}',
              ),
              _ReadOnlyValue(
                label: 'Line total',
                value: _quantity == null || _cost == null
                    ? '-'
                    : '${(_quantity! * _cost!).toStringAsFixed(2)} DA',
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            if (widget.formKey.currentState!.validate())
              Navigator.pop(
                context,
                _ReceiveProductResult(
                  quantity: _quantity!,
                  unitCost: _cost!,
                  baseQuantity: _isPackaged ? _baseQuantity : _quantity!,
                  sellingUnit: _selectedUnit,
                ),
              );
          },
          child: const Text('Add to purchase'),
        ),
      ],
    );
  }
}

class _ReadOnlyValue extends StatelessWidget {
  const _ReadOnlyValue({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Row(
          children: [
            Expanded(
                child: Text(label,
                    style: const TextStyle(color: AppColors.mutedColor))),
            Text(value, style: const TextStyle(fontWeight: FontWeight.w800)),
          ],
        ),
      );
}

class _PurchaseLineCard extends StatelessWidget {
  const _PurchaseLineCard({required this.line, required this.onRemove});
  final PurchaseLine line;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              const Icon(Icons.inventory_2_outlined,
                  color: AppColors.primaryColor, size: 30),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(line.productName,
                        style: const TextStyle(fontWeight: FontWeight.w800)),
                    Text(line.productBarcode,
                        style: const TextStyle(color: AppColors.mutedColor)),
                  ],
                ),
              ),
              _Metric(label: 'Current stock', value: '${line.currentStock}'),
              _Metric(label: 'Receiving', value: '+${line.quantity}'),
              if (line.sellingUnitName != null)
                _Metric(
                  label: 'Purchase unit',
                  value: line.sellingUnitName!,
                ),
              _Metric(label: 'New stock', value: '${line.resultingStock}'),
              _Metric(
                  label: 'Line total',
                  value: '${line.lineTotal.toStringAsFixed(2)} DA'),
              IconButton(
                  onPressed: onRemove,
                  tooltip: 'Remove',
                  icon: const Icon(Icons.delete_outline)),
            ],
          ),
        ),
      );
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(label,
                style:
                    const TextStyle(fontSize: 11, color: AppColors.mutedColor)),
            Text(value, style: const TextStyle(fontWeight: FontWeight.w700)),
          ],
        ),
      );
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.total});
  final double total;

  @override
  Widget build(BuildContext context) => Card(
        color: AppColors.primaryColor,
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Row(
            children: [
              const Expanded(
                  child: Text('Purchase total',
                      style: TextStyle(color: Colors.white, fontSize: 16))),
              Text('${total.toStringAsFixed(2)} DA',
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.w800)),
            ],
          ),
        ),
      );
}

class _EmptyPanel extends StatelessWidget {
  const _EmptyPanel(
      {required this.icon, required this.title, required this.message});
  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(30),
          child: Column(
            children: [
              Icon(icon, size: 40, color: AppColors.mutedColor),
              const SizedBox(height: 8),
              Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Text(message,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: AppColors.mutedColor)),
            ],
          ),
        ),
      );
}
