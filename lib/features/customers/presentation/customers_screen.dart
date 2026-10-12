import 'package:flutter/material.dart';

import '../../../core/constants/app_colors.dart';
import 'package:bayaa_pos/l10n/app_localizations.dart';

import '../data/models/customer_model.dart';
import '../data/repository/customer_repository_impl.dart';
import 'entity_history_dialog.dart';

class CustomersScreen extends StatefulWidget {
  const CustomersScreen({super.key, required this.repository});

  final CustomerRepository repository;

  @override
  State<CustomersScreen> createState() => _CustomersScreenState();
}

class _CustomersScreenState extends State<CustomersScreen> {
  final _searchController = TextEditingController();
  List<Customer> _customers = [];
  final Map<String, double> _balances = {};
  bool _loading = true;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load([String query = '']) async {
    setState(() {
      _loading = true;
      _errorMessage = null;
    });

    final result = query.trim().isEmpty
        ? await widget.repository.getAllCustomers()
        : await widget.repository.searchCustomers(query);

    if (!mounted) return;

    await result.fold(
      (failure) async {
        if (!mounted) return;
        setState(() {
          _errorMessage = failure.message;
          _customers = const [];
          _balances.clear();
        });
      },
      (customers) async {
        _customers = customers;
        _balances.clear();
        for (final customer in customers) {
          final balance =
              await widget.repository.getCustomerBalance(customer.id);
          balance.fold(
            (_) => _balances[customer.id] = 0.0,
            (amount) => _balances[customer.id] = amount,
          );
        }
        if (mounted) {
          setState(() {});
        }
      },
    );

    if (mounted) {
      setState(() => _loading = false);
    }
  }

  Future<void> _edit([Customer? customer]) async {
    final result = await showDialog<Customer>(
      context: context,
      builder: (_) => _CustomerDialog(customer: customer),
    );
    if (result == null) return;

    final saved = customer == null
        ? await widget.repository.createCustomer(result)
        : await widget.repository.updateCustomer(result);

    saved.fold(
      (failure) => ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(failure.message))),
      (_) => _load(_searchController.text),
    );
  }

  Future<void> _showDetails(Customer customer) async {
    await showCustomerHistory(
      context,
      customer: customer,
      repository: widget.repository,
    );
  }

  String _formatCurrency(double value, AppLocalizations l10n) {
    return '${value.toStringAsFixed(2)} ${l10n.currencyEg}';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: Text('${_customers.length} customers',
                style: const TextStyle(color: AppColors.mutedColor)),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchController,
                  decoration: InputDecoration(
                    labelText: l10n.search,
                    hintText: l10n.search,
                    prefixIcon: const Icon(Icons.search),
                    border: const OutlineInputBorder(),
                  ),
                  onChanged: _load,
                ),
              ),
              const SizedBox(width: 12),
              FilledButton.icon(
                onPressed: () => _edit(),
                icon: const Icon(Icons.add),
                label: Text(l10n.addCustomer),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _errorMessage != null
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(_errorMessage!),
                        ),
                      )
                    : _customers.isEmpty
                        ? Center(
                            child: Padding(
                              padding: const EdgeInsets.all(24),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(l10n.noCustomers),
                                  const SizedBox(height: 12),
                                  FilledButton.icon(
                                    onPressed: () => _edit(),
                                    icon: const Icon(Icons.add),
                                    label: Text(l10n.addCustomer),
                                  ),
                                ],
                              ),
                            ),
                          )
                        : LayoutBuilder(
                            builder: (context, constraints) {
                              return SingleChildScrollView(
                                scrollDirection: Axis.vertical,
                                child: SingleChildScrollView(
                                  scrollDirection: Axis.horizontal,
                                  child: ConstrainedBox(
                                    constraints: BoxConstraints(
                                      minWidth: constraints.maxWidth,
                                    ),
                                    child: DataTable(
                                      headingRowColor:
                                          WidgetStateProperty.resolveWith(
                                        (states) => Theme.of(context)
                                            .colorScheme
                                            .surfaceContainerHighest,
                                      ),
                                      columnSpacing: 18,
                                      horizontalMargin: 18,
                                      columns: [
                                        DataColumn(label: Text(l10n.name)),
                                        DataColumn(label: Text(l10n.code)),
                                        DataColumn(label: Text(l10n.phone)),
                                        DataColumn(
                                          label: Text(l10n.outstandingBalance),
                                        ),
                                        const DataColumn(
                                            label: SizedBox.shrink()),
                                      ],
                                      rows: _customers.map((customer) {
                                        final balance =
                                            _balances[customer.id] ?? 0.0;

                                        return DataRow(
                                          cells: [
                                            DataCell(
                                              GestureDetector(
                                                onTap: () =>
                                                    _showDetails(customer),
                                                child: Column(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.start,
                                                  mainAxisAlignment:
                                                      MainAxisAlignment.center,
                                                  children: [
                                                    Text(
                                                      customer.name,
                                                      style: const TextStyle(
                                                        fontWeight:
                                                            FontWeight.w600,
                                                      ),
                                                    ),
                                                    if (customer
                                                        .registrationName
                                                        .trim()
                                                        .isNotEmpty)
                                                      Text(
                                                        customer
                                                            .registrationName,
                                                        style: Theme.of(context)
                                                            .textTheme
                                                            .bodySmall,
                                                      ),
                                                  ],
                                                ),
                                              ),
                                            ),
                                            DataCell(Text(customer.code)),
                                            DataCell(Text(
                                              customer.phone.isNotEmpty
                                                  ? customer.phone
                                                  : customer.mobile.isNotEmpty
                                                      ? customer.mobile
                                                      : '—',
                                            )),
                                            DataCell(Text(
                                              _formatCurrency(balance, l10n),
                                              style: TextStyle(
                                                fontWeight: FontWeight.w600,
                                                color: balance > 0
                                                    ? Colors.orange.shade700
                                                    : balance < 0
                                                        ? Colors.green.shade700
                                                        : Theme.of(context)
                                                            .textTheme
                                                            .bodyMedium
                                                            ?.color,
                                              ),
                                            )),
                                            DataCell(Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                IconButton(
                                                  tooltip: l10n.search,
                                                  onPressed: () =>
                                                      _showDetails(customer),
                                                  icon: const Icon(Icons
                                                      .visibility_outlined),
                                                ),
                                                IconButton(
                                                  tooltip: l10n.edit,
                                                  onPressed: () =>
                                                      _edit(customer),
                                                  icon: const Icon(
                                                      Icons.edit_outlined),
                                                ),
                                              ],
                                            )),
                                          ],
                                        );
                                      }).toList(),
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
          ),
        ],
      ),
    );
  }
}

class _CustomerDialog extends StatefulWidget {
  const _CustomerDialog({this.customer});
  final Customer? customer;

  @override
  State<_CustomerDialog> createState() => _CustomerDialogState();
}

class _CustomerDialogState extends State<_CustomerDialog> {
  late final TextEditingController _code;
  late final TextEditingController _name;
  late final TextEditingController _phone;
  late final TextEditingController _email;
  late final TextEditingController _address;
  late final TextEditingController _notes;
  late final TextEditingController _reference;
  late final TextEditingController _commercialRegister;
  late final TextEditingController _taxId;
  late final TextEditingController _nis;
  late final TextEditingController _ai;

  @override
  void initState() {
    super.initState();
    _code = TextEditingController(text: widget.customer?.code);
    _name = TextEditingController(text: widget.customer?.name);
    _phone = TextEditingController(text: widget.customer?.phone);
    _email = TextEditingController(text: widget.customer?.email ?? '');
    _address = TextEditingController(text: widget.customer?.address ?? '');
    _notes = TextEditingController(text: widget.customer?.notes ?? '');
    _reference =
        TextEditingController(text: widget.customer?.customerReference ?? '');
    _commercialRegister =
        TextEditingController(text: widget.customer?.commercialRegister ?? '');
    _taxId = TextEditingController(text: widget.customer?.taxId ?? '');
    _nis = TextEditingController(text: widget.customer?.nis ?? '');
    _ai = TextEditingController(text: widget.customer?.ai ?? '');
  }

  @override
  void dispose() {
    _code.dispose();
    _name.dispose();
    _phone.dispose();
    _email.dispose();
    _address.dispose();
    _notes.dispose();
    _reference.dispose();
    _commercialRegister.dispose();
    _taxId.dispose();
    _nis.dispose();
    _ai.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return AlertDialog(
      title: Text(
        widget.customer == null ? l10n.addCustomer : l10n.edit,
      ),
      content: SizedBox(
        width: (MediaQuery.sizeOf(context).width - 32).clamp(0.0, 520.0),
        child: SingleChildScrollView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          child: Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              if (widget.customer != null)
                SizedBox(
                  width: 220,
                  child: TextField(
                    controller: _code,
                    readOnly: true,
                    decoration: InputDecoration(labelText: l10n.code),
                  ),
                ),
              SizedBox(
                width: 220,
                child: TextField(
                  controller: _name,
                  decoration: const InputDecoration(
                    labelText: 'Customer / Company Name',
                  ),
                ),
              ),
              SizedBox(
                width: 220,
                child: TextField(
                  controller: _phone,
                  decoration: InputDecoration(labelText: l10n.phone),
                ),
              ),
              SizedBox(
                width: 220,
                child: TextField(
                  controller: _reference,
                  decoration:
                      const InputDecoration(labelText: 'Customer Reference'),
                ),
              ),
              SizedBox(
                width: 220,
                child: TextField(
                  controller: _email,
                  decoration: const InputDecoration(labelText: 'Email Address'),
                  keyboardType: TextInputType.emailAddress,
                ),
              ),
              SizedBox(
                width: 460,
                child: TextField(
                  controller: _address,
                  decoration: const InputDecoration(labelText: 'Address'),
                  minLines: 2,
                  maxLines: 4,
                ),
              ),
              SizedBox(
                width: 220,
                child: TextField(
                  controller: _commercialRegister,
                  decoration: const InputDecoration(labelText: 'RC Number'),
                ),
              ),
              SizedBox(
                width: 220,
                child: TextField(
                  controller: _taxId,
                  decoration:
                      const InputDecoration(labelText: 'Tax ID (NIF / MF)'),
                ),
              ),
              SizedBox(
                width: 220,
                child: TextField(
                    controller: _nis,
                    decoration: const InputDecoration(labelText: 'NIS')),
              ),
              SizedBox(
                width: 220,
                child: TextField(
                    controller: _ai,
                    decoration: const InputDecoration(labelText: 'AI')),
              ),
              SizedBox(
                width: 460,
                child: TextField(
                  controller: _notes,
                  decoration: InputDecoration(labelText: l10n.notes),
                  minLines: 2,
                  maxLines: 5,
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
        FilledButton(
          onPressed: () => Navigator.pop(
            context,
            Customer(
              id: widget.customer?.id ??
                  DateTime.now().microsecondsSinceEpoch.toString(),
              code: widget.customer?.code ?? '',
              name: _name.text.trim(),
              phone: _phone.text.trim(),
              address: _address.text.trim(),
              email: _email.text.trim().isEmpty ? null : _email.text.trim(),
              notes: _notes.text.trim().isEmpty ? null : _notes.text.trim(),
              customerReference: _reference.text.trim().isEmpty
                  ? null
                  : _reference.text.trim(),
              commercialRegister: _commercialRegister.text.trim().isEmpty
                  ? null
                  : _commercialRegister.text.trim(),
              taxId: _taxId.text.trim().isEmpty ? null : _taxId.text.trim(),
              nis: _nis.text.trim().isEmpty ? null : _nis.text.trim(),
              ai: _ai.text.trim().isEmpty ? null : _ai.text.trim(),
              registrationName: widget.customer?.registrationName ?? '',
              activity: widget.customer?.activity ?? 'Retail',
              category: widget.customer?.category ?? 'General',
              mobile: widget.customer?.mobile ?? '',
              creditLimit: widget.customer?.creditLimit ?? 0.0,
              openingBalance: widget.customer?.openingBalance ?? 0.0,
              taxNumber: widget.customer?.taxNumber,
              registrationNumber: widget.customer?.registrationNumber,
              currentBalance: widget.customer?.currentBalance ?? 0.0,
              isActive: widget.customer?.isActive ?? true,
              createdAt: widget.customer?.createdAt ?? DateTime.now(),
              updatedAt: DateTime.now(),
            ),
          ),
          child: Text(l10n.save),
        ),
      ],
    );
  }
}
