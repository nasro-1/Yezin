import 'package:bayaa_pos/features/products/data/models/product_model.dart';
import 'package:bayaa_pos/features/products/data/models/selling_unit_model.dart';
import 'package:either_dart/either.dart';

import '../../../core/error/failure.dart';
import '../../auth/data/models/user_model.dart';

abstract class ProductRepositoryInt {
  Future<Either<Failure, List<Product>>> getAllProduct();
  Future<Either<Failure, List<Product>>> getProductsPaginated({
    required int page,
    required int pageSize,
    String? category,
    String? availability,
    String? searchQuery,
  });
  Future<Either<Failure, void>> saveProduct(
    Product product, {
    List<SellingUnit>? packagedSellingUnits,
  });
  Future<Either<Failure, void>> saveProductWithOpeningStock(
    Product product, {
    required double openingQuantity,
    required double openingUnitCost,
    required String openingReason,
    String openingNotes = '',
    required User user,
    List<SellingUnit>? packagedSellingUnits,
    String? openingUnit,
    List<OpeningStockLine>? openingLines,
  });
  Future<Either<Failure, void>> deleteProduct(String productId);
  Future<Either<Failure, List<String>>> getAllCategory();
  Future<Either<Failure, Map<String, String>>> getServerCategories();
  Future<Either<Failure, Map<String, String>>> getCategoryNamesById();
  Future<Either<Failure, String>> resolveCategoryId(String categoryName);
  Future<Either<Failure, void>> saveCategory(String category);
  Future<Either<Failure, void>> deleteCategory(
      {required String category,
      bool forceDelete = false,
      String? newCategory});
  Future<Either<Failure, bool>> productExists(String barcode);
  Future<Either<Failure, Product?>> findProductByBarcode(String barcode) =>
      Future.value(
        const Left(CacheFailure('Barcode lookup is unavailable')),
      );
}
