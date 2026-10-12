import 'package:dartz/dartz.dart';
import '../../../core/error/failure.dart';
import '../../sales/domain/sales_repository.dart';

/// Represents an item that can be refunded with calculated quantities
class RefundableItem {
  final String? saleItemId;
  final String productId;
  final String productName;
  final int originalQuantity;
  final int refundedQuantity;
  final int exchangedQuantity;
  final int remainingQuantity;
  final double unitPrice;
  final double wholesalePrice;
  final String? sellingUnitId;
  final double? sellingQuantity;
  final double? baseQuantity;
  final double? conversionFactorSnapshot;
  final String? sellingUnitNameSnapshot;
  final String? baseUnitSnapshot;

  RefundableItem({
    this.saleItemId,
    required this.productId,
    required this.productName,
    required this.originalQuantity,
    required this.refundedQuantity,
    this.exchangedQuantity = 0,
    required this.unitPrice,
    required this.wholesalePrice,
    this.sellingUnitId,
    this.sellingQuantity,
    this.baseQuantity,
    this.conversionFactorSnapshot,
    this.sellingUnitNameSnapshot,
    this.baseUnitSnapshot,
  }) : remainingQuantity =
            _remaining(originalQuantity, refundedQuantity, exchangedQuantity);

  static int _remaining(int original, int refunded, int exchanged) {
    final remaining = original - refunded - exchanged;
    return remaining > 0 ? remaining : 0;
  }

  bool get canBeRefunded => remainingQuantity > 0;
  double get totalRefundValue => unitPrice * remainingQuantity;
}

/// Service for calculating refund-related data
class RefundCalculationService {
  final SalesRepository repository;

  RefundCalculationService(this.repository);

  /// Get total refunded quantities for each product in an invoice
  Future<Either<Failure, Map<String, double>>> getRefundedQuantities(
      String originalInvoiceId) async {
    final refundsResult =
        await repository.getRefundsForInvoice(originalInvoiceId);

    return refundsResult.fold(
      (failure) => Left(failure),
      (refunds) {
        final Map<String, double> refundedQuantities = {};

        for (final refund in refunds) {
          for (final item in refund.saleItems) {
            refundedQuantities[item.productId] =
                (refundedQuantities[item.productId] ?? 0.0) + item.quantity;
          }
        }

        return Right(refundedQuantities);
      },
    );
  }

  /// Check if an invoice has been fully refunded
  Future<Either<Failure, bool>> isFullyRefunded(String invoiceId) async {
    final refundableItemsResult = await getRefundableItems(invoiceId);

    return refundableItemsResult.fold(
      (failure) => Left(failure),
      (items) => Right(items.every((item) => item.remainingQuantity == 0)),
    );
  }

  /// Get list of refundable items with remaining quantities
  Future<Either<Failure, List<RefundableItem>>> getRefundableItems(
      String invoiceId) async {
    // Get the original invoice
    final salesResult = await repository.getRecentSales(limit: 10000);

    return salesResult.fold(
      (failure) => Left(failure),
      (allSales) async {
        final originalSale = allSales.firstWhere(
          (s) => s.id == invoiceId,
          orElse: () => throw Exception('Invoice not found'),
        );

        if (originalSale.isRefund) {
          return Left(CacheFailure('Cannot refund a refund invoice'));
        }

        // Get refunded quantities
        // We now prioritize the stored refundedQuantity in SaleItem
        // to handle cases where refund invoices might be deleted

        return Right(originalSale.saleItems.map((item) {
          return RefundableItem(
            saleItemId: item.saleItemId,
            productId: item.productId,
            productName: item.name,
            originalQuantity: item.quantity.toInt(),
            refundedQuantity: item.refundedQuantity.toInt(),
            exchangedQuantity: item.exchangedQuantity.toInt(),
            unitPrice: item.price,
            wholesalePrice: item.wholesalePrice,
            sellingUnitId: item.sellingUnitId,
            sellingQuantity: item.sellingQuantity,
            baseQuantity: item.baseQuantity,
            conversionFactorSnapshot: item.conversionFactorSnapshot,
            sellingUnitNameSnapshot: item.sellingUnitNameSnapshot,
            baseUnitSnapshot: item.baseUnitSnapshot,
          );
        }).toList());
      },
    );
  }
}
