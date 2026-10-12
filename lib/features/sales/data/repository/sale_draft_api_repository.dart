import '../../../../core/network/backend_api_client.dart';
import 'package:flutter/foundation.dart';
import '../../domain/draft_sales_repository.dart';
import '../models/sale_draft_model.dart';
import '../models/sale_model.dart';

/// REST implementation of the server draft workspace.
class SaleDraftApiRepository implements DraftSalesRepository {
  SaleDraftApiRepository(this.client);

  final BackendApiClient client;

  @override
  Future<List<SaleDraft>> listDrafts({bool includeHeld = true}) async {
    final payload = await client.getSaleDrafts(includeHeld: includeHeld);
    final raw = payload is Map
        ? payload['drafts'] ?? payload['items'] ?? payload
        : payload;
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((item) => SaleDraft.fromJson(Map<String, dynamic>.from(item)))
        .toList();
  }

  @override
  Future<List<SaleDraft>> getDrafts({bool includeHeld = true}) =>
      listDrafts(includeHeld: includeHeld);

  @override
  Future<SaleDraft> createDraft() async =>
      SaleDraft.fromJson(await client.createSaleDraft());

  @override
  Future<SaleDraft> updateDraft(
    String draftId,
    List<SaleDraftItem> items, {
    required int version,
    String? customerId,
    String? customerName,
    double discount = 0,
    String paymentMethod = 'cash',
    SaleDraftVisibility? visibility,
  }) async {
    debugPrint('[DRAFT_WRITE_TRACE] caller=SaleDraftApiRepository.updateDraft '
        'draftId=$draftId reason=api-update version=$version '
        'itemCount=${items.length}');
    debugPrint('[DRAFT_TRACE] event=api-update-request targetDraftId=$draftId '
        'version=$version itemCount=${items.length} '
        'itemIds=${items.map((item) => item.productId).join(',')}');
    final result = await client.updateSaleDraft(
      draftId,
      {
        'items': items.map((item) => item.toJson()).toList(),
        if (customerId != null) 'customer_id': customerId,
        if (customerName != null) 'customer_name': customerName,
        'discount': discount,
        'payment_method': paymentMethod,
        if (visibility != null) 'visibility': visibility.name.toUpperCase(),
      },
      version: version,
    );
    final updated = SaleDraft.fromJson(result);
    debugPrint('[DRAFT_TRACE] event=api-update-response '
        'targetDraftId=${updated.id} version=${updated.version} '
        'itemCount=${updated.items.length} '
        'itemIds=${updated.items.map((item) => item.productId).join(',')}');
    return updated;
  }

  @override
  Future<SaleDraft> holdDraft(String draftId, {required int version}) async =>
      SaleDraft.fromJson(await client.holdSaleDraft(draftId, version: version));

  @override
  Future<SaleDraft> resumeDraft(String draftId, {required int version}) async =>
      SaleDraft.fromJson(
          await client.resumeSaleDraft(draftId, version: version));

  @override
  Future<void> deleteDraft(String draftId, {required int version}) =>
      client.deleteSaleDraft(draftId, version: version);

  @override
  Future<void> clearDraft(String draftId, {required int version}) =>
      deleteDraft(draftId, version: version);

  @override
  Future<Sale> checkoutDraft(
    String draftId, {
    required int version,
    required String paymentMethod,
    String? customerId,
  }) async {
    final json = await client.checkoutSaleDraft(
      draftId,
      version: version,
      paymentMethod: paymentMethod,
      customerId: customerId,
    );
    return _saleFromResponse(json);
  }

  Sale _saleFromResponse(Map<String, dynamic> json) {
    final raw = json['sale'] is Map
        ? Map<String, dynamic>.from(json['sale'] as Map)
        : json;
    final rawItems = raw['items'] is List ? raw['items'] as List : const [];
    final items = rawItems.whereType<Map>().map((value) {
      final item = Map<String, dynamic>.from(value);
      double number(Object? value) =>
          value is num ? value.toDouble() : double.tryParse('$value') ?? 0;
      final quantity = number(item['quantity'] ?? item['qty']);
      final price = number(item['unit_price'] ?? item['price']);
      return SaleItem(
        productId: '${item['product_id'] ?? item['productId'] ?? ''}',
        name:
            '${item['name'] ?? item['product_name'] ?? item['product_id'] ?? ''}',
        price: price,
        quantity: quantity,
        total: number(item['line_total'] ?? item['total']) == 0
            ? quantity * price
            : number(item['line_total'] ?? item['total']),
        wholesalePrice: 0,
        sellingQuantity: quantity,
        baseQuantity: item['base_quantity'] == null
            ? null
            : number(item['base_quantity']),
        sellingUnitNameSnapshot: item['unit']?.toString(),
      );
    }).toList();
    double number(Object? value) =>
        value is num ? value.toDouble() : double.tryParse('$value') ?? 0;
    final postedAt = DateTime.tryParse(
          '${raw['posted_at'] ?? raw['date'] ?? DateTime.now().toIso8601String()}',
        ) ??
        DateTime.now();
    return Sale(
      id: '${raw['sale_id'] ?? raw['id'] ?? ''}',
      total: number(raw['total']),
      items: items.length,
      date: postedAt,
      saleItems: items,
      cashierName: null,
      customerId: raw['customer_id']?.toString(),
      paymentMethod: '${raw['payment_method'] ?? 'cash'}',
      discount: number(raw['discount']),
      referenceNumber: raw['document_reference']?.toString(),
    );
  }
}
