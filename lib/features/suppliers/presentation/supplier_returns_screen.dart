import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../../../core/di/dependency_injection.dart';
import '../../../core/network/authority_context.dart';
import '../../../core/presentation/widgets/transaction_status_panel.dart';
import '../../../core/presentation/widgets/searchable_selection_dialog.dart';
import '../../../l10n/app_localizations.dart';
import '../../auth/presentation/cubit/user_cubit.dart';
import '../../products/presentation/cubit/product_cubit.dart';
import '../../products/presentation/cubit/product_states.dart';
import '../../purchases/data/repository/purchase_repository_impl.dart';
import '../../products/data/repository/product_api_repository.dart';
import '../data/models/supplier_model.dart';
import '../data/models/supplier_return_model.dart';
import '../data/repository/supplier_repository_impl.dart';
import '../data/repository/supplier_return_repository_impl.dart';

class SupplierReturnsScreen extends StatefulWidget {
  const SupplierReturnsScreen({super.key, required this.repository});

  final SupplierReturnRepository repository;

  @override
  State<SupplierReturnsScreen> createState() => _SupplierReturnsScreenState();
}

class _SupplierReturnsScreenState extends State<SupplierReturnsScreen> {
  Supplier? _supplier;
  String? _purchaseId;
  List<Map<String, dynamic>> _purchases = [];
  List<Map<String, dynamic>> _items = [];
  final Map<String, TextEditingController> _quantities = {};
  final _notes = TextEditingController();
  bool _saving = false;
  TransactionStatus _status = TransactionStatus.ready;
  String? _statusMessage;
  String? _completedReference;
  String? _pendingReference;
  DateTime? _pendingReturnDate;
  String _returnId = const Uuid().v4();
  double? _completedSupplierBalance;
  String? _refreshWarning;
  bool _completed = false;
  double _completedStockRemoved = 0;
  double _completedReturnValue = 0;

  void _startNewReturn() {
    for (final controller in _quantities.values) {
      controller.dispose();
    }
    setState(() {
      _completed = false;
      _completedReference = null;
      _pendingReference = null;
      _pendingReturnDate = null;
      _returnId = const Uuid().v4();
      _completedSupplierBalance = null;
      _refreshWarning = null;
      _status = TransactionStatus.ready;
      _statusMessage = null;
      _supplier = null;
      _purchases = [];
      _purchaseId = null;
      _items = [];
      _quantities.clear();
      _completedStockRemoved = 0;
      _completedReturnValue = 0;
      _notes.clear();
    });
  }

  @override
  void initState() {
    super.initState();
  }

  Future<void> _selectSupplier() async {
    final result = await getIt<SupplierRepository>().getAllSuppliers();
    if (!mounted) return;
    final suppliers = result.fold(
      (failure) {
        _showReadError(failure.message);
        return null;
      },
      (rows) => rows,
    );
    if (suppliers == null) return;
    final selected = await showSearchableSelectionDialog<Supplier>(
      context: context,
      title: AppLocalizations.of(context).selectSupplier,
      searchHint: 'Search supplier...',
      items: suppliers,
      filter: (item, query) => [
        item.name,
        item.code,
        item.phone,
      ].any((value) => value.toLowerCase().contains(query)),
      itemBuilder: (_, item) => ListTile(
        leading: const CircleAvatar(child: Icon(Icons.business_outlined)),
        title: Text(item.name),
        subtitle: Text('${item.code} · ${item.phone}'),
      ),
      emptyMessage: 'No suppliers available.',
      noResultsMessage: 'No suppliers found.',
    );
    if (selected == null) return;

    final List<Map<String, dynamic>> purchases;
    if (getIt<AuthorityContext>().readsFromServer) {
      final purchaseResult = await getIt<PurchaseRepository>().getPurchases();
      if (!mounted) return;
      final serverPurchases = purchaseResult.fold(
        (failure) {
          _showReadError(failure.message);
          return null;
        },
        (rows) => rows,
      );
      if (serverPurchases == null) return;
      purchases = await Future.wait(
        serverPurchases
            .where((row) => row['supplier_id']?.toString() == selected.id)
            .map(_mapServerPurchase),
      );
    } else {
      final purchaseResult =
          await widget.repository.getPurchasesForSupplier(selected.id);
      if (!mounted) return;
      final localPurchases = purchaseResult.fold(
        (failure) {
          _showReadError(failure.message);
          return null;
        },
        (rows) => rows,
      );
      if (localPurchases == null) return;
      purchases = localPurchases;
    }
    if (!mounted) return;
    setState(() {
      _supplier = selected;
      _purchases = purchases;
      _purchaseId = null;
      _items = [];
    });
  }

  Future<void> _selectPurchase(String id) async {
    List<Map<String, dynamic>> rows;
    if (getIt<AuthorityContext>().readsFromServer) {
      final purchase =
          _purchases.where((row) => row['id']?.toString() == id).firstOrNull;
      final items = purchase?['items'];
      if (items is! List) {
        _showReadError('The selected server purchase has no item data.');
        return;
      }
      rows = items
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList(growable: false);
    } else {
      final result = await widget.repository.getPurchaseItems(id);
      if (!mounted) return;
      final localItems = result.fold(
        (failure) {
          _showReadError(failure.message);
          return null;
        },
        (items) => items,
      );
      if (localItems == null) return;
      rows = localItems;
    }
    if (!mounted) return;
    for (final controller in _quantities.values) {
      controller.dispose();
    }
    setState(() {
      _purchaseId = id;
      _items = rows;
      _quantities
        ..clear()
        ..addEntries(rows.map((row) =>
            MapEntry(row['id'] as String, TextEditingController(text: '0'))));
    });
  }

  Future<Map<String, dynamic>> _mapServerPurchase(
      Map<String, dynamic> purchase) async {
    final purchaseId = purchase['id']?.toString() ?? '';
    final rawItems = purchase['items'];
    final items = <Map<String, dynamic>>[];
    if (rawItems is List) {
      for (var index = 0; index < rawItems.length; index++) {
        final value = rawItems[index];
        if (value is! Map) continue;
        final item = Map<String, dynamic>.from(value);
        final productId = item['product_id']?.toString() ?? '';
        var productName = item['product_name']?.toString().trim() ?? '';
        if (productId.isNotEmpty &&
            (productName.isEmpty || productName == productId)) {
          final result =
              await getIt<ProductApiRepository>().getProduct(productId);
          productName = result.fold(
            (_) => productId,
            (product) =>
                product.name.trim().isEmpty ? productId : product.name.trim(),
          );
        }
        final quantity = _number(item['selling_quantity'] ?? item['quantity']);
        items.add({
          ...item,
          'id': item['id']?.toString() ?? '${purchaseId}_$index',
          'product_id': productId,
          'product_name': productName.isEmpty ? productId : productName,
          'quantity': quantity,
          'selling_quantity': quantity,
          'unit_cost': _number(item['unit_cost']),
          'conversion_factor_snapshot': _number(
            item['conversion_factor_snapshot'] ?? item['conversion_factor'],
          ),
          'selling_unit_name_snapshot':
              item['selling_unit_name_snapshot'] ?? item['selling_unit_name'],
          'base_unit_snapshot': item['base_unit_snapshot'] ?? item['base_unit'],
        });
      }
    }
    return {
      ...purchase,
      'reference_number':
          purchase['reference'] ?? purchase['reference_number'] ?? '—',
      'total': _number(purchase['total']),
      'items': items,
    };
  }

  void _showReadError(String message) {
    if (!mounted) return;
    setState(() {
      _status = TransactionStatus.error;
      _statusMessage = message;
    });
  }

  double _number(Object? value) => value is num
      ? value.toDouble()
      : double.tryParse(value?.toString() ?? '') ?? 0;

  String _purchaseItemSummary(Map<String, dynamic> purchase) {
    final items = purchase['items'];
    if (items is! List || items.isEmpty) return '';
    return items.whereType<Map>().map((item) {
      final productName =
          item['product_name']?.toString() ?? item['product_id']?.toString();
      final quantity = _number(item['selling_quantity'] ?? item['quantity']);
      final unit =
          (item['selling_unit_name_snapshot'] ?? item['selling_unit_name'])
                  ?.toString() ??
              '';
      return [
        productName,
        '${_formatQuantity(quantity)}${unit.isEmpty ? '' : ' $unit'}',
      ].where((value) => value != null && value.isNotEmpty).join(' · ');
    }).join('\n');
  }

  String _formatQuantity(double value) => value == value.roundToDouble()
      ? value.toStringAsFixed(0)
      : value.toString();

  Future<void> _save() async {
    if (_saving) return;
    if (_supplier == null || _purchaseId == null) {
      setState(() {
        _status = TransactionStatus.error;
        _statusMessage = 'Select a supplier and source purchase.';
      });
      return;
    }
    final lines = _items
        .map((row) => SupplierReturnLine(
              purchaseItemId: row['id'] as String,
              productId: row['product_id'] as String,
              quantity: double.tryParse(
                      _quantities[row['id'] as String]!.text.trim()) ??
                  0,
            ))
        .where((line) => line.quantity > 0)
        .toList();
    if (lines.isEmpty) {
      setState(() {
        _status = TransactionStatus.error;
        _statusMessage = 'Enter at least one return quantity.';
      });
      return;
    }
    final reference =
        _pendingReference ??= 'SR-${DateTime.now().microsecondsSinceEpoch}';
    final returnDate = _pendingReturnDate ??= DateTime.now();
    final stockRemoved = _stockQuantity;
    final returnValue = _returnValue;
    setState(() {
      _saving = true;
      _status = TransactionStatus.processing;
      _statusMessage = 'Posting return transaction...';
    });
    final result = await widget.repository.createReturn(SupplierReturn(
      id: _returnId,
      reference: reference,
      supplierId: _supplier!.id,
      purchaseId: _purchaseId!,
      returnDate: returnDate,
      lines: lines,
      notes: _notes.text.trim().isEmpty ? null : _notes.text.trim(),
      createdBy: getIt<UserCubit>().currentUser.username,
    ));
    if (!mounted) return;
    final creationFailure = result.fold((failure) => failure, (_) => null);
    if (creationFailure != null) {
      setState(() {
        _saving = false;
        _status = TransactionStatus.error;
        _statusMessage = creationFailure.message;
      });
      return;
    }

    var refreshFailed = false;
    double? refreshedBalance;
    if (getIt<AuthorityContext>().readsFromServer) {
      final supplierRepository = getIt<SupplierRepository>();
      final balanceResult =
          await supplierRepository.getSupplierBalance(_supplier!.id);
      balanceResult.fold(
        (_) => refreshFailed = true,
        (balance) => refreshedBalance = balance,
      );
      final ledgerResult =
          await supplierRepository.getSupplierLedger(_supplier!.id);
      ledgerResult.fold(
        (_) => refreshFailed = true,
        (_) {},
      );
      if (getIt.isRegistered<ProductCubit>()) {
        await getIt<ProductCubit>().getAllProducts();
        if (getIt<ProductCubit>().state is ProductErrorState) {
          refreshFailed = true;
        }
      }
    }
    if (!mounted) return;
    setState(() {
      _saving = false;
      _completedReference = reference;
      _completed = true;
      _status = TransactionStatus.completed;
      _statusMessage = 'Return completed successfully.';
      _completedStockRemoved = stockRemoved;
      _completedReturnValue = returnValue;
      _completedSupplierBalance = refreshedBalance;
      _refreshWarning = refreshFailed
          ? 'Return posted, but some displayed stock or supplier history could not be refreshed.'
          : null;
    });
    for (final controller in _quantities.values) {
      controller.clear();
      controller.text = '0';
    }
  }

  @override
  void dispose() {
    for (final controller in _quantities.values) {
      controller.dispose();
    }
    _notes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    if (_completed) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: _ReturnCompletedCard(
          reference: _completedReference ?? '—',
          supplierName: _supplier?.name ?? '—',
          stockRemoved: _completedStockRemoved,
          returnValue: _completedReturnValue,
          supplierBalance: _completedSupplierBalance,
          refreshWarning: _refreshWarning,
          onNewReturn: _startNewReturn,
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.all(20),
      child: ListView(
        children: [
          _StepCard(
            step: '1',
            title: 'SUPPLIER',
            icon: Icons.business_outlined,
            child: Row(
              children: [
                CircleAvatar(
                  backgroundColor: const Color(0xFFE8EEFF),
                  child: Icon(Icons.business_outlined,
                      color: Theme.of(context).colorScheme.primary),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _supplier == null
                      ? const Text('Select a supplier to begin the return.')
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(_supplier!.name,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w700, fontSize: 16)),
                            Text(
                                '${_supplier!.code} · ${_supplier!.phone.isEmpty ? 'No phone' : _supplier!.phone}'),
                          ],
                        ),
                ),
                OutlinedButton.icon(
                  onPressed: _saving ? null : _selectSupplier,
                  icon: Icon(_supplier == null
                      ? Icons.person_add_alt_1_outlined
                      : Icons.swap_horiz),
                  label: Text(_supplier == null
                      ? l10n.selectSupplier
                      : 'Change supplier'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          _StepCard(
            step: '2',
            title: 'SOURCE PURCHASE',
            icon: Icons.receipt_long_outlined,
            child: _supplier == null
                ? const _WorkflowEmpty(
                    icon: Icons.lock_outline,
                    text: 'Select a supplier to choose a source purchase.')
                : Row(
                    children: [
                      const Icon(Icons.receipt_long_outlined),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _purchaseId == null
                            ? const Text('Select a purchase to continue.')
                            : _PurchaseSummary(row: _selectedPurchase),
                      ),
                      OutlinedButton.icon(
                        onPressed: _saving ? null : _showPurchasePicker,
                        icon: const Icon(Icons.search),
                        label: Text(_purchaseId == null
                            ? l10n.selectPurchase
                            : 'Change purchase'),
                      ),
                    ],
                  ),
          ),
          if (_purchaseId != null) ...[
            const SizedBox(height: 14),
            _StepCard(
              step: '3',
              title: 'ITEMS TO RETURN',
              icon: Icons.inventory_2_outlined,
              child: _items.isEmpty
                  ? const _WorkflowEmpty(
                      icon: Icons.inventory_2_outlined,
                      text:
                          'No returnable items are available for this purchase.')
                  : Column(
                      children: [
                        for (final row in _items) ...[
                          _ReturnItemCard(
                            row: row,
                            controller: _quantities[row['id'] as String]!,
                            enabled: !_saving,
                            onChanged: (_) => setState(() {}),
                          ),
                          const SizedBox(height: 10),
                        ],
                      ],
                    ),
            ),
            const SizedBox(height: 14),
            _ReturnSummary(
              items: _returnItemCount,
              stockRemoved: _stockQuantity,
              returnValue: _returnValue,
            ),
          ],
          TransactionStatusPanel(
            status: _status,
            message: _statusMessage ?? '',
          ),
          const SizedBox(height: 14),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: FilledButton.icon(
              onPressed: _saving ||
                      _items.isEmpty ||
                      _returnItemCount == 0 ||
                      _hasInvalidQuantity
                  ? null
                  : _save,
              icon: _saving
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.check),
              label: Text(_saving ? 'Processing Return...' : l10n.saveReturn),
            ),
          ),
        ],
      ),
    );
  }

  Map<String, dynamic>? get _selectedPurchase {
    for (final row in _purchases) {
      if (row['id'] == _purchaseId) return row;
    }
    return null;
  }

  Future<void> _showPurchasePicker() async {
    final selected = await showSearchableSelectionDialog<String>(
      context: context,
      title: 'Select purchase',
      searchHint: 'Search purchase...',
      items: _purchases.map((row) => row['id'] as String).toList(),
      filter: (id, query) {
        final row = _purchases.firstWhere((item) => item['id'] == id);
        return [
          row['reference_number']?.toString() ?? '',
          row['supplier_name']?.toString() ?? '',
          row['supplier_code']?.toString() ?? '',
          row['purchase_date']?.toString() ?? '',
          _purchaseItemSummary(row),
        ].any((value) => value.toLowerCase().contains(query));
      },
      itemBuilder: (_, id) {
        final row = _purchases.firstWhere((item) => item['id'] == id);
        final itemSummary = _purchaseItemSummary(row);
        return ListTile(
          leading: const Icon(Icons.receipt_long_outlined),
          title: Text(row['reference_number']?.toString() ?? '—'),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                  '${row['purchase_date'] ?? '—'} · ${row['status'] ?? 'confirmed'}'),
              if (itemSummary.isNotEmpty) Text(itemSummary),
            ],
          ),
          isThreeLine: itemSummary.isNotEmpty,
          trailing: Text('${_number(row['total']).toStringAsFixed(2)} DA'),
        );
      },
      emptyMessage: 'No purchases available.',
      noResultsMessage: 'No purchases found.',
    );
    if (selected != null) await _selectPurchase(selected);
  }

  double _quantityFor(Map<String, dynamic> row) =>
      double.tryParse(_quantities[row['id'] as String]?.text.trim() ?? '') ?? 0;

  double _conversionFor(Map<String, dynamic> row) =>
      (row['conversion_factor_snapshot'] as num?)?.toDouble() ?? 1;

  double _stockFor(Map<String, dynamic> row) =>
      _quantityFor(row) * _conversionFor(row);

  double _unitCostFor(Map<String, dynamic> row) =>
      (row['unit_cost'] as num?)?.toDouble() ?? 0;

  int get _returnItemCount =>
      _items.where((row) => _quantityFor(row) > 0).length;

  bool get _hasInvalidQuantity => _items.any((row) {
        final quantity = _quantityFor(row);
        final returnable = (row['quantity'] as num?)?.toDouble() ?? 0;
        return quantity < 0 || quantity > returnable;
      });

  double get _stockQuantity =>
      _items.fold(0, (sum, row) => sum + _stockFor(row));

  double get _returnValue =>
      _items.fold(0, (sum, row) => sum + _quantityFor(row) * _unitCostFor(row));
}

class _StepCard extends StatelessWidget {
  const _StepCard({
    required this.step,
    required this.title,
    required this.icon,
    required this.child,
  });

  final String step;
  final String title;
  final IconData icon;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: Colors.grey.shade200),
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 14,
                  backgroundColor: Theme.of(context).colorScheme.primary,
                  child: Text(step,
                      style: const TextStyle(
                          color: Colors.white, fontWeight: FontWeight.w700)),
                ),
                const SizedBox(width: 10),
                Icon(icon,
                    size: 19, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 8),
                Text(title,
                    style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                        letterSpacing: .6)),
              ],
            ),
            const SizedBox(height: 16),
            child,
          ],
        ),
      ),
    );
  }
}

class _WorkflowEmpty extends StatelessWidget {
  const _WorkflowEmpty({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 22, horizontal: 16),
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(icon, color: Colors.grey.shade600),
          const SizedBox(width: 12),
          Expanded(
              child: Text(text, style: TextStyle(color: Colors.grey.shade700))),
        ],
      ),
    );
  }
}

class _PurchaseSummary extends StatelessWidget {
  const _PurchaseSummary({required this.row});

  final Map<String, dynamic>? row;

  @override
  Widget build(BuildContext context) {
    if (row == null) return const Text('Select a purchase to continue.');
    final date = DateTime.tryParse(row!['purchase_date']?.toString() ?? '');
    final items = row!['items'];
    final itemSummary = items is List
        ? items.whereType<Map>().map((item) {
            final name = item['product_name']?.toString() ??
                item['product_id']?.toString() ??
                '';
            final quantity = item['selling_quantity'] ?? item['quantity'];
            final unit = (item['selling_unit_name_snapshot'] ??
                    item['selling_unit_name'])
                ?.toString();
            return [
              name,
              if (quantity != null)
                '${quantity.toString()}${unit == null || unit.isEmpty ? '' : ' $unit'}',
            ].join(' · ');
          }).join('\n')
        : '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(row!['reference_number']?.toString() ?? '—',
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
        const SizedBox(height: 4),
        Text(
            '${date == null ? '—' : MaterialLocalizations.of(context).formatMediumDate(date.toLocal())} · ${row!['status'] ?? 'confirmed'}'),
        if (itemSummary.isNotEmpty) Text(itemSummary),
        if (row!['total'] != null)
          Text('${(row!['total'] as num).toDouble().toStringAsFixed(2)} DA'),
        if (row!['supplier_name'] != null)
          Text(row!['supplier_name'].toString(),
              style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}

class _ReturnItemCard extends StatelessWidget {
  const _ReturnItemCard({
    required this.row,
    required this.controller,
    required this.enabled,
    required this.onChanged,
  });

  final Map<String, dynamic> row;
  final TextEditingController controller;
  final bool enabled;
  final ValueChanged<String> onChanged;

  double get _returnable => (row['quantity'] as num?)?.toDouble() ?? 0;
  double get _conversion =>
      (row['conversion_factor_snapshot'] as num?)?.toDouble() ?? 1;
  String get _unit =>
      row['selling_unit_name_snapshot']?.toString().trim().isNotEmpty == true
          ? row['selling_unit_name_snapshot'].toString()
          : 'Piece';
  String get _baseUnit => row['base_unit_snapshot']?.toString() ?? 'pieces';

  @override
  Widget build(BuildContext context) {
    final value = double.tryParse(controller.text.trim()) ?? 0;
    final cost = (row['unit_cost'] as num?)?.toDouble() ?? 0;
    final isDecimal = _conversion != 1 ||
        row['selling_quantity'] is double ||
        row['quantity'] is double;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(row['product_name']?.toString() ?? '—',
              style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 12),
          Wrap(
            spacing: 24,
            runSpacing: 14,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _ItemMetric(label: 'Purchase unit', value: _unit),
              _ItemMetric(
                  label: 'Returnable',
                  value: '${_formatNumber(_returnable)} $_unit'),
              _ItemMetric(
                  label: 'Unit cost',
                  value: '${cost.toStringAsFixed(2)} DA / $_unit'),
              SizedBox(
                width: 150,
                child: TextField(
                  controller: controller,
                  enabled: enabled,
                  keyboardType:
                      TextInputType.numberWithOptions(decimal: isDecimal),
                  onChanged: onChanged,
                  decoration: InputDecoration(
                    labelText: 'Return quantity',
                    suffixText: _unit,
                    border: const OutlineInputBorder(),
                    errorText: value > _returnable
                        ? 'Max ${_formatNumber(_returnable)}'
                        : null,
                  ),
                ),
              ),
              _ItemMetric(
                  label: 'Base quantity',
                  value: '${_formatNumber(value * _conversion)} $_baseUnit'),
            ],
          ),
          if (_conversion != 1)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text('1 $_unit = ${_formatNumber(_conversion)} $_baseUnit',
                  style: TextStyle(color: Colors.grey.shade700)),
            ),
        ],
      ),
    );
  }

  String _formatNumber(double value) => value == value.roundToDouble()
      ? value.toStringAsFixed(0)
      : value.toStringAsFixed(2);
}

class _ItemMetric extends StatelessWidget {
  const _ItemMetric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 110),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: Colors.grey.shade600)),
          const SizedBox(height: 3),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

class _ReturnSummary extends StatelessWidget {
  const _ReturnSummary({
    required this.items,
    required this.stockRemoved,
    required this.returnValue,
  });

  final int items;
  final double stockRemoved;
  final double returnValue;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: Theme.of(context).colorScheme.primary.withValues(alpha: .06),
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('RETURN SUMMARY',
                style:
                    TextStyle(fontWeight: FontWeight.w800, letterSpacing: .6)),
            const SizedBox(height: 12),
            _SummaryRow(label: 'Items to return', value: '$items'),
            _SummaryRow(
                label: 'Stock to remove',
                value: '${_format(stockRemoved)} pieces'),
            _SummaryRow(
                label: 'Return value',
                value: '${returnValue.toStringAsFixed(2)} DA'),
          ],
        ),
      ),
    );
  }

  String _format(double value) => value == value.roundToDouble()
      ? value.toStringAsFixed(0)
      : value.toStringAsFixed(2);
}

class _SummaryRow extends StatelessWidget {
  const _SummaryRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(child: Text(label)),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}

class _ReturnCompletedCard extends StatelessWidget {
  const _ReturnCompletedCard({
    required this.reference,
    required this.supplierName,
    required this.stockRemoved,
    required this.returnValue,
    required this.supplierBalance,
    required this.refreshWarning,
    required this.onNewReturn,
  });

  final String reference;
  final String supplierName;
  final double stockRemoved;
  final double returnValue;
  final double? supplierBalance;
  final String? refreshWarning;
  final VoidCallback onNewReturn;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Icon(Icons.check_circle, color: Colors.green, size: 54),
            const SizedBox(height: 12),
            const Text('Return completed',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
            const SizedBox(height: 24),
            _SummaryRow(label: 'Reference', value: reference),
            _SummaryRow(label: 'Supplier', value: supplierName),
            _SummaryRow(
                label: 'Stock removed',
                value: '${stockRemoved.toStringAsFixed(2)} pieces'),
            _SummaryRow(
                label: 'Return value',
                value: '${returnValue.toStringAsFixed(2)} DA'),
            if (supplierBalance != null)
              _SummaryRow(
                  label: 'Supplier outstanding',
                  value: '${supplierBalance!.toStringAsFixed(2)} DA'),
            if (refreshWarning != null) ...[
              const SizedBox(height: 12),
              Text(
                refreshWarning!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 24),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: FilledButton.icon(
                onPressed: onNewReturn,
                icon: const Icon(Icons.add),
                label: const Text('New Return'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
