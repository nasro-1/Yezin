import 'dart:async';
import 'package:bayaa_pos/features/products/data/models/product_model.dart';
import 'package:bayaa_pos/features/products/domain/product_repository_int.dart';
import 'package:bayaa_pos/features/stock/presentation/cubit/stock_states.dart'
    show StockErrorState, StockLoadingState, StockStates, StockSucssesState;
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../../../core/di/dependency_injection.dart';
import '../../../../core/services/activity_logger.dart';
import '../../../../core/data/models/activity_log.dart';

class StockCubit extends Cubit<StockStates> {
  StreamSubscription? _activitySubscription;

  StockCubit({required this.productRepository}) : super(StockLoadingState()) {
    _activitySubscription =
        getIt<ActivityLogger>().activitiesStream.listen((activities) {
      if (activities.isNotEmpty) {
        final type = activities.first.type;
        if (type == ActivityType.sale ||
            type == ActivityType.refund ||
            type == ActivityType.productAdd ||
            type == ActivityType.productUpdate ||
            type == ActivityType.productDelete ||
            type == ActivityType.productQuantityUpdate ||
            type == ActivityType.restock ||
            type == ActivityType.stockAdjustment) {
          loadData();
        }
      }
    });
  }

  @override
  Future<void> close() {
    _activitySubscription?.cancel();
    return super.close();
  }

  ProductRepositoryInt productRepository;
  List<Product> products = [];

  String filter = 'all';
  int lowStockCount = 0;
  int outOfStockCount = 0;
  int totalCount = 0;
  List<Product> sendData() {
    return products
        .where((p) => p.quantity > 0 && p.quantity <= p.effectiveMinimumStock)
        .toList();
  }

  void loadData() async {
    final result = await productRepository.getAllProduct();
    result.fold((error) => emit(StockErrorState(error.message)), (data) {
      products = data;
      _calculateCounts();
      filterProducts();
    });
  }

  void _calculateCounts() {
    outOfStockCount = products.where((p) => p.quantity == 0).length;
    lowStockCount = products
        .where((p) => p.quantity > 0 && p.quantity <= p.effectiveMinimumStock)
        .length;
    totalCount = lowStockCount + outOfStockCount;
  }

  void filterProducts() {
    final List<Product> filtered = products.where((p) {
      if (filter == 'all' && totalCount > 0) {
        return (p.quantity <= p.effectiveMinimumStock);
      }
      if (filter == 'low' && lowStockCount > 0) {
        return (p.quantity > 0 && p.quantity <= p.effectiveMinimumStock);
      }
      if (filter == 'out' && outOfStockCount > 0) return p.quantity == 0;
      return false;
    }).toList();
    emit(StockSucssesState(products: filtered));
  }
}
