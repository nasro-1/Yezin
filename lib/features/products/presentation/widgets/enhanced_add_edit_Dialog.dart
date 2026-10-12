import 'package:bayaa_pos/core/data/services/persistence_initializer.dart';
import 'package:bayaa_pos/features/products/data/models/product_model.dart';
import 'package:bayaa_pos/features/products/data/models/selling_unit_model.dart';
import 'package:bayaa_pos/features/products/domain/product_catalog_service.dart';
import 'package:bayaa_pos/core/components/local_image_view.dart';
import 'package:bayaa_pos/core/data/services/local_image_storage.dart';
import 'package:bayaa_pos/core/network/backend_api_config.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/di/dependency_injection.dart';
import '../../../../l10n/app_localizations.dart';
import '../../../notifications/presentation/cubit/notifications_cubit.dart';
import '../../../auth/presentation/cubit/user_cubit.dart';
import '../cubit/product_cubit.dart';
import 'product_stock_adjustment_dialog.dart';
import 'selling_unit_icon.dart';
import '../../../sales/presentation/widgets/barcode_camera_scanner.dart';

class _PackageUnitPreset {
  final String value;
  final String label;
  final double defaultConversion;

  const _PackageUnitPreset({
    required this.value,
    required this.label,
    required this.defaultConversion,
  });
}

class _SellingUnitDraft {
  final String draftKey;
  String? id;
  String name;
  double conversionToBase;
  double sellingPrice;
  double? wholesalePrice;
  double? costPrice;
  double minimumStock;
  String iconKey;
  bool isDefault;
  bool isActive;

  _SellingUnitDraft({
    required this.draftKey,
    this.id,
    required this.name,
    required this.conversionToBase,
    required this.sellingPrice,
    this.wholesalePrice,
    this.costPrice,
    this.minimumStock = 0,
    String? iconKey,
    this.isDefault = false,
    this.isActive = true,
  }) : iconKey = (iconKey == null || iconKey.trim().isEmpty)
            ? defaultSellingUnitIconKey(name)
            : iconKey.trim().toLowerCase();
}

class _OpeningStockDraft {
  String unit;
  final TextEditingController quantity;
  final TextEditingController cost;

  _OpeningStockDraft({
    required this.unit,
    String quantityText = '',
    String costText = '',
  })  : quantity = TextEditingController(text: quantityText),
        cost = TextEditingController(text: costText);

  void dispose() {
    quantity.dispose();
    cost.dispose();
  }
}

class EnhancedAddEditProductDialog extends StatefulWidget {
  final List<String> categories;
  final Product? productToEdit;

  const EnhancedAddEditProductDialog({
    super.key,
    required this.categories,
    this.productToEdit,
  });

  @override
  State<EnhancedAddEditProductDialog> createState() =>
      _EnhancedAddEditProductDialogState();
}

class _EnhancedAddEditProductDialogState
    extends State<EnhancedAddEditProductDialog> {
  static const _weightedUnits = ['g', 'kg', 'mg', 'ton', 'ml', 'L'];
  static const List<_PackageUnitPreset> _packagedSellingUnitPresets = [
    _PackageUnitPreset(value: 'piece', label: 'piece', defaultConversion: 1),
    _PackageUnitPreset(value: 'pack', label: 'pack', defaultConversion: 30),
    _PackageUnitPreset(value: 'box', label: 'box', defaultConversion: 360),
  ];
  late final TextEditingController? codeCtrl;
  late final TextEditingController nameCtrl;
  late final TextEditingController barcodeCtrl;
  late final TextEditingController priceCtrl;
  late final TextEditingController minQtyCtrl;
  late final TextEditingController minPriceCtrl;
  late final TextEditingController wholesalePriceCtrl;
  late final TextEditingController costCtrl;
  late final TextEditingController openingQuantityCtrl;
  late final TextEditingController openingCostCtrl;
  late final TextEditingController openingNotesCtrl;

  late String selectedCategory;
  String? _selectedImagePath;
  bool _isSubmitting = false;
  final _formKey = GlobalKey<FormState>();
  ProductType _selectedProductType = ProductType.standard;
  String _baseUnit = 'piece';
  bool _allowPartialPackageSale = false;
  bool _openingStockEnabled = false;
  int _mobileStep = 0;
  String _openingReason = 'initial_inventory';
  String _initialStockUnit = 'piece';
  final List<_SellingUnitDraft> _sellingUnits = [];
  int _nextDraftKey = 0;
  Future<void>? _sellingUnitsLoadFuture;
  String? _internalReference;
  String _weightedBaseUnit = 'kg';
  String _packagedBaseUnit = 'piece';
  bool _isClosing = false;
  final List<_OpeningStockDraft> _openingLines = [];

  bool _isAllCategory(String value) =>
      value == 'All' || value == 'الكل' || value == '*';

  @override
  void initState() {
    super.initState();
    final p = widget.productToEdit;
    nameCtrl = TextEditingController(text: p?.name ?? '');
    barcodeCtrl = TextEditingController(text: p?.barcode ?? '');
    priceCtrl = TextEditingController(text: p?.price.toString() ?? '');
    minQtyCtrl = TextEditingController(text: p?.minQuantity.toString() ?? '');
    minPriceCtrl = TextEditingController(text: p?.minPrice.toString() ?? '');
    wholesalePriceCtrl =
        TextEditingController(text: p?.wholesalePrice.toString() ?? '');
    costCtrl = TextEditingController(text: p == null ? '' : p.cost.toString());
    openingQuantityCtrl = TextEditingController();
    openingCostCtrl = TextEditingController();
    openingNotesCtrl = TextEditingController();
    _selectedImagePath = p?.imagePath;
    _selectedProductType = p?.productType ?? ProductType.standard;
    _baseUnit = p?.baseUnit ?? 'piece';
    _weightedBaseUnit =
        p?.productType == ProductType.weighted ? _baseUnit : 'kg';
    _packagedBaseUnit =
        p?.productType == ProductType.packaged ? _baseUnit : 'piece';
    _allowPartialPackageSale = p?.allowPartialPackageSale ?? false;
    _internalReference = p?.internalReference;

    final validCategories =
        widget.categories.where((c) => !_isAllCategory(c)).toList();
    final editingCategory = p?.categoryName ?? p?.category;
    if (editingCategory != null &&
        !_isAllCategory(editingCategory) &&
        validCategories.contains(editingCategory)) {
      selectedCategory = editingCategory;
    } else {
      selectedCategory =
          validCategories.isNotEmpty ? validCategories.first : '';
    }

    if (p == null) {
      _internalReference = null;
      if (_selectedProductType == ProductType.packaged) {
        _openingStockEnabled = true;
      }
    } else if (!validCategories.contains(editingCategory) &&
        BackendApiConfig.productReadMode != ProductReadMode.server) {
      _loadEditingCategoryName(p.category);
    }
    if (_selectedProductType == ProductType.packaged && p != null) {
      _sellingUnitsLoadFuture = _loadSellingUnits(p.id);
    }
    if (p == null) {
      _openingLines.add(_OpeningStockDraft(unit: 'pack'));
    }
  }

  Future<void> _loadEditingCategoryName(String categoryId) async {
    final db = PersistenceInitializer.persistenceManager!.sqliteManager;
    final rows = await db.database.query(
      'categories',
      columns: ['name'],
      where: 'id = ?',
      whereArgs: [categoryId],
      limit: 1,
    );
    if (!mounted || rows.isEmpty) return;
    final name = rows.single['name'] as String;
    if (widget.categories.contains(name)) {
      setState(() => selectedCategory = name);
    }
  }

  bool get _canScanBarcode =>
      widget.productToEdit == null &&
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  Future<void> _scanBarcode() async {
    final barcode = await BarcodeCameraScanner.show(context);
    if (!mounted || barcode == null || barcode.trim().isEmpty) return;
    final normalizedBarcode = barcode.trim();
    barcodeCtrl.value = TextEditingValue(
      text: normalizedBarcode,
      selection: TextSelection.collapsed(offset: normalizedBarcode.length),
    );
  }

  @override
  void dispose() {
    nameCtrl.dispose();
    barcodeCtrl.dispose();
    priceCtrl.dispose();
    minQtyCtrl.dispose();
    minPriceCtrl.dispose();
    wholesalePriceCtrl.dispose();
    costCtrl.dispose();
    openingQuantityCtrl.dispose();
    openingCostCtrl.dispose();
    for (final line in _openingLines) {
      line.dispose();
    }
    openingNotesCtrl.dispose();
    super.dispose();
  }

  void _closeDialog() {
    if (!mounted || _isClosing) return;
    _isClosing = true;
    FocusManager.instance.primaryFocus?.unfocus();
    Navigator.of(context).pop();
  }

  Future<void> _submit() async {
    if (!mounted || _isClosing || _isSubmitting) return;
    FocusManager.instance.primaryFocus?.unfocus();
    if (_sellingUnitsLoadFuture != null) {
      await _sellingUnitsLoadFuture;
      if (!mounted) return;
    }
    _ensurePackagedDefault();
    if (kDebugMode) debugPrint('PRODUCT SUBMIT START');
    final formValid = _selectedProductType == ProductType.packaged
        ? _validatePackagedIdentityFields()
        : _formKey.currentState!.validate();
    if (kDebugMode && !formValid) {
      final invalidFields = _formKey.currentState!.validateGranularly();
      for (final field in invalidFields) {
        final inputDecorator =
            field.context.findAncestorWidgetOfExactType<InputDecorator>();
        debugPrint(
          'PRODUCT INVALID FIELD: '
          'type=${field.widget.runtimeType}, '
          'label=${inputDecorator?.decoration.labelText}, '
          'value=${field.value}, error=${field.errorText}',
        );
      }
    }
    if (kDebugMode) debugPrint('PRODUCT FORM VALID = $formValid');
    if (!formValid) {
      _showSubmissionMessage(
        AppLocalizations.of(context).productSubmissionCorrectFields,
      );
      return;
    }
    final configurationError = _productConfigurationError();
    final configValid = configurationError == null;
    if (kDebugMode) debugPrint('PRODUCT CONFIG VALID = $configValid');
    if (!configValid) {
      _showSubmissionMessage(configurationError);
      return;
    }

    final barcode = barcodeCtrl.text.trim();

    if (BackendApiConfig.productWriteMode == ProductWriteMode.local &&
        widget.productToEdit == null &&
        _selectedProductType != ProductType.packaged) {
      if (!mounted) return;
      final exists = await getIt<ProductCubit>().checkProductExists(barcode);
      if (!mounted) return;

      if (barcode.isNotEmpty && exists) {
        final l10n = AppLocalizations.of(context);
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Row(children: [
              const Icon(Icons.error_outline, color: AppColors.errorColor),
              const SizedBox(width: 8),
              Text(l10n.barcodeError),
            ]),
            content: Text(l10n.barcodeExistsMessage(barcode)),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(l10n.ok),
              )
            ],
          ),
        );
        return;
      }
    }

    if (_isSubmitting) return;
    setState(() => _isSubmitting = true);

    final productBarcode = barcode;

    try {
      var storedImagePath = _selectedImagePath;
      if (storedImagePath != null &&
          storedImagePath != widget.productToEdit?.imagePath) {
        storedImagePath = await LocalImageStorage.persist(
          sourcePath: storedImagePath,
          collection: 'products',
          key: productBarcode,
        );
      }

      final serverWriteMode =
          BackendApiConfig.productWriteMode == ProductWriteMode.server;
      final reference = widget.productToEdit?.internalReference ??
          _internalReference ??
          (serverWriteMode
              ? null
              : await ProductCatalogRepository(
                  PersistenceInitializer.persistenceManager!.sqliteManager,
                ).generateInternalReference());
      late final String categoryId;
      if (serverWriteMode) {
        final serverCategoryId =
            getIt<ProductCubit>().resolveServerCategoryId(selectedCategory);
        if (serverCategoryId == null) {
          if (!mounted) return;
          _showSubmissionMessage('Select a valid server category');
          return;
        }
        categoryId = serverCategoryId;
      } else {
        final categoryResult =
            await getIt<ProductCubit>().resolveCategoryId(selectedCategory);
        if (categoryResult.isLeft) {
          if (!mounted) return;
          _showSubmissionMessage(categoryResult.left.message);
          return;
        }
        categoryId = categoryResult.right;
      }
      final isPackaged = _selectedProductType == ProductType.packaged;
      final productSave = Product(
        id: widget.productToEdit?.id ??
            'product-${DateTime.now().microsecondsSinceEpoch}',
        internalReference: reference,
        productType: _selectedProductType,
        baseUnit: _baseUnit.isNotEmpty ? _baseUnit : 'piece',
        quantityPrecision: 3,
        allowPartialPackageSale: _allowPartialPackageSale,
        wholesalePrice: isPackaged
            ? 0.0
            : double.tryParse(wholesalePriceCtrl.text.trim()) ?? 0.0,
        minPrice:
            isPackaged ? 0.0 : double.tryParse(minPriceCtrl.text.trim()) ?? 0.0,
        name: nameCtrl.text.trim(),
        barcode: productBarcode,
        price: isPackaged ? 0.0 : double.tryParse(priceCtrl.text.trim()) ?? 0.0,
        cost: isPackaged ? 0.0 : widget.productToEdit?.cost ?? 0.0,
        quantity: isPackaged ? 0 : widget.productToEdit?.quantity ?? 0,
        minQuantity: isPackaged ? 0 : int.tryParse(minQtyCtrl.text.trim()) ?? 0,
        category: categoryId,
        imagePath: storedImagePath,
      );

      final openingQuantity = (_openingStockEnabled
              ? (isPackaged
                  ? 0
                  : double.tryParse(openingQuantityCtrl.text.trim()) ?? 0)
              : 0.0)
          .toDouble();
      final double openingCost = _openingStockEnabled
          ? (isPackaged
              ? 0
              : double.tryParse(openingCostCtrl.text.trim()) ?? 0.0)
          : 0.0;
      final openingLines = isPackaged && _openingStockEnabled
          ? _openingLines
              .where((line) =>
                  line.quantity.text.trim().isNotEmpty ||
                  line.cost.text.trim().isNotEmpty)
              .map((line) => OpeningStockLine(
                    unit: line.unit,
                    quantity: double.tryParse(line.quantity.text.trim()) ?? 0,
                    unitCost: double.tryParse(line.cost.text.trim()) ?? 0,
                  ))
              .toList()
          : null;
      final openingNotes = openingNotesCtrl.text.trim();
      final submittedPackagedSellingUnits = isPackaged
          ? _sellingUnits.asMap().entries.map(
              (entry) {
                final unit = entry.value;
                return SellingUnit(
                  id: unit.id ?? 'unit-${productSave.id}-${entry.key}',
                  productId: productSave.id,
                  name: unit.name,
                  conversionToBase: unit.conversionToBase,
                  sellingPrice: unit.sellingPrice,
                  cost: unit.costPrice ?? 0,
                  wholesalePrice: unit.wholesalePrice,
                  minimumStock: unit.minimumStock,
                  iconKey: unit.iconKey,
                  isDefault: unit.isDefault,
                  isActive: unit.isActive,
                );
              },
            ).toList()
          : null;
      final saveResult = widget.productToEdit == null
          ? await getIt<ProductCubit>().saveProductWithOpeningStock(
              productSave,
              openingQuantity: openingQuantity,
              openingUnitCost: openingCost,
              openingReason: _openingReasonLabel(),
              openingNotes: openingNotes,
              openingUnit: isPackaged ? _initialStockUnit : null,
              user: getIt<UserCubit>().currentUser,
              packagedSellingUnits: submittedPackagedSellingUnits,
              openingLines: openingLines,
            )
          : await getIt<ProductCubit>().saveProduct(
              productSave,
              packagedSellingUnits: submittedPackagedSellingUnits,
            );
      if (kDebugMode) {
        debugPrint(
          'PRODUCT SAVE RESULT = ${saveResult.isRight ? 'success' : 'failure'}',
        );
      }
      if (saveResult.isLeft) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(saveResult.left.message)),
        );
        return;
      }

      if (!mounted) return;
      final savedProduct = getIt<ProductCubit>().products.firstWhere(
            (product) => product.id == productSave.id,
            orElse: () => productSave,
          );
      getIt<NotificationsCubit>().addItem(savedProduct);
      _closeDialog();
    } catch (e) {
      if (!mounted) return;
      setState(() => _isSubmitting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString())),
      );
      return;
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  bool _validatePackagedIdentityFields() {
    final hasName = nameCtrl.text.trim().isNotEmpty;
    final hasCategory =
        selectedCategory.trim().isNotEmpty && selectedCategory != 'All';
    if (hasName && hasCategory) return true;

    _formKey.currentState!.validate();
    return false;
  }

  void _showSubmissionMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _ensurePackagedDefault() {
    if (_selectedProductType != ProductType.packaged) return;
    final activeUnits = _sellingUnits.where((unit) => unit.isActive).toList();
    if (activeUnits.isEmpty) return;

    final existingDefault = activeUnits.cast<_SellingUnitDraft?>().firstWhere(
          (unit) => unit!.isDefault,
          orElse: () => null,
        );
    final acquisitionUnits = activeUnits
        .where((unit) => unit.name.toLowerCase() != 'piece')
        .toList();
    final defaultUnit = existingDefault ??
        (acquisitionUnits.isNotEmpty
            ? acquisitionUnits.first
            : activeUnits.first);
    if (!acquisitionUnits.any(
        (unit) => unit.name.toLowerCase() == _initialStockUnit.toLowerCase())) {
      _initialStockUnit = defaultUnit.name;
    }
    for (final unit in activeUnits) {
      unit.isDefault = identical(unit, defaultUnit);
    }
  }

  String? _productConfigurationError() {
    final l10n = AppLocalizations.of(context);
    if (_selectedProductType == ProductType.weighted) {
      if (_baseUnit.trim().isEmpty) return l10n.productWeightedBaseUnitRequired;
      if ((double.tryParse(priceCtrl.text.trim()) ?? 0) <= 0) {
        return l10n.productWeightedPriceRequired;
      }
    }

    if (_selectedProductType == ProductType.packaged) {
      final activeUnits = _sellingUnits.where((unit) => unit.isActive).toList();
      final activeDefaults = activeUnits.where((unit) => unit.isDefault).length;

      if (activeUnits.isEmpty) return l10n.productPackagedSellingUnitRequired;
      if (activeDefaults != 1) {
        return l10n.productPackagedDefaultUnitRequired;
      }

      for (final unit in activeUnits) {
        final contains = unit.conversionToBase;

        if (contains <= 0) return l10n.productPackagedContainsInvalid;
        if (unit.costPrice != null && unit.costPrice! < 0) {
          return l10n.productPackagedCostInvalid;
        }
        if (unit.sellingPrice < 0)
          return l10n.productPackagedSellingPriceInvalid;
        if (contains != 1 &&
            unit.wholesalePrice != null &&
            unit.wholesalePrice! < 0) {
          return l10n.productPackagedWholesaleInvalid;
        }
      }

      if (_openingStockEnabled) {
        if (_openingLines.isEmpty || _openingReason.trim().isEmpty) {
          return l10n.enterValidNumber;
        }
        for (final line in _openingLines) {
          final quantity = double.tryParse(line.quantity.text.trim());
          final cost = double.tryParse(line.cost.text.trim());
          if (quantity == null || quantity <= 0 || cost == null || cost < 0) {
            return l10n.enterValidNumber;
          }
        }
      }
    }
    if (widget.productToEdit == null &&
        _selectedProductType != ProductType.packaged) {
      if (!_openingStockEnabled) return null;
      final quantityText = openingQuantityCtrl.text.trim();
      final costText = openingCostCtrl.text.trim();
      final openingQuantity =
          quantityText.isEmpty ? null : double.tryParse(quantityText);
      final openingCost = costText.isEmpty ? null : double.tryParse(costText);
      if (openingQuantity == null && quantityText.isNotEmpty ||
          openingCost == null && costText.isNotEmpty ||
          (openingQuantity != null && openingQuantity < 0) ||
          (openingCost != null && openingCost < 0)) {
        return l10n.enterValidNumber;
      }
      if (openingQuantity == null ||
          openingQuantity <= 0 ||
          openingCost == null ||
          _openingReason.trim().isEmpty) {
        return l10n.enterValidNumber;
      }
    }
    return null;
  }

  String _openingReasonLabel() {
    final l10n = AppLocalizations.of(context);
    return stockAdjustmentReasonOptions(l10n)
        .firstWhere((reason) => reason.value == _openingReason)
        .label;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) => Container(
            constraints: BoxConstraints(
              maxWidth: 1120,
              maxHeight: MediaQuery.sizeOf(context).height -
                  MediaQuery.viewInsetsOf(context).vertical -
                  32,
            ),
            decoration: BoxDecoration(
              color: AppColors.surfaceColor,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              children: [
                if (constraints.maxWidth < 700)
                  _buildMobileDialogHeader(l10n)
                else
                  _buildDialogHeader(l10n),
                Expanded(
                  child: Form(
                    key: _formKey,
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(28, 20, 28, 24),
                      child: constraints.maxWidth < 700
                          ? _buildMobileStep(l10n)
                          : _buildDesktopForm(l10n),
                    ),
                  ),
                ),
                if (constraints.maxWidth < 700)
                  _buildMobileDialogFooter(l10n)
                else
                  _buildDialogFooter(l10n),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDesktopForm(AppLocalizations l10n) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildSectionCard(
          title: l10n.generalInformationTitle,
          icon: Icons.info_outline,
          child: _buildGeneralInformation(l10n),
        ),
        const SizedBox(height: 16),
        _buildSectionCard(
          title: l10n.productTypeSectionTitle,
          icon: Icons.category_outlined,
          child: _buildProductTypeCards(),
        ),
        const SizedBox(height: 16),
        _buildSectionCard(
          title: l10n.typeSpecificConfigurationTitle,
          icon: Icons.tune_outlined,
          child: _selectedProductType == ProductType.weighted
              ? _buildWeightedFields()
              : _selectedProductType == ProductType.packaged
                  ? _buildPackagedFields()
                  : _buildStandardConfiguration(l10n),
        ),
        if (_selectedProductType == ProductType.packaged) ...[
          const SizedBox(height: 16),
          _buildOpeningStockSection(l10n),
        ],
        if (_selectedProductType != ProductType.packaged) ...[
          const SizedBox(height: 16),
          _buildSectionCard(
            title: l10n.inventoryPricingTitle,
            icon: Icons.inventory_2_outlined,
            child: _buildInventoryPricing(l10n),
          ),
        ],
      ],
    );
  }

  Widget _buildMobileStep(AppLocalizations l10n) {
    switch (_mobileStep) {
      case 0:
        return _buildSectionCard(
          title: l10n.generalInformationTitle,
          icon: Icons.info_outline,
          child: _buildGeneralInformation(l10n),
        );
      case 1:
        return _buildSectionCard(
          title: l10n.productTypeSectionTitle,
          icon: Icons.category_outlined,
          child: _buildProductTypeCards(),
        );
      case 2:
        return _buildSectionCard(
          title: l10n.inventoryPricingTitle,
          icon: Icons.sell_outlined,
          child: _buildMobilePricing(l10n),
        );
      default:
        return _buildSectionCard(
          title: l10n.inventoryPricingTitle,
          icon: Icons.inventory_2_outlined,
          child: _buildMobileInventory(l10n),
        );
    }
  }

  Widget _buildMobilePricing(AppLocalizations l10n) {
    if (_selectedProductType == ProductType.packaged) {
      return _buildPackagedFields();
    }
    if (_selectedProductType == ProductType.weighted) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildWeightedFields(),
          const SizedBox(height: 12),
          _buildTextField(
            context,
            wholesalePriceCtrl,
            l10n.wholesalePriceLabel,
            Icons.price_change_outlined,
            keyboardType: TextInputType.number,
          ),
          const SizedBox(height: 12),
          _buildTextField(
            context,
            minPriceCtrl,
            l10n.minPriceLabel2,
            Icons.price_check_outlined,
            keyboardType: TextInputType.number,
          ),
          const SizedBox(height: 12),
          _buildTextField(
            context,
            minQtyCtrl,
            l10n.minimumStockSelectedUnitLabel(_baseUnit),
            Icons.trending_down,
            keyboardType: TextInputType.number,
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildTextField(
          context,
          priceCtrl,
          l10n.sellingPrice,
          Icons.sell_outlined,
          keyboardType: TextInputType.number,
        ),
        const SizedBox(height: 12),
        _buildTextField(
          context,
          wholesalePriceCtrl,
          l10n.wholesalePriceLabel,
          Icons.price_change_outlined,
          keyboardType: TextInputType.number,
        ),
        const SizedBox(height: 12),
        _buildTextField(
          context,
          minPriceCtrl,
          l10n.minPriceLabel2,
          Icons.price_check_outlined,
          keyboardType: TextInputType.number,
        ),
        const SizedBox(height: 12),
        _buildTextField(
          context,
          minQtyCtrl,
          l10n.minimumStockSelectedUnitLabel('piece'),
          Icons.trending_down,
          keyboardType: TextInputType.number,
        ),
      ],
    );
  }

  Widget _buildMobileInventory(AppLocalizations l10n) {
    if (_selectedProductType == ProductType.packaged) {
      return _buildOpeningStockSection(l10n);
    }
    return _buildOpeningStockSection(l10n);
  }

  Widget _buildMobileDialogHeader(AppLocalizations l10n) {
    final stepTitle = switch (_mobileStep) {
      0 => l10n.generalInformationTitle,
      1 => l10n.productTypeSectionTitle,
      2 => l10n.inventoryPricingTitle,
      _ => l10n.inventoryPricingTitle,
    };
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 10, 14),
      decoration: const BoxDecoration(
        color: AppColors.primaryColor,
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: Row(
        children: [
          if (_mobileStep > 0)
            IconButton(
              onPressed: _isSubmitting || _isClosing
                  ? null
                  : () {
                      FocusManager.instance.primaryFocus?.unfocus();
                      if (mounted && !_isClosing) {
                        setState(() => _mobileStep--);
                      }
                    },
              color: Colors.white,
              icon: const Icon(Icons.arrow_back),
              tooltip: l10n.cancelBtn,
            ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.productToEdit == null
                      ? l10n.addNewProduct
                      : l10n.editProduct,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                Text(
                  '${_mobileStep + 1} / 4  ·  $stepTitle',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white70),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: l10n.cancelBtn,
            onPressed: _closeDialog,
            icon: const Icon(Icons.close, color: Colors.white),
          ),
        ],
      ),
    );
  }

  Future<void> _continueMobileStep() async {
    if (!mounted || _isClosing || _isSubmitting) return;
    FocusManager.instance.primaryFocus?.unfocus();
    if (!mounted || _isClosing) return;
    if (_mobileStep == 3) {
      await _submit();
      return;
    }
    if (!_formKey.currentState!.validate()) {
      _showSubmissionMessage(
        AppLocalizations.of(context).productSubmissionCorrectFields,
      );
      return;
    }
    if (!mounted) return;
    setState(() => _mobileStep++);
  }

  Widget _buildMobileDialogFooter(AppLocalizations l10n) {
    final isFinalStep = _mobileStep == 3;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: AppColors.borderColor)),
      ),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton(
              onPressed: _isSubmitting || _isClosing ? null : _closeDialog,
              child: Text(l10n.cancelBtn),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            flex: 2,
            child: ElevatedButton.icon(
              onPressed: _isSubmitting ? null : _continueMobileStep,
              icon: _isSubmitting
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(
                      isFinalStep ? Icons.save_outlined : Icons.arrow_forward),
              label: Text(
                isFinalStep
                    ? (widget.productToEdit == null
                        ? l10n.addProduct
                        : l10n.saveChanges)
                    : l10n.nextStep,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDialogHeader(AppLocalizations l10n) {
    return Container(
      padding: const EdgeInsets.fromLTRB(28, 20, 20, 18),
      decoration: const BoxDecoration(
        color: AppColors.primaryColor,
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(11),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(.14),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              widget.productToEdit == null
                  ? Icons.add_box_outlined
                  : Icons.edit_outlined,
              color: Colors.white,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.productToEdit == null
                      ? l10n.addNewProduct
                      : l10n.editProduct,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 21,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 3),
              ],
            ),
          ),
          IconButton(
            tooltip: l10n.cancelBtn,
            onPressed: _closeDialog,
            icon: const Icon(Icons.close, color: Colors.white),
          ),
        ],
      ),
    );
  }

  Widget _buildDialogFooter(AppLocalizations l10n) {
    return Container(
      padding: const EdgeInsets.fromLTRB(28, 14, 28, 18),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: AppColors.borderColor)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          OutlinedButton(
            onPressed: _closeDialog,
            child: Text(l10n.cancelBtn),
          ),
          const SizedBox(width: 12),
          ElevatedButton.icon(
            onPressed: _isSubmitting ? null : _submit,
            icon: _isSubmitting
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.save_outlined, size: 18),
            label: Text(_isSubmitting
                ? l10n.savingProduct
                : (widget.productToEdit == null
                    ? l10n.addProduct
                    : l10n.saveChanges)),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primaryColor,
              foregroundColor: AppColors.primaryForeground,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionCard({
    required String title,
    required IconData icon,
    required Widget child,
  }) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.borderColor),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(.035),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(icon, color: AppColors.primaryColor, size: 20),
              const SizedBox(width: 8),
              Text(title,
                  style: const TextStyle(
                      fontWeight: FontWeight.w800, fontSize: 15)),
            ],
          ),
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }

  Widget _buildGeneralInformation(AppLocalizations l10n) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 700;
        final fields = <Widget>[];

        fields.add(
          _buildTextField(
            context,
            nameCtrl,
            l10n.productName,
            Icons.inventory_2_outlined,
          ),
        );

        fields.add(
          _buildTextField(
            context,
            barcodeCtrl,
            l10n.barcodeNumber,
            Icons.qr_code_2_outlined,
            readOnly: widget.productToEdit != null,
            requiredField: false,
            suffixIcon: _canScanBarcode
                ? IconButton(
                    tooltip: 'Scan barcode',
                    icon: const Icon(Icons.qr_code_scanner_rounded),
                    onPressed: _scanBarcode,
                  )
                : null,
          ),
        );

        fields.add(_buildCategoryDropdown());
        fields.add(
          widget.productToEdit != null || _internalReference != null
              ? _buildInternalReferenceField()
              : _buildReferencePreview(l10n),
        );

        return Column(
          children: [
            if (constraints.maxWidth < 620)
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(child: _buildCompactImagePicker(l10n)),
                  const SizedBox(height: 16),
                  ...fields
                      .expand((field) => [field, const SizedBox(height: 12)])
                      .toList()
                    ..removeLast(),
                ],
              )
            else
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildCompactImagePicker(l10n),
                  const SizedBox(width: 16),
                  Expanded(
                    child: wide
                        ? Column(
                            children: [
                              if (fields.length >= 2)
                                _buildTwoColumnRow(fields.sublist(0, 2)),
                              if (fields.length >= 3) ...[
                                const SizedBox(height: 12),
                                if (fields.length == 3)
                                  fields[2]
                                else
                                  _buildTwoColumnRow(fields.sublist(2, 4)),
                              ],
                            ],
                          )
                        : Column(
                            children: [
                              for (var i = 0; i < fields.length; i++) ...[
                                fields[i],
                                if (i < fields.length - 1)
                                  const SizedBox(height: 12),
                              ],
                            ],
                          ),
                  ),
                ],
              ),
          ],
        );
      },
    );
  }

  Widget _buildCompactImagePicker(AppLocalizations l10n) {
    return SizedBox(
      width: 116,
      child: Column(
        children: [
          LocalImageView(
            path: _selectedImagePath,
            width: 104,
            height: 104,
            borderRadius: 14,
            fallback: Container(
              color: AppColors.primaryColor.withOpacity(.08),
              alignment: Alignment.center,
              child: const Icon(Icons.inventory_2_outlined,
                  color: AppColors.primaryColor, size: 34),
            ),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: _pickImage,
            child: Text(l10n.chooseImage,
                maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );
  }

  Widget _buildReferencePreview(AppLocalizations l10n) {
    return InputDecorator(
      decoration: InputDecoration(
        labelText: l10n.internalReferenceLabel,
        helperText: l10n.generatedAutomatically,
        border: const OutlineInputBorder(),
      ),
      child: Text(l10n.autoGeneratedOnSave,
          style: const TextStyle(color: AppColors.mutedColor)),
    );
  }

  Widget _buildProductTypeCards() {
    final l10n = AppLocalizations.of(context);
    final cards = [
      (
        type: ProductType.standard,
        title: l10n.standardProductType,
        subtitle: l10n.standardTypeSubtitle,
        icon: Icons.shopping_bag_outlined,
      ),
      (
        type: ProductType.weighted,
        title: l10n.weightedProductType,
        subtitle: l10n.weightedTypeSubtitle,
        icon: Icons.scale_outlined,
      ),
      (
        type: ProductType.packaged,
        title: l10n.packagedProductType,
        subtitle: l10n.packagedTypeSubtitle,
        icon: Icons.inventory_2_outlined,
      ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: cards.map((card) {
            final selected = card.type == _selectedProductType;
            return SizedBox(
              width: constraints.maxWidth >= 780
                  ? (constraints.maxWidth - 24) / 3
                  : constraints.maxWidth >= 480
                      ? (constraints.maxWidth - 12) / 2
                      : constraints.maxWidth,
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () => setState(() {
                  _selectedProductType = card.type;
                  _openingStockEnabled = card.type == ProductType.packaged &&
                      widget.productToEdit == null;
                  if (card.type == ProductType.weighted) {
                    _baseUnit = _weightedBaseUnit;
                  } else if (card.type == ProductType.packaged) {
                    _baseUnit = _packagedBaseUnit;
                  } else {
                    _baseUnit = 'piece';
                  }
                }),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: selected
                        ? AppColors.primaryColor.withOpacity(.09)
                        : AppColors.surfaceColor,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: selected
                          ? AppColors.primaryColor
                          : AppColors.borderColor,
                      width: selected ? 2 : 1,
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(card.icon,
                          color: selected
                              ? AppColors.primaryColor
                              : AppColors.mutedColor),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(card.title,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w800)),
                            const SizedBox(height: 3),
                            Text(card.subtitle,
                                style: const TextStyle(fontSize: 11)),
                          ],
                        ),
                      ),
                      if (selected)
                        const Icon(Icons.check_circle,
                            color: AppColors.primaryColor),
                    ],
                  ),
                ),
              ),
            );
          }).toList(),
        );
      },
    );
  }

  Widget _buildStandardConfiguration(AppLocalizations l10n) {
    return Text(
      l10n.standardTypeSubtitle,
      style: const TextStyle(color: AppColors.mutedColor),
    );
  }

  Widget _buildInventoryPricing(AppLocalizations l10n) {
    if (_selectedProductType == ProductType.packaged) {
      return const SizedBox.shrink();
    }

    final stockUnit =
        _selectedProductType == ProductType.standard ? 'piece' : _baseUnit;
    final pricing = <Widget>[
      if (_selectedProductType == ProductType.standard ||
          _selectedProductType == ProductType.weighted)
        _buildTextField(
          context,
          wholesalePriceCtrl,
          l10n.wholesalePriceLabel,
          Icons.price_change_outlined,
          keyboardType: TextInputType.number,
        ),
      _buildTextField(
        context,
        minPriceCtrl,
        l10n.minPriceLabel2,
        Icons.price_check_outlined,
        keyboardType: TextInputType.number,
      ),
      _buildTextField(
        context,
        minQtyCtrl,
        l10n.minimumStockSelectedUnitLabel(stockUnit),
        Icons.trending_down,
        keyboardType: TextInputType.number,
      ),
      if (_selectedProductType == ProductType.standard)
        _buildTextField(
          context,
          priceCtrl,
          l10n.sellingPrice,
          Icons.sell_outlined,
          keyboardType: TextInputType.number,
        ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: pricing
              .map((field) => SizedBox(
                    width: 250,
                    child: field,
                  ))
              .toList(),
        ),
        const SizedBox(height: 10),
        Text(
          l10n.stockTrackedIn(stockUnit),
          style: const TextStyle(color: AppColors.mutedColor),
        ),
        if (widget.productToEdit == null) _buildOpeningStockSection(l10n),
      ],
    );
  }

  Widget _buildPackagedOpeningStockSection(AppLocalizations l10n) {
    return _buildMultiLinePackagedOpeningStockSection(l10n);
    /*
    final activeUnits = _sellingUnits
        .where((unit) => unit.isActive && unit.name.toLowerCase() != 'piece')
        .toList();
    final totalBaseQuantity = _packagedInitialStockBaseQuantity();
    return Container(
      margin: const EdgeInsets.only(top: 16),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surfaceColor.withOpacity(.55),
        border: Border.all(color: AppColors.borderColor),
        borderRadius: BorderRadius.circular(10),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'INITIAL STOCK (OPTIONAL)',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 12),
              const Text(
                'Select an existing selling unit and enter the opening quantity.',
                style: TextStyle(color: AppColors.mutedColor),
              ),
              const SizedBox(height: 12),
              if (activeUnits.isNotEmpty)
                DropdownButtonFormField<String>(
                  value: activeUnits.any((unit) =>
                          unit.name.toLowerCase() ==
                          _initialStockUnit.toLowerCase())
                      ? _initialStockUnit
                      :                       activeUnits.first,
                  decoration: const InputDecoration(
                    labelText: 'Opening stock unit',
                    prefixIcon: Icon(Icons.inventory_2_outlined),
                  ),
                  items: activeUnits
                      .map((unit) => DropdownMenuItem(
                            value: unit.name,
                            child: Text(unit.name),
                          ))
                      .toList(),
                  onChanged: (value) {
                    if (value != null) {
                      setState(() => _initialStockUnit = value);
                    }
                  },
                ),
              if (activeUnits.isNotEmpty) const SizedBox(height: 12),
              if (activeUnits.isEmpty)
                Text(l10n.sellingUnitsLabel)
              else ...[
                _buildTextField(
                  context,
                  openingQuantityCtrl,
                  'Initial quantity ($_initialStockUnit)',
                  Icons.add_box_outlined,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  requiredField: true,
                ),
                const SizedBox(height: 8),
                _buildTextField(
                  context,
                  openingCostCtrl,
                  'Acquisition cost / $_initialStockUnit',
                  Icons.payments_outlined,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  requiredField: true,
                ),
              ],
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                value: _openingReason,
                decoration:
                    InputDecoration(labelText: l10n.stockAdjustmentReason),
                items: stockAdjustmentReasonOptions(l10n)
                    .map((reason) => DropdownMenuItem(
                          value: reason.value,
                          child: Text(reason.label),
                        ))
                    .toList(),
                onChanged: (reason) {
                  if (reason != null) setState(() => _openingReason = reason);
                },
              ),
              const SizedBox(height: 12),
              Card(
                margin: EdgeInsets.zero,
                color: AppColors.primaryColor.withOpacity(.08),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.total,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        totalBaseQuantity == 0
                            ? l10n.outOfStock
                            : '${_formatQuantity(totalBaseQuantity)} '
                                '${l10n.quantity}',
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          color: AppColors.primaryColor,
                        ),
                      ),
                      if (totalBaseQuantity > 0) ...[
                        const SizedBox(height: 4),
                        Text(
                          'Base-unit acquisition cost: '
                          '${_packagedInitialStockBaseUnitCost().toStringAsFixed(4)} '
                          '${_baseUnit.isEmpty ? 'piece' : _baseUnit}',
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: openingNotesCtrl,
                decoration: InputDecoration(
                  labelText: l10n.notes,
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          );
        },
      ),
    ); */
  }

  Widget _buildMultiLinePackagedOpeningStockSection(AppLocalizations l10n) {
    final configuredUnits = _sellingUnits
        .where((unit) =>
            unit.isActive &&
            (unit.name.toLowerCase() == 'pack' ||
                unit.name.toLowerCase() == 'box'))
        .toList();
    final activeUnits = <String>[
      ...configuredUnits.map((unit) => unit.name),
      ..._packagedSellingUnitPresets
          .where((preset) =>
              (preset.value == 'pack' || preset.value == 'box') &&
              !configuredUnits.any(
                (unit) => unit.name.toLowerCase() == preset.value,
              ))
          .map((preset) => preset.label),
    ];
    final usedUnits = _openingLines
        .map((line) => line.unit.toLowerCase())
        .toSet();
    final totalBaseQuantity = _openingLines.fold<double>(
      0,
      (total, line) {
        final configured = configuredUnits.where(
          (candidate) =>
              candidate.name.toLowerCase() == line.unit.toLowerCase(),
        );
        final preset = _packagedSellingUnitPresets.firstWhere(
          (candidate) => candidate.value == line.unit.toLowerCase(),
          orElse: () => _packagedSellingUnitPresets.first,
        );
        return total +
            (double.tryParse(line.quantity.text.trim()) ?? 0) *
                (configured.isEmpty
                    ? preset.defaultConversion
                    : configured.first.conversionToBase);
      },
    );
    return Container(
      key: const ValueKey('packaged-initial-stock'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surfaceColor.withOpacity(.55),
        border: Border.all(color: AppColors.borderColor),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('INITIAL STOCK',
              style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 12),
          ..._openingLines.asMap().entries.map((entry) {
            final index = entry.key;
            final line = entry.value;
            final unitNames = activeUnits
                .where((unit) =>
                    unit.toLowerCase() == line.unit.toLowerCase() ||
                    !usedUnits.contains(unit.toLowerCase()))
                .toList();
            if (unitNames.isEmpty) {
              return const SizedBox.shrink();
            }
            final selectedUnit = unitNames.contains(line.unit)
                ? line.unit
                : unitNames.first;
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 3,
                    child: DropdownButtonFormField<String>(
                      value: selectedUnit,
                      decoration: const InputDecoration(
                        labelText: 'Selling Unit',
                        border: OutlineInputBorder(),
                      ),
                      items: unitNames
                          .map((unit) => DropdownMenuItem(
                                value: unit,
                                child: Text(unit),
                              ))
                          .toList(),
                      onChanged: (value) {
                        if (value != null) setState(() => line.unit = value);
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 2,
                    child: _buildTextField(
                      context,
                      line.quantity,
                      'Quantity',
                      Icons.numbers,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      requiredField: true,
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 3,
                    child: _buildTextField(
                      context,
                      line.cost,
                      'Acquisition Cost',
                      Icons.payments_outlined,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      requiredField: true,
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Remove',
                    onPressed: () => setState(() {
                      final removed = _openingLines.removeAt(index);
                      removed.dispose();
                    }),
                    icon: const Icon(Icons.delete_outline),
                  ),
                ],
              ),
            );
          }),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: activeUnits
                      .where((unit) =>
                          !usedUnits.contains(unit.toLowerCase()))
                      .isEmpty
                  ? null
                  : () => setState(() {
                        final nextUnit = activeUnits.firstWhere(
                          (unit) => !usedUnits.contains(unit.toLowerCase()),
                        );
                        _openingLines.add(
                            _OpeningStockDraft(unit: nextUnit));
                      }),
              icon: const Icon(Icons.add),
              label: const Text('Add Stock Line'),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Total opening stock: ${_formatQuantity(totalBaseQuantity)} $_packagedBaseUnit',
            style: const TextStyle(
              fontWeight: FontWeight.w700,
              color: AppColors.primaryColor,
            ),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            value: _openingReason,
            decoration: InputDecoration(labelText: l10n.stockAdjustmentReason),
            items: stockAdjustmentReasonOptions(l10n)
                .map((reason) => DropdownMenuItem(
                      value: reason.value,
                      child: Text(reason.label),
                    ))
                .toList(),
            onChanged: (reason) {
              if (reason != null) setState(() => _openingReason = reason);
            },
          ),
        ],
      ),
    );
  }

  Widget _buildOpeningStockSection(AppLocalizations l10n) {
    if (_selectedProductType == ProductType.packaged) {
      return _buildPackagedOpeningStockSection(l10n);
      /*
      if (widget.productToEdit != null) {
        return _buildPackagedInitialCostsSection();
      }
      final activeUnits = _sellingUnits.where((unit) => unit.isActive).toList();
      final defaultUnit = activeUnits.isNotEmpty
          ? activeUnits.firstWhere(
              (unit) => unit.isDefault,
              orElse: () => activeUnits.first,
            )
          : null;
      final selectedUnit = activeUnits.isNotEmpty
          ? (activeUnits.any((unit) =>
                  unit.name.toLowerCase() == _initialStockUnit.toLowerCase())
              ? _initialStockUnit
              : defaultUnit!.name)
          : _initialStockUnit.isNotEmpty
              ? _initialStockUnit
              : 'piece';
      final previewBaseQuantity = _packagedInitialStockBaseQuantity();
      final openingQuantity = _packagedOpeningQuantity();
      final unitItems = activeUnits.isEmpty
          ? const [DropdownMenuItem(value: 'piece', child: Text('piece'))]
          : activeUnits
              .map((unit) => DropdownMenuItem(
                    value: unit.name,
                    child: Text(unit.name),
                  ))
              .toList();
      return Container(
        margin: const EdgeInsets.only(top: 16),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.surfaceColor.withOpacity(.55),
          border: Border.all(color: AppColors.borderColor),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('INITIAL STOCK (OPTIONAL)',
                style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            const Text('Quantity',
                style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              decoration: BoxDecoration(
                border: Border.all(color: AppColors.borderColor),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  IconButton.filledTonal(
                    tooltip: 'Decrease quantity',
                    onPressed: openingQuantity == 0
                        ? null
                        : () => _adjustPackagedOpeningQuantity(-1),
                    icon: const Icon(Icons.remove),
                    iconSize: 24,
                  ),
                  Expanded(
                    child: TextFormField(
                      controller: openingQuantityCtrl,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          fontSize: 22, fontWeight: FontWeight.w700),
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      decoration: const InputDecoration(
                        hintText: '0',
                        border: InputBorder.none,
                        labelText: 'Quantity',
                      ),
                      validator: (_) => null,
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  IconButton.filledTonal(
                    tooltip: 'Increase quantity',
                    onPressed: () => _adjustPackagedOpeningQuantity(1),
                    icon: const Icon(Icons.add),
                    iconSize: 24,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              value: selectedUnit,
              decoration: const InputDecoration(
                labelText: 'Stock Unit',
                prefixIcon: Icon(Icons.inventory_2_outlined),
              ),
              items: unitItems,
              onChanged: (value) {
                if (value != null) {
                  setState(() => _initialStockUnit = value);
                }
              },
            ),
            Text(
              '${selectedUnit[0].toUpperCase()}${selectedUnit.substring(1)} contains ${_packagedSelectedUnitContains(selectedUnit).toInt()} pieces',
              style: const TextStyle(color: AppColors.mutedColor),
            ),
            const SizedBox(height: 8),
            Card(
              margin: EdgeInsets.zero,
              color: AppColors.primaryColor.withOpacity(.08),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Stock to add',
                        style: TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 4),
                    Text(
                      openingQuantity == 0
                          ? 'No initial stock will be added'
                          : '$openingQuantity ${selectedUnit[0].toUpperCase()}${selectedUnit.substring(1)} = ${_formatQuantity(previewBaseQuantity)} pieces',
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: AppColors.primaryColor,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              value: _openingReason,
              decoration: const InputDecoration(labelText: 'Reason'),
              items: stockAdjustmentReasonOptions(l10n)
                  .map((reason) => DropdownMenuItem(
                        value: reason.value,
                        child: Text(reason.label),
                      ))
                  .toList(),
              onChanged: (reason) {
                if (reason != null) setState(() => _openingReason = reason);
              },
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                border: Border.all(color: AppColors.borderColor),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('INITIAL COST BY SELLING UNIT',
                      style: TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 8),
                  ...activeUnits.map((unit) {
                    final key = _costKey(unit);
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: TextFormField(
                        key: ValueKey('initial-cost-$key'),
                        initialValue: _initialCostByUnit[key] ?? '',
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                        decoration: InputDecoration(
                          labelText:
                              '${unit.name[0].toUpperCase()}${unit.name.substring(1)} Initial Cost (optional)',
                          border: const OutlineInputBorder(),
                        ),
                        validator: (_) => null,
                        onChanged: (value) => _initialCostByUnit[key] = value,
                      ),
                    );
                  }),
                ],
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: openingNotesCtrl,
              decoration: const InputDecoration(
                labelText: 'Notes',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
      );
      */
    }

    final unit = _baseUnit.isEmpty ? 'piece' : _baseUnit;
    return Container(
      margin: const EdgeInsets.only(top: 16),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surfaceColor.withOpacity(.55),
        border: Border.all(color: AppColors.borderColor),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l10n.openingStock,
              style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text(
            'Add the quantity already available when this product is created.',
            style: const TextStyle(color: AppColors.mutedColor),
          ),
          const SizedBox(height: 8),
          if (!_openingStockEnabled)
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: () => setState(() => _openingStockEnabled = true),
                icon: const Icon(Icons.add),
                label: const Text('Add opening stock'),
              ),
            )
          else ...[
            _buildTextField(
              context,
              openingQuantityCtrl,
              'Initial quantity ($unit)',
              Icons.add_box_outlined,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              requiredField: true,
            ),
            const SizedBox(height: 8),
            _buildTextField(
              context,
              openingCostCtrl,
              'Cost price / $unit',
              Icons.payments_outlined,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              requiredField: true,
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              value: _openingReason,
              decoration: const InputDecoration(labelText: 'Reason'),
              items: stockAdjustmentReasonOptions(l10n)
                  .map((reason) => DropdownMenuItem(
                        value: reason.value,
                        child: Text(reason.label),
                      ))
                  .toList(),
              onChanged: (reason) {
                if (reason != null) setState(() => _openingReason = reason);
              },
            ),
            const SizedBox(height: 6),
            Text(
              'This opening stock will be recorded as an inventory adjustment.',
              style: const TextStyle(color: AppColors.mutedColor),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () => setState(() {
                  _openingStockEnabled = false;
                  openingQuantityCtrl.clear();
                  openingCostCtrl.clear();
                  _openingReason = 'initial_inventory';
                }),
                child: const Text('Remove opening stock'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildWeightedFields() {
    final l10n = AppLocalizations.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.weightedProductTitle,
              style:
                  const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 4),
          Text(l10n.weightedProductSubtitle),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _buildBaseUnitSelector(
                  l10n: l10n,
                  units: _weightedUnits,
                  fallback: 'kg',
                ),
              ),
              const SizedBox(width: 12),
            ],
          ),
          const SizedBox(height: 12),
          TextFormField(
            initialValue: priceCtrl.text,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: l10n.pricePerSelectedUnitLabel(_baseUnit),
              border: OutlineInputBorder(),
            ),
            onChanged: (value) => priceCtrl.text = value,
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _buildPackagedFields() {
    final l10n = AppLocalizations.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.primaryColor.withOpacity(.025),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.packagingSellingUnitsTitle,
              style:
                  const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 4),
          Text(l10n.packagingSellingUnitsSubtitle),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Text(l10n.sellingUnitsLabel,
                    style: const TextStyle(fontWeight: FontWeight.bold)),
              ),
              OutlinedButton.icon(
                onPressed: () => _openSellingUnitEditor(),
                icon: const Icon(Icons.add),
                label: Text('${l10n.addSellingUnit} ${l10n.sellingUnitLabel}'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _buildSellingUnitTable(),
        ],
      ),
    );
  }

  Widget _buildBaseUnitSelector({
    required AppLocalizations l10n,
    required List<String> units,
    required String fallback,
  }) {
    final value = units.contains(_baseUnit) ? _baseUnit : fallback;
    return DropdownButtonFormField<String>(
      value: value,
      decoration: InputDecoration(
        labelText: l10n.baseUnitLabel,
        helperText: l10n.baseUnitHint,
        border: const OutlineInputBorder(),
      ),
      items: units
          .map((unit) => DropdownMenuItem<String>(
                value: unit,
                child: Text(unit),
              ))
          .toList(),
      onChanged: (selected) {
        if (selected != null) {
          setState(() {
            _baseUnit = selected;
            if (_selectedProductType == ProductType.weighted) {
              _weightedBaseUnit = selected;
            } else if (_selectedProductType == ProductType.packaged) {
              _packagedBaseUnit = selected;
            }
          });
        }
      },
    );
  }

  Widget _buildSellingUnitTable() {
    final l10n = AppLocalizations.of(context);
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.borderColor),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          columnSpacing: 18,
          headingRowColor: const WidgetStatePropertyAll(AppColors.surfaceColor),
          columns: [
            DataColumn(label: Text(l10n.sellingUnitLabel)),
            DataColumn(label: Text(l10n.containsLabel)),
            DataColumn(label: Text(l10n.costLabel)),
            DataColumn(label: Text(l10n.sellingPrice)),
            DataColumn(label: Text(l10n.wholesalePriceLabel)),
            DataColumn(label: Text(l10n.unitActionsLabel)),
          ],
          rows: _sellingUnits.asMap().entries.map((entry) {
            final index = entry.key;
            final unit = entry.value;
            return DataRow(cells: [
              DataCell(Text(_packagedUnitDisplayName(unit.name))),
              DataCell(
                Text(
                  _containsDescription(
                    AppLocalizations.of(context),
                    unit.conversionToBase,
                  ),
                ),
              ),
              DataCell(Text(
                unit.costPrice != null && unit.costPrice! > 0
                    ? unit.costPrice!.toStringAsFixed(2)
                    : '—',
              )),
              DataCell(Text(unit.sellingPrice.toStringAsFixed(2))),
              DataCell(Text(unit.wholesalePrice?.toStringAsFixed(2) ?? '-')),
              DataCell(Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: l10n.editLabel,
                    onPressed: () => _openSellingUnitEditor(unit, index),
                    icon: const Icon(Icons.edit_outlined, size: 18),
                  ),
                  IconButton(
                    tooltip: l10n.removeLabel,
                    onPressed: () =>
                        setState(() => _sellingUnits.removeAt(index)),
                    icon: const Icon(Icons.delete_outline, size: 18),
                  ),
                ],
              )),
            ]);
          }).toList(),
        ),
      ),
    );
  }

  String _formatQuantity(double quantity) {
    return quantity == quantity.roundToDouble()
        ? quantity.toInt().toString()
        : quantity.toString();
  }

  String _containsDescription(
    AppLocalizations l10n,
    double quantity,
  ) {
    final amount = _formatQuantity(quantity);
    final unit = quantity == 1
        ? _baseUnit
        : _baseUnit == 'box'
            ? 'boxes'
            : '${_baseUnit}s';
    return l10n.containsUnitDescription(amount, unit);
  }

  String _normalizePackagedSellingUnitName(String? value) {
    final normalized = (value ?? '').trim().toLowerCase();
    for (final unit in _packagedSellingUnitPresets) {
      if (unit.value == normalized) {
        return unit.value;
      }
    }
    return _packagedSellingUnitPresets.first.value;
  }

  _PackageUnitPreset _packagedUnitPreset(String value) {
    final normalized = _normalizePackagedSellingUnitName(value);
    return _packagedSellingUnitPresets.firstWhere(
      (unit) => unit.value == normalized,
      orElse: () => _packagedSellingUnitPresets.first,
    );
  }

  String _packagedUnitDisplayName(String? value) {
    final preset = _packagedUnitPreset(value ?? 'piece');
    return preset.label;
  }

  String _newDraftKey() => 'draft-${_nextDraftKey++}';

  Future<void> _openSellingUnitEditor([
    _SellingUnitDraft? existing,
    int? index,
  ]) async {
    final draft = existing ??
        _SellingUnitDraft(
          draftKey: _newDraftKey(),
          name: 'piece',
          conversionToBase: 1,
          sellingPrice: 0,
          costPrice: 0,
          isDefault: _sellingUnits.isEmpty,
        );
    final result = await showDialog<_SellingUnitDraft>(
      context: context,
      builder: (_) => _SellingUnitEditorDialog(
        draft: draft,
        existing: existing,
        existingUnits: _sellingUnits,
        presets: _packagedSellingUnitPresets,
      ),
    );
    if (result == null || !mounted) return;
    setState(() {
      if (result.isDefault) {
        for (final unit in _sellingUnits) {
          unit.isDefault = false;
        }
      }
      if (index == null) {
        _sellingUnits.add(result);
      } else {
        _sellingUnits[index] = result;
      }
      _ensurePackagedDefault();
    });
  }

  Future<void> _loadSellingUnits(String productId) async {
    final rows = BackendApiConfig.productReadMode == ProductReadMode.server
        ? widget.productToEdit?.sellingUnits ?? const <SellingUnit>[]
        : await SellingUnitRepository(
            PersistenceInitializer.persistenceManager!.sqliteManager,
          ).listByProduct(productId, activeOnly: false);
    if (!mounted) return;
    setState(() {
      _sellingUnits
        ..clear()
        ..addAll(rows.map((unit) {
          final draft = _SellingUnitDraft(
            draftKey: _newDraftKey(),
            id: unit.id,
            name: unit.name,
            conversionToBase: unit.conversionToBase,
            sellingPrice: unit.sellingPrice,
            costPrice: unit.cost,
            wholesalePrice: unit.wholesalePrice,
            minimumStock: unit.minimumStock,
            iconKey: unit.iconKey,
            isDefault: unit.isDefault,
            isActive: unit.isActive,
          );
          return draft;
        }));
      _ensurePackagedDefault();
    });
  }

  Widget _buildInternalReferenceField() {
    final l10n = AppLocalizations.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.borderColor),
      ),
      child: TextFormField(
        initialValue: _internalReference ?? l10n.autoGeneratedOnSave,
        readOnly: true,
        decoration: InputDecoration(
          labelText: l10n.internalReferenceLabel,
          border: OutlineInputBorder(),
        ),
      ),
    );
  }

  Future<void> _pickImage() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['jpg', 'jpeg', 'png', 'webp', 'bmp'],
    );
    final selectedPath = result?.files.single.path;
    if (selectedPath != null && mounted) {
      setState(() => _selectedImagePath = selectedPath);
    }
  }

  Widget _buildCategoryDropdown() {
    final l10n = AppLocalizations.of(context);
    // Filter out "All" - it's only a UI filter, not a real category
    final validCategories =
        widget.categories.where((c) => c != 'All' && c != l10n.all).toList();

    // Ensure selected category is valid
    if ((selectedCategory == 'All' || selectedCategory == l10n.all) &&
        validCategories.isNotEmpty) {
      selectedCategory = validCategories.first;
    }

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.borderColor),
        boxShadow: [
          BoxShadow(
            color: AppColors.mutedColor.withOpacity(0.1),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: DropdownButtonFormField<String>(
        value: validCategories.contains(selectedCategory)
            ? selectedCategory
            : (validCategories.isNotEmpty ? validCategories.first : null),
        items: validCategories
            .map((c) => DropdownMenuItem(
                  value: c,
                  child: Text(c),
                ))
            .toList(),
        onChanged: (v) =>
            setState(() => selectedCategory = v ?? selectedCategory),
        decoration: InputDecoration(
          border: InputBorder.none,
          labelText: l10n.categoryLabel,
          prefixIcon: Icon(Icons.category, color: AppColors.primaryColor),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 16,
          ),
        ),
        validator: (value) {
          if (value == null ||
              value.isEmpty ||
              value == 'All' ||
              value == l10n.all) {
            return l10n.selectValidCategory;
          }
          return null;
        },
      ),
    );
  }
}

class _SellingUnitEditorDialog extends StatefulWidget {
  final _SellingUnitDraft draft;
  final _SellingUnitDraft? existing;
  final List<_SellingUnitDraft> existingUnits;
  final List<_PackageUnitPreset> presets;

  const _SellingUnitEditorDialog({
    required this.draft,
    required this.existing,
    required this.existingUnits,
    required this.presets,
  });

  @override
  State<_SellingUnitEditorDialog> createState() =>
      _SellingUnitEditorDialogState();
}

class _SellingUnitEditorDialogState extends State<_SellingUnitEditorDialog> {
  late final TextEditingController _containsController;
  late final TextEditingController _sellingController;
  late final TextEditingController _wholesaleController;
  late final TextEditingController _minimumStockController;
  late String _selectedUnit;

  @override
  void initState() {
    super.initState();
    _selectedUnit = _normalize(widget.draft.name);
    _containsController = TextEditingController(
      text: (widget.existing == null
              ? _preset(_selectedUnit).defaultConversion
              : widget.draft.conversionToBase)
          .toString(),
    );
    _sellingController =
        TextEditingController(text: widget.draft.sellingPrice.toString());
    _wholesaleController = TextEditingController(
      text: widget.draft.wholesalePrice?.toString() ?? '',
    );
    _minimumStockController =
        TextEditingController(text: widget.draft.minimumStock.toString());
  }

  _PackageUnitPreset _preset(String value) => widget.presets.firstWhere(
        (preset) => preset.value == value,
        orElse: () => widget.presets.first,
      );

  String _normalize(String value) {
    final normalized = value.trim().toLowerCase();
    return widget.presets.any((preset) => preset.value == normalized)
        ? normalized
        : widget.presets.first.value;
  }

  @override
  void dispose() {
    _containsController.dispose();
    _sellingController.dispose();
    _wholesaleController.dispose();
    _minimumStockController.dispose();
    super.dispose();
  }

  void _close() {
    if (!mounted) return;
    FocusManager.instance.primaryFocus?.unfocus();
    Navigator.of(context).pop();
  }

  void _save() {
    final contains = _selectedUnit == 'piece'
        ? 1.0
        : (double.tryParse(_containsController.text) ??
            widget.draft.conversionToBase);
    final selling = double.tryParse(_sellingController.text.trim());
    final wholesaleText = _wholesaleController.text.trim();
    final wholesale =
        wholesaleText.isEmpty ? null : double.tryParse(wholesaleText);
    final isPiece = _selectedUnit == 'piece';
    final minimumStock =
        isPiece ? 0.0 : double.tryParse(_minimumStockController.text.trim());
    if (contains <= 0 ||
        selling == null ||
        selling < 0 ||
        minimumStock == null ||
        minimumStock < 0 ||
        (!isPiece && wholesaleText.isNotEmpty && wholesale == null) ||
        (!isPiece && wholesale != null && wholesale < 0)) {
      return;
    }
    final duplicate = widget.existingUnits.any(
      (unit) =>
          unit != widget.existing &&
          unit.name.toLowerCase() == _selectedUnit.toLowerCase(),
    );
    if (duplicate) return;
    widget.draft
      ..name = _selectedUnit
      ..conversionToBase = contains
      ..sellingPrice = selling
      ..minimumStock = minimumStock
      ..wholesalePrice = isPiece
          ? widget.draft.wholesalePrice
          : wholesale ?? widget.draft.wholesalePrice;
    if (!mounted) return;
    FocusManager.instance.primaryFocus?.unfocus();
    Navigator.of(context).pop(widget.draft);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final helperValue = _selectedUnit == 'piece'
        ? 1.0
        : double.tryParse(_containsController.text) ??
            widget.draft.conversionToBase;
    final isPiece = helperValue == 1;
    return AlertDialog(
      title: Text(
        widget.existing == null ? l10n.addSellingUnitTitle : l10n.editLabel,
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                value: _selectedUnit,
                decoration: InputDecoration(
                  labelText: 'Selling Unit',
                  prefixIcon: Icon(
                    sellingUnitIconData(
                        defaultSellingUnitIconKey(_selectedUnit)),
                  ),
                ),
                items: widget.presets
                    .map((unit) => DropdownMenuItem(
                          value: unit.value,
                          child: Text(unit.label),
                        ))
                    .toList(),
                onChanged: (value) {
                  if (value == null) return;
                  setState(() {
                    _selectedUnit = value;
                    widget.draft.name = value;
                    widget.draft.iconKey = defaultSellingUnitIconKey(value);
                    final nextValue = _preset(value).defaultConversion;
                    _containsController.text = nextValue.toString();
                    widget.draft.conversionToBase = nextValue;
                  });
                },
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _containsController,
                onChanged: (_) => setState(() {}),
                enabled: _selectedUnit != 'piece',
                readOnly: _selectedUnit == 'piece',
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                  labelText: 'Units contained',
                  helperText: '$helperValue pieces',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _sellingController,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                  labelText: 'Selling Price / ${_selectedUnit.toLowerCase()}',
                ),
              ),
              const SizedBox(height: 12),
              if (!isPiece) ...[
                const SizedBox(height: 12),
                TextField(
                  controller: _wholesaleController,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(
                    labelText:
                        'Wholesale Price / ${_selectedUnit.toLowerCase()}',
                  ),
                ),
              ],
              if (!isPiece) ...[
                const SizedBox(height: 12),
                TextField(
                  controller: _minimumStockController,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'Minimum Stock'),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: _close, child: Text(l10n.cancelBtn)),
        FilledButton(onPressed: _save, child: Text(l10n.saveUnit)),
      ],
    );
  }
}

class AddCategories extends StatefulWidget {
  AddCategories({super.key});

  @override
  State<AddCategories> createState() => _AddCategoriesState();
}

class _AddCategoriesState extends State<AddCategories> {
  final TextEditingController nameCtrl = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  @override
  void dispose() {
    nameCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final mediaQuery = MediaQuery.of(context);
    final availableHeight = mediaQuery.size.height -
        mediaQuery.viewInsets.bottom -
        mediaQuery.padding.vertical -
        32;

    return SafeArea(
      child: Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 600,
            maxHeight: availableHeight.clamp(240.0, 640.0),
          ),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              gradient: LinearGradient(
                colors: [Colors.white, AppColors.surfaceColor],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: AppColors.primaryColor.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(
                          Icons.add_box_outlined,
                          color: AppColors.primaryColor,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerRight,
                          child: Text(
                            l10n.addNewCategory,
                            style: const TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: () {
                          FocusManager.instance.primaryFocus?.unfocus();
                          Navigator.of(context).pop();
                        },
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  Flexible(
                    child: SingleChildScrollView(
                      keyboardDismissBehavior:
                          ScrollViewKeyboardDismissBehavior.onDrag,
                      child: Form(
                        key: _formKey,
                        child: _buildCategoryNameField(context, l10n),
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () {
                            FocusManager.instance.primaryFocus?.unfocus();
                            Navigator.of(context).pop();
                          },
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: Text(l10n.cancelBtn),
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: ElevatedButton(
                          onPressed: () {
                            if (!_formKey.currentState!.validate()) return;
                            FocusManager.instance.primaryFocus?.unfocus();
                            getIt<ProductCubit>().saveCategory(nameCtrl.text);
                            Navigator.pop(context);
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.primaryColor,
                            foregroundColor: AppColors.primaryForeground,
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(l10n.addCategory),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCategoryNameField(
    BuildContext context,
    AppLocalizations l10n,
  ) {
    return _buildTextField(
      context,
      nameCtrl,
      l10n.categoryName,
      Icons.inventory_2,
    );
  }
}

Widget _buildTwoColumnRow(List<Widget> children) {
  return Row(
    children: [
      Expanded(child: children[0]),
      const SizedBox(width: 16),
      Expanded(child: children[1]),
    ],
  );
}

Widget _buildTextField(
  BuildContext context,
  TextEditingController controller,
  String label,
  IconData icon, {
  TextInputType? keyboardType,
  bool readOnly = false,
  bool requiredField = true,
  Widget? suffixIcon,
  ValueChanged<String>? onChanged,
}) {
  final l10n = AppLocalizations.of(context);
  return TextFormField(
    readOnly: readOnly,
    controller: controller,
    keyboardType: keyboardType,
    onChanged: onChanged,
    decoration: InputDecoration(
      labelText: label,
      prefixIcon: Icon(icon, color: AppColors.primaryColor),
      suffixIcon: suffixIcon,
      border: InputBorder.none,
      contentPadding: const EdgeInsets.symmetric(
        horizontal: 16,
        vertical: 16,
      ),
    ),
    validator: (value) {
      if (requiredField && (value == null || value.trim().isEmpty)) {
        return l10n.fieldRequired;
      }
      if (keyboardType == TextInputType.number &&
          double.tryParse(value?.trim() ?? '') == null &&
          (value?.trim().isNotEmpty ?? false)) {
        return l10n.enterValidNumber;
      }
      return null;
    },
  );
}
