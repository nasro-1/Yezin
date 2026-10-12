import 'package:dartz/dartz.dart';

import '../../../../core/error/failure.dart';
import '../../../../core/network/authority_context.dart';
import '../../../../core/network/backend_api_client.dart';
import '../models/supplier_payment_model.dart';
import 'supplier_payment_repository_impl.dart';

SupplierPaymentRepository supplierPaymentRepositoryForAuthority({
  required AuthorityContext authorityContext,
  required BackendApiClient client,
}) =>
    authorityContext.writesToServer
        ? SupplierPaymentApiRepository(client)
        : SupplierPaymentRepositoryImpl();

class SupplierPaymentApiRepository implements SupplierPaymentRepository {
  SupplierPaymentApiRepository(this.client);

  final BackendApiClient client;

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

  @override
  Future<Either<Failure, Unit>> createPayment(SupplierPayment payment) async {
    try {
      await client.postSupplierPayment(
        payment.supplierId,
        {
          'amount': payment.amount,
          'payment_date': payment.paymentDate.toIso8601String(),
          'payment_method': payment.paymentMethod,
          'reference': payment.reference,
          'notes': payment.notes,
        },
        idempotencyKey: payment.id,
      );
      return const Right(unit);
    } on BackendApiException catch (error) {
      return Left(_failure(error));
    } catch (error) {
      return Left(ServerFailure(error.toString()));
    }
  }

  @override
  Future<Either<Failure, List<Map<String, dynamic>>>> getPaymentHistory({
    String? supplierId,
  }) async {
    try {
      final ids =
          supplierId == null ? await _supplierIds() : <String>[supplierId];
      final payments = <Map<String, dynamic>>[];
      for (final id in ids) {
        final entries = await client.getSupplierLedger(id);
        payments.addAll(
          entries
              .whereType<Map>()
              .map(Map<String, dynamic>.from)
              .where(
                (entry) => entry['entry_type'] == 'supplier_payment',
              )
              .map(
                (entry) => {
                  ...entry,
                  'payment_id': entry['reference_id'],
                  'amount': _number(entry['amount']).abs(),
                  'payment_date': entry['created_at'],
                  'payment_method': 'cash',
                  'reference': entry['reference_id'],
                  'status': 'confirmed',
                },
              ),
        );
      }
      payments.sort((left, right) => right['payment_date']
          .toString()
          .compareTo(left['payment_date'].toString()));
      return Right(payments);
    } on BackendApiException catch (error) {
      return Left(_failure(error));
    } catch (error) {
      return Left(ServerFailure(error.toString()));
    }
  }

  Future<List<String>> _supplierIds() async {
    final response = await client.getSuppliers();
    final rawItems = response['items'];
    if (rawItems is! List) {
      throw const FormatException('Backend returned an invalid supplier list');
    }
    return rawItems
        .whereType<Map>()
        .map((item) => item['id'])
        .whereType<String>()
        .toList(growable: false);
  }

  double _number(Object? value) => value is num
      ? value.toDouble()
      : double.tryParse(value?.toString() ?? '') ?? 0.0;
}
