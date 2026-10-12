import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:bayaa_pos/core/data/services/persistence_initializer.dart';
import 'package:bayaa_pos/core/data/services/document_number_service.dart';
import 'package:bayaa_pos/core/di/dependency_injection.dart';
import 'package:bayaa_pos/features/auth/presentation/cubit/user_cubit.dart';
import 'package:bayaa_pos/features/sessions/data/models/session_model.dart';

import '../../../sales/data/models/sale_model.dart';
import '../../../sales/domain/sales_repository.dart';
import '../../../sales/data/repository/sales_api_repository.dart';
import '../../../stock/services/canonical_stock_posting_service.dart';
import '../../../../core/data/services/canonical_cash_posting_service.dart';
import '../widgets/partial_refund_dialog.dart';
import '../../../../core/services/activity_logger.dart';
import '../../../../core/data/models/activity_log.dart';
import '../../../../core/security/permission_guard.dart';
import '../../../../core/session/session_manager.dart';
import 'package:collection/collection.dart'; // for firstWhereOrNull
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'invoice_state.dart';

enum RefundResult {
  success,
  alreadyProcessed,
}

class InvoiceCubit extends Cubit<InvoiceState> {
  static const _stockPosting = CanonicalStockPostingService();
  static final _cashPosting = CanonicalCashPostingService();
  final SalesRepository repository;
  final Future<void> Function(DatabaseExecutor txn)? failureInjector;

  StreamSubscription? _activitySubscription;

  InvoiceCubit(this.repository, {this.failureInjector})
      : super(InvoiceState.initial()) {
    if (!getIt.isRegistered<ActivityLogger>()) return;
    _activitySubscription =
        getIt<ActivityLogger>().activitiesStream.listen((activities) {
      if (activities.isNotEmpty) {
        final type = activities.first.type;
        if (type == ActivityType.sale ||
            type == ActivityType.refund ||
            type == ActivityType.invoiceDelete) {
          // Reload sales if we are not already loading?
          // loadSales emits loading state which might flicker UI.
          // Ideally we'd do a silent refresh, but for now standard load is fine for "Real Time" request.
          loadSales();
        }
      }
    });
  }

  static List<Sale> documentsForFilter(
      List<Sale> sales, InvoiceFilterType filterType) {
    if (filterType == InvoiceFilterType.refunded) {
      return sales.where((sale) => sale.isRefund).toList();
    }
    if (filterType == InvoiceFilterType.exchanges) {
      return sales.where((sale) => sale.isExchanged).toList();
    }
    return sales.where((sale) => !sale.isRefund).toList();
  }

  @override
  Future<void> close() {
    _activitySubscription?.cancel();
    return super.close();
  }

  // Load initial and filtered sales
  Future<void> loadSales() async {
    emit(InvoiceState.loadingState(
        state.searchQuery, state.startDate, state.endDate, state.filterType,
        currentSales: state.sales));
    final result = await repository.getRecentSales(limit: 10000);
    result.fold(
      (failure) => emit(InvoiceState.error(
        state.searchQuery,
        state.startDate,
        state.endDate,
        state.filterType,
        message: failure.message,
      )),
      (sales) => emit(InvoiceState.loaded(
          _filterSales(sales, state.searchQuery, state.startDate, state.endDate,
              state.filterType),
          state.searchQuery,
          state.startDate,
          state.endDate,
          state.filterType)),
    );
  }

  Future<Sale?> loadSaleById(String saleId) async {
    final result = await repository.getSalesByIds([saleId]);
    return result.fold(
      (failure) => throw StateError(failure.message),
      (sales) => sales.firstWhereOrNull((sale) => sale.id == saleId),
    );
  }

  Future<void> refreshAfterExchange({
    required String originalSaleId,
    required String replacementSaleId,
    String? replacementDocumentReference,
  }) async {
    final authoritativeSales = <String, Sale>{};
    final original = await loadSaleById(originalSaleId);
    if (original != null) {
      authoritativeSales[original.id] = original;
    }
    if (replacementSaleId.isNotEmpty) {
      final replacement = await loadSaleById(replacementSaleId);
      if (replacement != null) {
        authoritativeSales[replacement.id] = replacement;
      }
    }
    await loadSales();
    if (!isClosed) {
      final linkedSales = state.sales.map((sale) {
        final refreshed = authoritativeSales[sale.id] ?? sale;
        return refreshed.id == originalSaleId &&
                replacementDocumentReference != null &&
                replacementDocumentReference.isNotEmpty
            ? refreshed.copyWith(
                replacementInvoiceReference: replacementDocumentReference)
            : refreshed;
      }).toList();
      emit(InvoiceState.loaded(
        linkedSales,
        state.searchQuery,
        state.startDate,
        state.endDate,
        state.filterType,
      ));
    }
  }

  Future<void> loadCustomerReturnCandidates() async {
    emit(InvoiceState.loadingState(
        state.searchQuery, state.startDate, state.endDate, state.filterType,
        currentSales: state.sales));
    final result = await repository.getCustomerReturnCandidates();
    result.fold(
      (failure) => emit(InvoiceState.error(
        state.searchQuery,
        state.startDate,
        state.endDate,
        InvoiceFilterType.sales,
        message: failure.message,
      )),
      (sales) => emit(InvoiceState.loaded(
          _filterSales(sales, state.searchQuery, state.startDate, state.endDate,
              InvoiceFilterType.sales),
          state.searchQuery,
          state.startDate,
          state.endDate,
          InvoiceFilterType.sales)),
    );
  }

  // Set search query and reload
  void setSearchQuery(String query) async {
    emit(InvoiceState.loadingState(
        query, state.startDate, state.endDate, state.filterType,
        currentSales: state.sales));
    final result = await repository.getRecentSales(limit: 10000);
    result.fold(
      (failure) => emit(InvoiceState.error(
        query,
        state.startDate,
        state.endDate,
        state.filterType,
        message: failure.message,
      )),
      (sales) => emit(InvoiceState.loaded(
          _filterSales(
              sales, query, state.startDate, state.endDate, state.filterType),
          query,
          state.startDate,
          state.endDate,
          state.filterType)),
    );
  }

  // Set date range and reload
  void setDate(DateTime? start, DateTime? end) async {
    emit(InvoiceState.loadingState(
        state.searchQuery, start, end, state.filterType,
        currentSales: state.sales));
    final result = await repository.getRecentSales(limit: 10000);
    result.fold(
      (failure) => emit(InvoiceState.error(
        state.searchQuery,
        start,
        end,
        state.filterType,
        message: failure.message,
      )),
      (sales) => emit(InvoiceState.loaded(
          _filterSales(sales, state.searchQuery, start, end, state.filterType),
          state.searchQuery,
          start,
          end,
          state.filterType)),
    );
  }

  // Set filter type and reload
  Future<void> setFilterType(InvoiceFilterType type) async {
    emit(InvoiceState.loadingState(
        state.searchQuery, state.startDate, state.endDate, type,
        currentSales: state.sales));
    final result = await repository.getRecentSales(limit: 10000);
    result.fold(
      (failure) => emit(InvoiceState.error(
        state.searchQuery,
        state.startDate,
        state.endDate,
        type,
        message: failure.message,
      )),
      (sales) => emit(InvoiceState.loaded(
          _filterSales(
              sales, state.searchQuery, state.startDate, state.endDate, type),
          state.searchQuery,
          state.startDate,
          state.endDate,
          type)),
    );
  }

  List<Sale> _filterSales(List<Sale> sales, String searchQuery,
      DateTime? startDate, DateTime? endDate, InvoiceFilterType filterType) {
    final refundCount = sales.where((sale) => sale.isRefund).length;
    debugPrint(
      '[INVOICE_FILTER_TRACE] filter=${filterType.name.toUpperCase()} '
      'before=${sales.length} after=${sales.length} refundCount=$refundCount',
    );
    var filtered = documentsForFilter(sales, filterType);

    // Filter by Type
    // All and Sales intentionally show only the original sale document.

    if (startDate != null || endDate != null) {
      filtered = filtered.where((sale) {
        if (startDate != null && sale.date.isBefore(startDate)) return false;
        if (endDate != null) {
          final endOfDay =
              DateTime(endDate.year, endDate.month, endDate.day, 23, 59, 59);
          if (sale.date.isAfter(endOfDay)) return false;
        }
        return true;
      }).toList();
    }
    if (searchQuery.isNotEmpty) {
      filtered = filtered.where((sale) {
        if (sale.id.contains(searchQuery) ||
            (sale.referenceNumber
                    ?.toLowerCase()
                    .contains(searchQuery.toLowerCase()) ??
                false)) {
          return true;
        }
        return sale.saleItems.any((item) =>
            item.productId.contains(searchQuery) ||
            item.name.toLowerCase().contains(searchQuery.toLowerCase()));
      }).toList();
    }
    debugPrint(
      '[INVOICE_FILTER_TRACE] filter=${filterType.name.toUpperCase()} '
      'before=${sales.length} after=${filtered.length} '
      'refundCount=${filtered.where((sale) => sale.isRefund).length}',
    );
    return filtered;
  }

  // Delete a single sale
  Future<void> deleteSale(String saleId) async {
    // Find the sale before deleting for logging
    final sale = state.sales.firstWhereOrNull((s) => s.id == saleId);

    final result = await repository.deleteSale(saleId);
    result.fold(
      (failure) => throw StateError(failure.message),
      (_) {},
    );

    // Log activity if sale was found
    if (sale != null) {
      final sid = await getIt<SessionManager>().ensureSessionId(
        userName: getIt<UserCubit>().currentUser.name,
      );
      await getIt<ActivityLogger>().logActivity(
        type: ActivityType.invoiceDelete,
        description: 'Delete invoice: ${sale.total.toStringAsFixed(2)} DA',
        userName: getIt<UserCubit>().currentUser.name,
        sessionId: sid,
        details: {'saleId': saleId, 'items': sale.items},
        eventKey: 'invoiceDeleted',
        parameters: {
          'user': getIt<UserCubit>().currentUser.name,
          'id': saleId,
          'total': sale.total.toStringAsFixed(2),
        },
      );
    }

    loadSales();
  }

  static double validateRefundAvailability(
      Sale originalSale, List<RefundItem> itemsToRefund) {
    double total = 0;
    for (final item in itemsToRefund) {
      final originalItem = originalSale.saleItems.firstWhere(
        (si) => item.saleItemId != null
            ? si.saleItemId == item.saleItemId
            : si.productId == item.productId,
        orElse: () => throw StateError('Item not found in original sale'),
      );
      final originalDisplayQuantity =
          originalItem.sellingQuantity ?? originalItem.quantity;
      final refundableQty =
          originalDisplayQuantity - originalItem.refundedQuantity;
      final requestedQuantity = item.sellingQuantity ?? item.quantity;
      if (requestedQuantity > refundableQty + 1e-9) {
        throw StateError(
          'Cannot refund $requestedQuantity of ${item.productName}; only $refundableQty available.',
        );
      }
      total += item.total;
    }
    return total;
  }

  static String buildStableRefundRequestId({
    required Sale originalSale,
    required List<RefundItem> itemsToRefund,
    required String? customerId,
  }) {
    final payload = {
      'sale_id': originalSale.id,
      'customer_id': customerId ?? originalSale.customerId ?? '',
      'payment_method': originalSale.paymentMethod,
      'items': itemsToRefund
          .map((item) => {
                'sale_item_id': item.saleItemId,
                'product_id': item.productId,
                'product_name': item.productName,
                'quantity': item.sellingQuantity ?? item.quantity,
                'unit_price': item.unitPrice,
                'wholesale_price': item.wholesalePrice,
                'total': item.total,
              })
          .toList()
        ..sort((a, b) {
          final aKey = (a['sale_item_id'] ?? a['product_id']) as String;
          final bKey = (b['sale_item_id'] ?? b['product_id']) as String;
          final comparison = aKey.compareTo(bKey);
          if (comparison != 0) return comparison;
          final aQuantity = (a['quantity'] as num).toDouble();
          final bQuantity = (b['quantity'] as num).toDouble();
          return aQuantity.compareTo(bQuantity);
        }),
    };
    final digest = sha256.convert(utf8.encode(jsonEncode(payload))).toString();
    return 'refund_$digest';
  }

  // Create Partial Refund (Item-based refund)
  Future<RefundResult> createPartialRefund({
    required Sale originalSale,
    required List<RefundItem> itemsToRefund,
    String? customerId,
  }) async {
    if (itemsToRefund.isEmpty) return RefundResult.alreadyProcessed;
    PermissionGuard.requireCustomerReturnAccess(getIt<UserCubit>().currentUser);

    if (repository is SalesApiRepository) {
      final serverRepository = repository as SalesApiRepository;
      final result = await serverRepository.postRefund(
        saleId: originalSale.id,
        idempotencyKey: buildStableRefundRequestId(
          originalSale: originalSale,
          itemsToRefund: itemsToRefund,
          customerId: customerId ?? originalSale.customerId,
        ),
        paymentMethod: originalSale.paymentMethod,
        items: itemsToRefund
            .map((item) => {
                  'sale_item_id': item.saleItemId,
                  'product_id': item.productId,
                  'quantity': item.sellingQuantity ?? item.quantity,
                })
            .toList(),
      );
      if (result.isLeft()) {
        throw StateError(
            result.fold((failure) => failure.message, (_) => 'Refund failed'));
      }
      await loadSales();
      return RefundResult.success;
    }

    Session session;
    try {
      session = await getIt<SessionManager>().getOrCreateSession(
        userName: getIt<UserCubit>().currentUser.name,
      );
    } catch (e) {
      throw StateError('Unable to create a session for the refund: $e');
    }

    final db = PersistenceInitializer.persistenceManager!.sqliteManager;
    String refundSaleId = '';
    var alreadyProcessed = false;
    try {
      final finalCustomerId = customerId ?? originalSale.customerId;
      final stableRefundRequestId = buildStableRefundRequestId(
        originalSale: originalSale,
        itemsToRefund: itemsToRefund,
        customerId: finalCustomerId,
      );
      await db.transaction((txn) async {
        final transactionTime = DateTime.now();
        final transactionTimestamp = transactionTime.toIso8601String();
        final originalSaleRows = await txn.query(
          'sales',
          columns: ['id', 'is_refund', 'customer_id', 'payment_method'],
          where: 'id = ?',
          whereArgs: [originalSale.id],
        );
        if (originalSaleRows.isEmpty ||
            (originalSaleRows.first['is_refund'] as num?)?.toInt() == 1) {
          throw StateError('Original sale ${originalSale.id} was not found.');
        }
        final storedCustomerId =
            originalSaleRows.first['customer_id'] as String?;
        final originalPaymentMethod =
            originalSaleRows.first['payment_method'] as String? ?? 'cash';
        if (finalCustomerId != storedCustomerId) {
          throw StateError('The selected customer does not own this sale.');
        }

        final existingRefund = await txn.query(
          'sales',
          columns: ['id'],
          where: 'id = ?',
          whereArgs: [stableRefundRequestId],
          limit: 1,
        );
        if (existingRefund.isNotEmpty) {
          alreadyProcessed = true;
          return;
        }

        double refundTotal = 0;
        int totalItems = 0;

        final refundSaleItems = <SaleItem>[];
        for (final item in itemsToRefund) {
          final originalRows = await txn.query(
            'sale_items',
            columns: [
              'id',
              'quantity',
              'selling_quantity',
              'base_quantity',
              'selling_unit_id',
              'conversion_factor_snapshot',
              'selling_unit_name_snapshot',
              'base_unit_snapshot',
              'refunded_quantity',
              'price',
              'subtotal',
            ],
            where: item.saleItemId != null
                ? 'sale_id = ? AND id = ?'
                : 'sale_id = ? AND product_id = ?',
            whereArgs: [originalSale.id, item.saleItemId ?? item.productId],
          );
          if (originalRows.isEmpty) {
            throw StateError(
              'Item ${item.productName} was not found in sale ${originalSale.id}.',
            );
          }

          final historicalRow = originalRows.first;
          final originalBaseQuantity =
              (historicalRow['base_quantity'] as num?)?.toDouble() ??
                  (((historicalRow['selling_quantity'] as num?)?.toDouble() ??
                          (historicalRow['quantity'] as num).toDouble()) *
                      ((historicalRow['conversion_factor_snapshot'] as num?)
                              ?.toDouble() ??
                          1.0));
          final originalDisplayQuantity =
              (historicalRow['selling_quantity'] as num?)?.toDouble() ??
                  (historicalRow['quantity'] as num).toDouble();
          final historicalPrice =
              (historicalRow['price'] as num?)?.toDouble() ?? item.unitPrice;
          final refundedQuantity =
              (historicalRow['refunded_quantity'] as num?)?.toDouble() ?? 0.0;
          final refundableQuantity = originalDisplayQuantity - refundedQuantity;
          final requestedQuantity = item.sellingQuantity ?? item.quantity;
          if (requestedQuantity <= 0 ||
              requestedQuantity > refundableQuantity + 1e-9) {
            throw StateError(
              'Cannot refund $requestedQuantity of ${item.productName}; '
              'only $refundableQuantity available.',
            );
          }

          final refundLineTotal = historicalPrice * requestedQuantity;
          refundTotal += refundLineTotal;
          totalItems += item.quantity.toInt();
          refundSaleItems.add(SaleItem(
            productId: item.productId,
            name: item.productName,
            price: historicalPrice,
            quantity: requestedQuantity,
            total: refundLineTotal,
            wholesalePrice: item.wholesalePrice,
            sellingUnitId: item.sellingUnitId ??
                historicalRow['selling_unit_id'] as String?,
            sellingQuantity: requestedQuantity,
            baseQuantity: originalBaseQuantity *
                (requestedQuantity / originalDisplayQuantity),
            conversionFactorSnapshot:
                (historicalRow['conversion_factor_snapshot'] as num?)
                        ?.toDouble() ??
                    (historicalRow['selling_unit_id'] == null ? 1.0 : null),
            sellingUnitNameSnapshot: item.sellingUnitNameSnapshot ??
                historicalRow['selling_unit_name_snapshot'] as String?,
            baseUnitSnapshot: item.baseUnitSnapshot ??
                historicalRow['base_unit_snapshot'] as String?,
          ));
        }

        refundSaleId = stableRefundRequestId;
        final refundReference = await DocumentNumberService.next(
          txn,
          sequenceKey: 'customer-return',
          prefix: 'CR',
          year: transactionTime.year.toString(),
          table: 'sales',
          column: 'reference_number',
        );
        final refundSale = Sale(
          id: refundSaleId,
          total: refundTotal,
          items: totalItems,
          date: transactionTime,
          saleItems: refundSaleItems,
          cashierName: getIt<UserCubit>().currentUser.name,
          cashierUsername: getIt<UserCubit>().currentUser.username,
          sessionId: session.id,
          customerId: finalCustomerId,
          invoiceTypeIndex: 1,
          refundOriginalInvoiceId: originalSale.id,
          referenceNumber: refundReference,
        );

        await txn.insert('sales', {
          'id': refundSale.id,
          'reference_number': refundReference,
          'total': refundSale.total,
          'items_count': refundSale.items,
          'created_at': transactionTimestamp,
          'user_id': refundSale.cashierUsername,
          'cashier_name': refundSale.cashierName,
          'customer_id': finalCustomerId,
          'shift_id': refundSale.sessionId,
          'is_refund': 1,
          'original_sale_id': refundSale.refundOriginalInvoiceId,
          'payment_method': refundSale.paymentMethod,
        });

        for (final item in refundSale.saleItems) {
          await txn.insert('sale_items', {
            'id':
                '${refundSale.id}_${item.productId}_${DateTime.now().microsecondsSinceEpoch}',
            'sale_id': refundSale.id,
            'product_id': item.productId,
            'product_barcode': item.productId,
            'product_name': item.name,
            'quantity': item.quantity.toDouble(),
            'price': item.price,
            'subtotal': item.total,
            'wholesale_price': item.wholesalePrice,
            'selling_unit_id': item.sellingUnitId,
            'selling_quantity': item.sellingQuantity ?? item.quantity,
            'base_quantity': item.baseQuantity ?? item.quantity,
            'conversion_factor_snapshot': item.conversionFactorSnapshot,
            'selling_unit_name_snapshot': item.sellingUnitNameSnapshot,
            'base_unit_snapshot': item.baseUnitSnapshot,
            'refunded_quantity': 0.0,
          });
        }

        for (final item in itemsToRefund) {
          final row = await txn.query(
            'sale_items',
            where: item.saleItemId != null
                ? 'sale_id = ? AND id = ?'
                : 'sale_id = ? AND product_id = ?',
            whereArgs: [originalSale.id, item.saleItemId ?? item.productId],
          );
          final updatedRefunded =
              (row.first['refunded_quantity'] as num?)?.toDouble() ?? 0.0;
          final requestedQuantity = item.sellingQuantity ?? item.quantity;
          final historicalRow = row.first;
          final originalDisplayQuantity =
              (historicalRow['selling_quantity'] as num?)?.toDouble() ??
                  (historicalRow['quantity'] as num).toDouble();
          final originalBaseQuantity =
              (historicalRow['base_quantity'] as num?)?.toDouble() ??
                  (originalDisplayQuantity *
                      ((historicalRow['conversion_factor_snapshot'] as num?)
                              ?.toDouble() ??
                          1.0));
          final refundBaseQuantity = originalBaseQuantity *
              (requestedQuantity / originalDisplayQuantity);
          await txn.update(
            'sale_items',
            {'refunded_quantity': updatedRefunded + requestedQuantity},
            where: 'id = ?',
            whereArgs: [row.first['id']],
          );

          await _stockPosting.post(
            txn: txn,
            movementId: '${refundSale.id}_${item.productId}_return_movement',
            productId: item.productId,
            quantityChange: refundBaseQuantity,
            movementType: 'customer_return',
            referenceType: 'refund',
            referenceId: refundSale.id,
            lineageId: historicalRow['id'] as String,
            notes: 'Refund $refundReference',
            userId: getIt<UserCubit>().currentUser.username,
            createdAt: DateTime.parse(transactionTimestamp),
            sellingQuantity: requestedQuantity,
            conversionToBase:
                (historicalRow['conversion_factor_snapshot'] as num?)
                    ?.toDouble(),
            sellingUnitName: item.sellingUnitNameSnapshot ??
                historicalRow['selling_unit_name_snapshot'] as String?,
            baseQuantity: refundBaseQuantity,
          );
        }
        if (originalPaymentMethod == 'cash') {
          await _cashPosting.postInTransaction(
            txn: txn,
            movementType: 'customer_refund_cash',
            amount: -refundTotal,
            referenceType: 'refund',
            referenceId: refundSale.id,
            sessionId: refundSale.sessionId,
            userId: refundSale.cashierUsername,
            idempotencyKey: 'refund:${refundSale.id}:cash',
            description: 'Cash refund $refundReference',
            createdAt: DateTime.parse(transactionTimestamp),
          );
        }

        if (finalCustomerId != null &&
            finalCustomerId.isNotEmpty &&
            originalPaymentMethod == 'credit') {
          final rows = await txn.query(
            'customer_ledger',
            columns: ['SUM(amount) AS total'],
            where: 'customer_id = ?',
            whereArgs: [finalCustomerId],
          );
          final currentBalance = rows.isNotEmpty
              ? ((rows.first['total'] as num?) ?? 0.0).toDouble()
              : 0.0;
          final nextBalance = currentBalance - refundTotal;
          await txn.insert('customer_ledger', {
            'id':
                '${refundSale.id}_ledger_${DateTime.now().microsecondsSinceEpoch}',
            'customer_id': finalCustomerId,
            'entry_type': 'refund',
            'amount': -refundTotal,
            'balance_after': nextBalance,
            'reference_type': 'refund',
            'reference_id': refundSale.id,
            'notes': 'Refund $refundReference',
            'created_at': transactionTimestamp,
          });
        }

        if (failureInjector != null) {
          await failureInjector!(txn);
        }

        await txn.insert('activity_logs', {
          'id':
              'activity_${refundSale.id}_${DateTime.now().microsecondsSinceEpoch}',
          'session_id': session.id,
          'timestamp': transactionTimestamp,
          'type': ActivityType.refund.toString().split('.').last,
          'description':
              'Refund $refundReference: ${refundTotal.toStringAsFixed(2)} DA',
          'user_name': getIt<UserCubit>().currentUser.name,
          'details': jsonEncode({
            'total': refundTotal,
            'itemCount': totalItems,
            'originalInvoiceId': originalSale.id,
            'returnReference': refundReference,
            'refundedItems': itemsToRefund.map((i) => i.productName).toList(),
            'customerId': finalCustomerId,
          }),
          'event_key': 'refundCompleted',
          'parameters': jsonEncode({
            'user': getIt<UserCubit>().currentUser.name,
            'total': refundTotal.toStringAsFixed(2),
            'originalInvoiceId': originalSale.id,
            'itemCount': totalItems,
          }),
        });
      });

      if (refundSaleId.isNotEmpty) {
        session.invoiceIds.add(refundSaleId);
      }
    } catch (e) {
      final message = e.toString();
      if (message.contains('UNIQUE constraint failed') ||
          message.contains('already been posted') ||
          message.contains('duplicate') ||
          message.contains('sales.id')) {
        await loadSales();
        return RefundResult.alreadyProcessed;
      }
      throw Exception('Refund failed: $e');
    }

    await loadSales();
    return alreadyProcessed
        ? RefundResult.alreadyProcessed
        : RefundResult.success;
  }

  // Bulk delete (date range or query)
  Future<void> deleteInvoices(
      DateTime? start, DateTime? end, String searchQuery) async {
    if (start != null && end != null) {
      final result = await repository.deleteSalesInRange(start, end);
      result.fold(
        (failure) => throw StateError(failure.message),
        (_) {},
      );
    } else {
      final result = await repository.deleteSalesByQuery(searchQuery);
      result.fold(
        (failure) => throw StateError(failure.message),
        (_) {},
      );
    }

    // Log bulk delete activity
    try {
      final sid = await getIt<SessionManager>().ensureSessionId(
        userName: getIt<UserCubit>().currentUser.name,
      );
      await getIt<ActivityLogger>().logActivity(
        type: ActivityType.invoiceDelete,
        description: 'Bulk invoice deletion',
        userName: getIt<UserCubit>().currentUser.name,
        sessionId: sid,
        details: {
          'startDate': start?.toIso8601String(),
          'endDate': end?.toIso8601String(),
          'searchQuery': searchQuery,
        },
        eventKey: 'invoiceDeleted',
        parameters: {
          'user': getIt<UserCubit>().currentUser.name,
          'id': 'bulk',
        },
      );
    } catch (_) {}

    loadSales();
  }

  // Reset all filters
  void resetFilters() async {
    const query = '';
    const InvoiceFilterType type = InvoiceFilterType.all;
    DateTime? start;
    DateTime? end;

    emit(InvoiceState.loadingState(query, start, end, type,
        currentSales: state.sales));
    final result = await repository.getRecentSales(limit: 10000);
    final sales = result.getOrElse(() => []);
    emit(InvoiceState.loaded(
        _filterSales(sales, query, start, end, type), query, start, end, type));
  }
}
