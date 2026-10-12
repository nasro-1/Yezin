import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/presentation/widgets/transaction_status_panel.dart';
import '../../../l10n/app_localizations.dart';
import '../../invoice/domain/refund_calculation_service.dart';
import '../../invoice/presentation/cubit/invoice_cubit.dart';
import '../../invoice/presentation/cubit/invoice_state.dart';
import '../../invoice/presentation/widgets/partial_refund_dialog.dart';
import '../../sales/data/models/sale_model.dart';
import '../../sales/domain/sales_repository.dart';

enum CustomerReturnFilter { allEligible, partiallyReturned }

class CustomerReturnsScreen extends StatefulWidget {
  const CustomerReturnsScreen({super.key, required this.repository});

  final SalesRepository repository;

  static bool isEligibleSale(Sale sale) =>
      !sale.isRefund &&
      sale.customerId != null &&
      sale.saleItems.any((item) => item.quantity - item.refundedQuantity > 0);

  static List<Sale> eligibleSales(Iterable<Sale> sales) =>
      sales.where(isEligibleSale).toList();

  static List<Sale> filterCandidates(
    Iterable<Sale> sales, {
    String query = '',
    CustomerReturnFilter filter = CustomerReturnFilter.allEligible,
    DateTime? startDate,
    DateTime? endDate,
  }) {
    final normalizedQuery = query.trim().toLowerCase();
    return sales.where((sale) {
      final partiallyReturned =
          sale.saleItems.any((item) => item.refundedQuantity > 0);
      if (filter == CustomerReturnFilter.partiallyReturned &&
          !partiallyReturned) {
        return false;
      }
      if (startDate != null && sale.date.isBefore(startDate)) return false;
      if (endDate != null &&
          sale.date.isAfter(
              DateTime(endDate.year, endDate.month, endDate.day, 23, 59, 59))) {
        return false;
      }
      if (normalizedQuery.isEmpty) return true;
      return (sale.referenceNumber ?? '')
              .toLowerCase()
              .contains(normalizedQuery) ||
          (sale.customerName ?? '').toLowerCase().contains(normalizedQuery) ||
          (sale.customerCode ?? '').toLowerCase().contains(normalizedQuery) ||
          sale.saleItems.any((item) =>
              item.name.toLowerCase().contains(normalizedQuery) ||
              item.productId.toLowerCase().contains(normalizedQuery));
    }).toList();
  }

  @override
  State<CustomerReturnsScreen> createState() => _CustomerReturnsScreenState();
}

class _CustomerReturnsScreenState extends State<CustomerReturnsScreen> {
  late final InvoiceCubit _invoiceCubit;
  final _searchController = TextEditingController();
  CustomerReturnFilter _filter = CustomerReturnFilter.allEligible;
  DateTime? _startDate;
  DateTime? _endDate;
  bool _processingReturn = false;
  TransactionStatus _returnStatus = TransactionStatus.ready;
  String? _returnStatusMessage;

  @override
  void initState() {
    super.initState();
    _invoiceCubit = InvoiceCubit(widget.repository);
    _invoiceCubit.loadCustomerReturnCandidates();
  }

  @override
  void dispose() {
    _invoiceCubit.close();
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<InvoiceCubit, InvoiceState>(
      bloc: _invoiceCubit,
      builder: (context, state) {
        final candidates = CustomerReturnsScreen.filterCandidates(
          state.sales,
          query: _searchController.text,
          filter: _filter,
          startDate: _startDate,
          endDate: _endDate,
        );
        return Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 4),
              _buildFilters(context),
              const SizedBox(height: 16),
              TransactionStatusPanel(
                status: _returnStatus,
                message: _returnStatusMessage ?? '',
              ),
              Expanded(
                child: state.loading
                    ? const Center(child: CircularProgressIndicator())
                    : state.errorMessage != null
                        ? _buildError(context, state.errorMessage!)
                        : candidates.isEmpty
                            ? _buildEmpty(context, state.sales.isNotEmpty)
                            : ListView.separated(
                                itemCount: candidates.length,
                                separatorBuilder: (_, __) =>
                                    const SizedBox(height: 12),
                                itemBuilder: (_, index) => _CandidateCard(
                                  sale: candidates[index],
                                  onReturn: _processingReturn
                                      ? null
                                      : () => _handleReturn(candidates[index]),
                                ),
                              ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildFilters(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.borderColor),
      ),
      child: Column(
        children: [
          TextField(
            controller: _searchController,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              hintText: l10n.customerReturnsSearchHint,
              prefixIcon: const Icon(LucideIcons.search),
              suffixIcon: _searchController.text.isEmpty
                  ? null
                  : IconButton(
                      onPressed: () {
                        _searchController.clear();
                        setState(() {});
                      },
                      icon: const Icon(LucideIcons.x),
                    ),
              filled: true,
              fillColor: AppColors.backgroundColor,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide.none,
              ),
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _filterChip(l10n.allEligible, CustomerReturnFilter.allEligible),
              _filterChip(l10n.partiallyReturned,
                  CustomerReturnFilter.partiallyReturned),
              _dateButton(l10n.fromDate, true),
              _dateButton(l10n.toDate, false),
              TextButton.icon(
                onPressed: () {
                  _searchController.clear();
                  setState(() {
                    _filter = CustomerReturnFilter.allEligible;
                    _startDate = null;
                    _endDate = null;
                  });
                },
                icon: const Icon(LucideIcons.rotateCcw, size: 16),
                label: Text(l10n.clearFilters),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _filterChip(String label, CustomerReturnFilter filter) {
    final selected = _filter == filter;
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => setState(() => _filter = filter),
      selectedColor: AppColors.primaryColor,
      labelStyle: TextStyle(
        color: selected ? Colors.white : AppColors.textSecondary,
        fontWeight: FontWeight.w700,
      ),
    );
  }

  Widget _dateButton(String label, bool start) {
    final value = start ? _startDate : _endDate;
    return OutlinedButton.icon(
      onPressed: () async {
        final picked = await showDatePicker(
          context: context,
          initialDate: value ?? DateTime.now(),
          firstDate: DateTime(2020),
          lastDate: DateTime.now(),
        );
        if (picked != null) {
          setState(() {
            if (start) {
              _startDate = picked;
            } else {
              _endDate = picked;
            }
          });
        }
      },
      icon: const Icon(LucideIcons.calendarDays, size: 16),
      label:
          Text(value == null ? label : DateFormat('yyyy-MM-dd').format(value)),
    );
  }

  Widget _buildEmpty(BuildContext context, bool hasCandidates) {
    final l10n = AppLocalizations.of(context);
    return Center(
      child: Text(
        hasCandidates ? l10n.noCustomerReturnsMatch : l10n.noCustomerReturns,
        style: const TextStyle(color: AppColors.mutedColor),
      ),
    );
  }

  Widget _buildError(BuildContext context, String message) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline,
              color: AppColors.errorColor, size: 42),
          const SizedBox(height: 10),
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 12),
          ElevatedButton(
            onPressed: _invoiceCubit.loadCustomerReturnCandidates,
            child: Text(AppLocalizations.of(context).retry),
          ),
        ],
      ),
    );
  }

  Future<void> _handleReturn(Sale sale) async {
    if (_processingReturn) return;
    final selectedItems = await showDialog<List<RefundItem>>(
      context: context,
      builder: (_) => PartialRefundDialog(
        originalSale: sale,
        refundService: RefundCalculationService(widget.repository),
        isCustomerReturn: true,
      ),
    );
    if (selectedItems == null || selectedItems.isEmpty || !mounted) return;
    setState(() {
      _processingReturn = true;
      _returnStatus = TransactionStatus.processing;
      _returnStatusMessage = 'Posting return transaction...';
    });
    try {
      await _invoiceCubit.createPartialRefund(
        originalSale: sale,
        itemsToRefund: selectedItems,
      );
      await _invoiceCubit.loadCustomerReturnCandidates();
      if (mounted) {
        setState(() {
          _processingReturn = false;
          _returnStatus = TransactionStatus.completed;
          _returnStatusMessage = 'Return completed successfully.';
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context).refundSuccess)),
        );
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _processingReturn = false;
          _returnStatus = TransactionStatus.error;
          _returnStatusMessage =
              'Unable to complete the return. Please try again.';
        });
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Unable to complete the return.')));
      }
    }
  }
}

class _CandidateCard extends StatelessWidget {
  const _CandidateCard({required this.sale, required this.onReturn});

  final Sale sale;
  final VoidCallback? onReturn;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final returned = sale.saleItems
        .fold<double>(0, (sum, item) => sum + item.refundedQuantity);
    final sold =
        sale.saleItems.fold<double>(0, (sum, item) => sum + item.quantity);
    final returnable = sold - returned;
    final partial = returned > 0;
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: AppColors.borderColor),
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Row(
          children: [
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                color: AppColors.primaryColor.withOpacity(0.08),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(LucideIcons.fileText,
                  color: AppColors.primaryColor),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Wrap(
                spacing: 22,
                runSpacing: 10,
                children: [
                  _field(l10n.invoiceLabel, sale.referenceNumber ?? sale.id),
                  _field(l10n.customerLabel,
                      sale.customerName ?? sale.customerId ?? ''),
                  _field(l10n.customerCodeLabel, sale.customerCode ?? ''),
                  _field(
                      l10n.datePdf, DateFormat('yyyy-MM-dd').format(sale.date)),
                  _field(l10n.totalColumn,
                      '${sale.total.toStringAsFixed(2)} ${l10n.currencyEg}'),
                  _field(l10n.returnableLabel, '$returnable / $sold'),
                  _status(l10n, partial),
                ],
              ),
            ),
            const SizedBox(width: 14),
            ElevatedButton.icon(
              onPressed: onReturn,
              icon: const Icon(LucideIcons.cornerUpLeft, size: 17),
              label: Text(partial ? l10n.continueReturn : l10n.startReturn),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primaryColor,
                foregroundColor: Colors.white,
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _field(String label, String value) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(
                  color: AppColors.mutedColor,
                  fontSize: 11,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 3),
          Text(value,
              style:
                  const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
        ],
      );

  Widget _status(AppLocalizations l10n, bool partial) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: BoxDecoration(
          color: (partial ? AppColors.warningColor : AppColors.successColor)
              .withOpacity(0.12),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          partial ? l10n.partiallyReturned : l10n.eligibleReturn,
          style: TextStyle(
            color: partial ? AppColors.warningColor : AppColors.successColor,
            fontSize: 11,
            fontWeight: FontWeight.w700,
          ),
        ),
      );
}
