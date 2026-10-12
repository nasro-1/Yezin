import 'package:dartz/dartz.dart';

import '../../../../core/error/failure.dart';
import '../../../../core/network/backend_api_client.dart';

import '../../../../core/network/authority_context.dart';
import '../models/purchase_model.dart';
import 'purchase_repository_impl.dart';

PurchaseRepository purchaseRepositoryForAuthority({
  required AuthorityContext authorityContext,
  required BackendApiClient client,
}) =>
    authorityContext.writesToServer
        ? PurchaseApiRepository(client)
        : PurchaseRepositoryImpl(authorityContext: authorityContext);

class PurchaseApiRepository implements PurchaseRepository {
  PurchaseApiRepository(this.client);

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

  Map<String, dynamic> _purchasePayload(Purchase purchase) => {
        'reference': purchase.referenceNumber,
        'supplier_id': purchase.supplierId,
        'purchase_date': purchase.purchaseDate.toIso8601String(),
        'notes': purchase.notes,
        'lines': purchase.lines
            .map(
              (line) => {
                'product_id': line.productId,
                'quantity': line.quantity,
                'unit_cost': line.unitCost,
                if (line.sellingUnitId != null)
                  'selling_unit_id': line.sellingUnitId,
              },
            )
            .toList(growable: false),
      };

  @override
  Future<Either<Failure, Unit>> createPurchase(Purchase purchase) async {
    try {
      await client.postPurchase(
        _purchasePayload(purchase),
        idempotencyKey: purchase.id,
      );
      return const Right(unit);
    } on BackendApiException catch (error) {
      return Left(_failure(error));
    } catch (error) {
      return Left(ServerFailure(error.toString()));
    }
  }

  @override
  Future<Either<Failure, List<Map<String, dynamic>>>> getPurchases() async {
    try {
      final all = <Map<String, dynamic>>[];
      var page = 1;
      int total;
      do {
        final response = await client.getPurchases(page: page, pageSize: 200);
        final items = response['items'];
        final resultTotal = response['total'];
        if (items is! List || resultTotal is! num) {
          throw const FormatException(
              'Backend returned an invalid purchase list');
        }
        all.addAll(items
            .whereType<Map>()
            .map((item) => Map<String, dynamic>.from(item)));
        total = resultTotal.toInt();
        page++;
      } while (all.length < total);
      return Right(all);
    } on BackendApiException catch (error) {
      return Left(_failure(error));
    } catch (error) {
      return Left(ServerFailure(error.toString()));
    }
  }

  @override
  Future<Either<Failure, List<Map<String, dynamic>>>> getProductPurchaseHistory(
    String productId,
  ) async {
    try {
      final rows = await client.getProductPurchaseHistory(productId);
      return Right(rows
          .whereType<Map>()
          .map((row) => Map<String, dynamic>.from(row))
          .toList(growable: false));
    } on BackendApiException catch (error) {
      return Left(_failure(error));
    } catch (error) {
      return Left(ServerFailure(error.toString()));
    }
  }

  @override
  Future<Either<Failure, Map<String, dynamic>?>> getLatestProductPurchaseCost(
    String productId,
  ) async {
    final result = await getProductPurchaseHistory(productId);
    return result.fold(
      (failure) async => Left(failure),
      (rows) async {
        if (rows.isNotEmpty) return Right(rows.first);
        try {
          final product = await client.getProduct(productId);
          return Right({'unit_cost': product['cost']});
        } on BackendApiException catch (error) {
          return Left(_failure(error));
        } catch (error) {
          return Left(ServerFailure(error.toString()));
        }
      },
    );
  }
}
