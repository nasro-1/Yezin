import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../core/data/services/persistence_initializer.dart';
import '../../../core/di/dependency_injection.dart';
import '../../../core/security/permission_guard.dart';
import '../../../l10n/app_localizations.dart';
import '../../auth/presentation/cubit/user_cubit.dart';
import '../data/models/opening_stock_model.dart';
import '../data/repository/opening_stock_repository.dart';
import '../services/opening_stock_service.dart';

class OpeningStockScreen extends StatefulWidget {
  final OpeningStockService? service;
  final OpeningStockRepository? repository;

  const OpeningStockScreen({
    super.key,
    this.service,
    this.repository,
  });

  @override
  State<OpeningStockScreen> createState() => _OpeningStockScreenState();
}

class _OpeningStockScreenState extends State<OpeningStockScreen> {
  late final OpeningStockService _service;
  late final OpeningStockRepository _repository;
  final _quantityController = TextEditingController();
  final _notesController = TextEditingController();
  final _reasonController = TextEditingController();
  final _unitCostController = TextEditingController();
  DateTime _openingDate = DateTime.now();
  String? _selectedProductId;
  List<Map<String, dynamic>> _products = [];
  final List<OpeningStockLineInput> _lines = [];
  List<OpeningStockDocument> _history = [];
  bool _loading = true;
  bool _posting = false;

  @override
  void initState() {
    super.initState();
    _service = widget.service ?? getIt<OpeningStockService>();
    _repository = widget.repository ?? getIt<OpeningStockRepository>();
    _load();
  }

  @override
  void dispose() {
    _quantityController.dispose();
    _notesController.dispose();
    _reasonController.dispose();
    _unitCostController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final db = PersistenceInitializer.persistenceManager!.sqliteManager;
      final products = await db.query(
        'products',
        columns: ['id', 'name', 'barcode', 'stock'],
        where: 'is_active = 1',
        orderBy: 'name COLLATE NOCASE ASC',
      );
      final history = await _repository.getPostedDocuments();
      if (!mounted) return;
      setState(() {
        _products = products;
        _history = history;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _post() async {
    final l10n = AppLocalizations.of(context);
    if (_lines.isEmpty) {
      _message(l10n.openingStockRequired);
      return;
    }
    final user = getIt<UserCubit>().currentUser;
    if (!PermissionGuard.canManageOpeningStock(user)) {
      _message(l10n.openingStockPermissionDenied);
      return;
    }
    setState(() => _posting = true);
    try {
      final document = await _service.post(
        lines: List.unmodifiable(_lines),
        notes: _notesController.text,
        reason: _reasonController.text,
        openingDate: _openingDate,
        user: user,
      );
      if (!mounted) return;
      setState(() {
        _lines.clear();
        _selectedProductId = null;
        _quantityController.clear();
        _notesController.clear();
        _reasonController.clear();
        _unitCostController.clear();
        _posting = false;
        _history = [document, ..._history];
      });
      _message(l10n.openingStockSuccess);
    } catch (error) {
      if (mounted) {
        setState(() => _posting = false);
        _message(error.toString());
      }
    }
  }

  void _addLine() {
    final l10n = AppLocalizations.of(context);
    final productId = _selectedProductId;
    final quantity = double.tryParse(_quantityController.text.trim());
    final unitCost = double.tryParse(_unitCostController.text.trim().isEmpty
        ? '0'
        : _unitCostController.text.trim());
    if (productId == null ||
        quantity == null ||
        quantity <= 0 ||
        unitCost == null ||
        unitCost < 0) {
      _message(l10n.openingStockInvalidQuantity);
      return;
    }
    if (_lines.any((line) => line.productId == productId)) {
      _message(l10n.openingStockProductExists);
      return;
    }
    setState(() {
      _lines.add(OpeningStockLineInput(
        productId: productId,
        quantity: quantity,
        unitCost: unitCost,
      ));
      _selectedProductId = null;
      _quantityController.clear();
      _unitCostController.clear();
    });
  }

  void _message(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final user = getIt<UserCubit>().currentUser;
    if (!PermissionGuard.canManageOpeningStock(user)) {
      return Center(child: Text(l10n.openingStockPermissionDenied));
    }
    if (_loading) return const Center(child: CircularProgressIndicator());

    return DefaultTabController(
      length: 2,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.openingStock, style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 6),
            Text(l10n.openingStockSubtitle),
            const SizedBox(height: 18),
            TabBar(
              tabs: [
                Tab(text: l10n.openingStockNewDocument),
                Tab(text: l10n.openingStockHistory),
              ],
            ),
            const SizedBox(height: 16),
            Expanded(
              child: TabBarView(
                children: [_buildEntry(l10n), _buildHistory(l10n)],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEntry(AppLocalizations l10n) {
    return ListView(
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              children: [
                DropdownButtonFormField<String>(
                  value: _selectedProductId,
                  decoration: InputDecoration(labelText: l10n.openingStockProduct),
                  items: _products.map((product) {
                    final id = product['id'] as String;
                    final barcode = product['barcode'] as String?;
                    return DropdownMenuItem(
                      value: id,
                      child: Text('${product['name']}${barcode == null ? '' : ' ($barcode)'}'),
                    );
                  }).toList(),
                  onChanged: (value) => setState(() => _selectedProductId = value),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _quantityController,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: InputDecoration(labelText: l10n.openingStockQuantity),
                      ),
                    ),
                    const SizedBox(width: 12),
                    ElevatedButton.icon(
                      onPressed: _addLine,
                      icon: const Icon(Icons.add),
                      label: Text(l10n.openingStockAddLine),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _notesController,
                  decoration: InputDecoration(labelText: l10n.openingStockNotes),
                  maxLines: 2,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _reasonController,
                  decoration: InputDecoration(labelText: l10n.openingStockReason),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: Text('${l10n.openingStockDate}: '
                          '${DateFormat.yMd().format(_openingDate)}'),
                    ),
                    TextButton(
                      onPressed: () async {
                        final selected = await showDatePicker(
                          context: context,
                          initialDate: _openingDate,
                          firstDate: DateTime(2000),
                          lastDate: DateTime(2100),
                        );
                        if (selected != null) {
                          setState(() => _openingDate = selected);
                        }
                      },
                      child: Text(l10n.openingStockDate),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _unitCostController,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(labelText: l10n.openingStockUnitCost),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        if (_lines.isNotEmpty)
          Card(
            child: Column(
              children: [
                for (var index = 0; index < _lines.length; index++)
                  ListTile(
                    title: Text(_productName(_lines[index].productId)),
                    subtitle: Text(
                      '${l10n.openingStockCurrentStock}: '
                      '${_currentStock(_lines[index].productId)}  +  '
                      '${l10n.openingStockQuantity}: ${_lines[index].quantity}  =  '
                      '${_currentStock(_lines[index].productId) + _lines[index].quantity}\n'
                      '${l10n.openingStockUnitCost}: ${_lines[index].unitCost}',
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_lines[index].quantity.toString()),
                        IconButton(
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () => setState(() => _lines.removeAt(index)),
                        ),
                      ],
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: FilledButton.icon(
                      onPressed: _posting ? null : _post,
                      icon: _posting
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.check),
                      label: Text(l10n.openingStockPost),
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildHistory(AppLocalizations l10n) {
    if (_history.isEmpty) return Center(child: Text(l10n.openingStockNoHistory));
    return ListView.builder(
      itemCount: _history.length,
      itemBuilder: (context, index) {
        final document = _history[index];
        return Card(
          child: ListTile(
            title: Text(document.referenceNumber),
            subtitle: Text(
              '${DateFormat.yMd().add_jm().format(document.postedAt)} • '
              '${document.lines.length} ${l10n.openingStockTotalLines}',
            ),
            trailing: TextButton(
              onPressed: () => _showDocument(document, l10n),
              child: Text(l10n.openingStockView),
            ),
          ),
        );
      },
    );
  }

  void _showDocument(OpeningStockDocument document, AppLocalizations l10n) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(document.referenceNumber),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${l10n.openingStockPostedBy}: ${document.postedBy}'),
                Text('${l10n.openingStockReason}: ${document.reason}'),
                Text('${l10n.openingStockDate}: '
                    '${DateFormat.yMd().format(document.openingDate)}'),
                Text('${l10n.openingStockPostedAt}: '
                    '${DateFormat.yMd().add_jm().format(document.postedAt)}'),
                if (document.notes?.isNotEmpty == true)
                  Text('${l10n.openingStockNotes}: ${document.notes}'),
                const Divider(),
                for (final line in document.lines)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(line.productName),
                    subtitle: Text(line.productBarcode ?? line.productId),
                    trailing: Text(
                      '${line.quantity} × ${line.unitCost}',
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.cancel),
          ),
        ],
      ),
    );
  }

  String _productName(String productId) {
    for (final product in _products) {
      if (product['id'] == productId) return product['name'] as String;
    }
    return productId;
  }

  double _currentStock(String productId) {
    for (final product in _products) {
      if (product['id'] == productId) {
        return (product['stock'] as num?)?.toDouble() ?? 0;
      }
    }
    return 0;
  }
}
