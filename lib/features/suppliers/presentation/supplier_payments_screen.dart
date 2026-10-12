import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../../../core/di/dependency_injection.dart';
import '../../../core/presentation/widgets/transaction_status_panel.dart';
import '../../../core/presentation/widgets/searchable_selection_dialog.dart';
import '../../../l10n/app_localizations.dart';
import '../../auth/presentation/cubit/user_cubit.dart';
import '../data/models/supplier_model.dart';
import '../data/models/supplier_payment_model.dart';
import '../data/repository/supplier_payment_repository_impl.dart';
import '../data/repository/supplier_repository_impl.dart';

class SupplierPaymentsScreen extends StatefulWidget {
  const SupplierPaymentsScreen({super.key, required this.repository});

  final SupplierPaymentRepository repository;

  @override
  State<SupplierPaymentsScreen> createState() => _SupplierPaymentsScreenState();
}

class _SupplierPaymentsScreenState extends State<SupplierPaymentsScreen> {
  Supplier? _supplier;
  double _balance = 0;
  DateTime _paymentDate = DateTime.now();
  final _amount = TextEditingController();
  final _reference = TextEditingController();
  final _notes = TextEditingController();
  String _method = 'cash';
  bool _saving = false;
  TransactionStatus _status = TransactionStatus.ready;
  String? _statusMessage;
  List<String> _statusDetails = const [];
  bool _completed = false;
  double _completedAmount = 0;
  double _completedRemaining = 0;
  String _completedReference = '—';

  void _startNewPayment() {
    setState(() {
      _supplier = null;
      _balance = 0;
      _amount.clear();
      _reference.clear();
      _notes.clear();
      _paymentDate = DateTime.now();
      _status = TransactionStatus.ready;
      _statusMessage = null;
      _statusDetails = const [];
      _completed = false;
    });
  }

  @override
  void initState() {
    super.initState();
  }

  Future<void> _selectSupplier() async {
    final result = await getIt<SupplierRepository>().getAllSuppliers();
    if (!mounted) return;
    result.fold((_) {}, (suppliers) async {
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
      final balance =
          await getIt<SupplierRepository>().getSupplierBalance(selected.id);
      if (!mounted) return;
      setState(() {
        _supplier = selected;
        _balance = balance.getOrElse(() => 0);
      });
    });
  }

  Future<void> _save() async {
    if (_saving) return;
    final amount = double.tryParse(_amount.text.trim().replaceAll(',', ''));
    if (_supplier == null || amount == null || amount <= 0) {
      setState(() {
        _status = TransactionStatus.error;
        _statusMessage = 'Select a supplier and enter a valid payment amount.';
      });
      return;
    }
    setState(() {
      _saving = true;
      _status = TransactionStatus.processing;
      _statusMessage = 'Recording payment...';
    });
    final result = await widget.repository.createPayment(SupplierPayment(
      id: const Uuid().v4(),
      supplierId: _supplier!.id,
      amount: amount,
      paymentDate: DateTime.now(),
      paymentMethod: _method,
      reference: '',
      notes: _notes.text.trim().isEmpty ? null : _notes.text.trim(),
      createdBy: getIt<UserCubit>().currentUser.username,
    ));
    if (!mounted) return;
    _saving = false;
    result.fold(
      (failure) => setState(() {
        _status = TransactionStatus.error;
        _statusMessage = 'Unable to record payment. Please try again.';
      }),
      (_) {
        final reference = _reference.text.trim();
        final remaining = _balance - amount;
        setState(() {
          _completed = true;
          _completedAmount = amount;
          _completedRemaining = remaining;
          _completedReference = reference.isEmpty ? '—' : reference;
          _status = TransactionStatus.completed;
          _statusMessage = 'Payment recorded successfully.';
          _statusDetails = [
            'Reference: $_completedReference'
          ];
        });
      },
    );
  }

  @override
  void dispose() {
    _amount.dispose();
    _reference.dispose();
    _notes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    if (_completed) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: _PaymentCompletedCard(
          title: 'Payment recorded',
          reference: _completedReference,
          amount: _completedAmount,
          remaining: _completedRemaining,
          supplierName: _supplier?.name ?? '—',
          onNewPayment: _startNewPayment,
          formatAmount: (value) => _formatAmount(value, l10n),
        ),
      );
    }
    final amount =
        double.tryParse(_amount.text.trim().replaceAll(',', '')) ?? 0;
    final remaining = _balance - amount;
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const CircleAvatar(
                            child: Icon(Icons.business_outlined),
                          ),
                          title: Text(_supplier?.name ?? l10n.selectSupplier),
                          subtitle: Text(_supplier?.code ?? ''),
                        ),
                      ),
                      OutlinedButton.icon(
                        onPressed: _selectSupplier,
                        icon: const Icon(Icons.business_center_outlined),
                        label: Text(l10n.selectSupplier),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: _SummaryValue(
                          label: l10n.outstandingBalance,
                          value: _formatAmount(_balance, l10n),
                        ),
                      ),
                      Expanded(
                        child: _SummaryValue(
                          label: l10n.paymentAmount,
                          value: _formatAmount(amount, l10n),
                          accent: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                      Expanded(
                        child: _SummaryValue(
                          label: l10n.remainingBalance,
                          value: _formatAmount(remaining, l10n),
                          accent: remaining > 0
                              ? Colors.orange.shade700
                              : Colors.green.shade700,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _amount,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(
                    labelText: l10n.paymentAmount,
                    prefixIcon: const Icon(Icons.payments_outlined),
                    border: const OutlineInputBorder(),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: DropdownButtonFormField<String>(
                  value: _method,
                  decoration: InputDecoration(
                    labelText: l10n.paymentMethodLabel,
                    prefixIcon:
                        const Icon(Icons.account_balance_wallet_outlined),
                    border: const OutlineInputBorder(),
                  ),
                  items: [
                    DropdownMenuItem(value: 'cash', child: Text(l10n.cash)),
                  ],
                  onChanged: (value) =>
                      setState(() => _method = value ?? 'cash'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: InkWell(
                  onTap: () async {
                    final selected = await showDatePicker(
                      context: context,
                      initialDate: _paymentDate,
                      firstDate: DateTime(2000),
                      lastDate: DateTime(2100),
                    );
                    if (selected != null) {
                      setState(() => _paymentDate = selected);
                    }
                  },
                  child: InputDecorator(
                    decoration: InputDecoration(
                      labelText: l10n.paymentDate,
                      prefixIcon: const Icon(Icons.calendar_today_outlined),
                      border: const OutlineInputBorder(),
                    ),
                    child: Text(MaterialLocalizations.of(context)
                        .formatMediumDate(_paymentDate)),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _reference,
                  decoration: InputDecoration(
                    labelText: l10n.reference,
                    hintText: l10n.paymentReferenceHint,
                    suffixText: '*',
                    prefixIcon: const Icon(Icons.receipt_long_outlined),
                    border: const OutlineInputBorder(),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _notes,
            minLines: 2,
            maxLines: 3,
            decoration: InputDecoration(
              labelText: l10n.notes,
              prefixIcon: const Icon(Icons.notes_outlined),
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: FilledButton.icon(
              onPressed: _saving ? null : _save,
              icon: _saving
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.check),
              label:
                  Text(_saving ? 'Recording payment...' : l10n.confirmPayment),
            ),
          ),
          TransactionStatusPanel(
            status: _status,
            message: _statusMessage ?? '',
            details: _statusDetails,
          ),
        ],
      ),
    );
  }

  String _formatAmount(double value, AppLocalizations l10n) =>
      '${value.toStringAsFixed(2)} ${l10n.currencyEg}';
}

class _SummaryValue extends StatelessWidget {
  const _SummaryValue({
    required this.label,
    required this.value,
    this.accent,
  });

  final String label;
  final String value;
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(color: Colors.grey)),
        const SizedBox(height: 4),
        Text(
          value,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: accent,
          ),
        ),
      ],
    );
  }
}

class _PaymentCompletedCard extends StatelessWidget {
  const _PaymentCompletedCard({
    required this.title,
    required this.reference,
    required this.amount,
    required this.remaining,
    required this.supplierName,
    required this.onNewPayment,
    required this.formatAmount,
  });

  final String title;
  final String reference;
  final double amount;
  final double remaining;
  final String supplierName;
  final VoidCallback onNewPayment;
  final String Function(double) formatAmount;

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(Icons.check_circle, color: Colors.green, size: 52),
              const SizedBox(height: 12),
              Text(title,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 22, fontWeight: FontWeight.w800)),
              const SizedBox(height: 24),
              Text('Reference: $reference'),
              Text('Supplier: $supplierName'),
              Text('Amount: ${formatAmount(amount)}'),
              Text('Remaining balance: ${formatAmount(remaining)}'),
              const SizedBox(height: 24),
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: FilledButton.icon(
                  onPressed: onNewPayment,
                  icon: const Icon(Icons.add),
                  label: const Text('New Payment'),
                ),
              ),
            ],
          ),
        ),
      );
}
