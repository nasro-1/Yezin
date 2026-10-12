import 'package:flutter/material.dart';

import 'package:bayaa_pos/core/constants/app_brand.dart';
import '../../../core/di/dependency_injection.dart';
import '../../../l10n/app_localizations.dart';
import '../../auth/data/models/user_model.dart';
import '../../customers/data/models/customer_model.dart';
import '../../customers/data/repository/customer_repository_impl.dart';
import '../../products/data/models/product_model.dart';
import '../../products/presentation/cubit/product_cubit.dart';
import '../data/models/order_model.dart';
import '../data/models/proforma_model.dart';
import '../data/repository/orders_proformas_repository.dart';
import '../../invoice/domain/invoice_mapper.dart';
import '../../invoice/presentation/invoice_preview_screen.dart';
import '../../settings/data/repository/settings_repository_imp.dart';
import '../../settings/data/models/store_info_model.dart';

class OrdersProformasScreen extends StatefulWidget {
  const OrdersProformasScreen({
    super.key,
    required this.repository,
    required this.user,
  });

  final OrdersProformasRepository repository;
  final User user;

  @override
  State<OrdersProformasScreen> createState() => _OrdersProformasScreenState();
}

class _OrdersProformasScreenState extends State<OrdersProformasScreen> {
  final _searchController = TextEditingController();
  bool _showProformas = false;
  String? _status;
  List<Order> _orders = [];
  List<Proforma> _proformas = [];
  List<Customer> _customers = [];

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final customers = await CustomerRepositoryImpl().getAllCustomers();
    if (_showProformas) {
      final documents = await widget.repository.getProformas(
        search: _searchController.text,
        status: _status == null ? null : proformaStatusFromName(_status),
      );
      if (!mounted) return;
      documents.fold((_) {}, (value) => _proformas = value);
    } else {
      final documents = await widget.repository.getOrders(
        search: _searchController.text,
        status: _status == null ? null : orderStatusFromName(_status),
      );
      if (!mounted) return;
      documents.fold((_) {}, (value) => _orders = value);
    }
    customers.fold((_) {}, (value) => _customers = value);
    setState(() {});
  }

  List<Product> _products() {
    try {
      return getIt<ProductCubit>().allProducts;
    } catch (_) {
      return const [];
    }
  }

  Future<void> _create(bool proforma) async {
    final products = _products();
    if (products.isEmpty || _customers.isEmpty) return;
    final product = products.first;
    final customer = _customers.first;
    final id =
        '${proforma ? 'proforma' : 'order'}_${DateTime.now().microsecondsSinceEpoch}';
    if (proforma) {
      await widget.repository.createProforma(
        Proforma(
          id: id,
          referenceNumber: '',
          proformaDate: DateTime.now(),
          customerId: customer.id,
          lines: [
            ProformaLine(
              productId: product.barcode,
              productName: product.name,
              productBarcode: product.barcode,
              quantity: 1,
              unitPrice: product.price,
              wholesalePrice: product.wholesalePrice,
            ),
          ],
        ),
        widget.user,
      );
    } else {
      await widget.repository.createOrder(
        Order(
          id: id,
          referenceNumber: id,
          orderDate: DateTime.now(),
          customerId: customer.id,
          lines: [
            OrderLine(
              productId: product.barcode,
              productName: product.name,
              productBarcode: product.barcode,
              quantity: 1,
              unitPrice: product.price,
              wholesalePrice: product.wholesalePrice,
            ),
          ],
        ),
        widget.user,
      );
    }
    await _reload();
  }

  Future<void> _action(String kind, String id) async {
    if (kind == 'confirm') {
      if (_showProformas) {
        await widget.repository.confirmProforma(id, widget.user);
      } else {
        await widget.repository.confirmOrder(id, widget.user);
      }
    } else if (kind == 'cancel') {
      if (_showProformas) {
        await widget.repository.cancelProforma(id, widget.user);
      } else {
        await widget.repository.cancelOrder(id, widget.user);
      }
    } else if (kind == 'convert' && _showProformas) {
      await widget.repository.convertProforma(id, widget.user);
    } else if (kind == 'convert') {
      await widget.repository.convertOrder(id, widget.user);
    }
    await _reload();
  }

  Future<void> _edit(Object document) async {
    final edited = await showDialog<Object>(
      context: context,
      builder: (_) => _DraftEditor(
        document: document,
        customers: _customers,
        products: _products(),
      ),
    );
    if (edited is Order) {
      await widget.repository.updateOrderDraft(edited, widget.user);
    } else if (edited is Proforma) {
      await widget.repository.updateProformaDraft(edited, widget.user);
    }
    if (edited != null) await _reload();
  }

  Future<void> _showDetails(Object document) async {
    final isProforma = document is Proforma;
    final id = isProforma ? document.id : (document as Order).id;
    final loaded = isProforma
        ? await widget.repository.getProformaById(id)
        : await widget.repository.getOrderById(id);
    final resolved = loaded.fold((_) => document, (value) => value ?? document);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => _DocumentDetails(
        document: resolved,
        customerName: _customerName(isProforma
            ? (resolved as Proforma).customerId
            : (resolved as Order).customerId),
        onEdit: (resolved is Order && resolved.status == OrderStatus.draft) ||
                (resolved is Proforma &&
                    resolved.status == ProformaStatus.draft)
            ? () {
                Navigator.pop(dialogContext);
                _edit(resolved);
              }
            : null,
      ),
    );
  }

  Future<void> _previewProforma(Proforma proforma) async {
    final result = await getIt<StoreInfoRepository>().getStoreInfo();
    final store = result.fold(
      (_) => StoreInfo(
        name: AppBrand.name,
        address: '',
        phone: '',
        email: '',
        vat: '',
      ),
      (value) => value,
    );
    final data = InvoiceMapper.fromProforma(
      proforma: proforma,
      storeName: store.name,
      storeAddress: store.address,
      storePhone: store.phone,
      customer: _customerFor(proforma.customerId),
    );
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => InvoicePreviewScreen(data: data, receiptMode: false),
      ),
    );
  }

  String _customerName(String? id) {
    if (id == null) return 'No customer';
    for (final customer in _customers) {
      if (customer.id == id) return customer.name;
    }

    return id;
  }

  Customer? _customerFor(String? id) {
    if (id == null) return null;
    for (final customer in _customers) {
      if (customer.id == id) return customer;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final documents = _showProformas ? _proformas : _orders;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: SegmentedButton<bool>(
                  segments: [
                    ButtonSegment(value: false, label: Text(l10n.orders)),
                    ButtonSegment(value: true, label: Text(l10n.proformas)),
                  ],
                  selected: {_showProformas},
                  onSelectionChanged: (value) {
                    setState(() {
                      _showProformas = value.first;
                      _status = null;
                    });
                    _reload();
                  },
                ),
              ),
              const SizedBox(width: 12),
              FilledButton.icon(
                onPressed: () => _create(_showProformas),
                icon: const Icon(Icons.add),
                label: Text(
                    _showProformas ? l10n.createProforma : l10n.createOrder),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchController,
                  onChanged: (_) => _reload(),
                  decoration: InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    labelText: l10n.search,
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              DropdownButton<String?>(
                value: _status,
                hint: const Text('All statuses'),
                items: [
                  const DropdownMenuItem<String?>(
                      value: null, child: Text('All statuses')),
                  ...['draft', 'confirmed', 'cancelled', 'converted']
                      .map((value) => DropdownMenuItem(
                            value: value,
                            child: Text(value),
                          )),
                ],
                onChanged: (value) {
                  setState(() => _status = value);
                  _reload();
                },
              ),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(
            child: documents.isEmpty
                ? Center(child: Text(l10n.noData))
                : ListView.builder(
                    itemCount: documents.length,
                    itemBuilder: (context, index) {
                      final document = documents[index];
                      final isProforma = document is Proforma;
                      final status = isProforma
                          ? document.status.name
                          : (document as Order).status.name;
                      final id =
                          isProforma ? document.id : (document as Order).id;
                      final reference = isProforma
                          ? document.referenceNumber
                          : (document as Order).referenceNumber;
                      final customerId = isProforma
                          ? document.customerId
                          : (document as Order).customerId;
                      return Card(
                        child: ListTile(
                          onTap: () => _showDetails(document),
                          title: Text(reference),
                          subtitle:
                              Text('${_customerName(customerId)}  •  $status'),
                          trailing: Wrap(
                            spacing: 4,
                            children: [
                              if (status == 'draft')
                                IconButton(
                                  tooltip: 'Edit draft',
                                  onPressed: () => _edit(document),
                                  icon: const Icon(Icons.edit_outlined),
                                ),
                              if (status == 'draft')
                                IconButton(
                                  tooltip: l10n.confirmDocument,
                                  onPressed: () => _action('confirm', id),
                                  icon: const Icon(Icons.check),
                                ),
                              if (status == 'draft' || status == 'confirmed')
                                IconButton(
                                  tooltip: l10n.cancelDocument,
                                  onPressed: () => _action('cancel', id),
                                  icon: const Icon(Icons.cancel_outlined),
                                ),
                              if (status == 'confirmed')
                                IconButton(
                                  tooltip: l10n.convertDocument,
                                  onPressed: () => _action('convert', id),
                                  icon: const Icon(Icons.receipt_long),
                                ),
                              if (isProforma)
                                IconButton(
                                  tooltip: 'Preview / Print proforma',
                                  onPressed: () => _previewProforma(document),
                                  icon: const Icon(Icons.print_outlined),
                                ),
                            ],
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

class _DocumentDetails extends StatelessWidget {
  const _DocumentDetails({
    required this.document,
    required this.customerName,
    this.onEdit,
  });

  final Object document;
  final String customerName;
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    final isProforma = document is Proforma;
    final List<dynamic> lines =
        isProforma ? (document as Proforma).lines : (document as Order).lines;
    final reference = isProforma
        ? (document as Proforma).referenceNumber
        : (document as Order).referenceNumber;
    final status = isProforma
        ? (document as Proforma).status.name
        : (document as Order).status.name;
    final convertedSaleId = isProforma
        ? (document as Proforma).convertedSaleId
        : (document as Order).convertedSaleId;
    final date = isProforma
        ? (document as Proforma).proformaDate
        : (document as Order).orderDate;
    final notes =
        isProforma ? (document as Proforma).notes : (document as Order).notes;
    return AlertDialog(
      title: Text(reference),
      content: SizedBox(
        width: 520,
        child: ListView(
          shrinkWrap: true,
          children: [
            Text('Customer: $customerName'),
            Text('Type: ${isProforma ? 'Proforma' : 'Order'}'),
            Text('Date: ${date.toLocal()}'),
            Text('Status: $status'),
            const Divider(),
            ...lines.map((line) => ListTile(
                  dense: true,
                  title: Text(line.productName),
                  subtitle: Text(
                      '${line.quantity} × ${line.unitPrice.toStringAsFixed(2)}'),
                  trailing: Text(line.lineTotal.toStringAsFixed(2)),
                )),
            if (notes != null && notes.trim().isNotEmpty) Text('Notes: $notes'),
            Text(
                'Subtotal: ${lines.fold<double>(0, (sum, line) => sum + line.lineTotal).toStringAsFixed(2)}'),
            Text('Discount: 0.00'),
            const SizedBox(height: 8),
            Text(
              'Total: ${(isProforma ? (document as Proforma).total : (document as Order).total).toStringAsFixed(2)}',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            if (convertedSaleId != null) Text('Linked sale: $convertedSaleId'),
          ],
        ),
      ),
      actions: [
        if (onEdit != null)
          TextButton(onPressed: onEdit, child: const Text('Edit draft')),
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close')),
      ],
    );
  }
}

class _LineDraft {
  _LineDraft({
    required this.productId,
    required this.productName,
    required this.barcode,
    required this.wholesalePrice,
    required double quantity,
    required double price,
  })  : quantity = TextEditingController(text: _number(quantity)),
        price = TextEditingController(text: _number(price));

  String productId;
  String productName;
  String barcode;
  double wholesalePrice;
  final TextEditingController quantity;
  final TextEditingController price;

  static String _number(double value) =>
      value == value.roundToDouble() ? value.toInt().toString() : '$value';

  void dispose() {
    quantity.dispose();
    price.dispose();
  }
}

class _DraftEditor extends StatefulWidget {
  const _DraftEditor({
    required this.document,
    required this.customers,
    required this.products,
  });

  final Object document;
  final List<Customer> customers;
  final List<Product> products;

  @override
  State<_DraftEditor> createState() => _DraftEditorState();
}

class _DraftEditorState extends State<_DraftEditor> {
  late final bool _isProforma;
  late final String _id;
  late final TextEditingController _reference;
  late final TextEditingController _notes;
  late String? _customerId;
  late DateTime _date;
  late List<_LineDraft> _lines;

  @override
  void initState() {
    super.initState();
    _isProforma = widget.document is Proforma;
    final List<dynamic> lines = _isProforma
        ? (widget.document as Proforma).lines
        : (widget.document as Order).lines;
    _id = _isProforma
        ? (widget.document as Proforma).id
        : (widget.document as Order).id;
    _reference = TextEditingController(
        text: _isProforma
            ? (widget.document as Proforma).referenceNumber
            : (widget.document as Order).referenceNumber);
    _notes = TextEditingController(
        text: (_isProforma
                ? (widget.document as Proforma).notes
                : (widget.document as Order).notes) ??
            '');
    _customerId = _isProforma
        ? (widget.document as Proforma).customerId
        : (widget.document as Order).customerId;
    _date = _isProforma
        ? (widget.document as Proforma).proformaDate
        : (widget.document as Order).orderDate;
    _lines = lines
        .map((line) => _LineDraft(
              productId: line.productId,
              productName: line.productName,
              barcode: line.productBarcode,
              wholesalePrice: line.wholesalePrice,
              quantity: line.quantity,
              price: line.unitPrice,
            ))
        .toList();
  }

  @override
  void dispose() {
    _reference.dispose();
    _notes.dispose();
    for (final line in _lines) {
      line.dispose();
    }
    super.dispose();
  }

  void _addLine() {
    if (widget.products.isEmpty) return;
    final product = widget.products.first;
    setState(() {
      _lines.add(_LineDraft(
        productId: product.barcode,
        productName: product.name,
        barcode: product.barcode,
        wholesalePrice: product.wholesalePrice,
        quantity: 1,
        price: product.price,
      ));
    });
  }

  void _save() {
    final parsed = <Object>[];
    for (final line in _lines) {
      final quantity = double.tryParse(line.quantity.text);
      final price = double.tryParse(line.price.text);
      if (quantity == null || quantity <= 0 || price == null || price < 0) {
        return;
      }
      parsed.add((quantity, price));
    }
    if (_lines.isEmpty ||
        _customerId == null ||
        _reference.text.trim().isEmpty) {
      return;
    }
    final newLines = <Object>[];
    for (var i = 0; i < _lines.length; i++) {
      final line = _lines[i];
      final values = parsed[i] as (double, double);
      if (_isProforma) {
        newLines.add(ProformaLine(
          productId: line.productId,
          productName: line.productName,
          productBarcode: line.barcode,
          quantity: values.$1,
          unitPrice: values.$2,
          wholesalePrice: line.wholesalePrice,
        ));
      } else {
        newLines.add(OrderLine(
          productId: line.productId,
          productName: line.productName,
          productBarcode: line.barcode,
          quantity: values.$1,
          unitPrice: values.$2,
          wholesalePrice: line.wholesalePrice,
        ));
      }
    }
    Navigator.pop(
      context,
      _isProforma
          ? Proforma(
              id: _id,
              referenceNumber: _reference.text.trim(),
              customerId: _customerId,
              proformaDate: _date,
              notes: _notes.text.trim().isEmpty ? null : _notes.text.trim(),
              lines: newLines.cast<ProformaLine>(),
            )
          : Order(
              id: _id,
              referenceNumber: _reference.text.trim(),
              customerId: _customerId,
              orderDate: _date,
              notes: _notes.text.trim().isEmpty ? null : _notes.text.trim(),
              lines: newLines.cast<OrderLine>(),
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_isProforma ? 'Edit proforma draft' : 'Edit order draft'),
      content: SizedBox(
        width: 620,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _reference,
                decoration: const InputDecoration(labelText: 'Reference'),
              ),
              DropdownButtonFormField<String>(
                value: widget.customers
                        .any((customer) => customer.id == _customerId)
                    ? _customerId
                    : null,
                decoration: const InputDecoration(labelText: 'Customer'),
                items: widget.customers
                    .map((customer) => DropdownMenuItem(
                          value: customer.id,
                          child: Text(customer.name),
                        ))
                    .toList(),
                onChanged: (value) => setState(() => _customerId = value),
              ),
              TextField(
                controller: _notes,
                decoration: const InputDecoration(labelText: 'Notes'),
                maxLines: 2,
              ),
              const SizedBox(height: 12),
              ..._lines.asMap().entries.map((entry) {
                final index = entry.key;
                final line = entry.value;
                final productIds =
                    widget.products.map((product) => product.barcode).toSet();
                final value =
                    productIds.contains(line.productId) ? line.productId : null;
                return Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: DropdownButtonFormField<String>(
                        value: value,
                        decoration: const InputDecoration(labelText: 'Item'),
                        items: widget.products
                            .map((product) => DropdownMenuItem(
                                  value: product.barcode,
                                  child: Text(product.name),
                                ))
                            .toList(),
                        onChanged: (selected) {
                          if (selected == null) return;
                          final product = widget.products
                              .firstWhere((item) => item.barcode == selected);
                          setState(() {
                            line.productId = product.barcode;
                            line.productName = product.name;
                            line.barcode = product.barcode;
                            line.wholesalePrice = product.wholesalePrice;
                          });
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: line.quantity,
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                        decoration: const InputDecoration(labelText: 'Qty'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: line.price,
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                        decoration: const InputDecoration(labelText: 'Price'),
                      ),
                    ),
                    IconButton(
                      onPressed: _lines.length == 1
                          ? null
                          : () {
                              setState(() {
                                final removed = _lines.removeAt(index);
                                removed.dispose();
                              });
                            },
                      icon: const Icon(Icons.delete_outline),
                    ),
                  ],
                );
              }),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _addLine,
                  icon: const Icon(Icons.add),
                  label: const Text('Add item'),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
        FilledButton(onPressed: _save, child: const Text('Save draft')),
      ],
    );
  }
}
