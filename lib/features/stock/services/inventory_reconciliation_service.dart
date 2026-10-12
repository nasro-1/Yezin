import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class InventoryReconciliation {
  final String productId;
  final double operationalStock;
  final double movementBalance;

  const InventoryReconciliation({
    required this.productId,
    required this.operationalStock,
    required this.movementBalance,
  });

  double get difference => operationalStock - movementBalance;
  bool get isMatched => difference.abs() < 0.000001;
}

class InventoryReconciliationService {
  const InventoryReconciliationService();

  Future<List<InventoryReconciliation>> reconcile(
    DatabaseExecutor db,
  ) async {
    final products = await db.query(
      'products',
      columns: ['id', 'stock'],
    );
    final movements = await db.rawQuery('''
      SELECT product_id, COALESCE(SUM(quantity_change), 0) AS movement_balance
      FROM stock_movements
      GROUP BY product_id
    ''');
    final byProduct = <String, double>{
      for (final row in movements)
        row['product_id'] as String:
            (row['movement_balance'] as num?)?.toDouble() ?? 0,
    };

    return products.map((row) {
      final productId = row['id'] as String;
      return InventoryReconciliation(
        productId: productId,
        operationalStock: (row['stock'] as num).toDouble(),
        movementBalance: byProduct[productId] ?? 0,
      );
    }).toList();
  }
}
