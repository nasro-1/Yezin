import 'package:dartz/dartz.dart' show Either, Unit;

import '../../../core/error/failure.dart';
import '../../auth/data/models/user_model.dart';
import '../../sales/data/models/sale_model.dart';
import '../data/models/order_model.dart';
import '../data/models/proforma_model.dart';
import '../data/repository/orders_proformas_repository.dart';

/// Business-layer facade. UI code must provide the authenticated actor so
/// authorization cannot be bypassed by calling a repository directly.
class OrderProformaService {
  const OrderProformaService(this.repository);

  final OrdersProformasRepository repository;

  Future<Either<Failure, Unit>> createOrder(Order order, User actor) =>
      repository.createOrder(order, actor);
  Future<Either<Failure, Unit>> confirmOrder(String id, User actor) =>
      repository.confirmOrder(id, actor);
  Future<Either<Failure, Unit>> cancelOrder(String id, User actor) =>
      repository.cancelOrder(id, actor);
  Future<Either<Failure, Sale>> convertOrder(String id, User actor) =>
      repository.convertOrder(id, actor);

  Future<Either<Failure, Unit>> createProforma(Proforma proforma, User actor) =>
      repository.createProforma(proforma, actor);
  Future<Either<Failure, Unit>> confirmProforma(String id, User actor) =>
      repository.confirmProforma(id, actor);
  Future<Either<Failure, Unit>> cancelProforma(String id, User actor) =>
      repository.cancelProforma(id, actor);
  Future<Either<Failure, Sale>> convertProforma(String id, User actor) =>
      repository.convertProforma(id, actor);
}
