import 'package:flutter/material.dart';
import 'package:bayaa_pos/l10n/app_localizations.dart';
import '../../../../core/constants/app_colors.dart';

import '../data/models/supplier_model.dart';
import '../data/repository/supplier_repository_impl.dart';
import '../../customers/presentation/entity_history_dialog.dart';

class SuppliersScreen extends StatefulWidget {
  const SuppliersScreen({super.key, required this.repository});

  final SupplierRepository repository;

  @override
  State<SuppliersScreen> createState() => _SuppliersScreenState();
}

class _SuppliersScreenState extends State<SuppliersScreen> {
  final _searchController = TextEditingController();
  List<Supplier> _suppliers = [];
  final Map<String, double> _balances = {};
  bool _loading = true;

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
    setState(() => _loading = true);
    final result = query.trim().isEmpty
        ? await widget.repository.getAllSuppliers()
        : await widget.repository.searchSuppliers(query);
    if (!mounted) return;
    await result.fold(
      (failure) async {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(failure.message)));
        }
        if (mounted) {
          setState(() {
            _suppliers = const [];
            _balances.clear();
          });
        }
      },
      (suppliers) async {
        _suppliers = suppliers;
        _balances.clear();
        for (final supplier in suppliers) {
          final balance =
              await widget.repository.getSupplierBalance(supplier.id);
          balance.fold(
            (_) => _balances[supplier.id] = 0.0,
            (amount) => _balances[supplier.id] = amount,
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

  Future<void> _edit([Supplier? supplier]) async {
    final result = await showDialog<Supplier>(
      context: context,
      builder: (_) => _SupplierDialog(supplier: supplier),
    );
    if (result == null) return;
    final saved = supplier == null
        ? await widget.repository.createSupplier(result)
        : await widget.repository.updateSupplier(result);
    saved.fold(
      (failure) => ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(failure.message))),
      (_) => _load(_searchController.text),
    );
  }

  Future<void> _showDetails(Supplier supplier) async {
    await showSupplierHistory(
      context,
      supplier: supplier,
      repository: widget.repository,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${_suppliers.length} suppliers',
                        style: const TextStyle(color: AppColors.mutedColor)),
                  ],
                ),
              ),
              Expanded(
                child: TextField(
                  controller: _searchController,
                  decoration: InputDecoration(
                    labelText: l10n.search,
                    prefixIcon: const Icon(Icons.search),
                  ),
                  onChanged: _load,
                ),
              ),
              FilledButton.icon(
                onPressed: () => _edit(),
                icon: const Icon(Icons.add),
                label: Text(l10n.addSupplier),
              ),
            ],
          ),
        ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _suppliers.isEmpty
                  ? Center(
                      child: Text(l10n.noSuppliers,
                          style: const TextStyle(color: AppColors.mutedColor)))
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      itemCount: _suppliers.length,
                      itemBuilder: (_, index) {
                        final supplier = _suppliers[index];
                        return Card(
                          child: ListTile(
                            contentPadding: const EdgeInsets.symmetric(
                                horizontal: 18, vertical: 6),
                            leading: const CircleAvatar(
                              backgroundColor: Color(0xFFE0E7FF),
                              child: Icon(Icons.business,
                                  color: AppColors.primaryColor),
                            ),
                            title: Text(supplier.name,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w700)),
                            subtitle:
                                Text('${supplier.code}  •  ${supplier.phone}'),
                            onTap: () => _showDetails(supplier),
                            trailing: Wrap(
                              spacing: 4,
                              children: [
                                Text(
                                  '${(_balances[supplier.id] ?? 0.0).toStringAsFixed(2)} ${supplier.currency}',
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w700),
                                ),
                                IconButton(
                                  tooltip: 'View history',
                                  icon: const Icon(Icons.visibility_outlined),
                                  onPressed: () => _showDetails(supplier),
                                ),
                                IconButton(
                                  tooltip: l10n.edit,
                                  icon: const Icon(Icons.edit_outlined),
                                  onPressed: () => _edit(supplier),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
        ),
      ],
    );
  }
}

class _SupplierDialog extends StatefulWidget {
  const _SupplierDialog({this.supplier});
  final Supplier? supplier;

  @override
  State<_SupplierDialog> createState() => _SupplierDialogState();
}

class _SupplierDialogState extends State<_SupplierDialog> {
  late final TextEditingController _code;
  late final TextEditingController _name;
  late final TextEditingController _phone;
  late final TextEditingController _reference;
  late final TextEditingController _contactPerson;
  late final TextEditingController _email;
  late final TextEditingController _address;
  late final TextEditingController _commercialRegister;
  late final TextEditingController _taxId;
  late final TextEditingController _nis;
  late final TextEditingController _ai;
  late final TextEditingController _bankName;
  late final TextEditingController _bankAccount;
  late final TextEditingController _notes;
  final _formKey = GlobalKey<FormState>();

  @override
  void initState() {
    super.initState();
    _code = TextEditingController(text: widget.supplier?.code);
    _name = TextEditingController(text: widget.supplier?.name);
    _phone = TextEditingController(text: widget.supplier?.phone);
    _reference =
        TextEditingController(text: widget.supplier?.supplierReference ?? '');
    _contactPerson =
        TextEditingController(text: widget.supplier?.contactPerson ?? '');
    _email = TextEditingController(text: widget.supplier?.email ?? '');
    _address = TextEditingController(text: widget.supplier?.address ?? '');
    _commercialRegister =
        TextEditingController(text: widget.supplier?.commercialRegister ?? '');
    _taxId = TextEditingController(text: widget.supplier?.taxId ?? '');
    _nis = TextEditingController(text: widget.supplier?.nis ?? '');
    _ai = TextEditingController(text: widget.supplier?.ai ?? '');
    _bankName = TextEditingController(text: widget.supplier?.bankName ?? '');
    _bankAccount =
        TextEditingController(text: widget.supplier?.bankAccount ?? '');
    _notes = TextEditingController(text: widget.supplier?.notes ?? '');
  }

  @override
  void dispose() {
    _code.dispose();
    _name.dispose();
    _phone.dispose();
    _reference.dispose();
    _contactPerson.dispose();
    _email.dispose();
    _address.dispose();
    _commercialRegister.dispose();
    _taxId.dispose();
    _nis.dispose();
    _ai.dispose();
    _bankName.dispose();
    _bankAccount.dispose();
    _notes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return AlertDialog(
      title: Text(
        widget.supplier == null ? l10n.addSupplier : l10n.edit,
      ),
      content: SizedBox(
        width: (MediaQuery.sizeOf(context).width - 32).clamp(0.0, 520.0),
        child: SingleChildScrollView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          child: Form(
            key: _formKey,
            child: Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                if (widget.supplier != null)
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
                    decoration: InputDecoration(labelText: l10n.name),
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
                        const InputDecoration(labelText: 'Supplier Reference'),
                  ),
                ),
                SizedBox(
                  width: 220,
                  child: TextField(
                    controller: _contactPerson,
                    decoration:
                        const InputDecoration(labelText: 'Contact Person'),
                  ),
                ),
                SizedBox(
                  width: 220,
                  child: TextField(
                    controller: _email,
                    decoration:
                        const InputDecoration(labelText: 'Email Address'),
                    keyboardType: TextInputType.emailAddress,
                  ),
                ),
                SizedBox(
                  width: 220,
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
                    decoration: const InputDecoration(labelText: 'NIS'),
                  ),
                ),
                SizedBox(
                  width: 220,
                  child: TextField(
                    controller: _ai,
                    decoration: const InputDecoration(labelText: 'AI'),
                  ),
                ),
                SizedBox(
                  width: 220,
                  child: TextField(
                    controller: _bankName,
                    decoration: const InputDecoration(labelText: 'Bank Name'),
                  ),
                ),
                SizedBox(
                  width: 220,
                  child: TextField(
                    controller: _bankAccount,
                    decoration:
                        const InputDecoration(labelText: 'RIB / Bank Account'),
                  ),
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
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          onPressed: () {
            if (_name.text.trim().isEmpty) return;
            Navigator.pop(
              context,
              Supplier(
                id: widget.supplier?.id ??
                    DateTime.now().microsecondsSinceEpoch.toString(),
                code: widget.supplier?.code ?? '',
                name: _name.text.trim(),
                phone: _phone.text.trim(),
                supplierReference: _reference.text.trim().isEmpty
                    ? null
                    : _reference.text.trim(),
                contactPerson: _contactPerson.text.trim().isEmpty
                    ? null
                    : _contactPerson.text.trim(),
                email: _email.text.trim().isEmpty ? null : _email.text.trim(),
                address: _address.text.trim(),
                commercialRegister: _commercialRegister.text.trim().isEmpty
                    ? null
                    : _commercialRegister.text.trim(),
                taxId: _taxId.text.trim().isEmpty ? null : _taxId.text.trim(),
                nis: _nis.text.trim().isEmpty ? null : _nis.text.trim(),
                ai: _ai.text.trim().isEmpty ? null : _ai.text.trim(),
                bankName: _bankName.text.trim().isEmpty
                    ? null
                    : _bankName.text.trim(),
                bankAccount: _bankAccount.text.trim().isEmpty
                    ? null
                    : _bankAccount.text.trim(),
                notes: _notes.text.trim().isEmpty ? null : _notes.text.trim(),
                createdAt: widget.supplier?.createdAt ?? DateTime.now(),
                updatedAt: DateTime.now(),
              ),
            );
          },
          child: Text(l10n.save),
        ),
      ],
    );
  }
}
