import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';

import '../../../../core/components/local_image_view.dart';
import '../../../../core/data/services/persistence_initializer.dart';
import '../../../../core/network/authority_context.dart';
import '../../../purchases/data/repository/purchase_repository_impl.dart';
import '../../../stock/data/models/stock_movement_model.dart';
import '../../../stock/data/repository/stock_movement_repository.dart';
import '../../../sales/data/models/sale_model.dart';
import '../../../sales/domain/sales_repository.dart';
import '../../data/models/product_model.dart';
import '../../data/models/selling_unit_model.dart';
import '../../data/repository/product_api_repository.dart';
import '../../../../core/network/backend_api_config.dart';
import 'fifo_cost_layers_section.dart';
import 'selling_unit_icon.dart';
import '../../../../l10n/app_localizations.dart';

class ProductDetailsDialog extends StatefulWidget {
  final Product product;
  final List<SellingUnit> sellingUnits;
  final AuthorityContext? authorityContext;

  const ProductDetailsDialog({
    super.key,
    required this.product,
    this.sellingUnits = const [],
    this.authorityContext,
  });

  @override
  State<ProductDetailsDialog> createState() => _ProductDetailsDialogState();
}

class _ProductDetailsDialogState extends State<ProductDetailsDialog> {
  late Future<_ProductHistory> _history;
  Future<List<Map<String, dynamic>>>? _fifoLayers;

  AuthorityContext get _authorityContext =>
      widget.authorityContext ??
      AuthorityContext(
        readMode: BackendApiConfig.productReadMode == ProductReadMode.server
            ? AuthorityMode.server
            : AuthorityMode.local,
        writeMode: BackendApiConfig.productWriteMode == ProductWriteMode.server
            ? AuthorityMode.server
            : AuthorityMode.local,
      );

  @override
  void initState() {
    super.initState();
    final serverMode = _authorityContext.readsFromServer;
    _history = _loadHistory();
    if (serverMode) {
      _fifoLayers = _loadServerFifoLayers();
    }
  }

  Future<List<Map<String, dynamic>>> _loadServerFifoLayers() async {
    final result = await GetIt.I<ProductApiRepository>()
        .getProductFifoLayers(widget.product.id);
    return result.fold(
      (failure) => throw StateError(failure.message),
      (layers) => layers,
    );
  }

  Future<_ProductHistory> _loadHistory() async {
    final serverMode = _authorityContext.readsFromServer;
    final purchaseRows = (await GetIt.I<PurchaseRepository>()
            .getProductPurchaseHistory(widget.product.id))
        .fold(
      (failure) => throw StateError(failure.message),
      (rows) => rows,
    );
    final movements =
        serverMode ? await _loadServerMovements() : await _loadLocalMovements();
    final sales = serverMode
        ? <Sale>[]
        : (await GetIt.I<SalesRepository>()
                .getProductSalesHistory(widget.product.id))
            .fold(
            (failure) => throw StateError(failure.message),
            (rows) => rows,
          );
    return _ProductHistory(
      purchases: purchaseRows,
      movements: movements,
      sales: sales,
    );
  }

  Future<List<StockMovement>> _loadLocalMovements() async {
    return await StockMovementRepository(
      sqliteManager: PersistenceInitializer.persistenceManager?.sqliteManager,
    ).getProductMovements(widget.product.id);
  }

  Future<List<StockMovement>> _loadServerMovements() async {
    try {
      final result = await GetIt.I<ProductApiRepository>()
          .getProductStockMovements(widget.product.id);
      return result.fold(
        (failure) => throw StateError(failure.message),
        (movements) => movements,
      );
    } catch (error, stackTrace) {
      debugPrint(
        '[ProductDetailsDialog] server stock history failed for '
        '${widget.product.id}: $error\n$stackTrace',
      );
      rethrow;
    }
  }

  void _handleFifoCostCorrected() {
    setState(() {
      _history = _loadHistory();
      _fifoLayers = _loadServerFifoLayers();
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final mobile = MediaQuery.sizeOf(context).width < 700;
    return AlertDialog(
      title: _header(),
      content: SizedBox(
        width: mobile ? MediaQuery.sizeOf(context).width - 64 : 900,
        height: (MediaQuery.sizeOf(context).height * .68).clamp(280.0, 560.0),
        child: FutureBuilder<_ProductHistory>(
          future: _history,
          builder: (context, snapshot) {
            if (!snapshot.hasData) {
              if (snapshot.hasError) {
                return SizedBox(
                  height: 120,
                  child: Center(
                    child: Text(
                      'Product history is unavailable: ${snapshot.error}',
                      textAlign: TextAlign.center,
                    ),
                  ),
                );
              }
              return const SizedBox(
                height: 180,
                child: Center(child: CircularProgressIndicator()),
              );
            }
            return _tabs(context, l10n, snapshot.data!);
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(MaterialLocalizations.of(context).closeButtonLabel),
        ),
      ],
    );
  }

  Widget _header() {
    final l10n = AppLocalizations.of(context);
    return Row(
      children: [
        LocalImageView(
          path: widget.product.imagePath,
          width: 56,
          height: 56,
          borderRadius: 28,
          fallback: CircleAvatar(
            radius: 28,
            child: Text(widget.product.name.isEmpty
                ? '?'
                : widget.product.name.characters.first.toUpperCase()),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.product.name,
                  style: const TextStyle(
                      fontSize: 20, fontWeight: FontWeight.bold)),
              Text(
                '${l10n.productTypeLabel}: '
                '${widget.product.productType.name.toUpperCase()}',
              ),
              Text(l10n.detailsCategory(
                widget.product.displayCategoryName.isEmpty
                    ? l10n.generalCategory
                    : widget.product.displayCategoryName,
              )),
            ],
          ),
        ),
      ],
    );
  }

  Widget _infoTab(BuildContext context, AppLocalizations l10n) {
    final product = widget.product;
    final packagedUnits =
        widget.sellingUnits.where((unit) => unit.isActive).toList();
    final packagedUnit =
        product.productType == ProductType.packaged && packagedUnits.isNotEmpty
            ? packagedUnits.firstWhere(
                (unit) => unit.isDefault,
                orElse: () => packagedUnits.first,
              )
            : null;
    final packagedWholesale = packagedUnits
        .where((unit) =>
            unit.wholesalePrice != null &&
            (unit.name.trim().toLowerCase() == 'pack' ||
                unit.name.trim().toLowerCase() == 'box'))
        .map((unit) =>
            '${unit.name}: ${unit.wholesalePrice!.toStringAsFixed(2)} DA')
        .join('\n');
    final double? sellingPrice = product.productType == ProductType.packaged
        ? packagedUnit?.sellingPrice
        : product.price;
    final double? wholesalePrice = product.productType == ProductType.packaged
        ? packagedUnit?.wholesalePrice
        : product.wholesalePrice;
    final double? minPrice =
        product.productType == ProductType.packaged ? null : product.minPrice;
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _section(l10n.productDetailsPricing, [
            if (product.productType == ProductType.packaged) ...[
              _row(
                l10n.sellingPrice,
                packagedUnits.isEmpty
                    ? '—'
                    : packagedUnits
                        .map((unit) =>
                            '${unit.name}: ${unit.sellingPrice.toStringAsFixed(2)} DA')
                        .join('\n'),
              ),
              _row(
                l10n.wholesalePrice,
                packagedWholesale.isEmpty ? '—' : packagedWholesale,
              ),
            ] else ...[
              _row(
                  product.productType == ProductType.weighted
                      ? '${l10n.sellingPrice} / ${product.baseUnit}'
                      : l10n.sellingPrice,
                  sellingPrice?.toStringAsFixed(2) ?? '—'),
              _row(l10n.wholesalePrice,
                  wholesalePrice?.toStringAsFixed(2) ?? '—'),
            ],
            if (product.productType != ProductType.packaged)
              _row(l10n.minPriceColumn, minPrice?.toStringAsFixed(2) ?? '—'),
          ]),
          _section(l10n.productDetailsIdentification, [
            _row(l10n.barcode, product.barcode.isEmpty ? '—' : product.barcode),
            _row(
              l10n.productCode(
                product.code == null || product.code!.trim().isEmpty
                    ? '—'
                    : product.code!,
              ),
              product.code == null || product.code!.trim().isEmpty
                  ? '—'
                  : product.code!,
            ),
            _row(l10n.internalReferenceLabel, product.internalReference ?? '—'),
            _row(l10n.productDetailsStock, product.quantityWithBaseUnit),
          ]),
          if (product.productType == ProductType.packaged)
            _sellingUnits(product),
        ],
      ),
    );
  }

  Widget _tabs(
      BuildContext context, AppLocalizations l10n, _ProductHistory history) {
    return DefaultTabController(
      length: 4,
      child: SizedBox(
        height: (MediaQuery.sizeOf(context).height * .58).clamp(300.0, 560.0),
        child: Column(
          children: [
            TabBar(
              isScrollable: MediaQuery.sizeOf(context).width < 520,
              labelPadding: const EdgeInsets.symmetric(horizontal: 10),
              tabs: [
                Tab(text: l10n.sales),
                Tab(text: l10n.products),
                Tab(text: l10n.purchases),
                Tab(text: l10n.stockHistory),
              ],
            ),
            Expanded(
              child: TabBarView(
                children: [
                  _salesHistory(
                      context, history.sales, widget.product.baseUnit),
                  _infoTab(context, l10n),
                  _purchaseHistory(
                    context,
                    history.purchases,
                    widget.product.baseUnit,
                  ),
                  _stockHistory(context, history.movements),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _section(String title, List<Widget> children) => Card(
        margin: const EdgeInsets.only(bottom: 12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
              const Divider(),
              ...children,
            ],
          ),
        ),
      );

  Widget _sellingUnits(Product product) {
    final l10n = AppLocalizations.of(context);
    final units = widget.sellingUnits.where((unit) => unit.isActive).toList();
    return _section(l10n.sellingUnitsLabel, [
      if (units.isEmpty)
        Text(l10n.sellingUnitsLabel)
      else
        ...units.map(
          (unit) => Card(
            margin: const EdgeInsets.only(bottom: 8),
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Wrap(
                spacing: 12,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Icon(
                    sellingUnitIconData(unit.iconKey, unitName: unit.name),
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  Text(
                    unit.name,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  Text(
                    '${_number(unit.conversionToBase)} × ${product.baseUnit}',
                  ),
                  Text('${l10n.sellingPrice}: '
                      '${unit.sellingPrice.toStringAsFixed(2)}'),
                  Text('${l10n.wholesalePrice}: '
                      '${unit.wholesalePrice?.toStringAsFixed(2) ?? '—'}'),
                  Text('Minimum stock: '
                      '${_number(unit.minimumStock)} ${unit.name} '
                      '(${_number(unit.minimumStock * unit.conversionToBase)} '
                      '${product.baseUnit})'),
                  if (unit.isDefault) const Chip(label: Text('Default')),
                ],
              ),
            ),
          ),
        ),
    ]);
  }

  Widget _stockHistory(BuildContext context, List<StockMovement> movements) {
    final layers = _fifoLayers;
    if (layers == null) {
      return _stockHistoryRows(context, movements, const []);
    }
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: layers,
      builder: (context, snapshot) => _stockHistoryRows(
        context,
        movements,
        snapshot.data ?? const [],
        layersError: snapshot.hasError ? snapshot.error : null,
      ),
    );
  }

  Widget _stockHistoryRows(
    BuildContext context,
    List<StockMovement> movements,
    List<Map<String, dynamic>> layers, {
    Object? layersError,
  }) {
    final l10n = AppLocalizations.of(context);
    final visibleMovements = movements
        .where((movement) => movement.movementType != 'cost_correction')
        .toList();
    return SingleChildScrollView(
      padding: const EdgeInsets.all(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _section(
            l10n.stockHistory,
            visibleMovements.isEmpty
                ? [Text(l10n.productDetailsNoStockMovements)]
                : visibleMovements.map(
                    (movement) {
                      final linkedLayers = layers
                          .where(
                            (layer) =>
                                layer['source_movement_id'] == movement.id,
                          )
                          .toList();
                      return Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${_signed(movement.quantityChange)} '
                                '${widget.product.baseUnit}',
                                style: const TextStyle(
                                  fontSize: 17,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              Text(_movementLabel(movement.movementType, l10n)),
                              Text('${l10n.productDetailsDate}: '
                                  '${movement.createdAt.toLocal()}'),
                              Text('${l10n.reference}: '
                                  '${movement.sourceDescription ?? movement.referenceId ?? '—'}'),
                              Text('${l10n.productDetailsStock}: '
                                  '${_number(movement.runningStock)} '
                                  '${widget.product.baseUnit}'),
                              if (linkedLayers.isEmpty) ...[
                                Text(
                                  'Cost: ${movement.unitCost.toStringAsFixed(2)} '
                                  'DA/${widget.product.baseUnit}',
                                ),
                                if (movement.quantityChange < 0)
                                  Text(
                                    'Total: ${movement.lineTotal.toStringAsFixed(2)} DA',
                                  ),
                              ] else
                                ...linkedLayers.map(
                                  (layer) => FifoCostLayerCostEditor(
                                    key: ValueKey(layer['layer_id']),
                                    product: widget.product,
                                    layer: layer,
                                    authorityContext: _authorityContext,
                                    onCorrected: _handleFifoCostCorrected,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      );
                    },
                  ).toList(),
          ),
          if (layersError != null)
            Text(
              'FIFO cost layers are unavailable: $layersError',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      ),
    );
  }

  Widget _purchaseHistory(
      BuildContext context, List<Map<String, dynamic>> rows, String baseUnit) {
    final l10n = AppLocalizations.of(context);
    double? numericValue(Object? value) {
      if (value is num) return value.toDouble();
      if (value is String) return double.tryParse(value);
      return null;
    }

    return _section(l10n.purchaseHistory, [
      if (rows.isEmpty)
        Text(l10n.productDetailsNoPurchaseHistory)
      else
        ...rows.map((row) {
          final quantity = numericValue(row['quantity']) ?? 0;
          final baseQuantity = numericValue(row['base_quantity']) ?? quantity;
          final unit = row['selling_unit_name_snapshot']?.toString() ??
              row['base_unit_snapshot']?.toString() ??
              baseUnit;
          final unitCost = numericValue(row['unit_cost']);
          final conversion = numericValue(row['conversion_factor_snapshot']);
          final lineTotal = numericValue(row['line_total']);
          final baseCost =
              unitCost != null && conversion != null && conversion > 0
                  ? unitCost / conversion
                  : unitCost;
          return Card(
            margin: const EdgeInsets.only(bottom: 8),
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 12),
              title: Text(row['reference_number']?.toString() ?? '—'),
              subtitle: Text(
                '${l10n.quantity}: ${_number(quantity)} $unit  '
                '${l10n.productDetailsBaseQuantity}: '
                '${_number(baseQuantity)} $baseUnit\n'
                '${l10n.productDetailsCost}: '
                '${unitCost?.toStringAsFixed(2) ?? '—'} / $unit  '
                '${l10n.productDetailsCost}: '
                '${baseCost?.toStringAsFixed(2) ?? '—'} / $baseUnit  '
                '${l10n.total}: '
                '${lineTotal?.toStringAsFixed(2) ?? '—'}',
              ),
              onTap: () => showDialog(
                context: context,
                builder: (_) => PurchaseDetailsDialog(
                  row: row,
                  productName: widget.product.name,
                  baseUnit: baseUnit,
                ),
              ),
            ),
          );
        }),
    ]);
  }

  String _movementLabel(String type, AppLocalizations l10n) => switch (type) {
        'stock_adjustment' => l10n.stockAdjustment,
        'opening_stock' => l10n.openingStock,
        'purchase' => l10n.purchases,
        'sale' => l10n.sales,
        _ => type,
      };

  Widget _salesHistory(
      BuildContext context, List<Sale> sales, String baseUnit) {
    final items = <({Sale sale, SaleItem item})>[];
    for (final sale in sales) {
      for (final item in sale.saleItems
          .where((item) => item.productId == widget.product.id)) {
        items.add((sale: sale, item: item));
      }
    }
    final l10n = AppLocalizations.of(context);
    return _section(l10n.sales, [
      if (items.isEmpty)
        Text(l10n.productDetailsNoSalesHistory)
      else
        ...items.map((entry) {
          final item = entry.item;
          final quantity = item.sellingQuantity ?? item.quantity;
          final baseQuantity = item.effectiveBaseQuantity;
          final unit = item.sellingUnitNameSnapshot ?? baseUnit;
          return Card(
            margin: const EdgeInsets.only(bottom: 8),
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 12),
              title: Text(entry.sale.referenceNumber ?? entry.sale.id),
              subtitle: Text(
                '${entry.sale.customerName ?? '—'} • ${entry.sale.date}\n'
                '${l10n.quantity}: ${_number(quantity)} $unit  '
                '${l10n.productDetailsBaseQuantity}: '
                '${_number(baseQuantity)} $baseUnit\n'
                '${l10n.sellingPrice}: ${item.price.toStringAsFixed(2)}  '
                '${l10n.total}: ${item.total.toStringAsFixed(2)}',
              ),
              onTap: () => showDialog(
                context: context,
                builder: (_) => SaleDetailsDialog(
                  sale: entry.sale,
                  item: item,
                  productName: widget.product.name,
                  baseUnit: baseUnit,
                ),
              ),
            ),
          );
        }),
    ]);
  }

  Widget _row(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 150,
              child: Text(label,
                  style: const TextStyle(fontWeight: FontWeight.w600)),
            ),
            Expanded(child: Text(value)),
          ],
        ),
      );

  String _number(num value) =>
      value % 1 == 0 ? value.toInt().toString() : value.toStringAsFixed(3);

  String _signed(num value) =>
      value >= 0 ? '+${_number(value)}' : _number(value);
}

class _ProductHistory {
  final List<Map<String, dynamic>> purchases;
  final List<StockMovement> movements;
  final List<Sale> sales;

  const _ProductHistory({
    required this.purchases,
    required this.movements,
    required this.sales,
  });
}

class PurchaseDetailsDialog extends StatelessWidget {
  final Map<String, dynamic> row;
  final String productName;
  final String baseUnit;

  const PurchaseDetailsDialog({
    super.key,
    required this.row,
    required this.productName,
    required this.baseUnit,
  });

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(row['reference_number']?.toString() ?? 'Purchase'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _detail('Supplier', row['supplier_name']?.toString() ?? '-'),
              _detail('Date', row['purchase_date']?.toString() ?? '-'),
              _detail('Status', row['status']?.toString() ?? '-'),
              _detail('Product', productName),
              _detail('Purchased',
                  '${row['quantity'] ?? 0} ${row['selling_unit_name_snapshot'] ?? baseUnit}'),
              _detail('Base quantity',
                  '${row['base_quantity'] ?? row['quantity'] ?? 0} $baseUnit'),
              _detail('Unit cost', '${row['unit_cost'] ?? 0}'),
              _detail('Line total', '${row['line_total'] ?? 0}'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(MaterialLocalizations.of(context).closeButtonLabel),
          ),
        ],
      );

  Widget _detail(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Text('$label: $value'),
      );
}

class SaleDetailsDialog extends StatelessWidget {
  final Sale sale;
  final SaleItem item;
  final String productName;
  final String baseUnit;

  const SaleDetailsDialog({
    super.key,
    required this.sale,
    required this.item,
    required this.productName,
    required this.baseUnit,
  });

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(sale.referenceNumber ?? sale.id),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _detail('Invoice', sale.referenceNumber ?? sale.id),
              _detail('Date', sale.date.toString()),
              _detail('Customer', sale.customerName ?? '-'),
              _detail('Product', productName),
              _detail('Selling unit', item.sellingUnitNameSnapshot ?? baseUnit),
              _detail('Selling quantity',
                  '${item.sellingQuantity ?? item.quantity} ${item.sellingUnitNameSnapshot ?? baseUnit}'),
              _detail(
                  'Base quantity', '${item.effectiveBaseQuantity} $baseUnit'),
              _detail('Unit price', item.price.toStringAsFixed(2)),
              _detail('Total', item.total.toStringAsFixed(2)),
              _detail('Payment method', sale.paymentMethod),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(MaterialLocalizations.of(context).closeButtonLabel),
          ),
        ],
      );

  Widget _detail(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Text('$label: $value'),
      );
}
