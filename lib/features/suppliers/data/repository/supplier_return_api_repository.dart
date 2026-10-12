import 'package:dartz/dartz.dart';

import '../../../../core/error/failure.dart';
import '../../../../core/network/authority_context.dart';
import '../../../../core/network/backend_api_client.dart';
import '../models/supplier_return_model.dart';
import 'supplier_return_repository_impl.dart';

SupplierReturnRepository supplierReturnRepositoryForAuthority({
  required AuthorityContext authorityContext,
  required BackendApiClient client,
}) =>
    authorityContext.writesToServer
        ? SupplierReturnApiRepository(client)
        : SupplierReturnRepositoryImpl();

class SupplierReturnApiRepository implements SupplierReturnRepository {
  SupplierReturnApiRepository(this.client);

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
  Future<Either<Failure, Unit>> createReturn(SupplierReturn value) async {
    try {
      await client.postSupplierReturn(
        value.supplierId,
        {
          'reference': value.reference,
          'purchase_id': value.purchaseId,
          'return_date': value.returnDate.toIso8601String(),
          'notes': value.notes,
          'lines': value.lines
              .map((line) => {
                    'purchase_item_id': line.purchaseItemId,
                    'product_id': line.productId,
                    'quantity': line.quantity,
                  })
              .toList(growable: false),
        },
        idempotencyKey: value.id,
      );
      return const Right(unit);
    } on BackendApiException catch (error) {
      return Left(_failure(error));
    } on FormatException catch (error) {
      return Left(ServerFailure(error.message));
    } catch (error) {
      return Left(ServerFailure(error.toString()));
    }
  }

  @override
  Future<Either<Failure, List<Map<String, dynamic>>>>
      getReturnHistory() async => const Left(
            ValidationFailure(
                'Supplier return history is not available from the server.'),
          );

  @override
  Future<Either<Failure, List<Map<String, dynamic>>>> getPurchasesForSupplier(
    String supplierId,
  ) async {
    try {
      final purchases = <Map<String, dynamic>>[];
      var page = 1;
      while (true) {
        final response = await client.getPurchases(page: page, pageSize: 200);
        final items = response['items'];
        if (items is! List) {
          throw const FormatException(
            'Backend returned an invalid purchase list',
          );
        }
        final pageItems = items
            .whereType<Map>()
            .map((item) => Map<String, dynamic>.from(item))
            .toList(growable: false);
        purchases.addAll(
          pageItems.where((purchase) => purchase['supplier_id'] == supplierId),
        );
        if (pageItems.length < 200) break;
        page++;
      }
      return Right(purchases);
    } on BackendApiException catch (error) {
      return Left(_failure(error));
    } on FormatException catch (error) {
      return Left(ServerFailure(error.message));
    } catch (error) {
      return Left(ServerFailure(error.toString()));
    }
  }

  @override
  Future<Either<Failure, List<Map<String, dynamic>>>> getPurchaseItems(
    String purchaseId,
  ) async {
    try {
      final items = (await client.getPurchase(purchaseId))['items'];
      if (items is! List) {
        throw const FormatException(
          'Backend returned invalid source purchase items',
        );
      }
      return Right(
        items
            .whereType<Map>()
            .map((item) => Map<String, dynamic>.from(item))
            .toList(growable: false),
      );
    } on BackendApiException catch (error) {
      return Left(_failure(error));
    } on FormatException catch (error) {
      return Left(ServerFailure(error.message));
    } catch (error) {
      return Left(ServerFailure(error.toString()));
    }
  }
}
