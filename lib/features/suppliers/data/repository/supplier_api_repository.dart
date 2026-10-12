import 'package:dartz/dartz.dart';

import '../../../../core/error/failure.dart';
import '../../../../core/network/backend_api_client.dart';

import '../../../../core/network/authority_context.dart';
import '../models/supplier_model.dart';
import 'supplier_repository_impl.dart';

SupplierRepository supplierRepositoryForAuthority({
  required AuthorityContext authorityContext,
  required BackendApiClient client,
}) =>
    authorityContext.writesToServer
        ? SupplierApiRepository(client)
        : SupplierRepositoryImpl();

class SupplierApiRepository implements SupplierRepository {
  SupplierApiRepository(this.client);

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

  Map<String, dynamic> _supplierPayload(Supplier supplier,
      {required bool create}) {
    return {
      if (create) 'id': supplier.id,
      if (create) 'code': supplier.code,
      'name': supplier.name,
      'registration_name': supplier.registrationName,
      'activity': supplier.activity,
      'address': supplier.address,
      'phone': supplier.phone,
      'mobile': supplier.mobile,
      'email': supplier.email,
      'tax_number': supplier.taxNumber,
      'registration_number': supplier.registrationNumber,
      'supplier_reference': supplier.supplierReference,
      'contact_person': supplier.contactPerson,
      'commercial_register': supplier.commercialRegister,
      'tax_id': supplier.taxId,
      'nis': supplier.nis,
      'ai': supplier.ai,
      'bank_name': supplier.bankName,
      'bank_account': supplier.bankAccount,
      'currency': supplier.currency,
      'credit_limit': supplier.creditLimit,
      if (create) 'opening_balance': supplier.openingBalance,
      'notes': supplier.notes,
      'is_active': supplier.isActive,
    };
  }

  @override
  Future<Either<Failure, List<Supplier>>> getAllSuppliers() async {
    try {
      return Right(_parseSuppliers(await client.getSuppliers()));
    } on BackendApiException catch (error) {
      return Left(_failure(error));
    } catch (error) {
      return Left(ServerFailure(error.toString()));
    }
  }

  @override
  Future<Either<Failure, List<Supplier>>> searchSuppliers(
    String query, {
    int limit = 50,
  }) async {
    try {
      final suppliers = _parseSuppliers(
        await client.getSuppliers(search: query),
      );
      return Right(suppliers.take(limit).toList(growable: false));
    } on BackendApiException catch (error) {
      return Left(_failure(error));
    } catch (error) {
      return Left(ServerFailure(error.toString()));
    }
  }

  List<Supplier> _parseSuppliers(Map<String, dynamic> payload) {
    final rawItems = payload['items'];
    if (rawItems is! List) {
      throw const FormatException('Backend returned an invalid supplier list');
    }
    return rawItems
        .whereType<Map>()
        .map((item) => Supplier.fromMap(Map<String, dynamic>.from(item)))
        .toList(growable: false);
  }

  @override
  Future<Either<Failure, Supplier?>> getSupplierById(String supplierId) async {
    try {
      return Right(Supplier.fromMap(await client.getSupplier(supplierId)));
    } on BackendApiException catch (error) {
      if (error.statusCode == 404) return const Right(null);
      return Left(_failure(error));
    } catch (error) {
      return Left(ServerFailure(error.toString()));
    }
  }

  @override
  Future<Either<Failure, Unit>> createSupplier(Supplier supplier) async {
    try {
      await client.createSupplier(_supplierPayload(supplier, create: true));
      return const Right(unit);
    } on BackendApiException catch (error) {
      return Left(_failure(error));
    } catch (error) {
      return Left(ServerFailure(error.toString()));
    }
  }

  @override
  Future<Either<Failure, Unit>> updateSupplier(Supplier supplier) async {
    try {
      await client.updateSupplier(
        supplier.id,
        _supplierPayload(supplier, create: false),
      );
      return const Right(unit);
    } on BackendApiException catch (error) {
      return Left(_failure(error));
    } catch (error) {
      return Left(ServerFailure(error.toString()));
    }
  }

  @override
  Future<Either<Failure, Unit>> deleteSupplier(String supplierId) async {
    try {
      await client.deleteSupplier(supplierId);
      return const Right(unit);
    } on BackendApiException catch (error) {
      return Left(_failure(error));
    } catch (error) {
      return Left(ServerFailure(error.toString()));
    }
  }

  @override
  Future<Either<Failure, double>> getSupplierBalance(String supplierId) async {
    try {
      final value = (await client.getSupplierBalance(supplierId))['balance'];
      return Right(_number(value));
    } on BackendApiException catch (error) {
      return Left(_failure(error));
    } catch (error) {
      return Left(ServerFailure(error.toString()));
    }
  }

  @override
  Future<Either<Failure, List<Map<String, dynamic>>>> getSupplierLedger(
    String supplierId,
  ) async {
    try {
      final rows = await client.getSupplierLedger(supplierId);
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

  double _number(Object? value) => value is num
      ? value.toDouble()
      : double.tryParse(value?.toString() ?? '') ?? 0.0;
}
