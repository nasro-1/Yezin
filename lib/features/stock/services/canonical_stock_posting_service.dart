import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class CanonicalStockPostingService {
  const CanonicalStockPostingService();

  Future<double> post({
    required DatabaseExecutor txn,
    required String movementId,
    required String productId,
    required double quantityChange,
    required String movementType,
    required String referenceType,
    required String referenceId,
    String? lineageId,
    String? notes,
    String? userId,
    double unitCost = 0,
    DateTime? createdAt,
    double? sellingQuantity,
    double? conversionToBase,
    String? sellingUnitName,
    double? baseQuantity,
  }) async {
    final resolvedQuantityChange = _resolveQuantityChange(
      quantityChange: quantityChange,
      sellingQuantity: sellingQuantity,
      conversionToBase: conversionToBase,
      baseQuantity: baseQuantity,
    );

    if (resolvedQuantityChange == 0) {
      throw ArgumentError.value(
        resolvedQuantityChange,
        'quantityChange',
        'Stock movement quantity cannot be zero.',
      );
    }
    if (referenceType.trim().isEmpty || referenceId.trim().isEmpty) {
      throw ArgumentError('Stock movements require a traceable source.');
    }
    await _validateSource(txn, referenceType, referenceId);

    final duplicate = await txn.query(
      'stock_movements',
      columns: ['id'],
      where: 'id = ?',
      whereArgs: [movementId],
      limit: 1,
    );
    if (duplicate.isNotEmpty) {
      throw StateError('Stock movement $movementId has already been posted.');
    }

    final products = await txn.query(
      'products',
      columns: ['stock', 'barcode', 'name'],
      where: 'id = ?',
      whereArgs: [productId],
      limit: 1,
    );
    if (products.isEmpty) {
      throw StateError('Product $productId not found.');
    }

    final product = products.first;
    final currentStock = (product['stock'] as num).toDouble();
    final nextStock = currentStock + resolvedQuantityChange;
    if (nextStock < 0) {
      throw StateError(
        'Stock cannot become negative for product $productId.',
      );
    }

    await txn.update(
      'products',
      {'stock': nextStock},
      where: 'id = ?',
      whereArgs: [productId],
    );
    await txn.insert('stock_movements', {
      'id': movementId,
      'product_id': productId,
      'product_barcode': product['barcode'] as String? ?? '',
      'product_name': product['name'] as String,
      'movement_type': movementType,
      'quantity_change': resolvedQuantityChange,
      'unit_cost': unitCost,
      'running_stock': nextStock,
      'reference_type': referenceType,
      'reference_id': referenceId,
      'lineage_id': lineageId,
      'notes': notes ??
          (sellingUnitName != null && sellingQuantity != null
              ? 'Sold $sellingQuantity $sellingUnitName'
              : null),
      'user_id': userId,
      'created_at': (createdAt ?? DateTime.now()).toIso8601String(),
    });

    return nextStock;
  }

  double _resolveQuantityChange({
    required double quantityChange,
    double? sellingQuantity,
    double? conversionToBase,
    double? baseQuantity,
  }) {
    if (baseQuantity != null) {
      if (quantityChange != 0 &&
          (quantityChange.abs() - baseQuantity.abs()).abs() > 1e-9) {
        throw ArgumentError(
          'Legacy quantityChange $quantityChange does not match the resolved baseQuantity $baseQuantity.',
        );
      }
      return baseQuantity;
    }

    if (sellingQuantity != null && conversionToBase != null) {
      final computedBaseQuantity = sellingQuantity * conversionToBase;
      if (quantityChange != 0 &&
          (quantityChange.abs() - computedBaseQuantity.abs()).abs() > 1e-9) {
        throw ArgumentError(
          'Legacy quantityChange $quantityChange does not match sellingQuantity $sellingQuantity × conversionToBase $conversionToBase.',
        );
      }
      return quantityChange == 0 ? computedBaseQuantity : quantityChange;
    }

    return quantityChange;
  }

  Future<void> _validateSource(
    DatabaseExecutor txn,
    String referenceType,
    String referenceId,
  ) async {
    final source = switch (referenceType) {
      'purchase' => ('purchases', 'id'),
      'sale' || 'customer_return' || 'refund' => ('sales', 'id'),
      'supplier_return' => ('supplier_returns', 'id'),
      'stock_adjustment' => ('stock_adjustment_documents', 'id'),
      'opening_stock' => ('opening_stock_documents', 'id'),
      _ => throw ArgumentError(
          'Unsupported stock movement source: $referenceType'),
    };
    final rows = await txn.query(
      source.$1,
      columns: [source.$2],
      where: '${source.$2} = ?',
      whereArgs: [referenceId],
      limit: 1,
    );
    if (rows.isEmpty) {
      throw StateError(
        'Stock movement source $referenceType/$referenceId was not found.',
      );
    }
  }
}
