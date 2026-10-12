import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../core/constants/app_colors.dart';
import '../../../l10n/app_localizations.dart';
import '../../auth/data/models/user_model.dart';
import '../../sales/data/models/sale_model.dart';
import '../../../core/components/screen_header.dart';
import '../../sales/domain/sales_repository.dart';
import '../data/invoice_models.dart';
import '../domain/refund_calculation_service.dart';
import 'cubit/invoice_cubit.dart';
import 'cubit/invoice_state.dart';
import 'invoice_preview_screen.dart';
import 'widgets/invoice_filter_section.dart';
import 'widgets/invoice_list_section.dart';
import 'widgets/partial_refund_dialog.dart';
import '../../exchange/domain/exchange_service.dart';
import '../../exchange/presentation/exchange_dialog.dart';
import '../../settings/presentation/cubit/settings_cubit.dart';
import '../../../core/di/dependency_injection.dart';
import '../../../core/services/activity_logger.dart';
import '../../analytics/presentation/cubit/analytics_cubit.dart';
import '../../sales/presentation/cubit/sales_cubit.dart';
import '../../customers/data/repository/customer_repository_impl.dart';

String _formatInvoiceQuantity(double quantity) {
  return quantity == quantity.truncateToDouble()
      ? quantity.toInt().toString()
      : quantity.toString();
}

class InvoiceScreen extends StatefulWidget {
  final SalesRepository repository;
  final User currentUser;

  const InvoiceScreen({
    Key? key,
    required this.repository,
    required this.currentUser,
  }) : super(key: key);

  @override
  State<InvoiceScreen> createState() => _InvoiceScreenState();
}

class _InvoiceScreenState extends State<InvoiceScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  final TextEditingController _barcodeSearchController =
      TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();

  final StringBuffer _hidBuffer = StringBuffer();
  Timer? _hidTimer;
  Timer? _debounceTimer;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _animationController.forward();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<InvoiceCubit>().loadSales();
    });

    _searchFocusNode.addListener(_onFocusChange);
    RawKeyboard.instance.addListener(_onRawKey);
  }

  void _onFocusChange() {
    if (_searchFocusNode.hasFocus) {
      RawKeyboard.instance.removeListener(_onRawKey);
    } else {
      RawKeyboard.instance.addListener(_onRawKey);
    }
  }

  @override
  void dispose() {
    _searchFocusNode.removeListener(_onFocusChange);
    RawKeyboard.instance.removeListener(_onRawKey);
    _hidTimer?.cancel();
    _debounceTimer?.cancel();
    _barcodeSearchController.dispose();
    _searchFocusNode.dispose();
    _animationController.dispose();
    super.dispose();
  }

  void _onRawKey(RawKeyEvent event) {
    if (event is! RawKeyDownEvent) return;

    if (ModalRoute.of(context)?.isCurrent != true) return;

    if (_searchFocusNode.hasFocus) return;

    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      _hidTimer?.cancel();
      final code = _hidBuffer.toString().trim();
      _hidBuffer.clear();
      _searchByBarcode(code);
      return;
    }
    String? ch = event.character;
    if ((ch == null || ch.isEmpty) && event.logicalKey.keyLabel.length == 1) {
      ch = event.logicalKey.keyLabel;
    }
    if (ch != null && ch.isNotEmpty && ch.codeUnitAt(0) >= 32) {
      _hidBuffer.write(ch);
      _barcodeSearchController.text = _hidBuffer.toString();

      _hidTimer?.cancel();
      _hidTimer = Timer(const Duration(milliseconds: 120), () {
        final code = _hidBuffer.toString().trim();
        _hidBuffer.clear();
        _searchByBarcode(code);
      });
    }
  }

  void _searchByBarcode(String barcode) {
    context.read<InvoiceCubit>().setSearchQuery(barcode);
  }

  void _onSearchChanged(String query) {
    _debounceTimer?.cancel();
    if (query.isEmpty) {
      _searchByBarcode('');
      return;
    }
    _debounceTimer = Timer(const Duration(milliseconds: 500), () {
      _searchByBarcode(query);
    });
  }

  void _clearFilters() {
    context.read<InvoiceCubit>().resetFilters();
  }

  Future<void> _selectDate(bool isStart) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme.light(
              primary: AppColors.primaryColor,
              onPrimary: Colors.white,
            ),
          ),
          child: child!,
        );
      },
    );
    if (picked != null) {
      final cubit = context.read<InvoiceCubit>();
      cubit.setDate(isStart ? picked : cubit.state.startDate,
          !isStart ? picked : cubit.state.endDate);
    }
  }

  Future<void> _handleDeleteSale(Sale sale) async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.confirmDeleteInvoiceTitle),
        content: Text(l10n.confirmDeleteInvoiceMessage(sale.id)),
        actions: [
          TextButton(
            child: Text(l10n.cancel),
            onPressed: () => Navigator.of(ctx).pop(false),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.errorColor,
            ),
            child: Text(l10n.confirmDeleteBtn),
            onPressed: () => Navigator.of(ctx).pop(true),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      await context.read<InvoiceCubit>().deleteSale(sale.id);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.invoiceDeletedSuccess)),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.invoiceDeleteFailed(e.toString()))),
        );
      }
    }
  }

  Future<void> _handleReturnSale(Sale sale) async {
    final l10n = AppLocalizations.of(context);
    final refundService = RefundCalculationService(widget.repository);

    final selectedItems = await showDialog<List<RefundItem>>(
      context: context,
      builder: (ctx) => PartialRefundDialog(
        originalSale: sale,
        refundService: refundService,
      ),
    );

    if (selectedItems == null || selectedItems.isEmpty) return;

    await context.read<InvoiceCubit>().createPartialRefund(
          originalSale: sale,
          itemsToRefund: selectedItems,
        );

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.refundSuccess)),
      );
    }
  }

  Future<void> _handleExchangeSale(Sale sale) async {
    final exchangeResult = await showDialog<ExchangeResult?>(
      context: context,
      builder: (ctx) => ExchangeDialog(
        originalSale: sale,
        currentUser: widget.currentUser,
      ),
    );

    if (exchangeResult == null) return;
    await getIt<ActivityLogger>().logExchangeOnce(
      exchangeId: exchangeResult.exchangeDocumentId,
      originalSaleId: sale.id,
      replacementSaleId: exchangeResult.replacementSaleId,
      userName: widget.currentUser.name,
    );
    await _refreshAfterExchange(
      originalSaleId: sale.id,
      replacementSaleId: exchangeResult.replacementSaleId,
      replacementDocumentReference: exchangeResult.replacementDocumentReference,
    );
    if (exchangeResult.openReplacementInvoice &&
        exchangeResult.replacementSaleId.isNotEmpty) {
      final replacement = await context
          .read<InvoiceCubit>()
          .loadSaleById(exchangeResult.replacementSaleId);
      if (replacement != null && mounted) {
        await _openInvoice(replacement);
      }
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Exchange completed: ${exchangeResult.exchangeDocumentId}',
          ),
        ),
      );
    }
  }

  Future<void> _refreshAfterExchange({
    required String originalSaleId,
    required String replacementSaleId,
    required String replacementDocumentReference,
  }) async {
    final invoiceCubit = context.read<InvoiceCubit>();
    final reloads = <Future<void>>[
      invoiceCubit.refreshAfterExchange(
        originalSaleId: originalSaleId,
        replacementSaleId: replacementSaleId,
        replacementDocumentReference: replacementDocumentReference,
      ),
    ];
    if (getIt.isRegistered<InvoiceCubit>() &&
        !identical(invoiceCubit, getIt<InvoiceCubit>())) {
      reloads.add(getIt<InvoiceCubit>().refreshAfterExchange(
        originalSaleId: originalSaleId,
        replacementSaleId: replacementSaleId,
        replacementDocumentReference: replacementDocumentReference,
      ));
    }
    if (getIt.isRegistered<SalesCubit>()) {
      reloads.add(getIt<SalesCubit>().load());
    }
    if (getIt.isRegistered<AnalyticsCubit>()) {
      reloads.add(getIt<AnalyticsCubit>().loadAnalytics());
    }
    await Future.wait(reloads);
  }

  Future<void> _deleteInvoices(
      DateTime? startDate, DateTime? endDate, String searchQuery) async {
    final l10n = AppLocalizations.of(context);
    if (startDate == null || endDate == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.selectDateRangeFirst),
          backgroundColor: AppColors.errorColor,
        ),
      );
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.confirmDeleteInvoicesTitle),
        content: Text(l10n.confirmDeleteInvoicesMessage(
            startDate.year,
            startDate.month,
            startDate.day,
            endDate.year,
            endDate.month,
            endDate.day)),
        actions: [
          TextButton(
            child: Text(l10n.cancel),
            onPressed: () => Navigator.of(ctx).pop(false),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.errorColor,
            ),
            child: Text(l10n.confirmDeleteBtn),
            onPressed: () => Navigator.of(ctx).pop(true),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      await context
          .read<InvoiceCubit>()
          .deleteInvoices(startDate, endDate, searchQuery);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.invoicesDeletedSuccess)),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.invoicesDeleteFailed(e.toString()))),
        );
      }
    }
  }

  Future<void> _openInvoice(Sale sale, {bool receiptMode = false}) async {
    final l10n = AppLocalizations.of(context);
    final displayItems = sale.currentDisplayItems;
    final subtotal = sale.currentDisplayTotal;
    final cashierName = sale.cashierName ?? l10n.cashier;
    final reference = sale.referenceNumber ?? sale.id;
    final customerResult = sale.customerId == null
        ? null
        : await getIt<CustomerRepository>().getCustomerById(sale.customerId!);
    final customer = customerResult?.fold((_) => null, (value) => value);

    final data = InvoiceData(
      invoiceId: reference,
      date: sale.date,
      storeName: getIt<SettingsCubit>().currentStoreInfo?.name ?? '',
      storeAddress: getIt<SettingsCubit>().currentStoreInfo?.address ?? '',
      storePhone: getIt<SettingsCubit>().currentStoreInfo?.phone ?? '',
      cashierName: cashierName,
      lines: displayItems
          .map((it) => InvoiceLine(
                name: it.name,
                price: it.price,
                qty: sale.isRefund ? it.quantity : it.remainingDisplayQuantity,
                qtyDisplay: sale.hasReturnedItems
                    ? '${_formatInvoiceQuantity(it.sellingQuantity ?? it.quantity)} / '
                        '${_formatInvoiceQuantity(it.remainingDisplayQuantity)}'
                    : null,
              ))
          .toList(),
      subtotal: subtotal,
      discount: 0.0,
      tax: 0.0,
      grandTotal: subtotal,
      paymentMethod: sale.paymentMethod,
      customerName: customer?.name,
      customerCode: customer?.code ?? sale.customerCode,
      customerAddress: customer?.address,
      customerCommercialRegister: customer?.commercialRegister,
      customerTaxId: customer?.taxId,
      customerNis: customer?.nis,
      customerAi: customer?.ai,
      customerReference: customer?.customerReference,
      documentTitle: sale.isRefund ? l10n.refundInvoice : null,
      originalInvoiceReference: sale.isRefund
          ? sale.refundOriginalInvoiceReference ?? sale.refundOriginalInvoiceId
          : null,
      originalTotal: sale.hasReturnedItems ? sale.total : null,
      refundedTotal: sale.hasReturnedItems ? sale.effectiveRefundedTotal : null,
      exchangedTotal:
          sale.hasReturnedItems ? sale.effectiveExchangedTotal : null,
      remainingTotal:
          sale.hasReturnedItems ? sale.remainingFinancialTotal : null,
    );

    await Navigator.of(context).push(PageRouteBuilder(
      pageBuilder: (context, animation, secondaryAnimation) =>
          InvoicePreviewScreen(data: data, receiptMode: receiptMode),
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        return FadeTransition(
          opacity: animation,
          child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0.0, 0.1),
                end: Offset.zero,
              ).animate(
                  CurvedAnimation(parent: animation, curve: Curves.easeOut)),
              child: child),
        );
      },
    ));
  }

  Future<void> _handlePrintInvoice(Sale sale) async {
    await _openInvoice(sale);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final screenWidth = MediaQuery.of(context).size.width;
    final isDesktop = screenWidth >= 1024;
    return BlocBuilder<InvoiceCubit, InvoiceState>(
      builder: (context, state) {
        return Directionality(
          textDirection:
              l10n.localeName == 'ar' ? TextDirection.rtl : TextDirection.ltr,
          child: Scaffold(
            backgroundColor: AppColors.backgroundColor,
            body: SafeArea(
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  isDesktop ? 32 : 24,
                  8,
                  isDesktop ? 32 : 24,
                  isDesktop ? 32 : 24,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    FadeTransition(
                      opacity: _animationController,
                      child: SlideTransition(
                        position: Tween<Offset>(
                          begin: const Offset(0, -0.2),
                          end: Offset.zero,
                        ).animate(CurvedAnimation(
                          parent: _animationController,
                          curve: Curves.easeOut,
                        )),
                        child: ScreenHeader(
                          title: l10n.invoices,
                          icon: LucideIcons.fileSpreadsheet,
                          subtitle: l10n.invoicesSubtitle,
                          subtitleColor: AppColors.mutedColor,
                          iconColor: AppColors.primaryColor,
                        ),
                      ),
                    ),
                    const ScreenHeaderGap(height: 24),
                    if (isDesktop)
                      _buildInvoiceFilters(state, isDesktop)
                    else
                      Flexible(
                        fit: FlexFit.loose,
                        child: SingleChildScrollView(
                          child: _buildInvoiceFilters(state, isDesktop),
                        ),
                      ),
                    const SizedBox(height: 24),
                    Expanded(
                      child: InvoiceListSection(
                        loading: state.loading,
                        sales: state.sales,
                        startDate: state.startDate,
                        endDate: state.endDate,
                        animationController: _animationController,
                        onOpenInvoice: _openInvoice,
                        onDeleteSale: _handleDeleteSale,
                        onReturnSale: _handleReturnSale,
                        onExchangeSale: _handleExchangeSale,
                        onPrintInvoice: _handlePrintInvoice,
                        onReceipt: (sale) =>
                            _openInvoice(sale, receiptMode: true),
                        isManager:
                            widget.currentUser.userType == UserType.manager,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildInvoiceFilters(InvoiceState state, bool isDesktop) {
    return FadeTransition(
      opacity: _animationController,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, -0.1),
          end: Offset.zero,
        ).animate(CurvedAnimation(
          parent: _animationController,
          curve: Curves.easeOut,
        )),
        child: InvoiceFilterSection(
          isDesktop: isDesktop,
          barcodeSearchController: _barcodeSearchController,
          focusNode: _searchFocusNode,
          searchQuery: state.searchQuery,
          onSearch: _searchByBarcode,
          onChanged: _onSearchChanged,
          onClearSearch: () {
            _barcodeSearchController.clear();
            _searchByBarcode('');
          },
          startDate: state.startDate,
          endDate: state.endDate,
          onSelectDate: _selectDate,
          onClearFilters: _clearFilters,
          onDeleteInvoices: () => _deleteInvoices(
              state.startDate, state.endDate, state.searchQuery),
          filterType: state.filterType,
          onFilterTypeChanged: (type) =>
              context.read<InvoiceCubit>().setFilterType(type),
          isManager: widget.currentUser.userType == UserType.manager,
        ),
      ),
    );
  }
}
