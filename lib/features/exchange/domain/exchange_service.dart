import 'dart:convert';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../../core/data/services/background_write_queue.dart';
import '../../../core/data/services/canonical_cash_posting_service.dart';
import '../../../core/data/services/document_number_service.dart';
import '../../../core/data/services/persistence_initializer.dart';
import '../../../core/data/services/sqlite_manager.dart';
import '../../../features/stock/services/canonical_stock_posting_service.dart';

class ExchangeLineRequest {
  final String originalSaleItemId;
  final String originalProductId;
  final double returnedQuantity;
  final String replacementProductId;
  final double replacementQuantity;
  final String? originalSellingUnitId;
  final String? replacementSellingUnitId;
  final double? replacementSellingQuantity;
  final double? replacementConversionFactor;
  final double? replacementBaseQuantity;

  const ExchangeLineRequest({
    required this.originalSaleItemId,
    required this.originalProductId,
    required this.returnedQuantity,
    required this.replacementProductId,
    required this.replacementQuantity,
    this.originalSellingUnitId,
    this.replacementSellingUnitId,
    this.replacementSellingQuantity,
    this.replacementConversionFactor,
    this.replacementBaseQuantity,
  });
}

class ExchangeRequest {
  final String originalSaleId;
  final List<ExchangeLineRequest> items;
  final String? customerId;
  final String paymentMethod;
  final String idempotencyKey;
  final String actorUserId;
  final String? notes;

  const ExchangeRequest({
    required this.originalSaleId,
    required this.items,
    required this.paymentMethod,
    required this.idempotencyKey,
    required this.actorUserId,
    this.customerId,
    this.notes,
  }) : assert(paymentMethod == 'cash' || paymentMethod == 'credit');
}

class ExchangeResult {
  final String exchangeDocumentId;
  final String replacementSaleId;
  final String replacementDocumentReference;
  final double differenceAmount;
  final String paymentMethod;
  final bool isDuplicate;
  final DateTime createdAt;
  final bool openReplacementInvoice;

  const ExchangeResult({
    required this.exchangeDocumentId,
    required this.replacementSaleId,
    this.replacementDocumentReference = '',
    required this.differenceAmount,
    required this.paymentMethod,
    required this.isDuplicate,
    required this.createdAt,
    this.openReplacementInvoice = false,
  });

  ExchangeResult copyWith({bool? openReplacementInvoice}) => ExchangeResult(
        exchangeDocumentId: exchangeDocumentId,
        replacementSaleId: replacementSaleId,
        replacementDocumentReference: replacementDocumentReference,
        differenceAmount: differenceAmount,
        paymentMethod: paymentMethod,
        isDuplicate: isDuplicate,
        createdAt: createdAt,
        openReplacementInvoice:
            openReplacementInvoice ?? this.openReplacementInvoice,
      );

  factory ExchangeResult.fromApiResponse(Map<String, dynamic> response) {
    final difference = double.tryParse(
          response['difference_amount']?.toString() ?? '',
        ) ??
        0.0;
    return ExchangeResult(
      exchangeDocumentId: '${response['exchange_id'] ?? ''}',
      replacementSaleId:
          '${response['replacement_sale_id'] ?? response['replacementSaleId'] ?? ''}',
      replacementDocumentReference:
          '${response['replacement_document_reference'] ?? response['replacementDocumentReference'] ?? ''}',
      differenceAmount: difference,
      paymentMethod: '${response['payment_method'] ?? 'cash'}',
      isDuplicate: false,
      createdAt:
          DateTime.tryParse('${response['posted_at']}') ?? DateTime.now(),
    );
  }
}

class ExchangeService {
  static const _stockPosting = CanonicalStockPostingService();
  static final _cashPosting = CanonicalCashPostingService();

  final Future<void> Function(DatabaseExecutor txn)? failureInjector;
  final SQLiteManager? sqliteManager;

  ExchangeService({this.failureInjector, this.sqliteManager});

  Future<ExchangeResult> execute(ExchangeRequest request) async {
    final db = sqliteManager ??
        PersistenceInitializer.persistenceManager!.sqliteManager;
    final normalizedKey = request.idempotencyKey.trim();
    if (normalizedKey.isEmpty) {
      throw ArgumentError.value(request.idempotencyKey, 'idempotencyKey');
    }
    if (request.items.isEmpty) {
      throw StateError('Exchange requires at least one item.');
    }

    try {
      return await DatabaseLifecycleCoordinator.instance
          .withWriteAccess(() async {
        return db.transaction((txn) async {
          await _ensureExchangeSchema(txn);

          final existing = await txn.query(
            'exchange_documents',
            columns: [
              'id',
              'replacement_sale_id',
              'difference_amount',
              'payment_method',
              'created_at'
            ],
            where: 'idempotency_key = ?',
            whereArgs: [normalizedKey],
            limit: 1,
          );
          if (existing.isNotEmpty) {
            final row = existing.first;
            final replacementReference = await _replacementReference(
              txn,
              row['replacement_sale_id'] as String?,
            );
            return ExchangeResult(
              exchangeDocumentId: row['id'] as String,
              replacementSaleId: (row['replacement_sale_id'] as String?) ?? '',
              replacementDocumentReference: replacementReference,
              differenceAmount:
                  (row['difference_amount'] as num?)?.toDouble() ?? 0.0,
              paymentMethod: (row['payment_method'] as String?) ?? 'cash',
              isDuplicate: true,
              createdAt: DateTime.parse(row['created_at'] as String),
            );
          }

          final originalSaleRows = await txn.query(
            'sales',
            columns: ['id', 'customer_id', 'payment_method'],
            where: 'id = ? AND is_refund = 0',
            whereArgs: [request.originalSaleId],
            limit: 1,
          );
          if (originalSaleRows.isEmpty) {
            throw StateError(
                'Original sale ${request.originalSaleId} was not found.');
          }
          final originalSale = originalSaleRows.first;
          final saleCustomerId = originalSale['customer_id'] as String?;
          final effectiveCustomerId = request.customerId ?? saleCustomerId;
          if (request.paymentMethod == 'credit' &&
              (effectiveCustomerId == null || effectiveCustomerId.isEmpty)) {
            throw StateError('Credit exchange requires a customer.');
          }
          if (request.paymentMethod !=
              (originalSale['payment_method'] as String? ?? 'cash')) {
            throw StateError(
                'Exchange payment method does not match the original sale method.');
          }
          if (saleCustomerId != null &&
              effectiveCustomerId != null &&
              saleCustomerId != effectiveCustomerId) {
            throw StateError(
                'The customer on the exchange request does not match the original sale.');
          }

          final validated = <_ValidatedExchangeLine>[];
          final requestedReturnedBySaleItem = <String, double>{};
          final requestedReturnedBaseBySaleItem = <String, double>{};
          for (final item in request.items) {
            final current =
                requestedReturnedBySaleItem[item.originalSaleItemId] ?? 0;
            requestedReturnedBySaleItem[item.originalSaleItemId] =
                item.returnedQuantity > current
                    ? item.returnedQuantity
                    : current;
          }
          final pricedOriginals = <String>{};
          var totalOldAmount = 0.0;
          var totalNewAmount = 0.0;

          for (final item in request.items) {
            if (item.returnedQuantity <= 0 || item.replacementQuantity <= 0) {
              throw StateError(
                  'Returned and replacement quantities must be positive.');
            }

            final saleItemRows = await txn.query(
              'sale_items',
              where: 'id = ? AND sale_id = ?',
              whereArgs: [item.originalSaleItemId, request.originalSaleId],
              limit: 1,
            );
            if (saleItemRows.isEmpty) {
              throw StateError(
                  'Original sale item ${item.originalSaleItemId} was not found.');
            }

            final saleItem = saleItemRows.first;
            final originalProductId = saleItem['product_id'] as String;
            if (item.originalProductId.isNotEmpty &&
                item.originalProductId != originalProductId) {
              throw StateError('Original product mismatch on exchange line.');
            }

            final originalBaseQuantity = _resolveOriginalBaseQuantity(saleItem);
            final refundedBaseQuantity =
                _resolveQuantityInBaseUnits(saleItem, 'refunded_quantity');
            final exchangedBaseQuantity =
                _resolveQuantityInBaseUnits(saleItem, 'exchanged_quantity');
            final remainingBaseQuantity = originalBaseQuantity -
                refundedBaseQuantity -
                exchangedBaseQuantity;
            requestedReturnedBaseBySaleItem[item.originalSaleItemId] =
                _resolveQuantityInBaseUnitsForRequestedValue(
              saleItem,
              requestedReturnedBySaleItem[item.originalSaleItemId]!,
            );
            if ((requestedReturnedBaseBySaleItem[item.originalSaleItemId] ??
                    0.0) >
                remainingBaseQuantity) {
              throw StateError(
                'Cannot exchange ${requestedReturnedBaseBySaleItem[item.originalSaleItemId]!.toStringAsFixed(3)} base units; only ${remainingBaseQuantity.toStringAsFixed(3)} remain.',
              );
            }

            final replacementRows = await txn.query(
              'products',
              columns: ['id', 'stock', 'base_unit', 'price'],
              where: 'id = ?',
              whereArgs: [item.replacementProductId],
              limit: 1,
            );
            if (replacementRows.isEmpty) {
              throw StateError(
                  'Replacement product ${item.replacementProductId} was not found.');
            }
            final replacement = replacementRows.first;
            final selectedReplacementUnit =
                await _resolveReplacementSellingUnit(
              txn,
              item.replacementProductId,
              item.replacementSellingUnitId,
            );
            final replacementSellingQuantity =
                item.replacementSellingQuantity ?? item.replacementQuantity;
            final replacementUnitFactor = item.replacementConversionFactor ??
                (selectedReplacementUnit != null
                    ? ((selectedReplacementUnit['conversion_to_base'] ?? 1.0)
                            as num)
                        .toDouble()
                    : 1.0);
            final replacementBaseQuantity = item.replacementBaseQuantity ??
                (replacementSellingQuantity * replacementUnitFactor);
            final available = (replacement['stock'] as num).toDouble();
            if (replacementBaseQuantity > available) {
              throw StateError(
                  'Insufficient replacement stock for product ${item.replacementProductId}.');
            }

            final oldUnitPrice = (saleItem['price'] as num).toDouble();
            final newUnitPrice = selectedReplacementUnit != null
                ? ((selectedReplacementUnit['selling_price'] ?? 0.0) as num)
                    .toDouble()
                : ((replacement['price'] as num?)?.toDouble() ?? 0.0);
            final oldTotal = oldUnitPrice * item.returnedQuantity;
            final newTotal = newUnitPrice * replacementSellingQuantity;
            validated.add(_ValidatedExchangeLine(
              originalSaleItemId: item.originalSaleItemId,
              originalProductId: originalProductId,
              returnedQuantity: item.returnedQuantity,
              replacementProductId: item.replacementProductId,
              replacementQuantity: replacementSellingQuantity,
              replacementUnitId: selectedReplacementUnit?['id'] as String?,
              replacementUnitName: selectedReplacementUnit?['name'] as String?,
              replacementConversionFactor: replacementUnitFactor,
              replacementBaseQuantity: replacementBaseQuantity,
              oldUnitPrice: oldUnitPrice,
              newUnitPrice: newUnitPrice,
              oldTotal: oldTotal,
              newTotal: newTotal,
              differenceAmount: newTotal - oldTotal,
            ));
            if (pricedOriginals.add(item.originalSaleItemId)) {
              totalOldAmount += oldTotal;
            }
            totalNewAmount += newTotal;
          }

          final differenceAmount = totalNewAmount - totalOldAmount;
          final createdAt = DateTime.now();
          final exchangeDocumentId =
              'exchange_${createdAt.microsecondsSinceEpoch}';
          final replacementSaleId =
              'replacement_sale_${createdAt.microsecondsSinceEpoch + 1}';

          final replacementReference = await DocumentNumberService.next(
            txn,
            sequenceKey: 'exchange-sale',
            prefix: 'EXG',
            year: createdAt.year.toString(),
            table: 'sales',
            column: 'reference_number',
          );

          await txn.insert('sales', {
            'id': replacementSaleId,
            'reference_number': replacementReference,
            'total': totalNewAmount,
            'items_count': validated.length,
            'created_at': createdAt.toIso8601String(),
            'cashier_name': request.actorUserId,
            'user_id': request.actorUserId,
            'customer_id': effectiveCustomerId,
            'shift_id': null,
            'is_refund': 0,
            'original_sale_id': null,
            'payment_method': request.paymentMethod,
          });

          final postedOriginals = <String>{};
          for (final line in validated) {
            final replacementItemId =
                '${replacementSaleId}_${line.replacementProductId}_${createdAt.microsecondsSinceEpoch}_${line.replacementQuantity.toInt()}';
            final replacementProductRow = await txn.query(
              'products',
              columns: ['barcode', 'name', 'wholesale_price', 'base_unit'],
              where: 'id = ?',
              whereArgs: [line.replacementProductId],
              limit: 1,
            );
            final replacementProduct = replacementProductRow.first;
            final replacementValues = <String, dynamic>{
              'id': replacementItemId,
              'sale_id': replacementSaleId,
              'product_id': line.replacementProductId,
              'product_barcode': replacementProduct['barcode'] as String? ??
                  line.replacementProductId,
              'product_name': replacementProduct['name'] as String,
              'quantity': line.replacementQuantity,
              'price': line.newUnitPrice,
              'subtotal': line.newTotal,
              'wholesale_price':
                  (replacementProduct['wholesale_price'] as num?)?.toDouble() ??
                      0.0,
              'selling_unit_id': line.replacementUnitId,
              'selling_quantity': line.replacementQuantity,
              'base_quantity': line.replacementBaseQuantity,
              'conversion_factor_snapshot': line.replacementConversionFactor,
              'selling_unit_name_snapshot': line.replacementUnitName ??
                  (replacementProduct['base_unit'] as String? ?? 'piece'),
              'base_unit_snapshot':
                  replacementProduct['base_unit'] as String? ?? 'piece',
              'refunded_quantity': 0.0,
              'exchanged_quantity': 0.0,
            };
            await txn.insert('sale_items', replacementValues);
          }

          await txn.insert('exchange_documents', {
            'id': exchangeDocumentId,
            'original_sale_id': request.originalSaleId,
            'customer_id': effectiveCustomerId,
            'payment_method': request.paymentMethod,
            'difference_amount': differenceAmount,
            'status': 'posted',
            'idempotency_key': normalizedKey,
            'created_at': createdAt.toIso8601String(),
            'created_by': request.actorUserId,
            'notes': request.notes,
            'replacement_sale_id': replacementSaleId,
          });

          for (final line in validated) {
            final exchangeItemId =
                '${exchangeDocumentId}_${line.originalSaleItemId}_'
                '${line.replacementProductId}_${DateTime.now().microsecondsSinceEpoch}';
            final originalSaleItemRow = await txn.query(
              'sale_items',
              where: 'id = ? AND sale_id = ?',
              whereArgs: [line.originalSaleItemId, request.originalSaleId],
              limit: 1,
            );
            final originalSaleItem = originalSaleItemRow.isNotEmpty
                ? originalSaleItemRow.first
                : null;
            final originalBaseQuantity = originalSaleItem != null
                ? _resolveOriginalBaseQuantity(originalSaleItem)
                : line.returnedQuantity;
            final returnedBaseQuantity = originalSaleItem != null
                ? _resolveQuantityInBaseUnitsForRequestedValue(
                    originalSaleItem, line.returnedQuantity)
                : line.returnedQuantity;
            final exchangeItemValues = <String, dynamic>{
              'id': exchangeItemId,
              'exchange_id': exchangeDocumentId,
              'original_sale_item_id': line.originalSaleItemId,
              'original_product_id': line.originalProductId,
              'returned_quantity': line.returnedQuantity,
              'replacement_product_id': line.replacementProductId,
              'replacement_quantity': line.replacementQuantity,
              'old_unit_price': line.oldUnitPrice,
              'new_unit_price': line.newUnitPrice,
              'old_total': line.oldTotal,
              'new_total': line.newTotal,
              'difference_amount': line.differenceAmount,
              'original_selling_unit_id': originalSaleItem?['selling_unit_id'],
              'original_selling_quantity':
                  originalSaleItem?['selling_quantity'] ??
                      originalSaleItem?['quantity'] ??
                      line.returnedQuantity,
              'original_base_quantity': originalBaseQuantity,
              'original_conversion_factor_snapshot':
                  originalSaleItem?['conversion_factor_snapshot'] ?? 1.0,
              'original_selling_unit_name_snapshot':
                  originalSaleItem?['selling_unit_name_snapshot'] ??
                      originalSaleItem?['product_name'] ??
                      'piece',
              'original_base_unit_snapshot':
                  originalSaleItem?['base_unit_snapshot'] ?? 'piece',
              'replacement_selling_unit_id': line.replacementUnitId,
              'replacement_selling_quantity': line.replacementQuantity,
              'replacement_base_quantity': line.replacementBaseQuantity,
              'replacement_conversion_factor_snapshot':
                  line.replacementConversionFactor,
              'replacement_selling_unit_name_snapshot':
                  line.replacementUnitName ?? 'piece',
              'replacement_base_unit_snapshot':
                  await _readProductBaseUnit(txn, line.replacementProductId),
            };
            await txn.insert('exchange_items', exchangeItemValues);

            if (postedOriginals.add(line.originalSaleItemId)) {
              await txn.update(
                'sale_items',
                {
                  'exchanged_quantity': ((await _currentExchangedQuantity(
                          txn, line.originalSaleItemId)) +
                      line.returnedQuantity)
                },
                where: 'id = ?',
                whereArgs: [line.originalSaleItemId],
              );

              await _stockPosting.post(
                txn: txn,
                movementId:
                    '${exchangeDocumentId}_${line.originalProductId}_return',
                productId: line.originalProductId,
                quantityChange: 0,
                baseQuantity: returnedBaseQuantity,
                movementType: 'customer_return',
                referenceType: 'sale',
                referenceId: request.originalSaleId,
                lineageId: line.originalSaleItemId,
                notes: 'Exchange return for $exchangeDocumentId',
                userId: request.actorUserId,
                createdAt: createdAt,
              );
            }

            await _stockPosting.post(
              txn: txn,
              movementId:
                  '${exchangeDocumentId}_${line.replacementProductId}_issue',
              productId: line.replacementProductId,
              quantityChange: 0,
              baseQuantity: -line.replacementBaseQuantity,
              movementType: 'sale',
              referenceType: 'sale',
              referenceId: replacementSaleId,
              lineageId: '${replacementSaleId}_${line.replacementProductId}_'
                  '${createdAt.microsecondsSinceEpoch}_'
                  '${line.replacementQuantity.toInt()}',
              notes: 'Exchange issue for $exchangeDocumentId',
              userId: request.actorUserId,
              createdAt: createdAt,
            );
          }

          if (request.paymentMethod == 'cash' && differenceAmount != 0) {
            await _cashPosting.postInTransaction(
              txn: txn,
              movementType: differenceAmount > 0 ? 'cash_in' : 'cash_out',
              amount: differenceAmount,
              referenceType: 'sale',
              referenceId: replacementSaleId,
              sessionId: null,
              userId: request.actorUserId,
              idempotencyKey: 'exchange:$exchangeDocumentId:cash',
              description:
                  'Exchange${differenceAmount > 0 ? ' received' : ' payout'} for $exchangeDocumentId',
              createdAt: createdAt,
            );
          }

          if (request.paymentMethod == 'credit' && differenceAmount != 0) {
            final ledgerRows = await txn.query(
              'customer_ledger',
              columns: ['SUM(amount) AS total'],
              where: 'customer_id = ?',
              whereArgs: [effectiveCustomerId],
            );
            final currentBalance = ledgerRows.isNotEmpty
                ? ((ledgerRows.first['total'] as num?) ?? 0.0).toDouble()
                : 0.0;
            await txn.insert('customer_ledger', {
              'id':
                  '${exchangeDocumentId}_ledger_${createdAt.microsecondsSinceEpoch}',
              'customer_id': effectiveCustomerId,
              'entry_type': 'exchange',
              'amount': differenceAmount,
              'balance_after': currentBalance + differenceAmount,
              'reference_type': 'exchange',
              'reference_id': exchangeDocumentId,
              'notes': request.notes ?? 'Exchange $exchangeDocumentId',
              'created_at': createdAt.toIso8601String(),
            });
          }

          if (failureInjector != null) {
            await failureInjector!(txn);
          }

          await txn.insert('activity_logs', {
            'id':
                '${exchangeDocumentId}_activity_${createdAt.microsecondsSinceEpoch}',
            'session_id': '',
            'timestamp': createdAt.toIso8601String(),
            'type': 'exchange',
            'description': 'Exchange $exchangeDocumentId posted',
            'user_name': request.actorUserId,
            'details': jsonEncode({
              'exchangeId': exchangeDocumentId,
              'originalSaleId': request.originalSaleId,
              'replacementSaleId': replacementSaleId,
              'differenceAmount': differenceAmount,
            }),
            'event_key': 'exchangeCompleted',
            'parameters': jsonEncode({
              'idempotencyKey': normalizedKey,
              'customerId': effectiveCustomerId,
            }),
          });

          return ExchangeResult(
            exchangeDocumentId: exchangeDocumentId,
            replacementSaleId: replacementSaleId,
            replacementDocumentReference: replacementReference,
            differenceAmount: differenceAmount,
            paymentMethod: request.paymentMethod,
            isDuplicate: false,
            createdAt: createdAt,
          );
        });
      });
    } catch (error) {
      if (_isDuplicateConstraintFailure(error)) {
        final existing = await db.query(
          'exchange_documents',
          columns: [
            'id',
            'replacement_sale_id',
            'difference_amount',
            'payment_method',
            'created_at'
          ],
          where: 'idempotency_key = ?',
          whereArgs: [normalizedKey],
          limit: 1,
        );
        if (existing.isNotEmpty) {
          final row = existing.first;
          final replacementReference = await _replacementReference(
            db.database,
            row['replacement_sale_id'] as String?,
          );
          return ExchangeResult(
            exchangeDocumentId: row['id'] as String,
            replacementSaleId: (row['replacement_sale_id'] as String?) ?? '',
            replacementDocumentReference: replacementReference,
            differenceAmount:
                (row['difference_amount'] as num?)?.toDouble() ?? 0.0,
            paymentMethod: (row['payment_method'] as String?) ?? 'cash',
            isDuplicate: true,
            createdAt: DateTime.parse(row['created_at'] as String),
          );
        }
      }
      rethrow;
    }
  }

  Future<String> _replacementReference(
    DatabaseExecutor db,
    String? replacementSaleId,
  ) async {
    if (replacementSaleId == null || replacementSaleId.isEmpty) return '';
    final rows = await db.query(
      'sales',
      columns: ['reference_number'],
      where: 'id = ?',
      whereArgs: [replacementSaleId],
      limit: 1,
    );
    return rows.isEmpty
        ? replacementSaleId
        : (rows.first['reference_number'] as String?) ?? replacementSaleId;
  }

  Future<Map<String, dynamic>?> _defaultSellingUnitForProduct(
    DatabaseExecutor txn,
    String productId,
  ) async {
    final rows = await txn.query(
      'product_selling_units',
      columns: ['id', 'name', 'conversion_to_base'],
      where: 'product_id = ? AND is_active = 1 AND is_default = 1',
      whereArgs: [productId],
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }
    return rows.first;
  }

  Future<String> _readProductBaseUnit(
      DatabaseExecutor txn, String productId) async {
    final rows = await txn.query(
      'products',
      columns: ['base_unit'],
      where: 'id = ?',
      whereArgs: [productId],
      limit: 1,
    );
    if (rows.isEmpty) return 'piece';
    return (rows.first['base_unit'] as String?) ?? 'piece';
  }

  double _resolveOriginalBaseQuantity(Map<String, dynamic> saleItem) {
    final baseQuantityValue = saleItem['base_quantity'];
    if (baseQuantityValue is num) {
      return baseQuantityValue.toDouble();
    }

    final sellingQuantityValue = saleItem['selling_quantity'];
    final conversionValue = saleItem['conversion_factor_snapshot'];
    if (sellingQuantityValue is num && conversionValue is num) {
      return sellingQuantityValue.toDouble() * conversionValue.toDouble();
    }

    final quantityValue = saleItem['quantity'];
    if (quantityValue is num) {
      return quantityValue.toDouble();
    }

    return 0.0;
  }

  double _resolveQuantityInBaseUnits(
      Map<String, dynamic> saleItem, String key) {
    final value = saleItem[key];
    if (value is! num) {
      return 0.0;
    }
    final raw = value.toDouble();
    final conversionValue = saleItem['conversion_factor_snapshot'];
    if (conversionValue is num && saleItem['selling_unit_id'] != null) {
      return raw * conversionValue.toDouble();
    }
    return raw;
  }

  double _resolveQuantityInBaseUnitsForRequestedValue(
    Map<String, dynamic> saleItem,
    double requestedQuantity,
  ) {
    final conversionValue = saleItem['conversion_factor_snapshot'];
    if (conversionValue is num && saleItem['selling_unit_id'] != null) {
      return requestedQuantity * conversionValue.toDouble();
    }
    return requestedQuantity;
  }

  Future<Map<String, dynamic>?> _resolveReplacementSellingUnit(
    DatabaseExecutor txn,
    String productId,
    String? selectedSellingUnitId,
  ) async {
    if (selectedSellingUnitId != null &&
        selectedSellingUnitId.trim().isNotEmpty) {
      final selectedRows = await txn.query(
        'product_selling_units',
        columns: ['id', 'name', 'conversion_to_base', 'selling_price'],
        where: 'id = ? AND product_id = ?',
        whereArgs: [selectedSellingUnitId, productId],
        limit: 1,
      );
      if (selectedRows.isEmpty) {
        throw StateError(
          'Replacement selling unit $selectedSellingUnitId does not belong to product $productId.',
        );
      }
      return selectedRows.first;
    }

    final activeRows = await txn.query(
      'product_selling_units',
      columns: ['id', 'name', 'conversion_to_base', 'selling_price'],
      where: 'product_id = ? AND is_active = 1',
      whereArgs: [productId],
    );
    if (activeRows.isEmpty) {
      return null;
    }
    if (activeRows.length > 1) {
      throw StateError(
        'Replacement selling unit is required for product $productId because multiple active units are configured.',
      );
    }
    return activeRows.first;
  }

  Future<void> _ensureExchangeSchema(DatabaseExecutor txn) async {
    final rows = await txn.query(
      'sqlite_master',
      columns: ['name'],
      where:
          "type = 'table' AND name IN ('exchange_documents', 'exchange_items', 'sale_items')",
    );
    final names = rows.map((row) => row['name'] as String).toSet();
    if (!names.contains('exchange_documents') ||
        !names.contains('exchange_items')) {
      throw StateError('Exchange schema is incomplete; schema 26 is required.');
    }
    final saleItemCols = await txn.rawQuery('PRAGMA table_info(sale_items)');
    if (!saleItemCols
        .any((column) => (column['name'] as String?) == 'exchanged_quantity')) {
      throw StateError(
          'sale_items.exchanged_quantity is missing; schema 26 is required.');
    }
  }

  Future<double> _currentExchangedQuantity(
      DatabaseExecutor txn, String saleItemId) async {
    final rows = await txn.query(
      'sale_items',
      columns: ['exchanged_quantity'],
      where: 'id = ?',
      whereArgs: [saleItemId],
      limit: 1,
    );
    return rows.isEmpty
        ? 0.0
        : ((rows.first['exchanged_quantity'] as num?) ?? 0.0).toDouble();
  }

  bool _isDuplicateConstraintFailure(Object error) {
    final value = error.toString();
    return value.contains('UNIQUE constraint failed') ||
        value.contains('already exists') ||
        value.contains('duplicate');
  }
}

class _ValidatedExchangeLine {
  final String originalSaleItemId;
  final String originalProductId;
  final double returnedQuantity;
  final String replacementProductId;
  final double replacementQuantity;
  final String? replacementUnitId;
  final String? replacementUnitName;
  final double replacementConversionFactor;
  final double replacementBaseQuantity;
  final double oldUnitPrice;
  final double newUnitPrice;
  final double oldTotal;
  final double newTotal;
  final double differenceAmount;

  const _ValidatedExchangeLine({
    required this.originalSaleItemId,
    required this.originalProductId,
    required this.returnedQuantity,
    required this.replacementProductId,
    required this.replacementQuantity,
    this.replacementUnitId,
    this.replacementUnitName,
    required this.replacementConversionFactor,
    required this.replacementBaseQuantity,
    required this.oldUnitPrice,
    required this.newUnitPrice,
    required this.oldTotal,
    required this.newTotal,
    required this.differenceAmount,
  });
}
