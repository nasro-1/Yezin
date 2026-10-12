import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:flutter/foundation.dart';

import '../../../../core/network/backend_api_error.dart';
import '../../../../core/network/sale_draft_event_client.dart';
import '../../data/models/sale_draft_model.dart';
import '../../data/models/sale_model.dart';
import '../../domain/draft_sales_repository.dart';
import '../sale_draft_grouping.dart';
import 'draft_sales_state.dart';

class DraftSalesCubit extends Cubit<DraftSalesState> {
  DraftSalesCubit({
    required this.repository,
    this.eventClient,
    this.draftEvents,
  }) : super(const DraftSalesInitial());

  final DraftSalesRepository repository;
  final SaleDraftEventClient? eventClient;
  final Stream<Map<String, dynamic>>? draftEvents;
  StreamSubscription<Map<String, dynamic>>? _eventsSubscription;
  bool _initialized = false;
  int _refreshGeneration = 0;
  int _requestSequence = 0;
  int _writesInFlight = 0;
  int _identityGeneration = 0;
  String? _authenticatedUserId;
  final Map<String, Future<void>> _pendingWritesByDraft = {};

  Future<void> switchUser(String userId) async {
    if (isClosed || userId == _authenticatedUserId) return;
    _authenticatedUserId = userId;
    _identityGeneration++;
    _refreshGeneration++;
    _pendingWritesByDraft.clear();
    _writesInFlight = 0;
    emit(const DraftSalesLoaded(drafts: [], activeDraftId: null));
    await eventClient?.reconnect();
    await refresh();
  }

  void clearForLogout() {
    if (isClosed) return;
    _authenticatedUserId = null;
    _identityGeneration++;
    _refreshGeneration++;
    _pendingWritesByDraft.clear();
    _writesInFlight = 0;
    emit(const DraftSalesInitial());
  }

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    final events = draftEvents ?? eventClient?.events;
    if (events != null) {
      _eventsSubscription = events.listen((_) => refresh());
    }
    if (eventClient != null) {
      unawaited(eventClient!.connect());
    }

    await refresh();
  }

  Future<void> refresh({String? preserveDraftId}) async {
    if (isClosed) return;
    if (_writesInFlight > 0 && preserveDraftId == null) {
      debugPrint('[DRAFT_TRACE] event=refresh-deferred '
          'selectedDraftId=${state.activeDraftId} writesInFlight=$_writesInFlight');
      return;
    }
    final generation = ++_refreshGeneration;
    final identityGeneration = _identityGeneration;
    final requestId = ++_requestSequence;
    debugPrint(
        '[DRAFT_TRACE] event=refresh-start preserveDraftId=$preserveDraftId '
        'selectedDraftId=${state.activeDraftId} requestId=$requestId');
    emit(state.copyWith(status: DraftSalesStatus.loading, message: null));
    try {
      final fetchedDrafts = _uniqueDrafts(await repository.listDrafts());
      if (generation != _refreshGeneration ||
          identityGeneration != _identityGeneration ||
          isClosed) {
        debugPrint('[DRAFT_TRACE] event=refresh-discard requestId=$requestId');
        return;
      }
      final drafts = _uniqueDrafts(fetchedDrafts);
      final requested = preserveDraftId ?? state.activeDraftId;
      final active = drafts.any((draft) => draft.id == requested)
          ? requested
          : drafts.where((draft) => !draft.isHeld).firstOrNull?.id ??
              drafts.firstOrNull?.id;
      final staleActiveDraft = state.activeDraftId != null &&
          !drafts.any((draft) => draft.id == state.activeDraftId);
      debugPrint('[DRAFT_SYNC_TRACE] source=server-refresh '
          'serverDraftCount=${drafts.length} '
          'clearingStaleActiveDraft=$staleActiveDraft '
          'activeDraftId=${state.activeDraftId}');
      emit(DraftSalesLoaded(drafts: drafts, activeDraftId: active));
      debugPrint('[DRAFT_TRACE] event=refresh-complete selectedDraftId=$active '
          'requestId=$requestId drafts=${drafts.length}');
    } catch (error) {
      emit(state.copyWith(
        status: DraftSalesStatus.error,
        message: _message(error),
      ));
    }
  }

  void selectDraft(String draftId) {
    if (!state.drafts.any((draft) => draft.id == draftId)) return;
    if (state.activeDraftId == draftId) {
      debugPrint('[DRAFT_WRITE_TRACE] caller=selectDraft '
          'draftId=$draftId reason=same-selection-read-only '
          'version=${state.activeDraft?.version ?? -1} '
          'itemCount=${state.activeDraft?.items.length ?? 0}');
      return;
    }
    _refreshGeneration++;
    debugPrint('[DRAFT_TRACE] event=select-draft id=$draftId '
        'previousDraftId=${state.activeDraftId}');
    emit(state.copyWith(
      status: DraftSalesStatus.loaded,
      activeDraftId: draftId,
      message: null,
      conflictDraftId: null,
    ));
  }

  Future<SaleDraft?> newSale() async {
    try {
      debugPrint('[DRAFT_WRITE_TRACE] caller=DraftSalesCubit.newSale '
          'draftId=<new> reason=user-new version=-1 itemCount=0');
      emit(state.copyWith(status: DraftSalesStatus.saving, message: null));
      final draft = await repository.createDraft();
      final drafts = _uniqueDrafts([...state.drafts, draft]);
      emit(DraftSalesLoaded(drafts: drafts, activeDraftId: draft.id));
      return draft;
    } catch (error) {
      emit(state.copyWith(
        status: DraftSalesStatus.error,
        message: _message(error),
      ));
      return null;
    }
  }

  Future<void> holdActive() async {
    final draft = state.activeDraft;
    if (draft == null) return;
    try {
      debugPrint('[DRAFT_WRITE_TRACE] caller=DraftSalesCubit.holdActive '
          'draftId=${draft.id} reason=user-hold version=${draft.version} '
          'itemCount=${draft.items.length}');
      emit(state.copyWith(status: DraftSalesStatus.saving));
      final held = await repository.holdDraft(draft.id, version: draft.version);
      _replace(held, nextActiveId: _nextActiveId(held.id));
    } catch (error) {
      await _handleError(error, draft.id);
    }
  }

  Future<void> resumeDraft(String draftId) async {
    final draft = _find(draftId);
    if (draft == null) return;
    try {
      debugPrint('[DRAFT_WRITE_TRACE] caller=DraftSalesCubit.resumeDraft '
          'draftId=${draft.id} reason=user-resume version=${draft.version} '
          'itemCount=${draft.items.length}');
      emit(state.copyWith(status: DraftSalesStatus.saving));
      final resumed =
          await repository.resumeDraft(draft.id, version: draft.version);
      _replace(resumed, nextActiveId: resumed.id);
    } catch (error) {
      debugPrint('[DRAFT_TRACE] event=checkout-error draftId=${draft.id} '
          'error=$error');
      await _handleError(error, draft.id);
    }
  }

  Future<void> clearActive() async {
    final draft = state.activeDraft;
    if (draft == null) return;
    try {
      debugPrint('[DRAFT_WRITE_TRACE] caller=DraftSalesCubit.clearActive '
          'draftId=${draft.id} reason=user-clear version=${draft.version} '
          'itemCount=${draft.items.length}');
      emit(state.copyWith(status: DraftSalesStatus.saving));
      await repository.deleteDraft(draft.id, version: draft.version);
      final drafts = state.drafts.where((item) => item.id != draft.id).toList();
      final next = drafts.where((item) => !item.isHeld).firstOrNull?.id ??
          drafts.firstOrNull?.id;
      emit(DraftSalesLoaded(drafts: drafts, activeDraftId: next));
    } catch (error) {
      await _handleError(error, draft.id);
    }
  }

  Future<void> toggleActiveVisibility() async {
    final draft = state.activeDraft;
    if (draft == null) return;
    final nextVisibility = draft.visibility == SaleDraftVisibility.private
        ? SaleDraftVisibility.shared
        : SaleDraftVisibility.private;
    try {
      debugPrint(
          '[DRAFT_WRITE_TRACE] caller=DraftSalesCubit.toggleActiveVisibility '
          'draftId=${draft.id} reason=user-visibility version=${draft.version} '
          'itemCount=${draft.items.length}');
      emit(state.copyWith(status: DraftSalesStatus.saving, message: null));
      final updated = await repository.updateDraft(
        draft.id,
        draft.items,
        version: draft.version,
        customerId: draft.customerId,
        customerName: draft.customerName,
        discount: draft.discount,
        paymentMethod: draft.paymentMethod,
        visibility: nextVisibility,
      );
      _replace(updated, nextActiveId: updated.id);
    } catch (error) {
      await _handleError(error, draft.id);
    }
  }

  Future<void> updateActiveItems(
    List<SaleDraftItem> items, {
    String? draftId,
    String? customerId,
    String? customerName,
    double discount = 0,
    String paymentMethod = 'cash',
  }) async {
    final draft = _find(draftId ?? state.activeDraftId ?? '');
    if (draft == null) return;
    final requestedCustomerId = customerId ?? draft.customerId;
    final requestedCustomerName = customerName ?? draft.customerName;
    if (_draftItemsEqual(draft.items, items) &&
        draft.customerId == requestedCustomerId &&
        draft.customerName == requestedCustomerName &&
        draft.discount == discount &&
        draft.paymentMethod == paymentMethod) {
      debugPrint('[DRAFT_WRITE_TRACE] caller=updateActiveItems '
          'draftId=${draft.id} reason=equivalent-state-read-only '
          'version=${draft.version} itemCount=${items.length}');
      return;
    }
    final targetDraftId = draft.id;
    final previous =
        _pendingWritesByDraft[targetDraftId] ?? Future<void>.value();
    final operation = previous.catchError((_) {}).then(
          (_) => _updateDraftItems(
            items,
            draftId: targetDraftId,
            customerId: customerId,
            customerName: customerName,
            discount: discount,
            paymentMethod: paymentMethod,
          ),
        );
    _pendingWritesByDraft[targetDraftId] = operation.whenComplete(() {
      if (identical(_pendingWritesByDraft[targetDraftId], operation)) {
        _pendingWritesByDraft.remove(targetDraftId);
      }
    });
    return operation;
  }

  bool _draftItemsEqual(
    List<SaleDraftItem> current,
    List<SaleDraftItem> requested,
  ) {
    if (current.length != requested.length) return false;
    for (var index = 0; index < current.length; index++) {
      final left = current[index];
      final right = requested[index];
      if (left.productId != right.productId ||
          left.quantity != right.quantity ||
          left.unitPrice != right.unitPrice ||
          left.unit != right.unit ||
          left.sellingUnitId != right.sellingUnitId ||
          left.conversionFactor != right.conversionFactor) {
        return false;
      }
    }
    return true;
  }

  Future<void> _updateDraftItems(
    List<SaleDraftItem> items, {
    required String draftId,
    String? customerId,
    String? customerName,
    double discount = 0,
    String paymentMethod = 'cash',
  }) async {
    final draft = _find(draftId);
    if (draft == null) return;
    final requestId = ++_requestSequence;
    final itemIds = items.map((item) => item.productId).join(',');
    debugPrint('[DRAFT_WRITE_TRACE] caller=DraftSalesCubit._updateDraftItems '
        'draftId=${draft.id} reason=cart-edit '
        'version=${draft.version} itemCount=${items.length}\n'
        '[DRAFT_TRACE] event=update-start selectedDraftId=${state.activeDraftId} '
        'targetDraftId=${draft.id} itemCount=${items.length} itemIds=$itemIds '
        'version=${draft.version} requestId=$requestId');
    try {
      _writesInFlight++;
      emit(state.copyWith(status: DraftSalesStatus.saving));
      final updated = await repository.updateDraft(
        draft.id,
        items,
        version: draft.version,
        customerId: customerId ?? draft.customerId,
        customerName: customerName ?? draft.customerName,
        discount: discount,
        paymentMethod: paymentMethod,
      );
      debugPrint(
          '[DRAFT_TRACE] event=update-response targetDraftId=${updated.id} '
          'itemCount=${updated.items.length} version=${updated.version} '
          'requestId=$requestId');
      // A save may finish after the user has selected another draft. Update
      // the saved draft in the server-backed list, but keep the current
      // selection so its cart cannot be replaced by a stale response.
      final selectedId = state.activeDraftId;
      final current = _find(updated.id);
      if (current != null && current.version > updated.version) {
        debugPrint(
            '[DRAFT_TRACE] event=update-discard-older targetDraftId=${updated.id} '
            'currentVersion=${current.version} responseVersion=${updated.version} '
            'requestId=$requestId');
        return;
      }
      _replace(
        updated,
        nextActiveId: selectedId == null || selectedId == draft.id
            ? updated.id
            : selectedId,
      );
    } catch (error) {
      await _handleError(
        error,
        draft.id,
        preserveDraftId: state.activeDraftId,
      );
    } finally {
      _writesInFlight--;
    }
  }

  Future<Sale?> checkoutActive({
    required String paymentMethod,
    String? customerId,
  }) async {
    final draft = state.activeDraft;
    if (draft == null) return null;
    try {
      debugPrint('[DRAFT_WRITE_TRACE] caller=DraftSalesCubit.checkoutActive '
          'draftId=${draft.id} reason=checkout version=${draft.version} '
          'itemCount=${draft.items.length}');
      emit(state.copyWith(status: DraftSalesStatus.saving));
      final sale = await repository.checkoutDraft(
        draft.id,
        version: draft.version,
        paymentMethod: paymentMethod,
        customerId: customerId ?? draft.customerId,
      );
      final drafts = state.drafts.where((item) => item.id != draft.id).toList();
      final next = drafts.where((item) => !item.isHeld).firstOrNull?.id ??
          drafts.firstOrNull?.id;
      emit(DraftSalesLoaded(drafts: drafts, activeDraftId: next));
      return sale;
    } catch (error) {
      await _handleCheckoutError(error, draft.id);
      return null;
    }
  }

  SaleDraft? _find(String id) =>
      state.drafts.where((draft) => draft.id == id).firstOrNull;

  String? _nextActiveId(String replacedId) {
    final candidates =
        state.drafts.where((draft) => draft.id != replacedId && !draft.isHeld);
    return candidates.firstOrNull?.id;
  }

  void _replace(SaleDraft replacement, {String? nextActiveId}) {
    final drafts = _uniqueDrafts(state.drafts
        .map((draft) => draft.id == replacement.id ? replacement : draft)
        .toList());
    emit(DraftSalesLoaded(
      drafts: drafts,
      activeDraftId: nextActiveId ?? replacement.id,
    ));
  }

  List<SaleDraft> _uniqueDrafts(Iterable<SaleDraft> drafts) {
    return uniqueSaleDrafts(drafts);
  }

  Future<void> _handleError(
    Object error,
    String draftId, {
    String? preserveDraftId,
  }) async {
    if (_isVersionConflict(error)) {
      await refresh(preserveDraftId: preserveDraftId ?? draftId);
      if (isClosed) return;
      emit(DraftSalesConflict(
        drafts: state.drafts,
        activeDraftId: state.activeDraftId,
        conflictDraftId: draftId,
        message:
            'This sale changed on another terminal. Review the refreshed draft.',
      ));
      return;
    }
    emit(state.copyWith(
      status: DraftSalesStatus.error,
      message: _message(error),
    ));
  }

  Future<void> _handleCheckoutError(Object error, String draftId) async {
    final missing = error is BackendApiException &&
        (error.statusCode == 404 ||
            error.errorKind == BackendApiErrorKind.notFound);
    final conflict = _isVersionConflict(error);
    if (!missing && !conflict) {
      emit(state.copyWith(
        status: DraftSalesStatus.error,
        message: _message(error),
      ));
      return;
    }

    await refresh(preserveDraftId: draftId);
    if (isClosed) return;
    final refreshed = _find(draftId);
    if (refreshed == null) {
      debugPrint('[DRAFT_SYNC_TRACE] source=checkout-error '
          'serverDraftCount=${state.drafts.length} '
          'clearingStaleActiveDraft=true activeDraftId=$draftId '
          'errorStatus=${error is BackendApiException ? error.statusCode : 'unknown'}');
      emit(DraftSalesState(
        status: DraftSalesStatus.error,
        drafts: state.drafts,
        activeDraftId: null,
        message: 'This draft is no longer available on the server. '
            'The sales list has been refreshed.',
      ));
      return;
    }

    if (conflict) {
      emit(DraftSalesConflict(
        drafts: state.drafts,
        activeDraftId: refreshed.id,
        conflictDraftId: draftId,
        message:
            'This sale changed on another terminal. Review the refreshed draft.',
      ));
    } else {
      emit(state.copyWith(
        status: DraftSalesStatus.error,
        activeDraftId: refreshed.id,
        message: _message(error),
      ));
    }
  }

  bool _isVersionConflict(Object error) {
    if (error is DraftVersionConflictException) return true;
    if (error is! BackendApiException) return false;
    final message = error.message.toLowerCase();
    return error.errorKind == BackendApiErrorKind.conflict &&
        (message.contains('version conflict') ||
            message.contains('draft version') ||
            message.contains('expected version') ||
            message.contains('optimistic concurrency'));
  }

  String _message(Object error) => error is BackendApiException
      ? error.message
      : error.toString().replaceFirst('Exception: ', '');

  @override
  Future<void> close() async {
    await _eventsSubscription?.cancel();
    return super.close();
  }
}

typedef DraftSalesBloc = DraftSalesCubit;
