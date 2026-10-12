import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../../sales/presentation/widgets/barcode_camera_scanner.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/data/services/persistence_initializer.dart';
import '../../../l10n/app_localizations.dart';
import '../../auth/data/models/user_model.dart';
import '../../sales/data/models/sale_model.dart';
import '../domain/exchange_service.dart';
import '../../../core/di/dependency_injection.dart';
import '../../../core/network/authority_context.dart';
import '../../products/presentation/cubit/product_cubit.dart';
import '../../sales/data/repository/sales_api_repository.dart';

class ExchangeDialog extends StatefulWidget {
  final Sale originalSale;
  final User currentUser;

  const ExchangeDialog({
    super.key,
    required this.originalSale,
    required this.currentUser,
  });

  @override
  State<ExchangeDialog> createState() => _ExchangeDialogState();
}

class _ProductChoice {
  final String id;
  final String name;
  final double price;
  final int stock;
  final String barcode;

  const _ProductChoice({
    required this.id,
    required this.name,
    required this.price,
    required this.stock,
    required this.barcode,
  });
}

class _ExchangeOriginalItem {
  final String saleItemId;
  final SaleItem item;
  int refundedQty;
  int exchangedQty;
  int selectedQty;

  _ExchangeOriginalItem({
    required this.saleItemId,
    required this.item,
    required this.refundedQty,
    required this.exchangedQty,
    required this.selectedQty,
  });

  double get availableQty =>
      (item.quantity - refundedQty - exchangedQty).clamp(0.0, item.quantity);
}

enum _ExchangeViewState {
  loading,
  editing,
  validationError,
  submitting,
  success,
  failure,
}

class _ExchangeDialogState extends State<ExchangeDialog> {
  String _entryKey(_ExchangeOriginalItem entry) =>
      entry.saleItemId.isNotEmpty ? entry.saleItemId : entry.item.productId;
  final TextEditingController _searchController = TextEditingController();
  final Map<String, int> _originalSelections = {};
  final Map<String, Map<String, int>> _selectedReplacementQuantities = {};
  final Map<String, _ExchangeOriginalItem> _originalEntries = {};
  List<_ProductChoice> _allProducts = const [];
  bool _loading = true;
  bool _invoiceChanged = false;
  _ExchangeViewState _state = _ExchangeViewState.loading;
  String? _message;
  String? _searchMessage;
  String? _stableIdempotencyKey;
  ExchangeResult? _result;

  @override
  void initState() {
    super.initState();
    _loadCatalog();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadCatalog() async {
    final serverMode = getIt.isRegistered<AuthorityContext>() &&
        getIt<AuthorityContext>().readsFromServer &&
        getIt.isRegistered<SalesApiRepository>();
    if (serverMode) {
      final products = getIt<ProductCubit>()
          .allProducts
          .map((product) => _ProductChoice(
                id: product.id,
                name: product.name,
                price: product.price,
                stock: product.quantity.toInt(),
                barcode: product.barcode,
              ))
          .toList();
      final availability = <String, _ExchangeOriginalItem>{
        for (final item in widget.originalSale.saleItems)
          (item.saleItemId ?? item.productId): _ExchangeOriginalItem(
            saleItemId: item.saleItemId ?? item.productId,
            item: item,
            refundedQty: item.refundedQuantity.toInt(),
            exchangedQty: item.exchangedQuantity.toInt(),
            selectedQty: 0,
          ),
      };
      if (!mounted) return;
      setState(() {
        _allProducts = products;
        _originalEntries
          ..clear()
          ..addAll(availability);
        _originalSelections
          ..clear()
          ..addEntries(availability.keys.map((id) => MapEntry(id, 0)));
        _selectedReplacementQuantities
          ..clear()
          ..addEntries(availability.keys.map((id) => MapEntry(id, {})));
        _loading = false;
        _state = _ExchangeViewState.editing;
      });
      return;
    }
    final db = PersistenceInitializer.persistenceManager!.sqliteManager;
    final rows = await db.query(
      'products',
      columns: ['id', 'name', 'price', 'stock', 'barcode'],
      orderBy: 'name COLLATE NOCASE',
    );

    final products = rows
        .map((row) => _ProductChoice(
              id: row['id'] as String,
              name: (row['name'] as String?) ?? 'Product',
              price: (row['price'] as num?)?.toDouble() ?? 0.0,
              stock: (row['stock'] as num?)?.toInt() ?? 0,
              barcode: (row['barcode'] as String?) ?? '',
            ))
        .toList();

    final saleRows = await db.query(
      'sale_items',
      columns: [
        'id',
        'product_id',
        'quantity',
        'refunded_quantity',
        'exchanged_quantity'
      ],
      where: 'sale_id = ?',
      whereArgs: [widget.originalSale.id],
    );

    final availability = <String, _ExchangeOriginalItem>{};
    for (final row in saleRows) {
      final productId = row['product_id'] as String;
      final item = widget.originalSale.saleItems.firstWhere(
        (element) => element.productId == productId,
        orElse: () => SaleItem(
          productId: productId,
          name: productId,
          price: 0,
          quantity: 0,
          total: 0,
          wholesalePrice: 0,
        ),
      );
      final refunded = (row['refunded_quantity'] as num?)?.toInt() ?? 0;
      final exchanged = (row['exchanged_quantity'] as num?)?.toInt() ?? 0;
      availability[productId] = _ExchangeOriginalItem(
        saleItemId: row['id'] as String,
        item: item,
        refundedQty: refunded,
        exchangedQty: exchanged,
        selectedQty: 0,
      );
    }

    if (!mounted) return;
    setState(() {
      _allProducts = products;
      _selectedReplacementQuantities.clear();
      _originalEntries.clear();
      _originalEntries.addAll(availability);
      for (final entry in _originalEntries.values) {
        _originalSelections[_entryKey(entry)] = 0;
        _selectedReplacementQuantities[_entryKey(entry)] = {};
      }
      _loading = false;
      _state = _ExchangeViewState.editing;
    });
  }

  List<_ExchangeOriginalItem> get _originalItems =>
      widget.originalSale.saleItems
          .where((item) =>
              _originalEntries.containsKey(item.saleItemId ?? item.productId))
          .map((item) => _originalEntries[item.saleItemId ?? item.productId]!)
          .toList();

  List<_ProductChoice> get _visibleReplacementProducts {
    final query = _searchController.text.trim().toLowerCase();
    if (query.isEmpty) {
      return _allProducts;
    }

    return _allProducts.where((product) {
      final haystack = '${product.name} ${product.barcode}'.toLowerCase();
      return haystack.contains(query);
    }).toList();
  }

  _ExchangeOriginalItem? get _selectedOriginalEntry {
    for (final entry in _originalItems) {
      if ((_originalSelections[_entryKey(entry)] ?? 0) > 0) return entry;
    }
    return null;
  }

  _ProductChoice? get _selectedReplacementProduct {
    final original = _selectedOriginalEntry;
    if (original == null) return null;
    final selections =
        _selectedReplacementQuantities[_entryKey(original)] ?? {};
    String? selectedId;
    for (final entry in selections.entries) {
      if (entry.value > 0) {
        selectedId = entry.key;
        break;
      }
    }
    return selectedId == null ? null : _productChoiceForId(selectedId);
  }

  void _selectReplacementProduct(_ProductChoice product) {
    final original = _selectedOriginalEntry;
    if (original == null) return;
    final originalKey = _entryKey(original);
    final quantity =
        (_originalSelections[originalKey] ?? 0).clamp(1, product.stock);
    if (quantity <= 0) return;
    setState(() {
      _selectedReplacementQuantities[originalKey] = {product.id: quantity};
    });
  }

  void _handleReplacementSearchChanged(String value) {
    final query = value.trim().toLowerCase();
    _searchMessage = null;
    if (query.isNotEmpty) {
      final matches = _allProducts
          .where((product) =>
              product.barcode.trim().toLowerCase() == query &&
              product.barcode.trim().isNotEmpty)
          .toList();
      if (matches.length == 1 && _selectedOriginalEntry != null) {
        _selectReplacementProduct(matches.single);
      } else if (matches.isEmpty &&
          !_allProducts.any((product) => '${product.name} ${product.barcode}'
              .toLowerCase()
              .contains(query))) {
        _searchMessage = 'Product not found';
      }
    }
    setState(() {});
  }

  Future<void> _scanReplacementBarcode() async {
    final value = await BarcodeCameraScanner.show(context);
    if (!mounted || value == null || value.trim().isEmpty) return;
    _searchController.text = value.trim();
    _handleReplacementSearchChanged(value);
  }

  bool get _hasValidOriginalSelection => _originalItems
      .any((entry) => (_originalSelections[_entryKey(entry)] ?? 0) > 0);

  double get _originalValue {
    if (!_hasValidOriginalSelection) return 0;
    double total = 0;
    for (final entry in _originalItems) {
      final selected = _originalSelections[_entryKey(entry)] ?? 0;
      if (selected <= 0) continue;
      total += entry.item.price * selected;
    }
    return total;
  }

  double get _replacementValue {
    if (!_hasValidOriginalSelection) return 0;
    double total = 0;
    for (final selections in _selectedReplacementQuantities.values) {
      for (final entry in selections.entries) {
        if (entry.value <= 0) continue;
        final product = _allProducts.firstWhere(
          (item) => item.id == entry.key,
          orElse: () => const _ProductChoice(
            id: '',
            name: '',
            price: 0,
            stock: 0,
            barcode: '',
          ),
        );
        total += product.price * entry.value;
      }
    }
    return total;
  }

  double get _difference => _replacementValue - _originalValue;

  bool get _isSubmitting => _state == _ExchangeViewState.submitting;

  AppLocalizations get _loc => AppLocalizations.of(context);

  bool get _isArabic => Localizations.localeOf(context).languageCode == 'ar';

  bool get _isSummaryIncomplete =>
      !_hasValidOriginalSelection || _originalValue <= 0;

  bool get canSubmit =>
      !_invoiceChanged &&
      _hasOriginalSelection &&
      _hasReplacementSelection &&
      !_isSubmitting;

  bool get _hasOriginalSelection => _originalItems
      .any((entry) => (_originalSelections[_entryKey(entry)] ?? 0) > 0);

  bool get _hasReplacementSelection =>
      _selectedReplacementQuantities.values.any(
        (selection) => selection.values.any((qty) => qty > 0),
      );

  void _setOriginalQuantity(String productId, int qty) {
    var entry = _originalEntries[productId];
    if (entry == null) {
      for (final candidate in _originalEntries.values) {
        if (candidate.saleItemId == productId) {
          entry = candidate;
          break;
        }
      }
    }
    if (entry == null) return;
    final safeQty = qty.clamp(0, entry.availableQty.toInt());
    setState(() {
      _originalSelections[productId] = safeQty;
      if (safeQty <= 0) {
        _selectedReplacementQuantities[productId]?.clear();
        _selectedReplacementQuantities.remove(productId);
      }
    });
  }

  List<ExchangeLineRequest> get _exchangeLines {
    final lines = <ExchangeLineRequest>[];
    for (final entry in _originalItems) {
      final selectedQty = _originalSelections[_entryKey(entry)] ?? 0;
      final selectedReplacements =
          _selectedReplacementQuantities[_entryKey(entry)] ?? const {};
      if (selectedQty <= 0 || selectedReplacements.isEmpty) continue;
      for (final replacement in selectedReplacements.entries) {
        final qty = replacement.value;
        if (qty <= 0) continue;
        lines.add(ExchangeLineRequest(
          originalSaleItemId: entry.saleItemId,
          originalProductId: entry.item.productId,
          returnedQuantity: selectedQty.toDouble(),
          replacementProductId: replacement.key,
          replacementQuantity: qty.toDouble(),
        ));
      }
    }
    return lines;
  }

  String get _customerActionText {
    if (_isSummaryIncomplete) {
      return _loc.exchangeSelectItemAndQuantity;
    }
    if (_difference > 0) {
      return '${_loc.exchangeCustomerPays} ${_difference.toStringAsFixed(2)}';
    }
    if (_difference < 0) {
      return '${_loc.exchangeCustomerReceives} ${(-_difference).toStringAsFixed(2)}';
    }
    return _loc.exchangeEvenExchange;
  }

  _ProductChoice? _productChoiceForId(String productId) {
    try {
      return _allProducts.firstWhere((product) => product.id == productId);
    } catch (_) {
      return null;
    }
  }

  void _updateReplacementQtyForOriginal(
      String originalProductId, String productId, int qty) {
    final product = _productChoiceForId(productId);
    if (product == null) return;
    final limited = qty.clamp(0, product.stock.toInt());
    setState(() {
      final selections = _selectedReplacementQuantities.putIfAbsent(
          originalProductId, () => {});
      if (limited <= 0) {
        selections.remove(productId);
      } else {
        selections[productId] = limited;
      }
    });
  }

  Future<bool> _invoiceStillMatchesLoadedState() async {
    final db = PersistenceInitializer.persistenceManager!.sqliteManager;
    final rows = await db.query(
      'sale_items',
      columns: [
        'product_id',
        'quantity',
        'refunded_quantity',
        'exchanged_quantity'
      ],
      where: 'sale_id = ?',
      whereArgs: [widget.originalSale.id],
    );
    final current = <String, Map<String, num>>{
      for (final row in rows)
        row['product_id'] as String: {
          'quantity': (row['quantity'] as num?) ?? 0,
          'refunded_quantity': (row['refunded_quantity'] as num?) ?? 0,
          'exchanged_quantity': (row['exchanged_quantity'] as num?) ?? 0,
        },
    };
    for (final entry in _originalEntries.entries) {
      final row = current[entry.key];
      if (row == null ||
          row['quantity'] != entry.value.item.quantity ||
          row['refunded_quantity'] != entry.value.refundedQty ||
          row['exchanged_quantity'] != entry.value.exchangedQty) {
        return false;
      }
    }
    return true;
  }

  void _markInvoiceChanged() {
    _invoiceChanged = true;
    _originalSelections.clear();
    _selectedReplacementQuantities.clear();
    _state = _ExchangeViewState.failure;
    _message = 'The invoice changed. Please refresh and try again.';
  }

  String get _idempotencyKey {
    _stableIdempotencyKey ??= () {
      final snapshot = _originalItems.map((entry) {
        final selectedQty = _originalSelections[_entryKey(entry)] ?? 0;
        final replacements =
            _selectedReplacementQuantities[_entryKey(entry)] ?? const {};
        final replacementSummary = replacements.entries
            .map((replacement) => '${replacement.key}:${replacement.value}')
            .join(',');
        return '${_entryKey(entry)}:$selectedQty:$replacementSummary';
      }).join('|');
      return 'exchange_${widget.originalSale.id}_$snapshot';
    }();
    return _stableIdempotencyKey!;
  }

  Future<void> _confirmExchange() async {
    if (_isSubmitting || _invoiceChanged) return;

    final serverMode = getIt.isRegistered<AuthorityContext>() &&
        getIt<AuthorityContext>().readsFromServer &&
        getIt<AuthorityContext>().writesToServer &&
        getIt.isRegistered<SalesApiRepository>();
    if (!serverMode && !await _invoiceStillMatchesLoadedState()) {
      if (!mounted) return;
      setState(_markInvoiceChanged);
      return;
    }

    final lines = _exchangeLines;
    if (lines.isEmpty) {
      setState(() {
        _state = _ExchangeViewState.validationError;
        _message =
            'Select at least one original item and one replacement product.';
      });
      return;
    }

    for (final entry in _originalItems) {
      final selected = _originalSelections[_entryKey(entry)] ?? 0;
      if (selected > entry.availableQty) {
        setState(() {
          _state = _ExchangeViewState.validationError;
          _message = 'This quantity is no longer available for exchange.';
        });
        return;
      }
    }

    for (final selections in _selectedReplacementQuantities.values) {
      for (final entry in selections.entries) {
        final product = _productChoiceForId(entry.key);
        if (product == null) {
          setState(() {
            _state = _ExchangeViewState.validationError;
            _message = 'This quantity is no longer available for exchange.';
          });
          return;
        }
        if (entry.value > product.stock) {
          setState(() {
            _state = _ExchangeViewState.validationError;
            _message = 'Not enough stock for replacement product.';
          });
          return;
        }
      }
    }

    setState(() {
      _state = _ExchangeViewState.submitting;
      _message = null;
    });

    try {
      if (serverMode) {
        final serverRepository = getIt<SalesApiRepository>();
        debugPrint(
            '[EXCHANGE_UI_TRACE] originalSaleId=${widget.originalSale.id} '
            'items=${lines.map((line) => {
                  'originalSaleItemId': line.originalSaleItemId,
                  'returnQuantity': line.returnedQuantity,
                  'replacementProductId': line.replacementProductId,
                  'replacementQuantity': line.replacementQuantity,
                  'paymentMethod': widget.originalSale.paymentMethod,
                }).toList()}');
        final result = await serverRepository.postExchange(
          saleId: widget.originalSale.id,
          idempotencyKey: _idempotencyKey,
          paymentMethod: widget.originalSale.paymentMethod,
          customerId: widget.originalSale.customerId,
          items: lines
              .map((line) => {
                    'sale_item_id': line.originalSaleItemId,
                    'product_id': line.originalProductId,
                    'returned_quantity': line.returnedQuantity,
                    'replacement_product_id': line.replacementProductId,
                    'replacement_quantity': line.replacementQuantity,
                    if (line.replacementSellingUnitId != null)
                      'replacement_unit': line.replacementSellingUnitId,
                  })
              .toList(),
        );
        final response = result.fold(
          (failure) => throw StateError(failure.message),
          (value) => value,
        );
        debugPrint('[EXCHANGE_API_TRACE] method=POST '
            'path=/sales/${widget.originalSale.id}/exchange '
            'status=201 response=$response');
        if (!mounted) return;
        setState(() {
          _result = ExchangeResult.fromApiResponse(response);
          _state = _ExchangeViewState.success;
        });
        return;
      }
      final service = ExchangeService();
      final result = await service.execute(
        ExchangeRequest(
          originalSaleId: widget.originalSale.id,
          items: lines,
          customerId: widget.originalSale.customerId,
          paymentMethod: widget.originalSale.paymentMethod,
          idempotencyKey: _idempotencyKey,
          actorUserId: widget.currentUser.username,
          notes: 'Product exchange from invoice ${widget.originalSale.id}',
        ),
      );
      if (!mounted) return;
      setState(() {
        _result = result;
        _state = _ExchangeViewState.success;
      });
    } catch (error) {
      if (!mounted) return;
      final message = _mapFailure(error.toString());
      final invoiceChanged =
          message == 'The invoice changed. Please refresh and try again.';
      setState(() {
        _state = _ExchangeViewState.failure;
        _message = message;
        if (invoiceChanged) {
          _markInvoiceChanged();
        }
      });
    }
  }

  String _mapFailure(String message) {
    debugPrint('[EXCHANGE_API_TRACE] failure=$message');
    final text = message.toLowerCase();
    if (text.contains('401') ||
        text.contains('authentication') ||
        text.contains('session')) {
      return 'Your session has expired. Please sign in again.';
    }
    if (text.contains('404') || text.contains('not found')) {
      return 'The invoice or product could not be found.';
    }
    if (text.contains('insufficient') || text.contains('stock')) {
      return 'Not enough stock for replacement product.';
    }
    if (text.contains('available') ||
        text.contains('cannot exchange') ||
        text.contains('quantity')) {
      return 'This quantity is no longer available for exchange.';
    }
    if (text.contains('duplicate') ||
        text.contains('already processed') ||
        text.contains('idempot')) {
      return 'This exchange has already been processed.';
    }
    if (text.contains('sale') ||
        text.contains('invoice') ||
        text.contains('customer') ||
        text.contains('not found')) {
      return 'The invoice changed. Please refresh and try again.';
    }
    return 'Something went wrong. Please try again.';
  }

  @override
  Widget build(BuildContext context) {
    final effectiveDirection = Directionality.of(context);
    return Directionality(
      textDirection: effectiveDirection,
      child: Dialog(
        insetPadding: const EdgeInsets.all(20),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1100, maxHeight: 780),
          child: SizedBox(
            width: 980,
            height: 760,
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _state == _ExchangeViewState.success
                    ? _buildSuccessState()
                    : _buildBody(),
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    return Column(
      children: [
        _buildHeader(),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildInvoiceSummary(),
                const SizedBox(height: 16),
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: _buildReturningCard()),
                      const SizedBox(width: 18),
                      Expanded(child: _buildReceivingCard()),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                if (_message != null)
                  Container(
                    width: double.infinity,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(
                      color: AppColors.errorColor.withOpacity(0.08),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                          color: AppColors.errorColor.withOpacity(0.25)),
                    ),
                    child: Text(
                      _message!,
                      style: const TextStyle(
                        color: AppColors.errorColor,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        _buildFooter(),
      ],
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.fromLTRB(22, 20, 18, 20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            AppColors.primaryColor,
            AppColors.primaryColor.withOpacity(0.8)
          ],
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.14),
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Icon(LucideIcons.arrowLeftRight,
                color: Colors.white, size: 24),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _loc.exchangeProductExchange,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _loc.exchangeReviewAndConfirm,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: () => Navigator.of(context).pop(),
            tooltip: _loc.exchangeClose,
            icon: const Icon(Icons.close_rounded, color: Colors.white),
          ),
        ],
      ),
    );
  }

  Widget _buildInvoiceSummary() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surfaceColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.borderColor),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _loc.exchangeOriginalInvoice,
                  style: const TextStyle(
                    color: AppColors.mutedColor,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  widget.originalSale.referenceNumber ?? widget.originalSale.id,
                  style: const TextStyle(
                      fontWeight: FontWeight.w800, fontSize: 16),
                ),
              ],
            ),
          ),
          const SizedBox(width: 18),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _loc.exchangeCustomer,
                  style: const TextStyle(
                    color: AppColors.mutedColor,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  widget.originalSale.customerId ?? 'Walk-in customer',
                  style: const TextStyle(
                      fontWeight: FontWeight.w700, fontSize: 15),
                ),
              ],
            ),
          ),
          const SizedBox(width: 18),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _loc.exchangePaymentMethod,
                  style: const TextStyle(
                    color: AppColors.mutedColor,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  widget.originalSale.paymentMethod.toUpperCase(),
                  style: const TextStyle(
                      fontWeight: FontWeight.w800, fontSize: 15),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildReturningCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surfaceColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _loc.exchangeReturning,
            style: const TextStyle(
              fontSize: 12,
              letterSpacing: 1.4,
              color: AppColors.primaryColor,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: ListView.separated(
              key: const ValueKey('exchange-returning-list'),
              itemCount: _originalItems.length,
              padding: EdgeInsets.zero,
              physics: const AlwaysScrollableScrollPhysics(),
              itemBuilder: (context, index) {
                final entry = _originalItems[index];
                final selected = _originalSelections[_entryKey(entry)] ?? 0;
                final item = entry.item;
                final available = entry.availableQty;
                final availableCount = available.toInt();
                return Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: AppColors.backgroundColor,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.borderColor),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          item.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontWeight: FontWeight.w800, fontSize: 14),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '${item.price.toStringAsFixed(2)} DA',
                        style: const TextStyle(
                            color: AppColors.warningColor,
                            fontWeight: FontWeight.w700,
                            fontSize: 12),
                      ),
                      const SizedBox(width: 6),
                      _quantityStepper(
                        value: selected,
                        maximum: availableCount,
                        onChanged: (value) =>
                            _setOriginalQuantity(_entryKey(entry), value),
                        compact: true,
                      ),
                    ],
                  ),
                );
              },
              separatorBuilder: (_, __) => const SizedBox(height: 10),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildReceivingCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surfaceColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _loc.exchangeReceiving,
            style: const TextStyle(
              fontSize: 12,
              letterSpacing: 1.4,
              color: AppColors.primaryColor,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _searchController,
            textDirection: _isArabic ? TextDirection.rtl : TextDirection.ltr,
            decoration: InputDecoration(
              hintText: 'Search product or scan barcode...',
              prefixIcon: const Icon(Icons.search_rounded),
              suffixIcon: IconButton(
                tooltip: 'Scan barcode',
                icon: const Icon(Icons.qr_code_scanner_rounded),
                onPressed: _scanReplacementBarcode,
              ),
              border:
                  OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            ),
            onChanged: _handleReplacementSearchChanged,
          ),
          const SizedBox(height: 12),
          if (_searchMessage != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(_searchMessage!,
                  style: const TextStyle(color: AppColors.errorColor)),
            ),
          if (_selectedReplacementProduct != null) ...[
            _buildSelectedReplacement(_selectedReplacementProduct!),
            const SizedBox(height: 12),
          ],
          Expanded(
            child: _visibleReplacementProducts.isEmpty
                ? Center(
                    child: Text(_loc.exchangeNoReplacementProductsFound),
                  )
                : ListView.separated(
                    key: const ValueKey('exchange-receiving-list'),
                    itemCount: _visibleReplacementProducts.length,
                    cacheExtent: 2000,
                    physics: const AlwaysScrollableScrollPhysics(),
                    itemBuilder: (context, index) {
                      final product = _visibleReplacementProducts[index];
                      return Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: AppColors.borderColor),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(product.name,
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w700)),
                                  Text(
                                    'Stock: ${product.stock}',
                                    style: const TextStyle(
                                        color: AppColors.mutedColor,
                                        fontSize: 11),
                                  ),
                                  Text(
                                    '${product.price.toStringAsFixed(2)} DA',
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w700,
                                        fontSize: 12),
                                  ),
                                ],
                              ),
                            ),
                            OutlinedButton(
                              onPressed: _selectedOriginalEntry == null
                                  ? null
                                  : () => _selectReplacementProduct(product),
                              child: const Text('Select'),
                            ),
                          ],
                        ),
                      );
                    },
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _quantityStepper({
    required int value,
    required int maximum,
    required ValueChanged<int> onChanged,
    bool compact = false,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          constraints: compact
              ? const BoxConstraints.tightFor(width: 28, height: 28)
              : null,
          padding: compact ? EdgeInsets.zero : null,
          onPressed: value > 0 ? () => onChanged(value - 1) : null,
          icon: Icon(Icons.remove_circle_outline, size: compact ? 18 : 24),
        ),
        SizedBox(
          width: compact ? 24 : 34,
          child: Text(
            '$value',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
          ),
        ),
        IconButton(
          constraints: compact
              ? const BoxConstraints.tightFor(width: 28, height: 28)
              : null,
          padding: compact ? EdgeInsets.zero : null,
          onPressed: value < maximum ? () => onChanged(value + 1) : null,
          icon: Icon(Icons.add_circle_outline, size: compact ? 18 : 24),
        ),
      ],
    );
  }

  Widget _buildSelectedReplacement(_ProductChoice product) {
    final original = _selectedOriginalEntry;
    final originalKey = original == null ? null : _entryKey(original);
    final quantity = originalKey == null
        ? 0
        : (_selectedReplacementQuantities[originalKey]?[product.id] ?? 0);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.primaryColor.withOpacity(0.06),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.primaryColor.withOpacity(0.35)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Replacement',
                    style: TextStyle(
                        color: AppColors.primaryColor,
                        fontSize: 11,
                        fontWeight: FontWeight.w800)),
                Text(product.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w800)),
                Text(
                    'Stock: ${product.stock} • '
                    '${product.price.toStringAsFixed(2)} DA',
                    style: const TextStyle(
                        color: AppColors.mutedColor, fontSize: 11)),
              ],
            ),
          ),
          _quantityStepper(
            value: quantity,
            maximum: product.stock,
            onChanged: (next) {
              if (originalKey != null) {
                _updateReplacementQtyForOriginal(originalKey, product.id, next);
              }
            },
            compact: true,
          ),
        ],
      ),
    );
  }

  Widget _buildSummary() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.backgroundColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.borderColor),
      ),
      child: Row(
        children: [
          Expanded(
              child: _summaryItem(_loc.exchangeOriginalValue,
                  _isSummaryIncomplete ? null : _originalValue)),
          Expanded(
              child: _summaryItem(_loc.exchangeReplacementValue,
                  _isSummaryIncomplete ? null : _replacementValue)),
          Expanded(
              child: _summaryItem(_loc.exchangeDifference,
                  _isSummaryIncomplete ? null : _difference)),
          Expanded(
            child: _summaryItem(
              _loc.exchangeCustomerAction,
              _invoiceChanged ? _message : _customerActionText,
              accent: true,
            ),
          ),
        ],
      ),
    );
  }

  Widget _summaryItem(String label, dynamic value, {bool accent = false}) {
    final display = value == null
        ? '—'
        : (value is double ? value.toStringAsFixed(2) : value.toString());
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            color: AppColors.mutedColor,
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          display,
          style: TextStyle(
            color: accent ? AppColors.primaryColor : AppColors.textPrimary,
            fontWeight: FontWeight.w800,
            fontSize: 15,
          ),
        ),
      ],
    );
  }

  Widget _buildFooter() {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: AppColors.borderColor)),
      ),
      child: Row(
        children: [
          Expanded(child: _buildSummary()),
          const SizedBox(width: 16),
          TextButton(
            onPressed: _isSubmitting ? null : () => Navigator.of(context).pop(),
            child: Text(_loc.exchangeCancel),
          ),
          const SizedBox(width: 10),
          ElevatedButton.icon(
            onPressed: canSubmit ? _confirmExchange : null,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primaryColor,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            ),
            icon: const Icon(Icons.check_circle_rounded),
            label: Text(_loc.exchangeConfirm),
          ),
        ],
      ),
    );
  }

  Widget _buildSuccessState() {
    final result = _result;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          const SizedBox(height: 20),
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: AppColors.successColor.withOpacity(0.12),
              borderRadius: BorderRadius.circular(24),
            ),
            child: const Icon(
              Icons.check_circle_rounded,
              color: AppColors.successColor,
              size: 40,
            ),
          ),
          const SizedBox(height: 18),
          Text(
            _loc.exchangeCompleted,
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 10),
          if (result != null) ...[
            Text(
              '${_loc.exchangeId}: ${result.exchangeDocumentId}',
              style: const TextStyle(color: AppColors.mutedColor),
            ),
            const SizedBox(height: 4),
            Text(
              '${_loc.exchangeOriginalInvoice}: ${widget.originalSale.referenceNumber ?? widget.originalSale.id}',
              style: const TextStyle(color: AppColors.mutedColor),
            ),
            const SizedBox(height: 4),
            Text(
              '${_loc.exchangeReplacementInvoice}: ${result.replacementDocumentReference.isNotEmpty ? result.replacementDocumentReference : result.replacementSaleId}',
              style: const TextStyle(color: AppColors.mutedColor),
            ),
            const SizedBox(height: 4),
            Text(
              '${_loc.exchangeDifference}: ${result.differenceAmount.toStringAsFixed(2)}',
              style: const TextStyle(color: AppColors.mutedColor),
            ),
          ],
          const SizedBox(height: 24),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              OutlinedButton.icon(
                onPressed: () => Navigator.of(context).pop(result),
                icon: const Icon(Icons.receipt_long_rounded),
                label: Text(_loc.exchangeViewExchange),
              ),
              OutlinedButton.icon(
                onPressed: () => Navigator.of(context).pop(
                  result!.copyWith(openReplacementInvoice: true),
                ),
                icon: const Icon(Icons.file_open_rounded),
                label: Text(_loc.exchangeViewReplacementInvoice),
              ),
              ElevatedButton(
                onPressed: () => Navigator.of(context).pop(result),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primaryColor,
                  foregroundColor: Colors.white,
                ),
                child: Text(_loc.exchangeDone),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
