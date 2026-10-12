import '../../../../core/network/backend_api_client.dart';
import '../models/stock_adjustment_model.dart';

class StockAdjustmentApiRepository {
  const StockAdjustmentApiRepository(this.client);

  final BackendApiClient client;

  Future<StockAdjustmentDocument> post({
    required String idempotencyKey,
    required List<StockAdjustmentLineInput> lines,
    required String reason,
    String? notes,
    DateTime? adjustmentDate,
  }) async {
    final payload = await client.postStockAdjustment({
      'idempotency_key': idempotencyKey,
      'adjustment_date': adjustmentDate?.toIso8601String(),
      'reason': reason,
      'notes': notes,
      'lines': lines
          .map((line) => {
                'product_id': line.productId,
                'unit': line.unit ?? 'piece',
                'counted_quantity': line.countedQuantity,
                'unit_cost': line.unitCost,
                'operation': line.operation,
              })
          .toList(),
    });
    return _mapDocument(payload);
  }

  StockAdjustmentDocument _mapDocument(Map<String, dynamic> payload) {
    final rawLines = payload['lines'];
    if (rawLines is! List) {
      throw const FormatException('Stock adjustment response is missing lines');
    }
    final documentId = payload['document_id'];
    final referenceNumber = payload['reference_number'];
    final idempotencyKey = payload['idempotency_key'];
    final reason = payload['reason'];
    final postedAt = payload['posted_at'];
    final adjustmentDate = payload['adjustment_date'];
    final postedBy = payload['posted_by'];
    if (documentId is! String ||
        referenceNumber is! String ||
        idempotencyKey is! String ||
        reason is! String ||
        postedAt is! String ||
        adjustmentDate is! String ||
        postedBy is! String) {
      throw const FormatException('Invalid stock adjustment response');
    }
    return StockAdjustmentDocument(
      id: documentId,
      referenceNumber: referenceNumber,
      idempotencyKey: idempotencyKey,
      status: StockAdjustmentStatus.posted,
      adjustmentDate: DateTime.parse(adjustmentDate),
      reason: reason,
      notes: payload['notes'] as String?,
      postedAt: DateTime.parse(postedAt),
      postedBy: postedBy,
      createdAt: DateTime.parse(postedAt),
      lines: rawLines
          .map((line) => _mapLine(line as Map))
          .toList(growable: false),
    );
  }

  StockAdjustmentLine _mapLine(Map line) {
    final values = Map<String, dynamic>.from(line);
    return StockAdjustmentLine(
      id: values['id'] as String,
      documentId: values['document_id'] as String,
      productId: values['product_id'] as String,
      productBarcode: values['product_barcode'] as String?,
      productName: values['product_name'] as String,
      currentQuantity: (values['current_quantity'] as num).toDouble(),
      countedQuantity: (values['counted_quantity'] as num).toDouble(),
      quantityChange: (values['quantity_change'] as num).toDouble(),
      unitCost: (values['unit_cost'] as num).toDouble(),
      lineTotal: (values['line_total'] as num).toDouble(),
      createdAt: DateTime.parse(values['created_at'] as String),
    );
  }
}
