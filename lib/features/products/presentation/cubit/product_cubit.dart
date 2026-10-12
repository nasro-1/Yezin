import 'dart:async';
import 'package:either_dart/either.dart';
import 'package:flutter/foundation.dart';
import 'package:bayaa_pos/core/error/failure.dart';
import 'package:bayaa_pos/features/products/data/models/product_model.dart';
import 'package:bayaa_pos/features/products/data/models/selling_unit_model.dart';
import 'package:bayaa_pos/features/products/domain/product_repository_int.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/di/dependency_injection.dart';
import '../../../../core/network/backend_api_config.dart';
import '../../../../core/services/activity_logger.dart';
import '../../../../core/data/models/activity_log.dart';
import '../../../auth/presentation/cubit/user_cubit.dart';
import '../../../../core/session/session_manager.dart';
import '../../../auth/data/models/user_model.dart';

import 'product_states.dart';

class ProductCubit extends Cubit<ProductStates> {
  StreamSubscription? _activitySubscription;
  final Map<String, String> serverCategoryIds = {};
  Map<String, String> categoryNamesById = {};
  bool _categoryNamesLoaded = false;
  Future<Either<Failure, Map<String, String>>>? _categoryNamesLoad;

  ProductCubit({required this.productRepositoryInt})
      : super(ProductInitialState()) {
    if (kDebugMode) {
      debugPrint(
        '[ProductCubit] repository=${productRepositoryInt.runtimeType}',
      );
    }
    _activitySubscription =
        getIt<ActivityLogger>().activitiesStream.listen((activities) {
      if (activities.isNotEmpty) {
        final type = activities.first.type;
        // Refresh product list (quantities) on sales/refunds/restocking
        if (type == ActivityType.sale ||
            type == ActivityType.refund ||
            type == ActivityType.restock ||
            type == ActivityType.productQuantityUpdate ||
            type == ActivityType.stockAdjustment) {
          // Only reload if we have products loaded, to avoid unnecessary calls?
          // Actually, usually we want to keep UI in sync.
          getAllProducts();
        }
      }
    });
  }

  @override
  Future<void> close() {
    _activitySubscription?.cancel();
    return super.close();
  }

  static ProductCubit get(context) => BlocProvider.of(context);
  ProductRepositoryInt productRepositoryInt;
  List<Product> products = [];
  List<Product> get allProducts => products;
  List<String> categories = [];
  String selectedCategory = '*';
  String selectedAvailability = '*';

  String currentSearchQuery = '';

  Future<Either<Failure, Map<String, String>>> _loadCategoryNames({
    bool refresh = false,
  }) async {
    if (_categoryNamesLoaded && !refresh) {
      return Right(Map.unmodifiable(categoryNamesById));
    }
    if (refresh) {
      _categoryNamesLoaded = false;
      categoryNamesById = {};
      serverCategoryIds.clear();
    }
    final inFlight = _categoryNamesLoad;
    if (inFlight != null) return inFlight;

    final load = productRepositoryInt.getCategoryNamesById();
    _categoryNamesLoad = load;
    try {
      final result = await load;
      result.fold(
        (_) {
          _categoryNamesLoaded = false;
          categoryNamesById = {};
          serverCategoryIds.clear();
        },
        (namesById) {
          categoryNamesById = Map<String, String>.unmodifiable(namesById);
          _categoryNamesLoaded = true;
          serverCategoryIds
            ..clear()
            ..addAll({
              for (final entry in namesById.entries) entry.value: entry.key,
            });
        },
      );
      return result;
    } finally {
      if (identical(_categoryNamesLoad, load)) {
        _categoryNamesLoad = null;
      }
    }
  }

  List<Product> _resolveProductCategories(List<Product> items) => items
      .map(
        (product) {
          final resolvedName = categoryNamesById[product.category] ?? '';
          return product.copyWith(categoryName: resolvedName);
        },
      )
      .toList();

  // Pagination state
  int currentPage = 0;
  bool hasMoreProducts = true;
  bool isLoadingMore = false;
  static const int pageSize = 50;
  int _requestVersion = 0;

  String? _categoryFilterForRequest() {
    if (selectedCategory == '*') {
      return null;
    }
    final serverCategoryId = serverCategoryIds[selectedCategory];
    if (serverCategoryId != null && serverCategoryId.isNotEmpty) {
      return serverCategoryId;
    }
    return selectedCategory;
  }

  bool _hasUnknownServerCategory() {
    return selectedCategory != '*' &&
        serverCategoryIds.isNotEmpty &&
        !serverCategoryIds.containsKey(selectedCategory);
  }

  void clearProducts() {
    products = [];
    currentPage = 0;
    hasMoreProducts = true;
    currentSearchQuery = '';
    selectedCategory = '*';
    selectedAvailability = '*';
    emit(ProductLoadedState([]));
  }

  Future<void> getAllProducts() async {
    final requestVersion = ++_requestVersion;
    if (kDebugMode) {
      debugPrint(
        '[ProductCubit] getAllProducts using '
        '${productRepositoryInt.runtimeType}',
      );
    }
    emit(ProductLoadingState());

    // Reset pagination
    currentPage = 0;
    hasMoreProducts = true;
    isLoadingMore = false;
    products = [];

    if (_hasUnknownServerCategory()) {
      emit(ProductErrorState('Selected category is unavailable'));
      return;
    }

    final categoryResult = await _loadCategoryNames();
    if (requestVersion != _requestVersion) return;
    if (categoryResult.isLeft) {
      emit(ProductErrorState(categoryResult.left.message));
      return;
    }

    // Load first page
    final result = await productRepositoryInt.getProductsPaginated(
      page: currentPage,
      pageSize: pageSize,
      category: _categoryFilterForRequest(),
      availability: selectedAvailability,
      searchQuery: currentSearchQuery,
    );

    result.fold(
      (failure) {
        if (requestVersion == _requestVersion) {
          emit(ProductErrorState(failure.message));
        }
      },
      (productsList) {
        if (requestVersion != _requestVersion) return;
        products = _resolveProductCategories(productsList);
        hasMoreProducts = productsList.length == pageSize;
        emit(ProductLoadedState(List<Product>.unmodifiable(products)));
      },
    );
  }

  void loadMoreProducts() async {
    if (isLoadingMore || !hasMoreProducts) return;

    final requestVersion = _requestVersion;
    final nextPage = currentPage + 1;
    isLoadingMore = true;
    emit(ProductLoadedState(List<Product>.unmodifiable(products)));

    if (_hasUnknownServerCategory()) {
      isLoadingMore = false;
      emit(ProductErrorState('Selected category is unavailable'));
      emit(ProductLoadedState(List<Product>.unmodifiable(products)));
      return;
    }

    final result = await productRepositoryInt.getProductsPaginated(
      page: nextPage,
      pageSize: pageSize,
      category: _categoryFilterForRequest(),
      availability: selectedAvailability,
      searchQuery: currentSearchQuery,
    );

    result.fold(
      (failure) {
        if (requestVersion != _requestVersion) return;
        isLoadingMore = false;
        emit(ProductErrorState(failure.message));
        emit(ProductLoadedState(List<Product>.unmodifiable(products)));
      },
      (productsList) {
        if (requestVersion != _requestVersion) return;
        final existingBarcodes = products.map((p) => p.barcode).toSet();
        products.addAll(
          _resolveProductCategories(productsList)
              .where((p) => existingBarcodes.add(p.barcode)),
        );
        currentPage = nextPage;
        hasMoreProducts = productsList.length == pageSize;
        isLoadingMore = false;
        emit(ProductLoadedState(List<Product>.unmodifiable(products)));
      },
    );
  }

  Future<Either<Failure, void>> saveProduct(
    Product product, {
    List<SellingUnit>? packagedSellingUnits,
  }) async {
    if (kDebugMode &&
        BackendApiConfig.productWriteMode == ProductWriteMode.server) {
      debugPrint('[ProductCubit] SERVER-WRITE SAVE REQUEST');
    }
    emit(ProductLoadingState());
    if (kDebugMode &&
        BackendApiConfig.productWriteMode == ProductWriteMode.server) {
      debugPrint('[ProductCubit] calling ProductRepository.saveProduct');
    }
    final result = await productRepositoryInt.saveProduct(
      product,
      packagedSellingUnits: packagedSellingUnits,
    );
    if (result.isLeft) {
      emit(ProductErrorState(result.left.message));
      return result;
    }

    emit(ProductSuccessState("productSavedSuccess"));

    // Determine activity type
    final isUpdate = products.any((p) => p.barcode == product.barcode);

    // Log activity with session (auto-creates session if closed)
    final sid = await getIt<SessionManager>().ensureSessionId(
      userName: getIt<UserCubit>().currentUser.name,
    );
    await getIt<ActivityLogger>().logActivity(
      type: isUpdate ? ActivityType.productUpdate : ActivityType.productAdd,
      description: isUpdate
          ? 'Update product: ${product.name}'
          : 'Add product: ${product.name}',
      userName: getIt<UserCubit>().currentUser.name,
      sessionId: sid,
      details: {'barcode': product.barcode, 'price': product.price},
      eventKey: isUpdate ? 'productUpdated' : 'productAdded',
      parameters: {
        'user': getIt<UserCubit>().currentUser.name,
        'product': product.name
      },
    );

    await getAllProducts();
    return result;
  }

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
  }) async {
    if (kDebugMode &&
        BackendApiConfig.productWriteMode == ProductWriteMode.server) {
      debugPrint('[ProductCubit] SERVER-WRITE SAVE REQUEST');
    }
    emit(ProductLoadingState());
    if (kDebugMode &&
        BackendApiConfig.productWriteMode == ProductWriteMode.server) {
      debugPrint(
        '[ProductCubit] calling '
        'ProductRepository.saveProductWithOpeningStock',
      );
    }
    late final Either<Failure, void> result;
    try {
      result = await productRepositoryInt.saveProductWithOpeningStock(
        product,
        openingQuantity: openingQuantity,
        openingUnitCost: openingUnitCost,
        openingReason: openingReason,
        openingNotes: openingNotes,
        user: user,
        packagedSellingUnits: packagedSellingUnits,
        openingUnit: openingUnit,
        openingLines: openingLines,
      );
    } catch (error, stackTrace) {
      if (kDebugMode) {
        debugPrint(
          '[ProductCubit] saveProductWithOpeningStock exception '
          '${error.runtimeType}: $error\n$stackTrace',
        );
      }
      final failure = CacheFailure(error.toString());
      emit(ProductErrorState(failure.message));
      return Left(failure);
    }
    if (result.isLeft) {
      emit(ProductErrorState(result.left.message));
      return result;
    }
    emit(ProductSuccessState("productSavedSuccess"));
    await getAllProducts();
    return result;
  }

  Future<void> deleteProduct(String productId) async {
    emit(ProductLoadingState());
    final result = await productRepositoryInt.deleteProduct(productId);
    if (result.isLeft) {
      emit(ProductErrorState(result.left.message));
      return;
    }

    products.removeWhere((product) => product.id == productId);
    emit(ProductLoadedState(List<Product>.unmodifiable(products)));
    await getAllProducts();
    if (state is ProductErrorState) return;

    emit(ProductSuccessState("msgProductDeleted"));
    final userName = getIt<UserCubit>().currentUser.name;
    final sessionId =
        await getIt<SessionManager>().ensureSessionId(userName: userName);
    await getIt<ActivityLogger>().logActivity(
      type: ActivityType.productDelete,
      description: 'Delete product: $productId',
      userName: userName,
      sessionId: sessionId,
      details: {'productId': productId},
      eventKey: 'productDeleted',
      parameters: {'user': userName, 'product': productId},
    );
  }

  void filterByCategory(String category) {
    selectedCategory = category;
    getAllProducts();
  }

  void filterByAvailability(String availability) {
    selectedAvailability = availability;
    getAllProducts();
  }

  void searchProducts(String query) {
    currentSearchQuery = query;
    getAllProducts();
  }

  void getAllCategories() async {
    final result = await _loadCategoryNames(refresh: true);
    result.fold(
      (failure) => emit(CategoryErrorState(failure.message)),
      (namesById) {
        final categoryNames = namesById.values.toList();
        categories = categoryNames;
        emit(CategoryLoadedState(categoryNames));
      },
    );
  }

  void saveCategory(String category) async {
    emit(ProductLoadingState());
    final result = await productRepositoryInt.saveCategory(category);
    result.fold(
      (failure) => emit(CategoryErrorState(failure.message)),
      (_) {
        emit(CategorySuccessState("categoryAddedSuccess"));
        getAllCategories();
      },
    );
  }

  void deleteCategory(
      {required String category,
      bool forceDelete = false,
      String? newCategory}) async {
    emit(ProductLoadingState());
    final result = await productRepositoryInt.deleteCategory(
        category: category, forceDelete: forceDelete, newCategory: newCategory);
    result.fold(
      (failure) {
        if (failure is CacheFailure) {
          emit(CategoryErrorDeleteState(failure.message, category));
        } else {
          emit(CategoryErrorState(failure.message));
        }
      },
      (_) {
        emit(CategorySuccessState("categoryDeletedSuccess"));
        getAllCategories();
        getAllProducts();
      },
    );
  }

  Future<bool> checkProductExists(String barcode) async {
    final result = await productRepositoryInt.productExists(barcode);
    return result.fold((l) => false, (exists) => exists);
  }

  Future<Either<Failure, String>> resolveCategoryId(String categoryName) {
    return productRepositoryInt.resolveCategoryId(categoryName);
  }

  String? resolveServerCategoryId(String categoryName) =>
      serverCategoryIds[categoryName];

  String resolveCategoryName(String categoryId) =>
      categoryNamesById[categoryId] ?? '';
}
