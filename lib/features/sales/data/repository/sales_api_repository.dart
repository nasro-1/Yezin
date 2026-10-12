import 'package:dartz/dartz.dart';
import 'package:flutter/foundation.dart';

import '../../../../core/error/failure.dart';
import '../../../../core/network/backend_api_client.dart';
import '../../../products/data/models/product_model.dart';
import '../../domain/sales_repository.dart';
import '../models/cart_item_model.dart';
import '../models/sale_model.dart';

/// Server-authoritative sales adapter. It deliberately has no SQLite access.
class SalesApiRepository implements SalesRepository {
  static const _serverPageSize = 200;

  SalesApiRepository(this.client);

  final BackendApiClient client;

  @override
  Future<Either<Failure, Unit>> saveSale(Sale sale) async {
    final result = await postSale(sale);
    return result.map((_) => unit);
  }

  @override
  Future<Either<Failure, Sale>> postSale(Sale sale) async {
    try {
      final payload = _salePayload(sale);
      debugPrint(
        '[SALES PAYMENT] subtotal=${payload['subtotal']} '
        'discount=${payload['discount']} paid=${payload['paid_amount']}',
      );
      return Right(_fromResponse(
        await client.postSale(payload, idempotencyKey: sale.id),
      ));
    } on BackendApiException catch (error) {
      return Left(_failure(error));
    } catch (error) {
      return Left(ServerFailure(error.toString()));
    }
  }

  Future<Either<Failure, Sale>> getSale(String saleId) async {
    try {
      return Right(_fromResponse(await client.getSale(saleId)));
    } on BackendApiException catch (error) {
      return Left(_failure(error));
    } catch (error) {
      return Left(ServerFailure(error.toString()));
    }
  }

  Future<Either<Failure, Map<String, dynamic>>> postRefund({
    required String saleId,
    required String idempotencyKey,
    required List<Map<String, dynamic>> items,
    String? paymentMethod,
  }) async {
    try {
      return Right(await client.postRefund(
        saleId,
        {
          'items': items,
          if (paymentMethod != null) 'payment_method': paymentMethod,
        },
        idempotencyKey: idempotencyKey,
      ));
    } on BackendApiException catch (error) {
      return Left(_failure(error));
    } catch (error) {
      return Left(ServerFailure(error.toString()));
    }
  }

  Future<Either<Failure, Map<String, dynamic>>> postExchange({
    required String saleId,
    required String idempotencyKey,
    required List<Map<String, dynamic>> items,
    String? paymentMethod,
    String? customerId,
  }) async {
    try {
      return Right(await client.postExchange(
        saleId,
        {
          'items': items,
          if (paymentMethod != null) 'payment_method': paymentMethod,
          if (customerId != null) 'customer_id': customerId,
        },
        idempotencyKey: idempotencyKey,
      ));
    } on BackendApiException catch (error) {
      return Left(_failure(error));
    } catch (error) {
      return Left(ServerFailure(error.toString()));
    }
  }

  @override
  Future<Either<Failure, List<Sale>>> getSalesByIds(List<String> ids) async {
    final results = <Sale>[];
    for (final id in ids) {
      final result = await getSale(id);
      if (result.isLeft())
        return Left(
            result.fold((f) => f, (_) => throw StateError('unreachable')));
      results.add(result.getOrElse(() => throw StateError('unreachable')));
    }
    return Right(results);
  }

  @override
  Future<Either<Failure, List<Sale>>> getAllSales() async =>
      _unsupported<List<Sale>>(
          'The server does not expose an unbounded sales list.');

  @override
  Future<Either<Failure, List<Sale>>> getRecentSales({
    int limit = 10,
    DateTime? startDate,
    DateTime? endDate,
    String? sessionId,
  }) async =>
      _loadServerSales(
        limit: limit,
        startDate: startDate,
        endDate: endDate,
      );

  @override
  Future<Either<Failure, Product?>> findProductByBarcode(
          String barcode) async =>
      _unsupported<Product?>('Product lookup must use the product repository.');

  @override
  Future<Either<Failure, List<Product>>> getAllProducts() async =>
      _unsupported<List<Product>>(
          'Product lookup must use the product repository.');

  @override
  Future<Either<Failure, Unit>> deleteSale(String saleId) async =>
      _unsupported<Unit>('Sales cannot be deleted in server mode.');
  @override
  Future<Either<Failure, Unit>> deleteSalesInRange(
          DateTime start, DateTime end) async =>
      _unsupported<Unit>('Sales cannot be deleted in server mode.');
  @override
  Future<Either<Failure, Unit>> deleteSalesByQuery(String query) async =>
      _unsupported<Unit>('Sales cannot be deleted in server mode.');
  @override
  Future<Either<Failure, List<Sale>>> getCustomerReturnCandidates() async =>
      _unsupported<List<Sale>>(
          'Returns must be posted by the server sales API.');
  @override
  Future<Either<Failure, bool>> validateMinPrice(
          String barcode, double salePrice) async =>
      _unsupported<bool>('Price validation must use server products.');
  @override
  Future<Either<Failure, List<Sale>>> getRefundsForInvoice(
          String originalInvoiceId) async =>
      _unsupported<List<Sale>>(
          'Refund lookup is not available from the sales API.');
  @override
  Future<Either<Failure, List<Sale>>> getProductSalesHistory(
          String productId) async =>
      _unsupported<List<Sale>>(
          'Sales history is not available from the sales API.');
  @override
  Future<Either<Failure, Unit>> createSaleWithCashier({
    required List<CartItemModel> items,
    required double total,
    required String cashierName,
    required String cashierUsername,
    String? customerId,
    String paymentMethod = 'cash',
  }) async =>
      _unsupported<Unit>(
          'Use saveSale so the posting idempotency key is stable.');
  @override
  Future<Either<Failure, Unit>> linkSalesToSession(
          List<String> saleIds, String sessionId) async =>
      _unsupported<Unit>('Sales sessions are server-owned.');

  Either<Failure, T> _unsupported<T>(String message) =>
      Left(ServerFailure(message));

  Map<String, dynamic> _salePayload(Sale sale) {
    final items = sale.saleItems
        .map((item) => {
              'product_id': item.productId,
              'quantity': item.sellingQuantity ?? item.quantity,
              'unit': item.sellingUnitNameSnapshot ??
                  item.baseUnitSnapshot ??
                  'piece',
              'unit_price': item.price,
            })
        .toList();
    final subtotal = items.fold<double>(
      0,
      (sum, item) =>
          sum +
          (item['quantity']! as num).toDouble() *
              (item['unit_price']! as num).toDouble(),
    );
    final discount = _money(sale.discount);
    final finalTotal = _money(subtotal - discount);
    return {
      'payment_method': sale.paymentMethod,
      'customer_id': sale.customerId,
      'discount': discount,
      'subtotal': _money(subtotal),
      'paid_amount': sale.paymentMethod == 'cash' ? finalTotal : 0,
      'items': items,
    };
  }

  double _money(double value) => double.parse(value.toStringAsFixed(2));

  Sale _fromResponse(Map<String, dynamic> json) {
    final items =
        (json['items'] as List? ?? const []).whereType<Map>().map((raw) {
      final item = Map<String, dynamic>.from(raw);
      final quantity = _decimal(item['quantity']);
      final baseQuantity = _decimal(item['base_quantity']);
      final price = _decimal(item['unit_price']);
      return SaleItem(
        saleItemId: item['id']?.toString(),
        productId: '${item['product_id']}',
        name: '${item['product_id']}',
        price: price,
        quantity: quantity,
        total: _decimal(item['line_total']),
        wholesalePrice: 0,
        historicalCost: item['historical_cost'] == null
            ? null
            : _decimal(item['historical_cost']),
        sellingQuantity: quantity,
        baseQuantity: baseQuantity,
        sellingUnitNameSnapshot: item['unit']?.toString(),
        refundedQuantity: _decimal(item['refunded_quantity']),
        exchangedQuantity: _decimal(item['exchanged_quantity']),
      );
    }).toList();
    return Sale(
      id: '${json['sale_id']}',
      total: _decimal(json['total']),
      items: items.length,
      date: _parseBackendTimestamp(json['posted_at']),
      saleItems: items,
      cashierName: json['posted_by_name']?.toString(),
      cashierUsername: json['posted_by']?.toString(),
      customerId: json['customer_id']?.toString(),
      paymentMethod: json['payment_method']?.toString() ?? 'cash',
      discount: _decimal(json['discount']),
      referenceNumber: json['document_reference']?.toString(),
      invoiceTypeIndex: json['is_refund'] == true ? 1 : 0,
      refundOriginalInvoiceId: json['original_sale_id']?.toString(),
      refundOriginalInvoiceReference:
          json['original_document_reference']?.toString() ??
              json['original_invoice_reference']?.toString(),
      refundedTotal: _decimal(json['refunded_total']),
    );
  }

  DateTime _parseBackendTimestamp(Object? value) {
    final raw = value?.toString();
    if (raw == null || raw.isEmpty) {
      return DateTime.now();
    }
    final parsed = DateTime.parse(raw);
    return (parsed.isUtc
            ? parsed
            : DateTime.utc(
                parsed.year,
                parsed.month,
                parsed.day,
                parsed.hour,
                parsed.minute,
                parsed.second,
                parsed.millisecond,
                parsed.microsecond,
              ))
        .toLocal();
  }

  double _decimal(Object? value) => value is num
      ? value.toDouble()
      : double.tryParse(value?.toString() ?? '') ?? 0;

  Failure _failure(BackendApiException error) => switch (error.errorKind) {
        BackendApiErrorKind.authentication ||
        BackendApiErrorKind.authorization =>
          AuthorizationFailure(error.message),
        BackendApiErrorKind.validation => ValidationFailure(error.message),
        BackendApiErrorKind.connection ||
        BackendApiErrorKind.timeout =>
          NetworkFailure(error.message),
        _ => ServerFailure(error.message),
      };

  Future<Either<Failure, List<Sale>>> _loadServerSales({
    required int limit,
    DateTime? startDate,
    DateTime? endDate,
  }) async {
    try {
      if (limit <= 0) {
        return const Right([]);
      }

      final sales = <Sale>[];
      var page = 1;
      var total = 0;
      do {
        final payload = await client.getSales(
          page: page,
          pageSize: _serverPageSize,
          startDate: startDate,
          endDate: endDate,
        );
        if (payload is! Map) {
          throw const FormatException('Backend returned invalid sales page');
        }
        final rawItems = payload['items'];
        final rawTotal = payload['total'];
        if (rawItems is! List || rawTotal is! num) {
          throw const FormatException('Backend returned invalid sales page');
        }
        total = rawTotal.toInt();
        sales.addAll(rawItems
            .whereType<Map>()
            .map((item) => _fromResponse(Map<String, dynamic>.from(item))));
        page++;
        if (rawItems.isEmpty) {
          break;
        }
      } while (sales.length < total && sales.length < limit);

      if (sales.length > limit) {
        sales.removeRange(limit, sales.length);
      }
      return Right(sales);
    } on BackendApiException catch (error) {
      return Left(_failure(error));
    } catch (error) {
      return Left(ServerFailure(error.toString()));
    }
  }
}
