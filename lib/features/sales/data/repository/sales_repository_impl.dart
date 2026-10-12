import 'dart:convert';

import 'package:bayaa_pos/core/data/models/activity_log.dart';
import 'package:bayaa_pos/core/data/services/persistence_initializer.dart';
import 'package:bayaa_pos/core/data/services/document_number_service.dart';
import 'package:bayaa_pos/core/data/services/canonical_cash_posting_service.dart';
import 'package:bayaa_pos/core/data/services/repository_persistence_mixin.dart';
import 'package:bayaa_pos/core/error/error_handler.dart';
import 'package:bayaa_pos/core/state/state_synchronizer.dart';
import 'package:dartz/dartz.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../../../../core/error/failure.dart';
import '../../../products/data/models/product_model.dart';
import '../../domain/sales_repository.dart';
import '../models/sale_model.dart';
import '../models/cart_item_model.dart';
import '../../../stock/services/canonical_stock_posting_service.dart';
import '../../../analytics/data/local_fifo_analytics_costing.dart';

class SalesRepositoryImpl
    with RepositoryPersistenceMixin
    implements SalesRepository {
  // Removed Hive boxes
  SalesRepositoryImpl();

  static const _stockPosting = CanonicalStockPostingService();
  static const _fifoCosting = LocalFifoAnalyticsCosting();
  static final _cashPosting = CanonicalCashPostingService();

  static Future<double> _historicalFifoUnitCost(
    DatabaseExecutor txn, {
    required String productId,
    required double quantity,
    required DateTime createdAt,
  }) async {
    final movements = await txn.rawQuery(
      '''
        SELECT id, product_id, movement_type, quantity_change, unit_cost,
          reference_type, reference_id, lineage_id, created_at
        FROM stock_movements
        WHERE product_id = ? AND created_at <= ?
        ORDER BY created_at ASC, rowid ASC
      ''',
      [productId, createdAt.toIso8601String()],
    );
    final cost = _fifoCosting.costForNextSale(
      movements: movements,
      productId: productId,
      quantity: quantity,
      createdAt: createdAt,
    );
    return cost == null || quantity <= 0 ? 0 : cost / quantity;
  }

  static Future<String> _nextSaleId(DatabaseExecutor txn) async {
    var candidate = DateTime.now().microsecondsSinceEpoch;
    while ((await txn.query(
      'sales',
      columns: ['id'],
      where: 'id = ?',
      whereArgs: [candidate.toString()],
      limit: 1,
    ))
        .isNotEmpty) {
      candidate++;
    }
    return candidate.toString();
  }

  @override
  Future<Either<Failure, Product?>> findProductByBarcode(String barcode) async {
    try {
      final db = PersistenceInitializer.persistenceManager!.sqliteManager;
      final results = await db.query(
        'products',
        where: 'barcode = ?',
        whereArgs: [barcode],
        limit: 1,
      );

      if (results.isEmpty) {
        return const Right(null);
      }

      final m = results.first;
      final product = Product(
        id: m['id']?.toString() ?? (m['barcode'] as String? ?? ''),
        name: m['name'] as String,
        barcode: (m['barcode'] as String?) ?? '',
        internalReference: m['internal_reference']?.toString(),
        productType: ProductType.fromValue(m['product_type']),
        baseUnit: m['base_unit']?.toString() ?? 'piece',
        quantityPrecision: ((m['quantity_precision'] ?? 3) as num).toInt(),
        allowPartialPackageSale: (m['allow_partial_package_sale'] ?? 0) == 1,
        price: (m['price'] as num?)?.toDouble() ?? 0.0,
        minPrice: (m['min_price'] as num?)?.toDouble() ?? 0.0,
        wholesalePrice: (m['wholesale_price'] as num?)?.toDouble() ?? 0.0,
        quantity: ((m['stock'] ?? m['quantity'] ?? 0) as num).toDouble(),
        minQuantity:
            ((m['min_stock'] ?? m['min_quantity'] ?? 0) as num).toInt(),
        category: m['category_id'] as String? ??
            m['category'] as String? ??
            'General',
        imagePath: m['image_path'] as String?,
        isActive: (m['is_active'] ?? 1) == 1,
      );

      return Right(product);
    } catch (e) {
      return Left(CacheFailure('Product not found: ${e.toString()}'));
    }
  }

  @override
  Future<Either<Failure, List<Product>>> getAllProducts() async {
    try {
      final db = PersistenceInitializer.persistenceManager!.sqliteManager;
      final results = await db.query('products', where: 'is_active = 1');

      final products = results
          .map((m) => Product(
                id: m['id']?.toString() ?? (m['barcode'] as String? ?? ''),
                name: m['name'] as String,
                barcode: (m['barcode'] as String?) ?? '',
                internalReference: m['internal_reference']?.toString(),
                productType: ProductType.fromValue(m['product_type']),
                baseUnit: m['base_unit']?.toString() ?? 'piece',
                quantityPrecision:
                    ((m['quantity_precision'] ?? 3) as num).toInt(),
                allowPartialPackageSale:
                    (m['allow_partial_package_sale'] ?? 0) == 1,
                price: (m['price'] as num?)?.toDouble() ?? 0.0,
                minPrice: (m['min_price'] as num?)?.toDouble() ?? 0.0,
                wholesalePrice:
                    (m['wholesale_price'] as num?)?.toDouble() ?? 0.0,
                quantity:
                    ((m['stock'] ?? m['quantity'] ?? 0) as num).toDouble(),
                minQuantity:
                    ((m['min_stock'] ?? m['min_quantity'] ?? 0) as num).toInt(),
                category: m['category_id'] as String? ??
                    m['category'] as String? ??
                    'General',
                imagePath: m['image_path'] as String?,
                isActive: (m['is_active'] ?? 1) == 1,
              ))
          .toList();

      return Right(products);
    } catch (e) {
      return Left(CacheFailure('Error fetching products: ${e.toString()}'));
    }
  }

  Future<void> _writeCustomerLedgerEntry(
    DatabaseExecutor txn, {
    required String customerId,
    required String entryType,
    required double amount,
    required String referenceType,
    required String referenceId,
    String? notes,
  }) async {
    final ledgerRows = await txn.query(
      'customer_ledger',
      columns: ['SUM(amount) AS total'],
      where: 'customer_id = ?',
      whereArgs: [customerId],
    );
    final currentBalance = ledgerRows.isNotEmpty
        ? ((ledgerRows.first['total'] as num?) ?? 0).toDouble()
        : 0.0;
    final nextBalance = currentBalance + amount;

    await txn.insert('customer_ledger', {
      'id': '${DateTime.now().microsecondsSinceEpoch}_${entryType}_$customerId',
      'customer_id': customerId,
      'entry_type': entryType,
      'amount': amount,
      'balance_after': nextBalance,
      'reference_type': referenceType,
      'reference_id': referenceId,
      'notes': notes,
      'created_at': DateTime.now().toIso8601String(),
    });
  }

  @override
  Future<Either<Failure, Unit>> saveSale(Sale sale) async {
    return ErrorHandler.executeWithErrorHandling(
      operation: () async {
        final db = PersistenceInitializer.persistenceManager!.sqliteManager;
        final existing = await db.query(
          'sales',
          columns: ['id'],
          where: 'id = ?',
          whereArgs: [sale.id],
          limit: 1,
        );
        if (existing.isNotEmpty) {
          throw StateError('Sale ${sale.id} has already been posted.');
        }

        await db.transaction((txn) => insertSaleInTransaction(txn, sale));

        StateSynchronizer.notify(DataChangeEvent(
          entityType: 'sale',
          operation: 'create',
          id: sale.id,
        ));

        return const Right(unit);
      },
      operationName: 'saveSale',
      userFriendlyMessage: 'Failed to save sale',
      source: 'SalesRepository',
    );
  }

  @override
  Future<Either<Failure, Sale>> postSale(Sale sale) async {
    final result = await saveSale(sale);
    return result.fold(
      (failure) => Left(failure),
      (_) => Right(sale),
    );
  }

  /// Compose a sale into an existing transaction (used by document
  /// conversion). This is deliberately the same stock/ledger path as
  /// [saveSale], so conversion cannot leave a partially posted sale.
  Future<void> insertSaleInTransaction(DatabaseExecutor txn, Sale sale) async {
    if (sale.paymentMethod == 'credit' &&
        (sale.customerId == null || sale.customerId!.isEmpty)) {
      throw StateError('Credit sales require a customer.');
    }

    final reference = await DocumentNumberService.next(
      txn,
      sequenceKey: 'invoice',
      prefix: 'INV',
      year: DateTime.now().year.toString(),
      table: 'sales',
      column: 'reference_number',
    );
    await txn.insert('sales', {
      'id': sale.id,
      'reference_number': reference,
      'total': sale.total,
      'items_count': sale.items,
      'created_at': sale.date.toIso8601String(),
      'cashier_name': sale.cashierName,
      'user_id': sale.cashierUsername,
      'customer_id': sale.customerId,
      'shift_id': sale.sessionId,
      'is_refund': sale.isRefund ? 1 : 0,
      'original_sale_id': sale.refundOriginalInvoiceId,
      'payment_method': sale.paymentMethod,
    });

    for (final item in sale.saleItems) {
      final productRows = await txn.query(
        'products',
        columns: ['stock', 'barcode', 'name'],
        where: 'id = ?',
        whereArgs: [item.productId],
      );
      if (productRows.isEmpty) {
        throw StateError(
            'Product ${item.productId} not found while saving sale.');
      }
      final suffix = DateTime.now().microsecondsSinceEpoch;
      final saleItemId = '${sale.id}_${item.productId}_$suffix';
      final sellingQuantity = item.sellingQuantity ?? item.quantity;
      final resolvedBaseQuantity = item.baseQuantity ??
          (item.conversionFactorSnapshot != null
              ? sellingQuantity * item.conversionFactorSnapshot!
              : item.quantity);
      await txn.insert('sale_items', {
        'id': saleItemId,
        'sale_id': sale.id,
        'product_id': item.productId,
        'product_barcode':
            productRows.first['barcode'] as String? ?? item.productId,
        'product_name': item.name,
        'quantity': item.quantity,
        'price': item.price,
        'subtotal': item.total,
        'wholesale_price': item.wholesalePrice,
        'selling_unit_id': item.sellingUnitId,
        'selling_quantity': sellingQuantity,
        'base_quantity': resolvedBaseQuantity,
        'conversion_factor_snapshot': item.conversionFactorSnapshot,
        'selling_unit_name_snapshot': item.sellingUnitNameSnapshot,
        'base_unit_snapshot': item.baseUnitSnapshot,
        'refunded_quantity': item.refundedQuantity,
      });
      await _stockPosting.post(
        txn: txn,
        movementId: '${saleItemId}_movement',
        productId: item.productId,
        quantityChange: -resolvedBaseQuantity,
        movementType: 'sale',
        referenceType: 'sale',
        referenceId: sale.id,
        lineageId: saleItemId,
        notes: 'Sale ${sale.id}',
        userId: sale.cashierUsername,
        unitCost: await _historicalFifoUnitCost(
          txn,
          productId: item.productId,
          quantity: resolvedBaseQuantity,
          createdAt: sale.date,
        ),
        createdAt: sale.date,
        sellingQuantity: sellingQuantity,
        conversionToBase: item.conversionFactorSnapshot,
        sellingUnitName: item.sellingUnitNameSnapshot,
        baseQuantity: -resolvedBaseQuantity,
      );
    }
    if (sale.customerId != null &&
        sale.customerId!.isNotEmpty &&
        sale.paymentMethod == 'credit') {
      await _writeCustomerLedgerEntry(
        txn,
        customerId: sale.customerId!,
        entryType: sale.isRefund ? 'refund' : 'sale',
        amount: sale.isRefund ? -sale.total : sale.total,
        referenceType: sale.isRefund ? 'refund' : 'sale',
        referenceId: sale.id,
        notes: sale.isRefund ? 'Refund ${sale.id}' : 'Sale ${sale.id}',
      );
    }
    if (!sale.isRefund && sale.paymentMethod == 'cash') {
      await _cashPosting.postInTransaction(
        txn: txn,
        movementType: 'sale_cash',
        amount: sale.total,
        referenceType: 'sale',
        referenceId: sale.id,
        sessionId: sale.sessionId,
        userId: sale.cashierUsername,
        idempotencyKey: 'sale:${sale.id}:cash',
        description: 'Cash sale ${sale.id}',
        createdAt: sale.date,
      );
    }
    await txn.insert('activity_logs', {
      'id': 'activity_${sale.id}_${DateTime.now().microsecondsSinceEpoch}',
      'session_id': sale.sessionId ?? '',
      'timestamp': sale.date.toIso8601String(),
      'type': (sale.isRefund ? ActivityType.refund : ActivityType.sale).name,
      'description': sale.isRefund
          ? 'Refund: ${sale.total.toStringAsFixed(2)} DA'
          : 'Sale: ${sale.total.toStringAsFixed(2)} DA',
      'user_name': sale.cashierName ?? sale.cashierUsername ?? 'system',
      'details': jsonEncode({
        'saleId': sale.id,
        'total': sale.total,
        'items': sale.saleItems.map((e) => e.name).toList(),
        'customerId': sale.customerId,
      }),
      'event_key': sale.isRefund ? 'refundCompleted' : 'saleCompleted',
      'parameters': jsonEncode({
        'user': sale.cashierName ?? sale.cashierUsername ?? 'system',
        'total': sale.total.toStringAsFixed(2),
        'id': sale.id,
      }),
    });
  }

  Future<List<Sale>> _getSalesWithItems(
      List<Map<String, dynamic>> saleRows) async {
    if (saleRows.isEmpty) return [];

    final db = PersistenceInitializer.persistenceManager!.sqliteManager;
    final saleIds = saleRows.map((r) => r['id'] as String).toList();

    // Fetch items for these sales
    final placeholders = List.filled(saleIds.length, '?').join(',');
    final itemRows = await db.query(
      'sale_items',
      where: 'sale_id IN ($placeholders)',
      whereArgs: saleIds,
    );

    // Group items by sale_id
    final itemsMap = <String, List<SaleItem>>{};
    for (var row in itemRows) {
      final saleId = row['sale_id'] as String;
      if (!itemsMap.containsKey(saleId)) {
        itemsMap[saleId] = [];
      }

      itemsMap[saleId]!.add(SaleItem(
        saleItemId: row['id'] as String?,
        productId: row['product_id'] as String,
        name: row['product_name'] as String,
        price: (row['price'] as num).toDouble(),
        quantity: (row['quantity'] as num).toDouble(),
        total: (row['subtotal'] as num).toDouble(),
        wholesalePrice: (row['wholesale_price'] as num?)?.toDouble() ?? 0.0,
        sellingUnitId: row['selling_unit_id'] as String?,
        sellingQuantity: (row['selling_quantity'] as num?)?.toDouble(),
        baseQuantity: (row['base_quantity'] as num?)?.toDouble(),
        conversionFactorSnapshot:
            (row['conversion_factor_snapshot'] as num?)?.toDouble(),
        sellingUnitNameSnapshot: row['selling_unit_name_snapshot'] as String?,
        baseUnitSnapshot: row['base_unit_snapshot'] as String?,
        refundedQuantity: (row['refunded_quantity'] as num?)?.toDouble() ?? 0.0,
        exchangedQuantity:
            (row['exchanged_quantity'] as num?)?.toDouble() ?? 0.0,
      ));
    }

    final exchangeRows = await db.query(
      'exchange_documents',
      columns: ['original_sale_id', 'replacement_sale_id'],
      where:
          'original_sale_id IN (${List.filled(saleIds.length, '?').join(',')})',
      whereArgs: saleIds,
    );
    final replacementSaleIds = exchangeRows
        .map((row) => row['replacement_sale_id'] as String?)
        .whereType<String>()
        .toList();
    final replacementReferences = <String, String?>{};
    if (replacementSaleIds.isNotEmpty) {
      final replacementRows = await db.query(
        'sales',
        columns: ['id', 'reference_number'],
        where:
            'id IN (${List.filled(replacementSaleIds.length, '?').join(',')})',
        whereArgs: replacementSaleIds,
      );
      for (final row in replacementRows) {
        replacementReferences[row['id'] as String] =
            row['reference_number'] as String?;
      }
    }
    final replacementReferenceByOriginal = <String, String?>{};
    for (final row in exchangeRows) {
      final originalId = row['original_sale_id'] as String?;
      final replacementId = row['replacement_sale_id'] as String?;
      if (originalId != null && replacementId != null) {
        replacementReferenceByOriginal[originalId] =
            replacementReferences[replacementId] ?? replacementId;
      }
    }

    final originalIds = saleRows
        .map((row) => row['original_sale_id'] as String?)
        .whereType<String>()
        .toSet()
        .toList();
    final originalReferences = <String, String?>{};
    if (originalIds.isNotEmpty) {
      final originalRows = await db.query(
        'sales',
        columns: ['id', 'reference_number'],
        where: 'id IN (${List.filled(originalIds.length, '?').join(',')})',
        whereArgs: originalIds,
      );
      for (final row in originalRows) {
        originalReferences[row['id'] as String] =
            row['reference_number'] as String?;
      }
    }

    // Bind items to sales
    return saleRows.map((row) {
      final id = row['id'] as String;
      final originalId = row['original_sale_id'] as String?;
      return Sale(
        id: id,
        referenceNumber: row['reference_number'] as String?,
        total: row['total'] as double,
        items: row['items_count'] as int? ?? 0,
        date: DateTime.parse(row['created_at'] as String),
        saleItems: itemsMap[id] ?? [],
        cashierName: row['cashier_name'] as String?,
        cashierUsername: row['user_id'] as String?,
        sessionId: row['shift_id'] as String?,
        customerId: row['customer_id'] as String?,
        customerName: row['customer_name'] as String?,
        customerCode: row['customer_code'] as String?,
        invoiceTypeIndex: (row['is_refund'] as int? ?? 0) == 1 ? 1 : 0,
        refundOriginalInvoiceId: originalId,
        refundOriginalInvoiceReference:
            originalId == null ? null : originalReferences[originalId],
        replacementInvoiceReference: replacementReferenceByOriginal[id],
        paymentMethod: row['payment_method'] as String? ?? 'cash',
      );
    }).toList();
  }

  @override
  Future<Either<Failure, List<Sale>>> getProductSalesHistory(
      String productId) async {
    try {
      final db = PersistenceInitializer.persistenceManager!.sqliteManager;
      final rows = await db.rawQuery('''
        SELECT s.*, c.name AS customer_name, c.code AS customer_code
        FROM sales s
        LEFT JOIN customers c ON c.id = s.customer_id
        INNER JOIN sale_items si ON si.sale_id = s.id
        WHERE si.product_id = ?
        ORDER BY s.created_at DESC, s.id DESC
      ''', [productId]);
      return Right(await _getSalesWithItems(rows));
    } catch (e) {
      return Left(CacheFailure('Unable to load product sales history: $e'));
    }
  }

  @override
  Future<Either<Failure, List<Sale>>> getRecentSales({
    int limit = 10,
    DateTime? startDate,
    DateTime? endDate,
    String? sessionId,
  }) async {
    try {
      final db = PersistenceInitializer.persistenceManager!.sqliteManager;

      String? where;
      List<Object?>? whereArgs;

      if (startDate != null || endDate != null) {
        final conditions = <String>[];
        whereArgs = [];

        if (startDate != null) {
          conditions.add('created_at >= ?');
          whereArgs.add(startDate.toIso8601String());
        }

        if (endDate != null) {
          conditions.add('created_at <= ?');
          whereArgs.add(endDate.toIso8601String());
        }
        if (sessionId != null) {
          conditions.add('shift_id = ?');
          whereArgs.add(sessionId);
        }
        where = conditions.join(' AND ');
      } else if (sessionId != null) {
        where = 'shift_id = ?';
        whereArgs = [sessionId];
      }

      final saleRows = await db.query(
        'sales',
        where: where,
        whereArgs: whereArgs,
        orderBy: 'created_at DESC',
        limit: limit,
      );

      final sales = await _getSalesWithItems(saleRows);
      return Right(sales);
    } catch (e) {
      return Left(CacheFailure('Error fetching recent sales: ${e.toString()}'));
    }
  }

  @override
  Future<Either<Failure, List<Sale>>> getCustomerReturnCandidates() async {
    try {
      final db = PersistenceInitializer.persistenceManager!.sqliteManager;
      final saleRows = await db.rawQuery('''
        SELECT s.*, c.name AS customer_name, c.code AS customer_code
        FROM sales s
        LEFT JOIN customers c ON c.id = s.customer_id
        WHERE s.is_refund = 0
          AND s.customer_id IS NOT NULL
          AND EXISTS (
            SELECT 1
            FROM sale_items si
            WHERE si.sale_id = s.id
              AND si.quantity > COALESCE(si.refunded_quantity, 0)
          )
        ORDER BY s.created_at DESC
      ''');
      return Right(await _getSalesWithItems(saleRows));
    } catch (e) {
      return Left(CacheFailure(
          'Error fetching customer return candidates: ${e.toString()}'));
    }
  }

  @override
  Future<Either<Failure, bool>> validateMinPrice(
      String barcode, double salePrice) async {
    try {
      final db = PersistenceInitializer.persistenceManager!.sqliteManager;
      final results = await db.query('products',
          columns: ['price', 'min_price'],
          where: 'id = ?',
          whereArgs: [barcode]);

      if (results.isEmpty) return const Right(false);

      final productPrice = results.first['price'] as double;

      return Right(salePrice >= productPrice);
    } catch (e) {
      return Left(CacheFailure('Error checking price: ${e.toString()}'));
    }
  }

  @override
  Future<Either<Failure, Unit>> createSaleWithCashier({
    required List<CartItemModel> items,
    required double total,
    required String cashierName,
    required String cashierUsername,
    String? customerId,
    String paymentMethod = 'cash',
  }) async {
    return ErrorHandler.executeWithErrorHandling(
      operation: () async {
        if (paymentMethod == 'credit' &&
            (customerId == null || customerId.isEmpty)) {
          throw StateError('Credit sales require a customer.');
        }

        final db = PersistenceInitializer.persistenceManager!.sqliteManager;
        var createdSaleId = '';
        await db.transaction((txn) async {
          final sale = Sale(
            id: await _nextSaleId(txn),
            total: total,
            items: items.length,
            date: DateTime.now(),
            cashierName: cashierName,
            cashierUsername: cashierUsername,
            customerId: customerId,
            paymentMethod: paymentMethod,
            saleItems: items
                .map((item) => SaleItem(
                      productId: item.id,
                      name: item.name,
                      price: item.salePrice,
                      quantity: item.qty.toDouble(),
                      total: item.total,
                      wholesalePrice: item.wholesalePrice,
                    ))
                .toList(),
          );
          createdSaleId = sale.id;
          final reference = await DocumentNumberService.next(
            txn,
            sequenceKey: 'invoice',
            prefix: 'INV',
            year: DateTime.now().year.toString(),
            table: 'sales',
            column: 'reference_number',
          );
          await txn.insert('sales', {
            'id': sale.id,
            'reference_number': reference,
            'total': sale.total,
            'items_count': sale.items,
            'created_at': sale.date.toIso8601String(),
            'cashier_name': sale.cashierName,
            'user_id': sale.cashierUsername,
            'customer_id': sale.customerId,
            'shift_id': sale.sessionId,
            'is_refund': sale.isRefund ? 1 : 0,
            'original_sale_id': sale.refundOriginalInvoiceId,
            'payment_method': sale.paymentMethod,
          });

          for (final item in sale.saleItems) {
            final productRows = await txn.query(
              'products',
              columns: ['stock', 'barcode', 'name'],
              where: 'id = ?',
              whereArgs: [item.productId],
            );
            if (productRows.isEmpty) {
              throw StateError(
                  'Product ${item.productId} not found while creating sale.');
            }

            final saleItemId =
                '${sale.id}_${item.productId}_${DateTime.now().microsecondsSinceEpoch}';
            await txn.insert('sale_items', {
              'id': saleItemId,
              'sale_id': sale.id,
              'product_id': item.productId,
              'product_barcode': item.productId,
              'product_name': item.name,
              'quantity': item.quantity.toDouble(),
              'price': item.price,
              'subtotal': item.total,
              'wholesale_price': item.wholesalePrice,
              'refunded_quantity': 0.0,
            });

            await _stockPosting.post(
              txn: txn,
              movementId: '${saleItemId}_movement',
              productId: item.productId,
              quantityChange: -item.quantity.toDouble(),
              movementType: 'sale',
              referenceType: 'sale',
              referenceId: sale.id,
              lineageId: saleItemId,
              notes: 'Sale ${sale.id}',
              userId: sale.cashierUsername,
              unitCost: await _historicalFifoUnitCost(
                txn,
                productId: item.productId,
                quantity: item.quantity.toDouble(),
                createdAt: sale.date,
              ),
              createdAt: sale.date,
            );
          }

          if (sale.customerId != null &&
              sale.customerId!.isNotEmpty &&
              sale.paymentMethod == 'credit') {
            await _writeCustomerLedgerEntry(
              txn,
              customerId: sale.customerId!,
              entryType: 'sale',
              amount: sale.total,
              referenceType: 'sale',
              referenceId: sale.id,
              notes: 'Sale ${sale.id}',
            );
          }
          if (sale.paymentMethod == 'cash') {
            await _cashPosting.postInTransaction(
              txn: txn,
              movementType: 'sale_cash',
              amount: sale.total,
              referenceType: 'sale',
              referenceId: sale.id,
              sessionId: sale.sessionId,
              userId: sale.cashierUsername,
              idempotencyKey: 'sale:${sale.id}:cash',
              description: 'Cash sale ${sale.id}',
              createdAt: sale.date,
            );
          }

          await txn.insert('activity_logs', {
            'id':
                'activity_${sale.id}_${DateTime.now().microsecondsSinceEpoch}',
            'session_id': sale.sessionId ?? '',
            'timestamp': sale.date.toIso8601String(),
            'type': ActivityType.sale.toString().split('.').last,
            'description': 'Sale: ${sale.total.toStringAsFixed(2)} DA',
            'user_name': sale.cashierName ?? sale.cashierUsername ?? 'system',
            'details': jsonEncode({
              'saleId': sale.id,
              'total': sale.total,
              'items': sale.saleItems.map((e) => e.name).toList(),
              'customerId': sale.customerId,
            }),
            'event_key': 'saleCompleted',
            'parameters': jsonEncode({
              'user': sale.cashierName ?? sale.cashierUsername ?? 'system',
              'total': sale.total.toStringAsFixed(2),
              'id': sale.id,
            }),
          });
        });

        // Notify state changes
        StateSynchronizer.notify(DataChangeEvent(
          entityType: 'sale',
          operation: 'create',
          id: createdSaleId,
        ));

        // Notify that product stock changed
        StateSynchronizer.notify(DataChangeEvent(
          entityType: 'product_stock',
          operation: 'update',
        ));

        return const Right(unit);
      },
      operationName: 'createSaleWithCashier',
      userFriendlyMessage: 'Failed to create sale',
      source: 'SalesRepository',
    );
  }

  @override
  Future<Either<Failure, Unit>> deleteSalesInRange(
      DateTime start, DateTime end) async {
    try {
      final db = PersistenceInitializer.persistenceManager!.sqliteManager;

      // Get sales to be deleted to restore stock?
      // Original code called deleteSale which deletes items.
      // Ideally we should handle stock restoration here too if deleteSale handles it??
      // Looking at original deleteSale, it just deletes from box. It does NOT seem to restore stock.
      // So I will just delete them.

      // Use raw SQL delete for efficiency
      await deleteCritical(
          entity: 'sales_range',
          id: '${start.millisecondsSinceEpoch}_${end.millisecondsSinceEpoch}',
          sqliteWrite: () async {
            // Delete sale_items first via cascade or manual
            // Our schema ON DELETE CASCADE on sale_items might handle it,
            // but let's be safe or query IDs first.

            // First select IDs to delete for logging/security if needed.
            // Then delete.

            // Ensure we cover the full range of the given end date
            // e.g. if start=today, end=today, we want start 00:00:00 to end 23:59:59
            final adjustedStart =
                DateTime(start.year, start.month, start.day, 0, 0, 0);
            final adjustedEnd =
                DateTime(end.year, end.month, end.day, 23, 59, 59, 999);

            final protected = await db.rawQuery(
              "SELECT id FROM sales WHERE created_at >= ? AND created_at <= ? "
              "AND status IN ('posted', 'completed') LIMIT 1",
              [adjustedStart.toIso8601String(), adjustedEnd.toIso8601String()],
            );
            if (protected.isNotEmpty) {
              throw StateError('Posted or completed sales cannot be deleted');
            }

            await db.delete('sales',
                where: "created_at >= ? AND created_at <= ? "
                    "AND status NOT IN ('posted', 'completed')",
                whereArgs: [
                  adjustedStart.toIso8601String(),
                  adjustedEnd.toIso8601String()
                ]);
            // SQLite with PRAGMA foreign_keys = ON should trigger cascade delete on sale_items
            // If not, we should manually delete items where sale_id undefined.
          });

      return const Right(unit);
    } catch (e) {
      return Left(CacheFailure('Error deleting invoices: ${e.toString()}'));
    }
  }

  @override
  Future<Either<Failure, Unit>> deleteSalesByQuery(String query) async {
    try {
      final db = PersistenceInitializer.persistenceManager!.sqliteManager;

      // Complex query: search sales by ID OR sale_items by name/barcode
      final sql = '''
        SELECT DISTINCT s.id
        FROM sales s
        LEFT JOIN sale_items si ON s.id = si.sale_id
        WHERE s.id LIKE ? OR si.product_barcode LIKE ? OR si.product_name LIKE ?
      ''';

      final pattern = '%$query%';
      final results =
          await db.database.rawQuery(sql, [pattern, pattern, pattern]);

      final idsToDelete = results.map((r) => r['id'] as String).toList();

      final protected = await db.rawQuery(
        "SELECT id FROM sales WHERE id IN (${List.filled(idsToDelete.length, '?').join(',')}) "
        "AND status IN ('posted', 'completed') LIMIT 1",
        idsToDelete,
      );
      if (protected.isNotEmpty) {
        return const Left(
          ValidationFailure('Posted or completed sales cannot be deleted'),
        );
      }

      for (final id in idsToDelete) {
        await deleteSale(id);
      }

      return const Right(unit);
    } catch (e) {
      return Left(
          CacheFailure('Error deleting matching invoices: ${e.toString()}'));
    }
  }

  @override
  Future<Either<Failure, Unit>> deleteSale(String saleId) async {
    try {
      final db = PersistenceInitializer.persistenceManager!.sqliteManager;
      final sale = await db.query(
        'sales',
        columns: ['status'],
        where: 'id = ?',
        whereArgs: [saleId],
      );
      if (sale.isNotEmpty &&
          const ['posted', 'completed'].contains(sale.first['status'])) {
        return const Left(
          ValidationFailure('Posted or completed sales cannot be deleted'),
        );
      }
      await deleteCritical(
        entity: 'sale',
        id: saleId,
        sqliteWrite: () async {
          await db.delete('sales', where: 'id = ?', whereArgs: [saleId]);
          // Items deleted by cascade or manual
          await db
              .delete('sale_items', where: 'sale_id = ?', whereArgs: [saleId]);
        },
      );
      return const Right(unit);
    } catch (e) {
      return Left(CacheFailure('Error deleting sale: ${e.toString()}'));
    }
  }

  @override
  Future<Either<Failure, List<Sale>>> getAllSales() async {
    try {
      final db = PersistenceInitializer.persistenceManager!.sqliteManager;
      final saleRows = await db.query(
        'sales',
        orderBy: 'created_at DESC',
        limit: 100, // Matching original limit
      );

      final sales = await _getSalesWithItems(saleRows);
      return Right(sales);
    } catch (e) {
      return Left(CacheFailure('Error fetching sales: ${e.toString()}'));
    }
  }

  @override
  Future<Either<Failure, List<Sale>>> getSalesByIds(List<String> ids) async {
    try {
      if (ids.isEmpty) return const Right([]);

      final db = PersistenceInitializer.persistenceManager!.sqliteManager;
      final placeholders = List.filled(ids.length, '?').join(',');

      final saleRows = await db.query(
        'sales',
        where: 'id IN ($placeholders)',
        whereArgs: ids,
      );

      final sales = await _getSalesWithItems(saleRows);
      return Right(sales);
    } catch (e) {
      return Left(
          CacheFailure('Error fetching selected invoices: ${e.toString()}'));
    }
  }

  @override
  Future<Either<Failure, List<Sale>>> getRefundsForInvoice(
      String originalInvoiceId) async {
    try {
      final db = PersistenceInitializer.persistenceManager!.sqliteManager;
      final saleRows = await db.query(
        'sales',
        where: 'original_sale_id = ? AND is_refund = 1',
        whereArgs: [originalInvoiceId],
      );

      final sales = await _getSalesWithItems(saleRows);
      return Right(sales);
    } catch (e) {
      return Left(CacheFailure('Error fetching refunds: ${e.toString()}'));
    }
  }

  @override
  Future<Either<Failure, Unit>> linkSalesToSession(
      List<String> saleIds, String sessionId) async {
    try {
      if (saleIds.isEmpty) return const Right(unit);

      await updateCritical(
        entity: 'session_sales_link',
        id: sessionId,
        data: {'sale_ids': saleIds},
        sqliteWrite: () async {
          final db = PersistenceInitializer.persistenceManager!.sqliteManager;
          final placeholders = List.filled(saleIds.length, '?').join(',');

          await db.database.rawUpdate(
            'UPDATE sales SET shift_id = ? WHERE id IN ($placeholders)',
            [sessionId, ...saleIds],
          );
        },
      );
      return const Right(unit);
    } catch (e) {
      return Left(
          CacheFailure('Error linking invoices to session: ${e.toString()}'));
    }
  }
}
