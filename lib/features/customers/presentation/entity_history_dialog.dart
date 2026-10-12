import 'package:flutter/material.dart';

import '../../../core/di/dependency_injection.dart';
import '../../../core/data/services/persistence_initializer.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/network/authority_context.dart';
import '../data/models/customer_model.dart';
import '../data/repository/customer_repository_impl.dart';
import '../../suppliers/data/models/supplier_model.dart';
import '../../suppliers/data/repository/supplier_repository_impl.dart';
import '../../suppliers/data/repository/supplier_payment_repository_impl.dart';
import '../../purchases/data/repository/purchase_repository_impl.dart';
import '../../products/data/repository/product_api_repository.dart';

enum EntityHistoryKind { all, sales, purchases, payments, returns }

class EntityHistoryEntry {
  const EntityHistoryEntry({
    required this.kind,
    required this.reference,
    required this.date,
    required this.amount,
    required this.status,
    required this.description,
    required this.data,
  });

  final EntityHistoryKind kind;
  final String reference;
  final DateTime date;
  final double amount;
  final String status;
  final String description;
  final Map<String, dynamic> data;
}

List<EntityHistoryEntry> filterEntityHistory(
  Iterable<EntityHistoryEntry> entries,
  EntityHistoryKind filter,
) {
  final result = entries
      .where((entry) => filter == EntityHistoryKind.all || entry.kind == filter)
      .toList();
  result.sort((a, b) => b.date.compareTo(a.date));
  return result;
}

Future<void> showSupplierHistory(
  BuildContext context, {
  required Supplier supplier,
  required SupplierRepository repository,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => _EntityHistoryDialog(
      entityName: supplier.name,
      entityCode: supplier.code,
      phone: supplier.phone,
      details: [
        supplier.supplierReference,
        supplier.contactPerson,
        supplier.address,
        supplier.commercialRegister,
        supplier.taxId,
        supplier.nis,
        supplier.ai,
        supplier.bankName,
        supplier.bankAccount,
      ],
      title: 'Supplier History',
      isSupplier: true,
      entityId: supplier.id,
      supplierRepository: repository,
    ),
  );
}

Future<void> showCustomerHistory(
  BuildContext context, {
  required Customer customer,
  required CustomerRepository repository,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => _EntityHistoryDialog(
      entityName: customer.name,
      entityCode: customer.code,
      phone: customer.phone,
      details: [
        customer.customerReference,
        customer.address,
        customer.commercialRegister,
        customer.taxId,
        customer.nis,
        customer.ai,
      ],
      title: 'Customer History',
      isSupplier: false,
      entityId: customer.id,
      customerRepository: repository,
    ),
  );
}

class _EntityHistoryDialog extends StatefulWidget {
  const _EntityHistoryDialog({
    required this.entityName,
    required this.entityCode,
    required this.phone,
    required this.details,
    required this.title,
    required this.isSupplier,
    required this.entityId,
    this.supplierRepository,
    this.customerRepository,
  });

  final String entityName;
  final String entityCode;
  final String phone;
  final List<String?> details;
  final String title;
  final bool isSupplier;
  final String entityId;
  final SupplierRepository? supplierRepository;
  final CustomerRepository? customerRepository;

  @override
  State<_EntityHistoryDialog> createState() => _EntityHistoryDialogState();
}

class _EntityHistoryDialogState extends State<_EntityHistoryDialog> {
  List<EntityHistoryEntry> _entries = [];
  double _balance = 0;
  double _purchases = 0;
  double _sales = 0;
  double _payments = 0;
  double _returns = 0;
  EntityHistoryKind _filter = EntityHistoryKind.all;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final id = widget.entityId;
      final entries = <EntityHistoryEntry>[];
      if (widget.isSupplier) {
        final serverMode = getIt<AuthorityContext>().readsFromServer;
        final balance = await widget.supplierRepository!.getSupplierBalance(id);
        _balance = balance.fold(
          (failure) {
            if (serverMode) throw StateError(failure.message);
            return 0;
          },
          (value) => value,
        );
        if (serverMode) {
          final purchaseResult =
              await getIt<PurchaseRepository>().getPurchases();
          final purchases = purchaseResult.fold(
            (failure) => throw StateError(failure.message),
            (rows) => rows,
          );
          for (final row in purchases
              .where((row) => row['supplier_id']?.toString() == id)) {
            final amount = _number(row['total']);
            _purchases += amount;
            entries.add(_entry(
                EntityHistoryKind.purchases,
                row['reference'] ?? row['reference_number'],
                row['purchase_date'],
                amount,
                row['status'],
                'Purchase',
                row));
          }

          final paymentResult = await getIt<SupplierPaymentRepository>()
              .getPaymentHistory(supplierId: id);
          final payments = paymentResult.fold(
            (failure) => throw StateError(failure.message),
            (rows) => rows,
          );
          for (final row in payments) {
            final amount = _number(row['amount']);
            _payments += amount;
            entries.add(_entry(
                EntityHistoryKind.payments,
                row['reference'],
                row['payment_date'],
                amount,
                row['status'],
                'Supplier Payment',
                row));
          }
          final ledgerResult =
              await widget.supplierRepository!.getSupplierLedger(id);
          final ledger = ledgerResult.fold(
            (failure) => throw StateError(failure.message),
            (rows) => rows,
          );
          for (final row in ledger.where(
            (entry) => entry['entry_type'] == 'supplier_return',
          )) {
            final amount = _number(row['amount']).abs();
            _returns += amount;
            entries.add(_entry(EntityHistoryKind.returns, row['reference_id'],
                row['created_at'], amount, 'POSTED', 'Supplier Return', row));
          }
        } else {
          final db = PersistenceInitializer.persistenceManager!.sqliteManager;
          final purchases = await db.query('purchases',
              where: 'supplier_id = ?',
              whereArgs: [id],
              orderBy: 'purchase_date DESC');
          for (final row in purchases) {
            final amount = _number(row['total']);
            _purchases += amount;
            entries.add(_entry(
                EntityHistoryKind.purchases,
                row['reference_number'],
                row['purchase_date'],
                amount,
                row['status'],
                'Purchase',
                row));
          }
          final payments = await db.query('supplier_payments',
              where: 'supplier_id = ?',
              whereArgs: [id],
              orderBy: 'payment_date DESC');
          for (final row in payments) {
            final amount = _number(row['amount']);
            _payments += amount;
            entries.add(_entry(
                EntityHistoryKind.payments,
                row['reference'],
                row['payment_date'],
                amount,
                row['status'],
                'Supplier Payment',
                row));
          }
          final returns = await db.query('supplier_returns',
              where: 'supplier_id = ?',
              whereArgs: [id],
              orderBy: 'return_date DESC');
          for (final row in returns) {
            final amount = _number(row['total_amount']);
            _returns += amount;
            entries.add(_entry(
                EntityHistoryKind.returns,
                row['reference'],
                row['return_date'],
                amount,
                row['status'],
                'Supplier Return',
                row));
          }
        }
      } else {
        final db = PersistenceInitializer.persistenceManager!.sqliteManager;
        final balance = await widget.customerRepository!.getCustomerBalance(id);
        _balance = balance.getOrElse(() => 0);
        final sales = await db.query('sales',
            where: 'customer_id = ? AND is_refund = 0',
            whereArgs: [id],
            orderBy: 'created_at DESC');
        for (final row in sales) {
          final amount = _number(row['total']);
          _sales += amount;
          entries.add(_entry(EntityHistoryKind.sales, row['reference_number'],
              row['created_at'], amount, 'Confirmed', 'Sale / Invoice', row));
        }
        final payments = await db.query('customer_payments',
            where: 'customer_id = ?',
            whereArgs: [id],
            orderBy: 'payment_date DESC');
        for (final row in payments) {
          final amount = _number(row['amount']);
          _payments += amount;
          entries.add(_entry(
              EntityHistoryKind.payments,
              row['reference'],
              row['payment_date'],
              amount,
              row['status'],
              'Customer Payment',
              row));
        }
        final returns = await db.query('sales',
            where: 'customer_id = ? AND is_refund = 1',
            whereArgs: [id],
            orderBy: 'created_at DESC');
        for (final row in returns) {
          final amount = _number(row['total']);
          _returns += amount;
          entries.add(_entry(EntityHistoryKind.returns, row['reference_number'],
              row['created_at'], amount, 'Confirmed', 'Customer Return', row));
        }
      }
      entries.sort((a, b) => b.date.compareTo(a.date));
      if (mounted) {
        setState(() {
          _entries = entries;
          _loading = false;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error.toString();
          _loading = false;
        });
      }
    }
  }

  EntityHistoryEntry _entry(
      EntityHistoryKind kind,
      dynamic reference,
      dynamic date,
      double amount,
      dynamic status,
      String description,
      Map<String, dynamic> data) {
    return EntityHistoryEntry(
      kind: kind,
      reference: (reference as String?)?.trim().isNotEmpty == true
          ? reference as String
          : '—',
      date: DateTime.tryParse(date as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      amount: amount,
      status: status as String? ?? '—',
      description: description,
      data: data,
    );
  }

  double _number(dynamic value) => value is num
      ? value.toDouble()
      : double.tryParse(value?.toString() ?? '') ?? 0;

  @override
  Widget build(BuildContext context) {
    final visible = filterEntityHistory(_entries, _filter);
    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 980, maxHeight: 760),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(widget.title,
                            style: Theme.of(context).textTheme.headlineSmall),
                        const SizedBox(height: 4),
                        Text('${widget.entityName} · ${widget.entityCode}'),
                        if (widget.phone.trim().isNotEmpty)
                          Text(widget.phone,
                              style:
                                  const TextStyle(color: AppColors.mutedColor)),
                        ...widget.details
                            .where((value) => value?.trim().isNotEmpty == true)
                            .map((value) => Text(value!)),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  _SummaryCard('Outstanding', _balance),
                  _SummaryCard(
                      widget.isSupplier ? 'Total purchases' : 'Total sales',
                      widget.isSupplier ? _purchases : _sales),
                  _SummaryCard('Total payments', _payments),
                  _SummaryCard('Total returns', _returns),
                ],
              ),
              const SizedBox(height: 18),
              Wrap(
                spacing: 8,
                children: [
                  _filterButton('All', EntityHistoryKind.all),
                  if (widget.isSupplier)
                    _filterButton('Purchases', EntityHistoryKind.purchases)
                  else
                    _filterButton('Sales', EntityHistoryKind.sales),
                  _filterButton('Payments', EntityHistoryKind.payments),
                  _filterButton('Returns', EntityHistoryKind.returns),
                ],
              ),
              const SizedBox(height: 12),
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : _error != null
                        ? Center(child: Text(_error!))
                        : visible.isEmpty
                            ? const Center(
                                child: Text('No transaction history yet.'))
                            : ListView.separated(
                                itemCount: visible.length,
                                separatorBuilder: (_, __) =>
                                    const SizedBox(height: 8),
                                itemBuilder: (_, index) =>
                                    _historyTile(visible[index]),
                              ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _filterButton(String label, EntityHistoryKind kind) {
    return ChoiceChip(
      label: Text(label),
      selected: _filter == kind,
      onSelected: (_) => setState(() => _filter = kind),
      selectedColor: AppColors.primaryColor,
      labelStyle: TextStyle(
          color: _filter == kind ? Colors.white : AppColors.textSecondary),
    );
  }

  Widget _historyTile(EntityHistoryEntry entry) {
    return Card(
      elevation: 0,
      child: ListTile(
        leading: CircleAvatar(child: Icon(_icon(entry.kind))),
        title: Text(entry.reference,
            style: const TextStyle(fontWeight: FontWeight.w800)),
        subtitle: Text(
            '${entry.description} · ${_date(entry.date)}\n${entry.status}'),
        isThreeLine: true,
        trailing: Text(entry.amount.toStringAsFixed(2),
            style: const TextStyle(fontWeight: FontWeight.w700)),
        onTap: () => _showDetail(entry),
      ),
    );
  }

  IconData _icon(EntityHistoryKind kind) {
    switch (kind) {
      case EntityHistoryKind.purchases:
        return Icons.shopping_bag_outlined;
      case EntityHistoryKind.sales:
        return Icons.receipt_long_outlined;
      case EntityHistoryKind.payments:
        return Icons.payments_outlined;
      case EntityHistoryKind.returns:
        return Icons.undo_outlined;
      case EntityHistoryKind.all:
        return Icons.history;
    }
  }

  String _date(DateTime value) =>
      MaterialLocalizations.of(context).formatMediumDate(value.toLocal());

  Future<void> _showDetail(EntityHistoryEntry entry) async {
    final itemRows = <Map<String, dynamic>>[];
    final serverMode =
        widget.isSupplier && getIt<AuthorityContext>().readsFromServer;
    if (serverMode) {
      final items = entry.data['items'];
      if (entry.kind == EntityHistoryKind.purchases && items is List) {
        itemRows.addAll(items
            .whereType<Map>()
            .map((item) => Map<String, dynamic>.from(item)));
        for (final item in itemRows) {
          final productId = item['product_id']?.toString();
          final productName = item['product_name']?.toString().trim();
          if (productId == null ||
              productId.isEmpty ||
              (productName != null &&
                  productName.isNotEmpty &&
                  productName != productId)) {
            continue;
          }
          final result =
              await getIt<ProductApiRepository>().getProduct(productId);
          final resolvedName = result.fold(
            (_) => null,
            (product) => product.name.trim(),
          );
          if (resolvedName != null && resolvedName.isNotEmpty) {
            item['product_name'] = resolvedName;
          }
        }
      }
    } else {
      final db = PersistenceInitializer.persistenceManager!.sqliteManager;
      final table = entry.kind == EntityHistoryKind.purchases
          ? 'purchase_items'
          : (widget.isSupplier && entry.kind == EntityHistoryKind.returns
              ? 'supplier_return_items'
              : (entry.kind == EntityHistoryKind.sales ||
                      entry.kind == EntityHistoryKind.returns
                  ? 'sale_items'
                  : null));
      final foreignKey = entry.kind == EntityHistoryKind.purchases
          ? 'purchase_id'
          : (widget.isSupplier && entry.kind == EntityHistoryKind.returns
              ? 'return_id'
              : 'sale_id');
      if (table != null) {
        itemRows.addAll(await db.query(table,
            where: '$foreignKey = ?', whereArgs: [entry.data['id']]));
      }
    }
    if (!mounted) return;
    final itemText = itemRows.map((item) {
      final unit = (item['selling_unit_name_snapshot'] ??
          item['selling_unit_name']) as String?;
      final quantity =
          (item['selling_quantity'] ?? item['quantity'])?.toString();
      final base = item['base_quantity'] ?? item['base_quantity_snapshot'];
      final conversion =
          item['conversion_factor_snapshot'] ?? item['conversion_factor'];
      final cost = item['unit_cost'] ?? item['price'];
      return [
        item['product_name'] ?? item['product_id'],
        if (unit != null && unit.isNotEmpty) 'Unit: $unit',
        'Quantity: $quantity',
        if (conversion != null) 'Conversion: $conversion',
        if (base != null) 'Base quantity: $base',
        if (cost != null) 'Unit cost: $cost',
        'Line total: ${item['line_total'] ?? item['subtotal'] ?? '—'}',
      ].join(' · ');
    }).join('\n');
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(entry.reference),
        content: SizedBox(
          width: 520,
          child: Text([
            entry.description,
            'Reference: ${entry.reference}',
            'Date: ${_date(entry.date)}',
            'Amount: ${entry.amount.toStringAsFixed(2)}',
            'Status: ${entry.status}',
            if (entry.data['notes'] != null &&
                (entry.data['notes'] as String).trim().isNotEmpty)
              'Notes: ${entry.data['notes']}',
            if (itemText.isNotEmpty) 'Items:\n$itemText',
          ].join('\n')),
        ),
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard(this.label, this.value);
  final String label;
  final double value;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 190,
      child: Card(
        elevation: 0,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: const TextStyle(color: AppColors.mutedColor)),
              const SizedBox(height: 5),
              Text(value.toStringAsFixed(2),
                  style: const TextStyle(fontWeight: FontWeight.w800)),
            ],
          ),
        ),
      ),
    );
  }
}
