import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';

import '../../../core/data/services/persistence_initializer.dart';
import '../../../core/di/dependency_injection.dart';
import '../../../core/security/permission_guard.dart';
import '../../../l10n/app_localizations.dart';
import '../../auth/presentation/cubit/user_cubit.dart';
import '../data/models/stock_adjustment_model.dart';
import '../data/repository/stock_adjustment_repository.dart';
import '../services/stock_adjustment_service.dart';

class StockAdjustmentScreen extends StatefulWidget {
  final StockAdjustmentService? service;
  final StockAdjustmentRepository? repository;
  final String? initialProductId;
  final double? initialCountedQuantity;

  const StockAdjustmentScreen({
    super.key,
    this.service,
    this.repository,
    this.initialProductId,
    this.initialCountedQuantity,
  });

  @override
  State<StockAdjustmentScreen> createState() => _StockAdjustmentScreenState();
}

class _StockAdjustmentScreenState extends State<StockAdjustmentScreen> {
  late final StockAdjustmentService _service;
  late final StockAdjustmentRepository _repository;
  final _countedController = TextEditingController();
  final _reasonController = TextEditingController();
  final _notesController = TextEditingController();
  DateTime _adjustmentDate = DateTime.now();
  String? _selectedProductId;
  List<Map<String, dynamic>> _products = [];
  List<StockAdjustmentDocument> _history = [];
  final List<StockAdjustmentLineInput> _lines = [];
  bool _loading = true;
  bool _posting = false;
  String _idempotencyKey = const Uuid().v4();

  @override
  void initState() {
    super.initState();
    _service = widget.service ?? getIt<StockAdjustmentService>();
    _repository = widget.repository ?? getIt<StockAdjustmentRepository>();
    _selectedProductId = widget.initialProductId;
    if (widget.initialCountedQuantity != null) {
      _countedController.text = _formatQuantity(widget.initialCountedQuantity!);
    }
    _load();
  }

  @override
  void dispose() {
    _countedController.dispose();
    _reasonController.dispose();
    _notesController.dispose();
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
      _message(l10n.stockAdjustmentRequired);
      return;
    }
    final user = getIt<UserCubit>().currentUser;
    if (!PermissionGuard.canAdjustStock(user)) {
      _message(l10n.stockAdjustmentPermissionDenied);
      return;
    }
    setState(() => _posting = true);
    try {
      final document = await _service.post(
        idempotencyKey: _idempotencyKey,
        lines: List.unmodifiable(_lines),
        notes: _notesController.text,
        reason: _reasonController.text,
        adjustmentDate: _adjustmentDate,
        user: user,
      );
      if (!mounted) return;
      setState(() {
        _lines.clear();
        _selectedProductId = null;
        _countedController.clear();
        _reasonController.clear();
        _notesController.clear();
        _idempotencyKey = const Uuid().v4();
        _posting = false;
        _history = [document, ..._history];
      });
      await _load();
      _message(l10n.stockAdjustmentSuccess);
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
    final counted = double.tryParse(_countedController.text.trim());
    if (productId == null || counted == null || counted < 0) {
      _message(l10n.stockAdjustmentInvalidQuantity);
      return;
    }
    if (_lines.any((line) => line.productId == productId)) {
      _message(l10n.stockAdjustmentProductExists);
      return;
    }
    setState(() {
      _lines.add(StockAdjustmentLineInput(
        productId: productId,
        countedQuantity: counted,
      ));
      _selectedProductId = null;
      _countedController.clear();
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
    if (!PermissionGuard.canAdjustStock(user)) {
      return Center(child: Text(l10n.stockAdjustmentPermissionDenied));
    }
    if (_loading) return const Center(child: CircularProgressIndicator());

    return DefaultTabController(
      length: 2,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.stockAdjustment,
                style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 6),
            Text(l10n.stockAdjustmentSubtitle),
            const SizedBox(height: 18),
            TabBar(
              tabs: [
                Tab(text: l10n.stockAdjustmentNewDocument),
                Tab(text: l10n.stockAdjustmentHistory),
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
                  decoration:
                      InputDecoration(labelText: l10n.stockAdjustmentProduct),
                  items: _products.map((product) {
                    final id = product['id'] as String;
                    final barcode = product['barcode'] as String?;
                    return DropdownMenuItem(
                      value: id,
                      child: Text(
                        '${product['name']}${barcode == null ? '' : ' ($barcode)'}',
                      ),
                    );
                  }).toList(),
                  onChanged: (value) => setState(() {
                    _selectedProductId = value;
                    if (value != null && widget.initialCountedQuantity == null) {
                      _countedController.text =
                          _formatQuantity(_currentStock(value));
                    }
                  }),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _countedController,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        onChanged: (_) => setState(() {}),
                        decoration: InputDecoration(
                          labelText: l10n.stockAdjustmentCountedQuantity,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    ElevatedButton.icon(
                      onPressed: _addLine,
                      icon: const Icon(Icons.add),
                      label: Text(l10n.stockAdjustmentAddLine),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _reasonController,
                  decoration:
                      InputDecoration(labelText: l10n.stockAdjustmentReason),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _notesController,
                  decoration:
                      InputDecoration(labelText: l10n.stockAdjustmentNotes),
                  maxLines: 2,
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: Text('${l10n.stockAdjustmentDate}: '
                          '${DateFormat.yMd().format(_adjustmentDate)}'),
                    ),
                    TextButton(
                      onPressed: () async {
                        final selected = await showDatePicker(
                          context: context,
                          initialDate: _adjustmentDate,
                          firstDate: DateTime(2000),
                          lastDate: DateTime(2100),
                        );
                        if (selected != null) {
                          setState(() => _adjustmentDate = selected);
                        }
                      },
                      child: Text(l10n.stockAdjustmentDate),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        if (_selectedProductId != null &&
            double.tryParse(_countedController.text.trim()) != null)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: _buildQuantityPreview(
                l10n,
                _currentStock(_selectedProductId!),
                double.parse(_countedController.text.trim()),
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
                      '${l10n.stockAdjustmentCurrentQuantity}: '
                      '${_currentStock(_lines[index].productId)}\n'
                      '${l10n.stockAdjustmentCountedQuantity}: '
                      '${_lines[index].countedQuantity}\n'
                      '${l10n.stockAdjustmentDelta}: '
                      '${_lines[index].countedQuantity - _currentStock(_lines[index].productId)}\n'
                      '${l10n.stockAdjustmentResult}: '
                      '${_lines[index].countedQuantity}',
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () => setState(() => _lines.removeAt(index)),
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
                      label: Text(l10n.stockAdjustmentPost),
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildQuantityPreview(
    AppLocalizations l10n,
    double current,
    double counted,
  ) {
    final adjustment = counted - current;
    return Text(
      '${l10n.stockAdjustmentCurrentQuantity}: $current\n'
      '${l10n.stockAdjustmentCountedQuantity}: $counted\n'
      '${l10n.stockAdjustmentDelta}: '
      '${adjustment >= 0 ? '+' : ''}$adjustment\n'
      '${l10n.stockAdjustmentResult}: $counted',
    );
  }

  Widget _buildHistory(AppLocalizations l10n) {
    if (_history.isEmpty) {
      return Center(child: Text(l10n.stockAdjustmentNoHistory));
    }
    return ListView.builder(
      itemCount: _history.length,
      itemBuilder: (context, index) {
        final document = _history[index];
        return Card(
          child: ListTile(
            title: Text(document.referenceNumber),
            subtitle: Text(
              '${DateFormat.yMd().add_jm().format(document.postedAt)} • '
              '${document.lines.length} ${l10n.stockAdjustmentTotalItems}',
            ),
            trailing: TextButton(
              onPressed: () => _showDocument(document, l10n),
              child: Text(l10n.stockAdjustmentView),
            ),
          ),
        );
      },
    );
  }

  void _showDocument(
    StockAdjustmentDocument document,
    AppLocalizations l10n,
  ) {
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
                Text('${l10n.stockAdjustmentPostedBy}: ${document.postedBy}'),
                Text('${l10n.stockAdjustmentReason}: ${document.reason ?? ''}'),
                const Divider(),
                for (final line in document.lines)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(line.productName),
                    subtitle: Text(
                      '${l10n.stockAdjustmentCurrentQuantity}: '
                      '${line.currentQuantity} • '
                      '${l10n.stockAdjustmentCountedQuantity}: '
                      '${line.countedQuantity}',
                    ),
                    trailing: Text(
                      '${line.quantityChange > 0 ? '+' : ''}'
                      '${line.quantityChange}',
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

  String _formatQuantity(double value) {
    return value == value.roundToDouble()
        ? value.toInt().toString()
        : value.toString();
  }
}
