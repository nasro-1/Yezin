import 'dart:convert';

import 'package:dartz/dartz.dart' show Either, Left, Right, Unit, unit;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../../../core/data/services/persistence_initializer.dart';
import '../../../../core/data/services/document_number_service.dart';
import '../../../../core/error/failure.dart';
import '../../../../core/security/permission_guard.dart';
import '../../../../core/network/authority_context.dart';
import '../../../../core/data/models/activity_log.dart';
import '../../../auth/data/models/user_model.dart';
import '../../../sales/data/models/sale_model.dart';
import '../../../sales/data/repository/sales_repository_impl.dart';
import '../models/order_model.dart';
import '../models/proforma_model.dart';

class OrdersProformasRepository {
  OrdersProformasRepository(
      {SalesRepositoryImpl? salesRepository,
      Database? database,
      Future<void> Function(DatabaseExecutor txn)? failureInjector,
      AuthorityContext? authorityContext})
      : _salesRepository = salesRepository ?? SalesRepositoryImpl(),
        _providedDatabase = database,
        _failureInjector = failureInjector,
        _authorityContext = authorityContext ??
            AuthorityContext.fromProductConfig();

  final SalesRepositoryImpl _salesRepository;
  final Database? _providedDatabase;
  final Future<void> Function(DatabaseExecutor txn)? _failureInjector;
  final AuthorityContext _authorityContext;

  Database get _db =>
      _providedDatabase ??
      PersistenceInitializer.persistenceManager!.sqliteManager.database;

  static const _validStatuses = {
    'draft',
    'confirmed',
    'cancelled',
    'converted'
  };

  static String? validateLines<T>(List<T> lines, double Function(T) quantity,
      double Function(T) price, double Function(T) total) {
    if (lines.isEmpty) return 'At least one line is required.';
    for (final line in lines) {
      final qty = quantity(line);
      final unitPrice = price(line);
      if (!qty.isFinite || qty <= 0) {
        return 'Line quantities must be greater than zero.';
      }
      if (!unitPrice.isFinite || unitPrice < 0) {
        return 'Line prices must not be negative.';
      }
      if (!total(line).isFinite || total(line) < 0) {
        return 'Line totals are invalid.';
      }
    }
    return null;
  }

  static bool canTransition(String current, String next) {
    if (!_validStatuses.contains(current) || !_validStatuses.contains(next)) {
      return false;
    }
    return switch (current) {
      'draft' => next == 'confirmed' || next == 'cancelled',
      'confirmed' => next == 'cancelled' || next == 'converted',
      _ => false,
    };
  }

  Future<Either<Failure, Unit>> createOrder(Order order, User actor) async {
    try {
      PermissionGuard.requireOrdersAndProformasAccess(actor);
      final validation = validateLines<OrderLine>(
          order.lines,
          (line) => line.quantity,
          (line) => line.unitPrice,
          (line) => line.lineTotal);
      if (validation != null) return Left(ValidationFailure(validation));
      if (order.id.trim().isEmpty) {
        return const Left(ValidationFailure('Order id is required.'));
      }
      if (order.status != OrderStatus.draft) {
        return const Left(
            ValidationFailure('Only draft orders can be edited.'));
      }
      await _validateCustomer(order.customerId);
      if (order.status != OrderStatus.draft) {
        return const Left(
            ValidationFailure('New orders must start in draft status.'));
      }
      await _db.transaction((txn) async {
        final now = DateTime.now().toIso8601String();
        final reference = order.referenceNumber.trim().isEmpty
            ? await DocumentNumberService.next(txn,
                sequenceKey: 'order',
                prefix: 'ORD',
                year: DateTime.now().year.toString(),
                table: 'orders',
                column: 'reference_number')
            : order.referenceNumber;
        await txn.insert('orders', {
          'id': order.id,
          'reference_number': reference,
          'customer_id': order.customerId,
          'order_date': order.orderDate.toIso8601String(),
          'subtotal': order.subtotal,
          'total': order.total,
          'status': order.status.name,
          'notes': order.notes,
          'created_by': actor.username,
          'created_at': now,
          'updated_at': now,
        });
        await _insertOrderLines(txn, order);
        await _audit(txn, ActivityType.orderCreated, 'orderCreated', order.id,
            reference, actor);
      });
      return const Right(unit);
    } catch (e) {
      return Left(_failure(e, 'Unable to create order'));
    }
  }

  Future<Either<Failure, Unit>> createProforma(
      Proforma proforma, User actor) async {
    try {
      PermissionGuard.requireOrdersAndProformasAccess(actor);
      final validation = validateLines<ProformaLine>(
          proforma.lines,
          (line) => line.quantity,
          (line) => line.unitPrice,
          (line) => line.lineTotal);
      if (validation != null) return Left(ValidationFailure(validation));
      if (proforma.id.trim().isEmpty) {
        return const Left(ValidationFailure('Proforma id is required.'));
      }
      if (proforma.status != ProformaStatus.draft) {
        return const Left(
            ValidationFailure('Only draft proformas can be edited.'));
      }
      await _validateCustomer(proforma.customerId);
      if (proforma.status != ProformaStatus.draft) {
        return const Left(
            ValidationFailure('New proformas must start in draft status.'));
      }
      await _db.transaction((txn) async {
        final now = DateTime.now().toIso8601String();
        final reference = proforma.referenceNumber.trim().isEmpty
            ? await DocumentNumberService.next(txn,
                sequenceKey: 'proforma',
                prefix: 'PRO',
                year: DateTime.now().year.toString(),
                table: 'proformas',
                column: 'reference_number')
            : proforma.referenceNumber;
        await txn.insert('proformas', {
          'id': proforma.id,
          'reference_number': reference,
          'customer_id': proforma.customerId,
          'proforma_date': proforma.proformaDate.toIso8601String(),
          'subtotal': proforma.subtotal,
          'total': proforma.total,
          'status': proforma.status.name,
          'notes': proforma.notes,
          'created_by': actor.username,
          'created_at': now,
          'updated_at': now,
        });
        await _insertProformaLines(txn, proforma);
        await _audit(txn, ActivityType.proformaCreated, 'proformaCreated',
            proforma.id, reference, actor);
      });
      return const Right(unit);
    } catch (e) {
      return Left(_failure(e, 'Unable to create proforma'));
    }
  }

  Future<Either<Failure, List<Order>>> getOrders({
    String? search,
    OrderStatus? status,
    DateTime? from,
    DateTime? to,
  }) async {
    try {
      final filter = _documentFilter(
        search: search,
        status: status?.name,
        from: from,
        to: to,
        dateColumn: 'order_date',
      );
      final rows = await _db.query(
        'orders',
        where: filter.where,
        whereArgs: filter.args,
        orderBy: 'order_date DESC',
      );
      return Right(await Future.wait(rows.map(_readOrder)));
    } catch (e) {
      return Left(_failure(e, 'Unable to load orders'));
    }
  }

  Future<Either<Failure, List<Proforma>>> getProformas({
    String? search,
    ProformaStatus? status,
    DateTime? from,
    DateTime? to,
  }) async {
    try {
      final filter = _documentFilter(
        search: search,
        status: status?.name,
        from: from,
        to: to,
        dateColumn: 'proforma_date',
      );
      final rows = await _db.query(
        'proformas',
        where: filter.where,
        whereArgs: filter.args,
        orderBy: 'proforma_date DESC',
      );
      return Right(await Future.wait(rows.map(_readProforma)));
    } catch (e) {
      return Left(_failure(e, 'Unable to load proformas'));
    }
  }

  Future<Either<Failure, Order?>> getOrderById(String id) async {
    try {
      final rows = await _db.query('orders', where: 'id = ?', whereArgs: [id]);
      return Right(rows.isEmpty ? null : await _readOrder(rows.first));
    } catch (e) {
      return Left(_failure(e, 'Unable to load order'));
    }
  }

  Future<Either<Failure, Proforma?>> getProformaById(String id) async {
    try {
      final rows =
          await _db.query('proformas', where: 'id = ?', whereArgs: [id]);
      return Right(rows.isEmpty ? null : await _readProforma(rows.first));
    } catch (e) {
      return Left(_failure(e, 'Unable to load proforma'));
    }
  }

  Future<Either<Failure, List<Order>>> searchOrders(
    String query, {
    OrderStatus? status,
    DateTime? from,
    DateTime? to,
  }) =>
      getOrders(search: query, status: status, from: from, to: to);

  Future<Either<Failure, List<Proforma>>> searchProformas(
    String query, {
    ProformaStatus? status,
    DateTime? from,
    DateTime? to,
  }) =>
      getProformas(search: query, status: status, from: from, to: to);

  Future<Either<Failure, Unit>> updateOrderDraft(
      Order order, User actor) async {
    return _updateOrderDraft(order, actor);
  }

  Future<Either<Failure, Unit>> updateProformaDraft(
      Proforma proforma, User actor) async {
    return _updateProformaDraft(proforma, actor);
  }

  Future<Either<Failure, Unit>> _updateOrderDraft(
      Order order, User actor) async {
    try {
      PermissionGuard.requireOrdersAndProformasAccess(actor);
      final validation = validateLines<OrderLine>(
          order.lines,
          (line) => line.quantity,
          (line) => line.unitPrice,
          (line) => line.lineTotal);
      if (validation != null) return Left(ValidationFailure(validation));
      if (order.id.trim().isEmpty || order.referenceNumber.trim().isEmpty) {
        return const Left(
            ValidationFailure('Order id and reference are required.'));
      }
      await _validateCustomer(order.customerId);
      await _db.transaction((txn) async {
        final existing = await _one(txn, 'orders', order.id);
        if (existing == null || existing['status'] != OrderStatus.draft.name) {
          throw StateError('Only draft orders can be edited.');
        }
        final duplicate = await txn.query(
          'orders',
          columns: ['id'],
          where: 'reference_number = ? AND id <> ?',
          whereArgs: [order.referenceNumber, order.id],
          limit: 1,
        );
        if (duplicate.isNotEmpty) {
          throw StateError('Order reference must be unique.');
        }
        final changed = await txn.update(
          'orders',
          {
            'reference_number': order.referenceNumber,
            'customer_id': order.customerId,
            'order_date': order.orderDate.toIso8601String(),
            'subtotal': order.subtotal,
            'total': order.total,
            'notes': order.notes,
            'updated_at': DateTime.now().toIso8601String(),
          },
          where: 'id = ? AND status = ?',
          whereArgs: [order.id, OrderStatus.draft.name],
        );
        if (changed != 1) throw StateError('Only draft orders can be edited.');
        await txn.delete('order_items',
            where: 'order_id = ?', whereArgs: [order.id]);
        await _insertOrderLines(txn, order);
      });
      return const Right(unit);
    } catch (e) {
      return Left(_failure(e, 'Unable to update order'));
    }
  }

  Future<Either<Failure, Unit>> _updateProformaDraft(
      Proforma proforma, User actor) async {
    try {
      PermissionGuard.requireOrdersAndProformasAccess(actor);
      final validation = validateLines<ProformaLine>(
          proforma.lines,
          (line) => line.quantity,
          (line) => line.unitPrice,
          (line) => line.lineTotal);
      if (validation != null) return Left(ValidationFailure(validation));
      if (proforma.id.trim().isEmpty ||
          proforma.referenceNumber.trim().isEmpty) {
        return const Left(
            ValidationFailure('Proforma id and reference are required.'));
      }
      await _validateCustomer(proforma.customerId);
      await _db.transaction((txn) async {
        final existing = await _one(txn, 'proformas', proforma.id);
        if (existing == null ||
            existing['status'] != ProformaStatus.draft.name) {
          throw StateError('Only draft proformas can be edited.');
        }
        final duplicate = await txn.query(
          'proformas',
          columns: ['id'],
          where: 'reference_number = ? AND id <> ?',
          whereArgs: [proforma.referenceNumber, proforma.id],
          limit: 1,
        );
        if (duplicate.isNotEmpty) {
          throw StateError('Proforma reference must be unique.');
        }
        final changed = await txn.update(
          'proformas',
          {
            'reference_number': proforma.referenceNumber,
            'customer_id': proforma.customerId,
            'proforma_date': proforma.proformaDate.toIso8601String(),
            'subtotal': proforma.subtotal,
            'total': proforma.total,
            'notes': proforma.notes,
            'updated_at': DateTime.now().toIso8601String(),
          },
          where: 'id = ? AND status = ?',
          whereArgs: [proforma.id, ProformaStatus.draft.name],
        );
        if (changed != 1) {
          throw StateError('Only draft proformas can be edited.');
        }
        await txn.delete('proforma_items',
            where: 'proforma_id = ?', whereArgs: [proforma.id]);
        await _insertProformaLines(txn, proforma);
      });
      return const Right(unit);
    } catch (e) {
      return Left(_failure(e, 'Unable to update proforma'));
    }
  }

  Future<Either<Failure, Unit>> confirmOrder(String id, User actor) =>
      _transitionOrder(id, OrderStatus.confirmed, actor);

  Future<Either<Failure, Unit>> cancelOrder(String id, User actor) =>
      _transitionOrder(id, OrderStatus.cancelled, actor);

  Future<Either<Failure, Unit>> confirmProforma(String id, User actor) =>
      _transitionProforma(id, ProformaStatus.confirmed, actor);

  Future<Either<Failure, Unit>> cancelProforma(String id, User actor) =>
      _transitionProforma(id, ProformaStatus.cancelled, actor);

  Future<Either<Failure, Sale>> convertOrder(String id, User actor) =>
      _convert(kind: 'order', id: id, actor: actor);

  Future<Either<Failure, Sale>> convertProforma(String id, User actor) =>
      _convert(kind: 'proforma', id: id, actor: actor);

  Future<Either<Failure, Unit>> _transitionOrder(
      String id, OrderStatus next, User actor) async {
    try {
      PermissionGuard.requireOrdersAndProformasAccess(actor);
      await _db.transaction((txn) async {
        final row = await _one(txn, 'orders', id);
        if (row == null || !canTransition(row['status'] as String, next.name)) {
          throw StateError('Invalid order status transition.');
        }
        await txn.update(
            'orders',
            {
              'status': next.name,
              'updated_at': DateTime.now().toIso8601String()
            },
            where: 'id = ? AND status = ?',
            whereArgs: [id, row['status']]);
        await _audit(
            txn,
            next == OrderStatus.confirmed
                ? ActivityType.orderConfirmed
                : ActivityType.orderCancelled,
            'order${next.name[0].toUpperCase()}${next.name.substring(1)}',
            id,
            row['reference_number'] as String,
            actor);
      });
      return const Right(unit);
    } catch (e) {
      return Left(_failure(e, 'Unable to change order status'));
    }
  }

  Future<Either<Failure, Unit>> _transitionProforma(
      String id, ProformaStatus next, User actor) async {
    try {
      PermissionGuard.requireOrdersAndProformasAccess(actor);
      await _db.transaction((txn) async {
        final row = await _one(txn, 'proformas', id);
        if (row == null || !canTransition(row['status'] as String, next.name)) {
          throw StateError('Invalid proforma status transition.');
        }
        await txn.update(
            'proformas',
            {
              'status': next.name,
              'updated_at': DateTime.now().toIso8601String()
            },
            where: 'id = ? AND status = ?',
            whereArgs: [id, row['status']]);
        await _audit(
            txn,
            next == ProformaStatus.confirmed
                ? ActivityType.proformaConfirmed
                : ActivityType.proformaCancelled,
            'proforma${next.name[0].toUpperCase()}${next.name.substring(1)}',
            id,
            row['reference_number'] as String,
            actor);
      });
      return const Right(unit);
    } catch (e) {
      return Left(_failure(e, 'Unable to change proforma status'));
    }
  }

  Future<Either<Failure, Sale>> _convert({
    required String kind,
    required String id,
    required User actor,
  }) async {
    try {
      PermissionGuard.requireOrdersAndProformasAccess(actor);
      if (_authorityContext.writesToServer) {
        throw StateError(
          'Order and proforma conversion requires a server API in server-authoritative mode.',
        );
      }
      late Sale sale;
      await _db.transaction((txn) async {
        final table = kind == 'order' ? 'orders' : 'proformas';
        final itemTable = kind == 'order' ? 'order_items' : 'proforma_items';
        final parentKey = kind == 'order' ? 'order_id' : 'proforma_id';
        final row = await _one(txn, table, id);
        if (row == null || row['status'] != 'confirmed') {
          throw StateError('Only a confirmed $kind can be converted.');
        }
        if (row['converted_sale_id'] != null) {
          throw StateError('$kind has already been converted.');
        }
        final itemRows = await txn
            .query(itemTable, where: '$parentKey = ?', whereArgs: [id]);
        if (itemRows.isEmpty) {
          throw StateError('Cannot convert an empty $kind.');
        }
        sale = Sale(
          id: 'sale_${kind}_$id',
          total: (row['total'] as num).toDouble(),
          items: itemRows.length,
          date: DateTime.now(),
          cashierName: actor.name,
          cashierUsername: actor.username,
          customerId: row['customer_id'] as String?,
          saleItems: itemRows
              .map((item) => SaleItem(
                    productId: item['product_id'] as String,
                    name: item['product_name'] as String,
                    price: (item['unit_price'] as num).toDouble(),
                    quantity: (item['quantity'] as num).toDouble(),
                    total: (item['line_total'] as num).toDouble(),
                    wholesalePrice: (item['wholesale_price'] as num).toDouble(),
                  ))
              .toList(),
        );
        await _salesRepository.insertSaleInTransaction(txn, sale);
        await _failureInjector?.call(txn);
        final changed = await txn.update(
          table,
          {
            'status': 'converted',
            'converted_sale_id': sale.id,
            'updated_at': DateTime.now().toIso8601String(),
          },
          where: 'id = ? AND status = ? AND converted_sale_id IS NULL',
          whereArgs: [id, 'confirmed'],
        );
        if (changed != 1) throw StateError('$kind has already been converted.');
        await _audit(
            txn,
            kind == 'order'
                ? ActivityType.orderConverted
                : ActivityType.proformaConverted,
            '${kind}Converted',
            id,
            row['reference_number'] as String,
            actor,
            details: {'saleId': sale.id});
      });
      return Right(sale);
    } catch (e) {
      return Left(_failure(e, 'Unable to convert $kind'));
    }
  }

  Future<void> _validateCustomer(String? customerId) async {
    if (customerId == null || customerId.trim().isEmpty) {
      throw StateError('A customer is required.');
    }
    final rows = await _db.query('customers',
        columns: ['id'],
        where: 'id = ? AND is_active = 1',
        whereArgs: [customerId]);
    if (rows.isEmpty) throw StateError('Customer $customerId was not found.');
  }

  Future<void> _insertOrderLines(DatabaseExecutor txn, Order order) async {
    for (var i = 0; i < order.lines.length; i++) {
      final line = order.lines[i];
      await txn.insert('order_items', {
        'id': '${order.id}_$i',
        'order_id': order.id,
        'product_id': line.productId,
        'product_barcode': line.productBarcode,
        'product_name': line.productName,
        'quantity': line.quantity,
        'unit_price': line.unitPrice,
        'wholesale_price': line.wholesalePrice,
        'line_total': line.lineTotal,
      });
    }
  }

  Future<void> _insertProformaLines(
      DatabaseExecutor txn, Proforma proforma) async {
    for (var i = 0; i < proforma.lines.length; i++) {
      final line = proforma.lines[i];
      await txn.insert('proforma_items', {
        'id': '${proforma.id}_$i',
        'proforma_id': proforma.id,
        'product_id': line.productId,
        'product_barcode': line.productBarcode,
        'product_name': line.productName,
        'quantity': line.quantity,
        'unit_price': line.unitPrice,
        'wholesale_price': line.wholesalePrice,
        'line_total': line.lineTotal,
      });
    }
  }

  Future<Order> _readOrder(Map<String, dynamic> row) async {
    final items = await _db
        .query('order_items', where: 'order_id = ?', whereArgs: [row['id']]);
    return Order(
      id: row['id'] as String,
      referenceNumber: row['reference_number'] as String,
      customerId: row['customer_id'] as String?,
      orderDate: DateTime.parse(row['order_date'] as String),
      status: orderStatusFromName(row['status'] as String?),
      notes: row['notes'] as String?,
      createdBy: row['created_by'] as String?,
      convertedSaleId: row['converted_sale_id'] as String?,
      lines: items
          .map((item) => OrderLine(
                productId: item['product_id'] as String,
                productName: item['product_name'] as String,
                productBarcode: item['product_barcode'] as String? ?? '',
                quantity: (item['quantity'] as num).toDouble(),
                unitPrice: (item['unit_price'] as num).toDouble(),
                wholesalePrice: (item['wholesale_price'] as num).toDouble(),
              ))
          .toList(),
    );
  }

  Future<Proforma> _readProforma(Map<String, dynamic> row) async {
    final items = await _db.query('proforma_items',
        where: 'proforma_id = ?', whereArgs: [row['id']]);
    return Proforma(
      id: row['id'] as String,
      referenceNumber: row['reference_number'] as String,
      customerId: row['customer_id'] as String?,
      proformaDate: DateTime.parse(row['proforma_date'] as String),
      status: proformaStatusFromName(row['status'] as String?),
      notes: row['notes'] as String?,
      createdBy: row['created_by'] as String?,
      convertedSaleId: row['converted_sale_id'] as String?,
      lines: items
          .map((item) => ProformaLine(
                productId: item['product_id'] as String,
                productName: item['product_name'] as String,
                productBarcode: item['product_barcode'] as String? ?? '',
                quantity: (item['quantity'] as num).toDouble(),
                unitPrice: (item['unit_price'] as num).toDouble(),
                wholesalePrice: (item['wholesale_price'] as num).toDouble(),
              ))
          .toList(),
    );
  }

  Future<Map<String, dynamic>?> _one(
      DatabaseExecutor txn, String table, String id) async {
    final rows =
        await txn.query(table, where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : rows.first;
  }

  Future<void> _audit(DatabaseExecutor txn, ActivityType type, String eventKey,
      String id, String reference, User actor,
      {Map<String, dynamic>? details}) async {
    await txn.insert('activity_logs', {
      'id': 'activity_${eventKey}_$id',
      'session_id': '',
      'timestamp': DateTime.now().toIso8601String(),
      'type': type.name,
      'description': '$eventKey: $reference',
      'user_name': actor.name,
      'details': jsonEncode({'id': id, 'reference': reference, ...?details}),
      'event_key': eventKey,
      'parameters': jsonEncode({'user': actor.name, 'id': id}),
    });
  }

  Failure _failure(Object error, String prefix) {
    if (error is PermissionDeniedException) {
      return AuthorizationFailure(error.message);
    }
    if (error is StateError || error is FormatException) {
      return ValidationFailure('$prefix: $error');
    }
    return CacheFailure('$prefix: $error');
  }

  _DocumentFilter _documentFilter({
    String? search,
    String? status,
    DateTime? from,
    DateTime? to,
    required String dateColumn,
  }) {
    final clauses = <String>[];
    final args = <Object?>[];
    final cleaned = search?.trim() ?? '';
    if (cleaned.isNotEmpty) {
      final pattern = '%$cleaned%';
      clauses.add('(reference_number LIKE ? OR customer_id IN '
          '(SELECT id FROM customers WHERE name LIKE ? OR code LIKE ?))');
      args.addAll([pattern, pattern, pattern]);
    }
    if (status != null) {
      clauses.add('status = ?');
      args.add(status);
    }
    if (from != null) {
      clauses.add('$dateColumn >= ?');
      args.add(from.toIso8601String());
    }
    if (to != null) {
      clauses.add('$dateColumn <= ?');
      args.add(to.toIso8601String());
    }
    return _DocumentFilter(
      where: clauses.isEmpty ? null : clauses.join(' AND '),
      args: args,
    );
  }
}

class _DocumentFilter {
  const _DocumentFilter({required this.where, required this.args});

  final String? where;
  final List<Object?> args;
}
