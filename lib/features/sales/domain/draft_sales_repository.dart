import '../data/models/sale_draft_model.dart';
import '../data/models/sale_model.dart';

class DraftVersionConflictException implements Exception {
  const DraftVersionConflictException(this.draftId, {this.message});

  final String draftId;
  final String? message;

  @override
  String toString() => message ?? 'Draft $draftId was changed remotely';
}

/// Server-authoritative workspace for sales which have not been posted yet.
abstract interface class DraftSalesRepository {
  Future<List<SaleDraft>> listDrafts({bool includeHeld = true});

  Future<List<SaleDraft>> getDrafts({bool includeHeld = true}) =>
      listDrafts(includeHeld: includeHeld);

  Future<SaleDraft> createDraft();

  Future<SaleDraft> updateDraft(
    String draftId,
    List<SaleDraftItem> items, {
    required int version,
    String? customerId,
    String? customerName,
    double discount = 0,
    String paymentMethod = 'cash',
    SaleDraftVisibility? visibility,
  });

  Future<SaleDraft> holdDraft(String draftId, {required int version});

  Future<SaleDraft> resumeDraft(String draftId, {required int version});

  Future<void> deleteDraft(String draftId, {required int version});

  Future<void> clearDraft(String draftId, {required int version}) =>
      deleteDraft(draftId, version: version);

  Future<Sale> checkoutDraft(
    String draftId, {
    required int version,
    required String paymentMethod,
    String? customerId,
  });
}

/// Kept as a domain-friendly alias for integrations which use the singular name.
typedef SaleDraftRepository = DraftSalesRepository;
