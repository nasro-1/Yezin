import 'package:dartz/dartz.dart';

import '../../../core/error/failure.dart';
import '../data/models/stock_movement_model.dart';
import '../data/repository/stock_movement_repository.dart';

class StockService {
  final StockMovementRepository stockMovementRepository;

  const StockService({required this.stockMovementRepository});

  Future<Either<Failure, Unit>> recordAdjustment({
    required String productId,
    required String productBarcode,
    required String productName,
    required double quantityChange,
    required double runningStock,
    required String movementType,
    String? referenceType,
    String? referenceId,
    String? notes,
    String? userId,
  }) async {
    final movement = StockMovement(
      id: '${DateTime.now().microsecondsSinceEpoch}',
      productId: productId,
      productBarcode: productBarcode,
      productName: productName,
      movementType: movementType,
      quantityChange: quantityChange,
      unitCost: 0,
      runningStock: runningStock,
      referenceType: referenceType,
      referenceId: referenceId,
      notes: notes,
      userId: userId,
      createdAt: DateTime.now(),
    );

    return stockMovementRepository.recordMovement(movement);
  }
}
