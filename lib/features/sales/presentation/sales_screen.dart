// lib/features/sales/presentation/sales_screen.dart
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:bayaa_pos/core/constants/app_brand.dart';
import 'package:bayaa_pos/l10n/app_localizations.dart';
import 'package:bayaa_pos/core/data/services/persistence_initializer.dart';
import 'package:bayaa_pos/core/data/models/activity_log.dart';
import 'package:bayaa_pos/core/services/activity_logger.dart';
import 'package:bayaa_pos/core/di/dependency_injection.dart';
import 'package:bayaa_pos/core/functions/messege.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:bayaa_pos/features/products/presentation/cubit/product_cubit.dart';

import '../../../core/components/screen_header.dart';
import '../../../core/constants/app_colors.dart';
import '../../auth/presentation/cubit/user_cubit.dart';
import '../../products/data/models/product_model.dart';
import '../../products/data/models/selling_unit_model.dart';
import '../../products/domain/product_catalog_service.dart';
import '../../products/domain/product_repository_int.dart';
import '../data/models/sale_model.dart';
import '../data/models/sale_draft_model.dart';
import '../domain/sales_repository.dart';
import '../../invoice/data/invoice_models.dart';
import '../../invoice/presentation/invoice_preview_screen.dart';
import '../../customers/data/models/customer_model.dart';
import '../../customers/data/repository/customer_repository_impl.dart';

import 'widgets/barcode_scan_card.dart';
import 'widgets/cart_section.dart';
import 'widgets/total_section_card.dart';
import 'widgets/recent_sales.dart';
import 'widgets/product_search_overlay.dart';
import 'widgets/barcode_camera_scanner.dart';
import 'sales_cart_line.dart';
import '../../../../core/session/session_manager.dart';
import '../../../../core/network/authority_context.dart';
import '../../../../core/network/backend_token_store.dart';
import 'package:bayaa_pos/features/invoice/presentation/cubit/invoice_cubit.dart';
import '../../settings/presentation/cubit/settings_cubit.dart';
import 'cubit/draft_sales_cubit.dart';
import 'cubit/draft_sales_state.dart';
import 'sale_draft_grouping.dart';

class SalesScreen extends StatefulWidget {
  final SalesRepository? repository;

  const SalesScreen({super.key, this.repository});

  @override
  State<SalesScreen> createState() => _SalesScreenState();
}

class _SalesScreenState extends State<SalesScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _fadeController;
  late final Animation<double> _fadeAnimation;

  final TextEditingController _barcodeController = TextEditingController();
  final FocusNode _barcodeFocusNode = FocusNode();

  final StringBuffer _hidBuffer = StringBuffer();
  Timer? _hidTimer;

  late final SalesRepository _repository;
  bool _serverMode = false;
  DraftSalesCubit? _draftSalesCubit;
  StreamSubscription<DraftSalesState>? _draftStateSubscription;
  StreamSubscription<List<ActivityLog>>? _activitySubscription;
  Future<void>? _draftReady;
  String? _lastDraftMessage;

  final List<Map<String, dynamic>> _cartItems = [];
  List<Map<String, dynamic>> _recentSales = [];
  List<Product> _filteredProducts = [];
  Customer? _selectedCustomer;
  bool _isRecentSalesCollapsed = false;
  bool _isMobileInvoiceSummaryExpanded = false;

  double get _totalAmount => _cartItems.fold<double>(
        0.0,
        (sum, e) =>
            sum + (e['price'] as num).toDouble() * (e['qty'] as num).toDouble(),
      );
  Timer? _searchDebounce;

  @override
  void initState() {
    super.initState();

    _repository = widget.repository ?? getIt<SalesRepository>();
    _serverMode = getIt.isRegistered<AuthorityContext>() &&
        getIt<AuthorityContext>().usesServerDrafts &&
        getIt.isRegistered<DraftSalesCubit>();
    if (_serverMode) {
      _draftSalesCubit = getIt<DraftSalesCubit>();
      _draftStateSubscription = _draftSalesCubit!.stream.listen(_onDraftState);
      _draftReady = _draftSalesCubit!.initialize();
      _syncCartFromDraftState(logRouteEntry: true);
      unawaited(_draftReady!.then((_) {
        if (mounted) {
          _syncCartFromDraftState();
        }
      }));
    }

    _fadeController = AnimationController(
        duration: const Duration(milliseconds: 800), vsync: this);
    _fadeAnimation =
        CurvedAnimation(parent: _fadeController, curve: Curves.easeInOut);
    _fadeController.forward();

    RawKeyboard.instance.addListener(_onRawKey);
    _loadRecentSales();
    if (getIt.isRegistered<ActivityLogger>()) {
      _activitySubscription =
          getIt<ActivityLogger>().activitiesStream.listen((activities) {
        if (activities.isNotEmpty &&
            activities.first.type == ActivityType.exchange) {
          _loadRecentSales();
        }
      });
    }
  }

  void _onDraftState(DraftSalesState state) {
    if (!mounted || !_serverMode) return;
    final message = state.message;
    if (message != null && message != _lastDraftMessage) {
      _lastDraftMessage = message;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          MotionSnackBarError(context, message);
        }
      });
    } else if (message == null) {
      _lastDraftMessage = null;
    }
    if (state.status == DraftSalesStatus.loading ||
        state.status == DraftSalesStatus.saving) {
      return;
    }
    final draft = state.activeDraft;
    if (draft == null) {
      if (_cartItems.isNotEmpty || _selectedCustomer != null) {
        setState(() {
          _cartItems.clear();
          _selectedCustomer = null;
        });
        debugPrint('[DRAFT_SYNC_TRACE] source=sales-screen-state '
            'clearingStaleActiveDraft=true activeDraftId=${state.activeDraftId} '
            'cartCleared=true');
      }
      return;
    }
    _applyDraftToCart(draft);
  }

  void _syncCartFromDraftState({bool logRouteEntry = false}) {
    if (!_serverMode || _draftSalesCubit == null) return;
    final state = _draftSalesCubit!.state;
    final draft = state.activeDraft;
    if (logRouteEntry) {
      debugPrint('[SALES_SCREEN_SYNC] route-enter '
          'selectedDraftId=${state.activeDraftId} '
          'draftItemCount=${draft?.items.length ?? 0} '
          'cartItemCount=${_cartItems.length}');
    }
    if (draft == null) {
      if (_cartItems.isNotEmpty || _selectedCustomer != null) {
        setState(() {
          _cartItems.clear();
          _selectedCustomer = null;
        });
        debugPrint('[DRAFT_SYNC_TRACE] source=sales-screen-sync '
            'clearingStaleActiveDraft=true activeDraftId=${state.activeDraftId} '
            'cartCleared=true');
      }
      return;
    }
    if (_cartMatchesDraft(draft)) {
      debugPrint('[SALES_SCREEN_SYNC] cart already synchronized '
          'draftId=${draft.id} itemCount=${draft.items.length}');
      return;
    }
    _applyDraftToCart(draft);
    debugPrint('[SALES_SCREEN_SYNC] restored cart from selected draft '
        'draftId=${draft.id} itemCount=${draft.items.length}');
  }

  bool _cartMatchesDraft(SaleDraft draft) {
    if (_cartItems.length != draft.items.length) return false;
    for (final item in draft.items) {
      final lineKey = item.sellingUnitId == null
          ? item.productId
          : '${item.productId}:${item.sellingUnitId}';
      Map<String, dynamic>? line;
      for (final candidate in _cartItems) {
        if (candidate['lineKey'] == lineKey) {
          line = candidate;
          break;
        }
      }
      if (line == null ||
          (line['qty'] as num?)?.toDouble() != item.quantity ||
          (line['price'] as num?)?.toDouble() != item.unitPrice) {
        return false;
      }
    }
    return true;
  }

  void _applyDraftToCart(SaleDraft draft) {
    final productsById = {
      for (final product in getIt<ProductCubit>().allProducts)
        product.id: product,
    };
    final lines = draft.items.map((item) {
      final product = productsById[item.productId];
      final previous = _cartItems.firstWhere(
        (line) => line['productId'] == item.productId,
        orElse: () => const <String, dynamic>{},
      );
      final configuredUnits = product?.sellingUnits
              .where((unit) => unit.isActive)
              .toList(growable: false) ??
          (previous['sellingUnits'] as List?)
              ?.whereType<SellingUnit>()
              .toList(growable: false) ??
          const <SellingUnit>[];
      return {
        'lineKey': item.sellingUnitId == null
            ? item.productId
            : '${item.productId}:${item.sellingUnitId}',
        'id': item.productId,
        'productId': item.productId,
        'displayCode': item.code ?? '',
        'name': item.name,
        'price': item.unitPrice,
        'qty': item.quantity,
        'quantity': item.stock ?? 0.0,
        'stock': item.stock ?? 0.0,
        'wholesalePrice': 0.0,
        'date': draft.updatedAt ?? DateTime.now(),
        'minPrice': 0.0,
        'productType': item.productType ?? 'standard',
        'sellingUnitId': item.sellingUnitId,
        'sellingQuantity': item.quantity,
        'baseQuantity': item.baseQuantity ?? item.quantity,
        'conversionFactorSnapshot': item.conversionFactor ?? 1.0,
        'sellingUnitNameSnapshot': item.unit,
        'sellingUnitIconKey': item.iconKey,
        'baseUnitSnapshot': item.unit,
        'sellingUnits': configuredUnits,
      };
    }).toList();
    setState(() {
      _cartItems
        ..clear()
        ..addAll(lines);
      _selectedCustomer = null;
    });
    debugPrint('[DRAFT_TRACE] event=cart-applied '
        'selectedDraftId=${draft.id} itemCount=${draft.items.length} '
        'itemIds=${draft.items.map((item) => item.productId).join(',')}');
  }

  Future<void> _ensureServerDraft() async {
    if (!_serverMode || _draftSalesCubit == null) return;
    await _draftReady;
    if (_draftSalesCubit!.state.activeDraft == null) {
      await _draftSalesCubit!.newSale();
    }
  }

  Future<void> _persistServerCart() async {
    if (!_serverMode || _draftSalesCubit == null) return;
    final draftId = _draftSalesCubit!.state.activeDraftId;
    if (draftId == null) return;
    final itemIds = _cartItems
        .map((item) => item['productId'] as String? ?? item['id'] as String)
        .join(',');
    debugPrint('[DRAFT_WRITE_TRACE] caller=SalesScreen._persistServerCart '
        'draftId=$draftId reason=cart-edit version='
        '${_draftSalesCubit!.state.activeDraft?.version ?? -1} '
        'itemCount=${_cartItems.length}');
    debugPrint('[DRAFT_TRACE] event=persist-start selectedDraftId=$draftId '
        'targetDraftId=$draftId itemCount=${_cartItems.length} itemIds=$itemIds');
    await _draftSalesCubit!.updateActiveItems(
      _cartItems
          .map(
            (item) => SaleDraftItem(
              productId: item['productId'] as String? ?? item['id'] as String,
              name: item['name'] as String? ?? '',
              quantity: (item['qty'] as num).toDouble(),
              unitPrice: (item['price'] as num).toDouble(),
              unit: item['sellingUnitNameSnapshot'] as String? ?? 'piece',
              baseQuantity: (item['baseQuantity'] as num?)?.toDouble(),
              conversionFactor:
                  (item['conversionFactorSnapshot'] as num?)?.toDouble(),
              sellingUnitId: item['sellingUnitId'] as String?,
              productType: item['productType'] as String?,
              iconKey: item['sellingUnitIconKey'] as String?,
            ),
          )
          .toList(),
      draftId: draftId,
    );
  }

  void _onSearchChanged(String text) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 150), () async {
      final q = text.trim();
      if (q.isEmpty) {
        setState(() => _filteredProducts = []);
        return;
      }

      final productCubit = getIt<ProductCubit>();
      final allProducts = productCubit.allProducts;

      final query = q.toLowerCase();
      final parsedNumber = double.tryParse(q.replaceAll(',', '.'));

      final List<Map<String, dynamic>> scored = [];
      for (final p in allProducts) {
        var score = 0;
        final name = p.name.toLowerCase();
        final barcode = p.barcode.toLowerCase();
        final internalReference = (p.internalReference ?? '').toLowerCase();
        final category = (p.category).toLowerCase();
        final priceStr = p.price.toStringAsFixed(2).toLowerCase();

        if (barcode == query) score += 100;
        if (barcode.startsWith(query)) score += 40;
        if (internalReference == query) score += 100;
        if (internalReference.startsWith(query)) score += 40;
        if (name == query) score += 80;
        if (name.contains(query)) score += 30;
        if (category.contains(query)) score += 20;
        if (priceStr.contains(query)) score += 30;
        if (parsedNumber != null) {
          if ((p.price - parsedNumber).abs() < 0.001) score += 60;
        }

        if (score > 0) scored.add({'product': p, 'score': score});
      }

      scored.sort((a, b) => (b['score'] as int).compareTo(a['score'] as int));

      setState(() => _filteredProducts =
          scored.map((s) => s['product'] as Product).toList());
    });
  }

  Future<void> _commitBarcode(String code) async {
    debugPrint('[BARCODE] lookup started');
    if (code.isEmpty) {
      debugPrint('[BARCODE] lookup failed status=empty barcode');
      return;
    }

    debugPrint('[BARCODE] repository lookup started');
    final result =
        await getIt<ProductRepositoryInt>().findProductByBarcode(code);

    result.fold((failure) {
      debugPrint('[BARCODE] lookup failed status=${failure.message}');
      MotionSnackBarError(context,
          AppLocalizations.of(context).searchErrorMsg(failure.message));
    }, (product) async {
      if (product == null) {
        debugPrint('[BARCODE] lookup failed status=not found');
        MotionSnackBarError(
            context, AppLocalizations.of(context).productNotFound(code));
        _barcodeController.clear();
        setState(() {});
        _barcodeFocusNode.requestFocus();
        return;
      }

      debugPrint('[BARCODE] lookup succeeded');
      await _addResolvedProduct(product);
    });
  }

  Future<void> _scanBarcodeWithCamera() async {
    if (kIsWeb ||
        (defaultTargetPlatform != TargetPlatform.android &&
            defaultTargetPlatform != TargetPlatform.iOS)) {
      return;
    }

    final code = await BarcodeCameraScanner.show(context);
    if (!mounted) {
      debugPrint('[BARCODE] scanner result ignored: screen not mounted');
      return;
    }
    if (code == null || code.isEmpty) {
      debugPrint('[BARCODE] scanner result ignored: empty result');
      return;
    }
    debugPrint('[BARCODE] raw value=$code');
    await _commitBarcode(code);
  }

  Future<void> _addResolvedProduct(Product product) async {
    await _ensureServerDraft();
    if (product.quantity <= 0) {
      MotionSnackBarError(context, AppLocalizations.of(context).outOfStock);
      _barcodeController.clear();
      setState(() {});
      unawaited(_persistServerCart());
      _barcodeFocusNode.requestFocus();
      return;
    }

    SellingUnit? selectedUnit;
    List<SellingUnit>? availableUnits;
    if (product.productType == ProductType.packaged) {
      final units = getIt<AuthorityContext>().readsFromServer
          ? product.sellingUnits
          : await SellingUnitRepository(
              PersistenceInitializer.persistenceManager!.sqliteManager,
            ).listByProduct(product.id, activeOnly: true);
      final activeUnits = units.where((unit) => unit.isActive).toList();
      availableUnits = activeUnits;
      if (activeUnits.isEmpty) {
        MotionSnackBarError(
          context,
          'No active selling units are configured for this product.',
        );
        return;
      }
      // Deterministically choose initial selling unit for packaged products.
      // Prefer the persisted default unit; otherwise use the first active unit.
      selectedUnit = activeUnits.firstWhere(
        (u) => u.isDefault,
        orElse: () => activeUnits.first,
      );
      if (product.matchedSellingUnitId != null) {
        selectedUnit = activeUnits.firstWhere(
          (unit) => unit.id == product.matchedSellingUnitId,
          orElse: () => selectedUnit!,
        );
      }
      // Do not show the selling-unit selection dialog on insertion; the
      // inline selector remains available after insertion for switching.
    }

    final lineKey =
        selectedUnit == null ? product.id : '${product.id}:${selectedUnit.id}';
    final idx = _cartItems.indexWhere((e) => e['lineKey'] == lineKey);

    final qtyStep = product.productType == ProductType.weighted ? 0.1 : 1.0;
    if (idx != -1) {
      final currentQty = (_cartItems[idx]['qty'] as num).toDouble();
      final maxQty =
          product.quantity.toDouble() / (selectedUnit?.conversionToBase ?? 1.0);
      final nextQty = currentQty + qtyStep;
      if (nextQty > maxQty) {
        MotionSnackBarWarning(
          context,
          AppLocalizations.of(context).maxQtyReached(maxQty.toInt()),
        );
        _barcodeController.clear();
        setState(() {});
        _barcodeFocusNode.requestFocus();
        return;
      }
      if (!isValidCartQuantity(_cartItems[idx], nextQty)) {
        MotionSnackBarWarning(
          context,
          'This quantity is not valid for the selected selling unit.',
        );
        return;
      }
      _cartItems[idx]['qty'] = nextQty;
      _cartItems[idx]['sellingQuantity'] = nextQty;
      _cartItems[idx]['baseQuantity'] =
          (nextQty * (selectedUnit?.conversionToBase ?? 1.0));
    } else {
      final line = createSalesCartLine(
        product: product,
        sellingUnit: selectedUnit,
        date: DateTime.now(),
      );
      if (!isValidCartQuantity(line, 1)) {
        MotionSnackBarWarning(
          context,
          'The selected selling unit exceeds available base stock.',
        );
        return;
      }
      _cartItems.add(line);
      _cartItems.last['sellingUnits'] = availableUnits;
    }

    _barcodeController.clear();
    setState(() {});
    if (_serverMode) {
      unawaited(_persistServerCart());
    }
    _barcodeFocusNode.requestFocus();
  }

  void _changeSellingUnit(int index, SellingUnit unit) {
    final item = _cartItems[index];
    try {
      final switched = switchCartSellingUnit(item, unit);
      if (!isValidCartQuantity(
        switched,
        (switched['qty'] as num).toDouble(),
      )) {
        MotionSnackBarWarning(
          context,
          AppLocalizations.of(context).cantAddMoreStock(
            maxSellingQuantity(switched).floor(),
          ),
        );
        return;
      }
      _cartItems[index] = switched;
    } on StateError catch (error) {
      MotionSnackBarWarning(context, error.message);
      return;
    }
    setState(() {});
    unawaited(_persistServerCart());
  }

  Future<void> _removeCartItem(int index) async {
    if (!_serverMode) {
      _cartItems.removeAt(index);
      setState(() {});
      return;
    }
    final removed = _cartItems.removeAt(index);
    setState(() {});
    await _persistServerCart();
    if (_draftSalesCubit?.state.status == DraftSalesStatus.error) {
      _cartItems.insert(index, removed);
      setState(() {});
    }
  }

  void _setCartQuantity(int index, double quantity) {
    if (quantity <= 0) {
      MotionSnackBarError(context, 'Quantity must be greater than zero.');
      return;
    }

    final item = _cartItems[index];
    final maxQuantity = maxSellingQuantity(item);
    if (!isValidCartQuantity(item, quantity)) {
      MotionSnackBarWarning(
        context,
        AppLocalizations.of(context).cantAddMoreStock(maxQuantity.floor()),
      );
      return;
    }
    final conversion =
        (item['conversionFactorSnapshot'] as num?)?.toDouble() ?? 1.0;

    item['qty'] = item['productType'] == 'weighted' ||
            item['productType'] == ProductType.packaged.name
        ? double.parse(quantity.toStringAsFixed(3))
        : quantity.round();
    item['sellingQuantity'] = item['qty'];
    item['baseQuantity'] = (item['qty'] as num).toDouble() * conversion;
    setState(() {});
    unawaited(_persistServerCart());
  }

  void _increaseCartQuantity(int index) {
    final item = _cartItems[index];
    final currentQuantity = (item['qty'] as num).toDouble();
    final step = item['productType'] == 'weighted' ? 0.1 : 1.0;
    _setCartQuantity(index, currentQuantity + step);
  }

  void _decreaseCartQuantity(int index) {
    final item = _cartItems[index];
    final currentQuantity = (item['qty'] as num).toDouble();
    final step = item['productType'] == 'weighted' ? 0.1 : 1.0;
    if (currentQuantity <= step) {
      return;
    }
    _setCartQuantity(index, currentQuantity - step);
  }

  Future<void> _onCheckout() async {
    if (_cartItems.isEmpty) {
      MotionSnackBarError(context, AppLocalizations.of(context).cartEmpty);
      return;
    }

    if (_serverMode &&
        (_draftSalesCubit?.state.activeDraft?.customerId != null ||
            _draftSalesCubit?.state.activeDraft?.customerName != null)) {
      MotionSnackBarError(
        context,
        'This server draft contains a customer identity from local storage. Remove the draft and create a new one before checkout.',
      );
      return;
    }

    final total = _totalAmount;
    final itemCount = _cartItems.length;
    final userName = getIt<UserCubit>().currentUser.name;

    // Show payment method selection dialog
    final paymentMethod = await _showPaymentMethodDialog();
    if (paymentMethod == null) return; // User cancelled

    if (_serverMode && _draftSalesCubit != null) {
      final completedSale = await _draftSalesCubit!.checkoutActive(
        paymentMethod: paymentMethod,
      );
      if (!mounted) return;
      if (completedSale == null) {
        MotionSnackBarError(
          context,
          'Unable to checkout the selected server draft.',
        );
        return;
      }
      MotionSnackBarSuccess(
        context,
        AppLocalizations.of(context).saleCompleted(
          completedSale.total.toStringAsFixed(2),
          AppLocalizations.of(context).currencyEg,
        ),
      );
      _cartItems.clear();
      _selectedCustomer = null;
      setState(() {});
      getIt<InvoiceCubit>().loadSales();
      _openInvoice(completedSale);
      return;
    }

    String? sessionId;
    try {
      sessionId = await getIt<SessionManager>().ensureSessionId(
        userName: userName,
      );
    } catch (_) {}

    final sale = Sale(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      cashierName: userName,
      total: total,
      items: itemCount,
      date: DateTime.now(),
      sessionId: sessionId,
      cashierUsername: getIt<UserCubit>().currentUser.username,
      customerId: _selectedCustomer?.id,
      paymentMethod: paymentMethod,
      saleItems: _cartItems.map((item) {
        final sellingQuantity = (item['sellingQuantity'] as num?)?.toDouble() ??
            (item['qty'] as num).toDouble();
        final conversion =
            (item['conversionFactorSnapshot'] as num?)?.toDouble() ?? 1.0;
        final baseQuantity = (item['baseQuantity'] as num?)?.toDouble() ??
            sellingQuantity * conversion;
        return SaleItem(
          productId: item['productId'] as String? ?? item['id'] as String,
          name: item['name'] as String,
          price: (item['price'] as num).toDouble(),
          quantity: (item['qty'] as num).toDouble(),
          total: (item['price'] as num).toDouble() *
              (item['qty'] as num).toDouble(),
          wholesalePrice: (item['wholesalePrice'] as num?)?.toDouble() ?? 0.0,
          sellingUnitId: item['sellingUnitId'] as String?,
          sellingQuantity: sellingQuantity,
          baseQuantity: baseQuantity,
          conversionFactorSnapshot: conversion,
          sellingUnitNameSnapshot: item['sellingUnitNameSnapshot'] as String?,
          baseUnitSnapshot: item['baseUnitSnapshot'] as String?,
        );
      }).toList(),
    );

    debugPrint(
      '[SALES PAYMENT] total=${sale.total.toStringAsFixed(2)} '
      'discount=${sale.discount.toStringAsFixed(2)} '
      'paid=${(sale.total - sale.discount).toStringAsFixed(2)}',
    );
    final result = await _repository.postSale(sale);

    result.fold(
      (failure) {
        MotionSnackBarError(context,
            AppLocalizations.of(context).saveSaleFailed(failure.message));
        setState(() {});
      },
      (completedSale) async {
        final completedTotal = completedSale.total;
        final completedItemCount = completedSale.items;
        MotionSnackBarSuccess(
          context,
          AppLocalizations.of(context).saleCompleted(
              completedTotal.toStringAsFixed(2),
              AppLocalizations.of(context).currencyEg),
        );

        _recentSales = [
          {
            'total': completedTotal,
            'items': completedItemCount,
            'date': completedSale.date,
            'isRefund': false,
          },
          ..._recentSales,
        ];

        _cartItems.clear();
        _selectedCustomer = null;
        setState(() {});

        getIt<InvoiceCubit>().loadSales();

        _openInvoice(completedSale);
      },
    );
  }

  Future<void> _openInvoice(Sale sale) async {
    final subtotal = sale.saleItems.fold<double>(0, (s, it) => s + it.total);
    final cashierName = sale.cashierName ?? 'Cashier';
    final configuredStoreName =
        getIt<SettingsCubit>().currentStoreInfo?.name;

    final data = InvoiceData(
      invoiceId: sale.id,
      date: sale.date,
      storeName: AppBrand.isDefaultStoreName(configuredStoreName)
          ? AppBrand.name
          : configuredStoreName ?? AppBrand.name,
      storeAddress:
          getIt<SettingsCubit>().currentStoreInfo?.address ?? 'AlKhanaka',
      storePhone:
          getIt<SettingsCubit>().currentStoreInfo?.phone ?? '0100000000',
      cashierName: cashierName,
      lines: sale.saleItems
          .map((it) => InvoiceLine(
                name: it.name,
                price: it.price,
                qty: it.quantity,
              ))
          .toList(),
      subtotal: subtotal,
      discount: 0.0,
      tax: 0.0,
      grandTotal: sale.total,
      paymentMethod: sale.paymentMethod,
    );

    await Navigator.of(context).push(
      PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) =>
            InvoicePreviewScreen(data: data, receiptMode: true),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          return FadeTransition(
            opacity: animation,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0.0, 0.1),
                end: Offset.zero,
              ).animate(
                  CurvedAnimation(parent: animation, curve: Curves.easeOut)),
              child: child,
            ),
          );
        },
      ),
    );
  }

  Future<String?> _showPaymentMethodDialog() {
    final l10n = AppLocalizations.of(context);
    return showDialog<String>(
      context: context,
      builder: (context) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: Container(
          width: 380,
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: AppColors.primaryColor.withOpacity(0.08),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.payments_outlined,
                  color: AppColors.primaryColor,
                  size: 28,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                l10n.paymentMethodTitle,
                style: const TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                l10n.saleCompleted(
                    _totalAmount.toStringAsFixed(2), l10n.currencyEg),
                style: const TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: 12,
                  color: AppColors.textSecondary,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: _PaymentOption(
                      icon: Icons.money,
                      label: l10n.paymentCash,
                      color: Colors.green,
                      onTap: () => Navigator.of(context).pop('cash'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _PaymentOption(
                      icon: Icons.account_balance_wallet,
                      label: l10n.paymentWallet,
                      color: AppColors.primaryColor,
                      onTap: () => Navigator.of(context).pop('wallet'),
                    ),
                  ),
                  if (_selectedCustomer != null) ...[
                    const SizedBox(width: 12),
                    Expanded(
                      child: _PaymentOption(
                        icon: Icons.account_balance,
                        label: l10n.paymentCredit,
                        color: Colors.orange,
                        onTap: () => Navigator.of(context).pop('credit'),
                      ),
                    ),
                  ],
                ],
              ),
              if (_selectedCustomer != null) ...[
                const SizedBox(height: 12),
                Text(
                  l10n.creditSaleHint,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 11,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
              const SizedBox(height: 16),
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(
                  l10n.cancelPayment,
                  style: const TextStyle(
                    fontFamily: 'Cairo',
                    color: AppColors.textSecondary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.backgroundColor,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final isDesktop = constraints.maxWidth > 1100;
            final isTablet =
                constraints.maxWidth >= 768 && constraints.maxWidth <= 1100;
            return Padding(
              padding: EdgeInsets.fromLTRB(
                isDesktop ? 24 : (isTablet ? 16 : 12),
                8,
                isDesktop ? 24 : (isTablet ? 16 : 12),
                isDesktop ? 24 : (isTablet ? 16 : 12),
              ),
              child: (isDesktop || isTablet)
                  ? _buildDesktopTabletLayout(isDesktop)
                  : _buildMobileLayout(),
            );
          },
        ),
      ),
    );
  }

  Widget _buildDesktopTabletLayout(bool isDesktop) {
    final l10n = AppLocalizations.of(context);
    return Directionality(
      textDirection:
          l10n.localeName == 'ar' ? TextDirection.rtl : TextDirection.ltr,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Left Column (POS Scanner + Cart Table)
          Expanded(
            flex: isDesktop ? 7 : 6,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ScreenHeader(
                  title: AppLocalizations.of(context).salesScreenTitle,
                  subtitle: AppLocalizations.of(context).salesScreenSubtitle,
                  fontSize: 30,
                  icon: Icons.point_of_sale,
                  iconColor: AppColors.primaryColor,
                  titleColor: AppColors.textPrimary,
                ),
                const ScreenHeaderGap(height: 16),
                if (_serverMode) _buildServerDraftControls(),
                Expanded(
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const SizedBox(height: 16),
                          Expanded(
                            child: CartSection(
                              cartItems: _cartItems,
                              onRemoveItem: (i) =>
                                  unawaited(_removeCartItem(i)),
                              onIncreaseQty: _increaseCartQuantity,
                              onDecreaseQty: _decreaseCartQuantity,
                              onEditQuantity: _setCartQuantity,
                              onEditPrice: (i, newPrice) {
                                _cartItems[i]['price'] = newPrice;
                                setState(() {});
                                unawaited(_persistServerCart());
                              },
                              onSellingUnitChanged: _changeSellingUnit,
                            ),
                          ),
                        ],
                      ),
                      Positioned(
                        top: 0,
                        left: 0,
                        right: 0,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            BarcodeScanCard(
                              controller: _barcodeController,
                              focusNode: _barcodeFocusNode,
                              onSubmitted: (val) => _commitBarcode(val),
                              onChanged: _onSearchChanged,
                              onScan: _scanBarcodeWithCamera,
                            ),
                            if (_filteredProducts.isNotEmpty)
                              ProductSearchOverlay(
                                products: _filteredProducts,
                                onProductSelected: _addProductFromSearch,
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          SizedBox(width: isDesktop ? 24 : 16),
          // Right Column (Checkout totals + Recent sales)
          Expanded(
            flex: isDesktop ? 3 : 4,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const ScreenHeaderGap(height: 86),
                if (_serverMode)
                  const Text(
                    'Customer selection is unavailable in server mode until customer identity mapping is supported.',
                    textAlign: TextAlign.center,
                  )
                else
                  OutlinedButton.icon(
                    onPressed: _selectCustomer,
                    icon: const Icon(Icons.person_outline),
                    label: Text(
                      _selectedCustomer?.name ??
                          AppLocalizations.of(context).selectCustomer,
                    ),
                  ),
                const SizedBox(height: 10),
                TotalSectionCard(
                  totalAmount: _totalAmount,
                  itemCount: _cartItems.length,
                  onCheckout: _onCheckout,
                  onClearCart: () {
                    _cartItems.clear();
                    setState(() {});
                    unawaited(_persistServerCart());
                  },
                ),
                const SizedBox(height: 16),
                if (!_isRecentSalesCollapsed)
                  Expanded(
                    child: FadeTransition(
                      opacity: _fadeAnimation,
                      child: RecentSalesSection(
                        recentSales: _recentSales,
                        onToggleCollapse: () {
                          setState(() {
                            _isRecentSalesCollapsed = !_isRecentSalesCollapsed;
                          });
                        },
                      ),
                    ),
                  ),
                if (_isRecentSalesCollapsed)
                  InkWell(
                    onTap: () {
                      setState(() {
                        _isRecentSalesCollapsed = false;
                      });
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      decoration: BoxDecoration(
                        color: AppColors.kCardBackground,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: AppColors.borderColor),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.01),
                            blurRadius: 10,
                          ),
                        ],
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.chevron_left,
                              color: AppColors.primaryColor, size: 20),
                          SizedBox(width: 8),
                          Text(
                            AppLocalizations.of(context).showRecentSales,
                            style: TextStyle(
                              color: AppColors.primaryColor,
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMobileLayout() {
    final keyboardVisible = MediaQuery.viewInsetsOf(context).bottom > 0;
    final searchMode = keyboardVisible && _filteredProducts.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!keyboardVisible)
          ScreenHeader(
            title: AppLocalizations.of(context).salesScreenTitle,
            subtitle: AppLocalizations.of(context).salesScreenSubtitle,
            fontSize: 26,
            icon: Icons.point_of_sale,
            iconColor: AppColors.primaryColor,
            titleColor: AppColors.textPrimary,
          ),
        if (!keyboardVisible) const ScreenHeaderGap(height: 12),
        if (_serverMode && !keyboardVisible)
          _buildServerDraftControls(compact: true),
        BarcodeScanCard(
          controller: _barcodeController,
          focusNode: _barcodeFocusNode,
          onSubmitted: (val) => _commitBarcode(val),
          onChanged: _onSearchChanged,
          onScan: _scanBarcodeWithCamera,
        ),
        if (searchMode)
          Expanded(
            child: ProductSearchOverlay(
              products: _filteredProducts,
              onProductSelected: _addProductFromSearch,
              expandToAvailableSpace: true,
            ),
          )
        else ...[
          if (_filteredProducts.isNotEmpty)
            ProductSearchOverlay(
              products: _filteredProducts,
              onProductSelected: _addProductFromSearch,
            ),
          SizedBox(height: keyboardVisible ? 6 : 12),
          Expanded(
            child: CartSection(
              cartItems: _cartItems,
              onRemoveItem: (i) => unawaited(_removeCartItem(i)),
              onIncreaseQty: _increaseCartQuantity,
              onDecreaseQty: _decreaseCartQuantity,
              onEditQuantity: _setCartQuantity,
              onEditPrice: (i, newPrice) {
                _cartItems[i]['price'] = newPrice;
                setState(() {});
                unawaited(_persistServerCart());
              },
              onSellingUnitChanged: _changeSellingUnit,
            ),
          ),
        ],
        if (keyboardVisible && !searchMode)
          _buildKeyboardSummary()
        else if (!keyboardVisible) ...[
          const SizedBox(height: 8),
          _buildMobileInvoiceSummary(),
          const SizedBox(height: 12),
          _buildRecentSalesButton(),
        ],
      ],
    );
  }

  Widget _buildServerDraftControls({bool compact = false}) {
    final state = _draftSalesCubit?.state;
    final drafts = uniqueSaleDrafts(state?.drafts ?? const []);
    final activeId = state?.activeDraftId;
    final activeDraft = state?.activeDraft;
    final tokenStore = getIt<BackendTokenStore>();
    final canChangeVisibility = activeDraft != null &&
        (tokenStore.role?.toLowerCase() == 'admin' ||
            tokenStore.userId == activeDraft.ownerId);
    final draftGroups = groupSaleDrafts(
      drafts,
      userId: tokenStore.userId,
      role: tokenStore.role,
    );
    final groupedDrafts = selectableSaleDrafts(draftGroups);
    final selectedActiveId =
        groupedDrafts.where((draft) => draft.id == activeId).length == 1
            ? activeId
            : null;
    final groupedDraftEntries = [
      for (final group in draftGroups) ...[
        DropdownMenuItem<String>(
          enabled: false,
          child: Text(
            group.title,
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
        ...group.drafts.map(
          (draft) => DropdownMenuItem<String>(
            value: draft.id,
            child: Text(
              '#${draft.saleNumber.toString().padLeft(3, '0')} · '
              '${draft.customerName ?? 'Walk-in Customer'} · '
              '${draft.items.length} items · '
              '${draft.total.toStringAsFixed(2)} DA',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
      ],
    ];
    _logDraftDropdownDiagnostics(
      location: compact
          ? '_buildServerDraftControls.compact'
          : '_buildServerDraftControls.desktop',
      activeId: activeId,
      groupedDrafts: groupedDrafts,
      entries: groupedDraftEntries,
    );
    if (compact) {
      return Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        decoration: BoxDecoration(
          color: AppColors.kCardBackground,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.borderColor),
        ),
        child: Row(
          children: [
            TextButton.icon(
              onPressed: () => _draftSalesCubit?.newSale(),
              icon: const Icon(Icons.add, size: 17),
              label: const Text('New Sale'),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                minimumSize: const Size(0, 34),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
            const SizedBox(width: 2),
            Expanded(
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  isExpanded: true,
                  isDense: true,
                  value: selectedActiveId,
                  hint: const Text(
                    'Open Sales',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  selectedItemBuilder: (context) => [
                    for (final group in draftGroups) ...[
                      const SizedBox.shrink(),
                      ...group.drafts.map(
                        (draft) => Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: Text(
                            '#${draft.saleNumber.toString().padLeft(3, '0')} · '
                            '${draft.customerName ?? 'Walk-in Customer'} · '
                            '${draft.items.length} items',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                  items: groupedDraftEntries,
                  onChanged: (id) {
                    if (id != null) _draftSalesCubit?.selectDraft(id);
                  },
                ),
              ),
            ),
            IconButton(
              onPressed: activeDraft == null
                  ? null
                  : () => _draftSalesCubit?.clearActive(),
              tooltip: 'Clear Sale',
              icon: const Icon(Icons.delete_outline, size: 19),
              color: AppColors.kDangerRed,
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.all(5),
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            ),
            if (canChangeVisibility)
              IconButton(
                onPressed: () => _draftSalesCubit?.toggleActiveVisibility(),
                tooltip: activeDraft.visibility == SaleDraftVisibility.shared
                    ? 'Make Private'
                    : 'Share Sale',
                icon: Icon(
                  activeDraft.visibility == SaleDraftVisibility.shared
                      ? Icons.lock_outline
                      : Icons.share_outlined,
                  size: 18,
                ),
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.all(5),
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              ),
          ],
        ),
      );
    }
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Wrap(
          spacing: 6,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            TextButton.icon(
              onPressed: () => _draftSalesCubit?.newSale(),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('New Sale'),
            ),
            SizedBox(
              width: 220,
              child: DropdownButton<String>(
                isExpanded: true,
                value: selectedActiveId,
                hint: const Text('Open Sales'),
                items: [
                  for (final group in draftGroups) ...[
                    DropdownMenuItem<String>(
                      enabled: false,
                      child: Text(
                        group.title,
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                    ...group.drafts.map(
                      (draft) => DropdownMenuItem<String>(
                        value: draft.id,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              '#${draft.saleNumber.toString().padLeft(3, '0')}  '
                              '${draft.customerName ?? 'Walk-in Customer'}'
                              '${draft.ownerName == null ? '' : ' · ${draft.ownerName}'}',
                              overflow: TextOverflow.ellipsis,
                              style:
                                  const TextStyle(fontWeight: FontWeight.w600),
                            ),
                            Text(
                              '${draft.items.length} items · '
                              '${draft.total.toStringAsFixed(2)} DA · '
                              '${draft.isHeld ? 'HELD' : 'OPEN'}',
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ],
                onChanged: (id) {
                  if (id != null) _draftSalesCubit?.selectDraft(id);
                },
              ),
            ),
            TextButton.icon(
              onPressed: state?.activeDraft == null
                  ? null
                  : () => _draftSalesCubit?.clearActive(),
              icon: const Icon(Icons.delete_outline, size: 18),
              label: const Text('Clear Sale'),
            ),
            if (canChangeVisibility)
              TextButton.icon(
                onPressed: () => _draftSalesCubit?.toggleActiveVisibility(),
                icon: Icon(
                  activeDraft.visibility == SaleDraftVisibility.shared
                      ? Icons.lock_outline
                      : Icons.share_outlined,
                  size: 18,
                ),
                label: Text(
                  activeDraft.visibility == SaleDraftVisibility.shared
                      ? 'Make Private'
                      : 'Share Sale',
                ),
              ),
            if (state?.activeDraft != null)
              Text(
                'Customer: ${state!.activeDraft!.customerName ?? 'Walk-in Customer'}',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            if (state?.status == DraftSalesStatus.conflict)
              const Text(
                'Draft refreshed',
                style: TextStyle(color: Colors.orange),
              ),
          ],
        ),
      ),
    );
  }

  void _logDraftDropdownDiagnostics({
    required String location,
    required String? activeId,
    required List<SaleDraft> groupedDrafts,
    required List<DropdownMenuItem<String>> entries,
  }) {
    final values = entries
        .map((entry) => entry.value)
        .whereType<String>()
        .toList(growable: false);
    final counts = <String, int>{};
    for (final value in values) {
      counts[value] = (counts[value] ?? 0) + 1;
    }
    final duplicates = counts.entries
        .where((entry) => entry.value > 1)
        .map((entry) => '${entry.key} x${entry.value}')
        .toList(growable: false);
    debugPrint('[DRAFT_DROPDOWN] location=$location '
        'activeId=$activeId '
        'draftIds=${groupedDrafts.map((draft) => draft.id).toList()} '
        'itemValues=$values duplicates=$duplicates '
        'itemCount=${entries.length}');
  }

  Widget _buildMobileInvoiceSummary() {
    final l10n = AppLocalizations.of(context);

    return Material(
      color: AppColors.kCardBackground,
      borderRadius: BorderRadius.circular(10),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => setState(() {
          _isMobileInvoiceSummaryExpanded = !_isMobileInvoiceSummaryExpanded;
        }),
        child: AnimatedSize(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          alignment: Alignment.topCenter,
          child: Container(
            padding: EdgeInsets.fromLTRB(
              10,
              _isMobileInvoiceSummaryExpanded ? 8 : 4,
              6,
              _isMobileInvoiceSummaryExpanded ? 8 : 4,
            ),
            decoration: BoxDecoration(
              border: Border.all(color: AppColors.borderColor),
              borderRadius: BorderRadius.circular(10),
            ),
            child: _isMobileInvoiceSummaryExpanded
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              l10n.invoiceSummaryTitle,
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 14,
                              ),
                            ),
                          ),
                          const Icon(Icons.keyboard_arrow_down, size: 20),
                        ],
                      ),
                      const SizedBox(height: 6),
                      _buildMobileSummaryRow(
                        l10n.itemCountLabel,
                        l10n.itemCountValue(_cartItems.length),
                      ),
                      const SizedBox(height: 4),
                      _buildMobileSummaryRow(
                        l10n.subtotalLabel,
                        l10n.priceWithCurrency(
                          _totalAmount.toStringAsFixed(2),
                          l10n.currencyEg,
                        ),
                      ),
                      const SizedBox(height: 4),
                      _buildMobileSummaryRow(
                        l10n.grandTotalLabel,
                        l10n.priceWithCurrency(
                          _totalAmount.toStringAsFixed(2),
                          l10n.currencyEg,
                        ),
                        emphasize: true,
                      ),
                      const SizedBox(height: 7),
                      Row(
                        children: [
                          Expanded(
                            child: ElevatedButton.icon(
                              onPressed: _onCheckout,
                              icon: const Icon(
                                Icons.check_circle_outline,
                                size: 17,
                              ),
                              label: Text(
                                l10n.checkoutBtn,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              style: ElevatedButton.styleFrom(
                                minimumSize: const Size(0, 34),
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 8),
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          IconButton(
                            onPressed:
                                _cartItems.isEmpty ? null : _clearMobileCart,
                            tooltip: l10n.clearCartBtn,
                            icon: const Icon(Icons.delete_outline, size: 19),
                            color: AppColors.kDangerRed,
                            visualDensity: VisualDensity.compact,
                            padding: const EdgeInsets.all(5),
                            constraints: const BoxConstraints(
                              minWidth: 34,
                              minHeight: 34,
                            ),
                          ),
                        ],
                      ),
                    ],
                  )
                : Row(
                    children: [
                      Expanded(
                        child: Text(
                          l10n.itemCountValue(_cartItems.length),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppColors.mutedColor,
                            fontSize: 12,
                          ),
                        ),
                      ),
                      Flexible(
                        child: Text(
                          l10n.priceWithCurrency(
                            _totalAmount.toStringAsFixed(2),
                            l10n.currencyEg,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.end,
                          style: TextStyle(
                            color: AppColors.primaryColor,
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      const Icon(Icons.keyboard_arrow_up, size: 20),
                    ],
                  ),
          ),
        ),
      ),
    );
  }

  void _clearMobileCart() {
    _cartItems.clear();
    setState(() {});
    unawaited(_persistServerCart());
  }

  Widget _buildMobileSummaryRow(
    String label,
    String value, {
    bool emphasize = false,
  }) {
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: emphasize ? AppColors.textPrimary : AppColors.mutedColor,
              fontSize: 12,
              fontWeight: emphasize ? FontWeight.bold : FontWeight.normal,
            ),
          ),
        ),
        Flexible(
          child: Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.end,
            style: TextStyle(
              color: emphasize ? AppColors.primaryColor : AppColors.textPrimary,
              fontSize: emphasize ? 15 : 12,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildKeyboardSummary() {
    final l10n = AppLocalizations.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.kCardBackground,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.borderColor),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              l10n.priceWithCurrency(
                _totalAmount.toStringAsFixed(2),
                l10n.currencyEg,
              ),
              style: const TextStyle(
                color: AppColors.primaryColor,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          IconButton(
            onPressed: _cartItems.isEmpty
                ? null
                : () {
                    _cartItems.clear();
                    setState(() {});
                    unawaited(_persistServerCart());
                  },
            tooltip: l10n.clearCartBtn,
            icon: const Icon(Icons.delete_outline),
            color: AppColors.kDangerRed,
            visualDensity: VisualDensity.compact,
          ),
          const SizedBox(width: 2),
          Expanded(
            child: ElevatedButton(
              onPressed: _onCheckout,
              style: ElevatedButton.styleFrom(
                minimumSize: const Size(0, 36),
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
              child: Text(
                l10n.checkoutBtn,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRecentSalesButton() {
    return InkWell(
      onTap: () {
        showModalBottomSheet(
          context: context,
          backgroundColor: Colors.transparent,
          builder: (context) => Container(
            decoration: const BoxDecoration(
              color: AppColors.backgroundColor,
              borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
            ),
            padding: const EdgeInsets.all(16),
            child: RecentSalesSection(
              recentSales: _recentSales,
            ),
          ),
        );
      },
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: AppColors.primaryColor.withOpacity(0.08),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.primaryColor.withOpacity(0.2)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.history, color: AppColors.primaryColor, size: 18),
            const SizedBox(width: 8),
            Text(
              AppLocalizations.of(context).recentSalesLabel,
              style: const TextStyle(
                color: AppColors.primaryColor,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _onRawKey(RawKeyEvent event) {
    if (event is! RawKeyDownEvent) return;
    if (_barcodeFocusNode.hasFocus) return;

    final primary = FocusManager.instance.primaryFocus;
    if (primary != null && primary != _barcodeFocusNode) return;

    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      _hidTimer?.cancel();
      final code = _hidBuffer.toString().trim();
      _hidBuffer.clear();
      _commitBarcode(code);
      return;
    }

    String? ch = event.character;
    if ((ch == null || ch.isEmpty) && event.logicalKey.keyLabel.length == 1) {
      ch = event.logicalKey.keyLabel;
    }

    if (ch != null && ch.isNotEmpty && ch.codeUnitAt(0) >= 32) {
      _hidBuffer.write(ch);
      _barcodeController.text = _hidBuffer.toString();
    }

    _hidTimer?.cancel();
    _hidTimer = Timer(const Duration(milliseconds: 120), () {
      final code = _hidBuffer.toString().trim();
      _hidBuffer.clear();
      _commitBarcode(code);
    });
  }

  Future<void> _addProductFromSearch(Product product) async {
    await _addResolvedProduct(product);
    if (!mounted) return;
    setState(() => _filteredProducts = []);
    _barcodeController.clear();
    _barcodeFocusNode.requestFocus();
  }

  Future<void> _selectCustomer() async {
    if (_serverMode) {
      MotionSnackBarError(
        context,
        'Customer selection is unavailable in server mode until customer identity mapping is supported.',
      );
      return;
    }
    final customer = await showDialog<Customer?>(
      context: context,
      builder: (_) => _CustomerPicker(
        repository: getIt<CustomerRepository>(),
        selectedCustomerId: _selectedCustomer?.id,
      ),
    );
    if (!mounted) return;
    setState(() => _selectedCustomer = customer);
  }

  Future<void> _loadRecentSales() async {
    final result = await _repository.getRecentSales(limit: 10);
    result.fold(
      (_) {},
      (sales) {
        if (mounted) {
          setState(() {
            _recentSales = sales
                .map((s) => {
                      'total': s.total,
                      'items': s.items,
                      'date': s.date,
                      'isRefund': s.isRefund,
                    })
                .toList();
          });
        }
      },
    );
  }

  @override
  void dispose() {
    RawKeyboard.instance.removeListener(_onRawKey);
    _draftStateSubscription?.cancel();
    _activitySubscription?.cancel();
    _hidTimer?.cancel();
    _searchDebounce?.cancel();
    _barcodeController.dispose();
    _barcodeFocusNode.dispose();
    _fadeController.dispose();
    super.dispose();
  }
}

class _CustomerPicker extends StatefulWidget {
  const _CustomerPicker({
    required this.repository,
    required this.selectedCustomerId,
  });

  final CustomerRepository repository;
  final String? selectedCustomerId;

  @override
  State<_CustomerPicker> createState() => _CustomerPickerState();
}

class _CustomerPickerState extends State<_CustomerPicker> {
  final _searchController = TextEditingController();
  List<Customer> _customers = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load([String query = '']) async {
    setState(() => _loading = true);
    final result = query.trim().isEmpty
        ? await widget.repository.getAllCustomers()
        : await widget.repository.searchCustomers(query);
    if (!mounted) return;
    result.fold(
      (_) => setState(() {
        _customers = [];
        _loading = false;
      }),
      (customers) => setState(() {
        _customers = customers;
        _loading = false;
      }),
    );
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l10n.selectCustomer),
      content: SizedBox(
        width: 420,
        height: 420,
        child: Column(
          children: [
            TextField(
              controller: _searchController,
              decoration: InputDecoration(
                labelText: l10n.search,
                prefixIcon: const Icon(Icons.search),
              ),
              onChanged: _load,
            ),
            const SizedBox(height: 8),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : ListView(
                      children: [
                        ListTile(
                          leading: const Icon(Icons.person_off_outlined),
                          title: Text(l10n.anonymousSale),
                          onTap: () => Navigator.pop(context, null),
                        ),
                        ..._customers.map(
                          (customer) => ListTile(
                            selected: customer.id == widget.selectedCustomerId,
                            title: Text(customer.name),
                            subtitle:
                                Text('${customer.code} | ${customer.phone}'),
                            onTap: () => Navigator.pop(context, customer),
                          ),
                        ),
                      ],
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.cancel),
        ),
      ],
    );
  }
}

class _PaymentOption extends StatelessWidget {
  const _PaymentOption({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: color.withOpacity(0.06),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 18),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: color.withOpacity(0.2)),
          ),
          child: Column(
            children: [
              Icon(icon, color: color, size: 30),
              const SizedBox(height: 8),
              Text(
                label,
                style: TextStyle(
                  fontFamily: 'Cairo',
                  fontWeight: FontWeight.w800,
                  fontSize: 14,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
