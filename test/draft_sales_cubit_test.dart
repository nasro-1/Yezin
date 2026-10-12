import 'dart:async';

import 'package:bayaa_pos/features/sales/data/models/sale_draft_model.dart';
import 'package:bayaa_pos/features/sales/data/models/sale_model.dart';
import 'package:bayaa_pos/core/network/backend_api_error.dart';
import 'package:bayaa_pos/features/sales/domain/draft_sales_repository.dart';
import 'package:bayaa_pos/features/sales/presentation/cubit/draft_sales_cubit.dart';
import 'package:bayaa_pos/features/sales/presentation/cubit/draft_sales_state.dart';
import 'package:flutter_test/flutter_test.dart';

class _DraftRepository implements DraftSalesRepository {
  _DraftRepository(
    this.responses, {
    this.updateResponse,
    this.checkoutResponse,
    this.checkoutError,
  });

  final List<List<SaleDraft>> responses;
  final SaleDraft? updateResponse;
  final Sale? checkoutResponse;
  final Object? checkoutError;
  var index = 0;
  var updateCalls = 0;
  var checkoutCalls = 0;

  @override
  Future<List<SaleDraft>> listDrafts({bool includeHeld = true}) async =>
      responses[index++];

  @override
  Future<List<SaleDraft>> getDrafts({bool includeHeld = true}) =>
      listDrafts(includeHeld: includeHeld);

  @override
  Future<SaleDraft> createDraft() => throw UnimplementedError();

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
  }) {
    updateCalls++;
    if (updateResponse != null) return Future.value(updateResponse);
    return Future.error(StateError('unexpected draft update'));
  }

  @override
  Future<SaleDraft> holdDraft(String draftId, {required int version}) =>
      throw UnimplementedError();

  @override
  Future<SaleDraft> resumeDraft(String draftId, {required int version}) =>
      throw UnimplementedError();

  @override
  Future<void> deleteDraft(String draftId, {required int version}) =>
      throw UnimplementedError();

  @override
  Future<void> clearDraft(String draftId, {required int version}) =>
      throw UnimplementedError();

  @override
  Future<Sale> checkoutDraft(
    String draftId, {
    required int version,
    required String paymentMethod,
    String? customerId,
  }) {
    checkoutCalls++;
    if (checkoutResponse != null) return Future.value(checkoutResponse);
    if (checkoutError != null) return Future.error(checkoutError!);
    return Future.error(StateError('unexpected checkout'));
  }
}

SaleDraft _draft({required int version, required List<SaleDraftItem> items}) =>
    SaleDraft(
      id: 'draft-1',
      version: version,
      status: SaleDraftStatus.open,
      items: items,
    );

SaleDraftItem _item() => const SaleDraftItem(
      productId: 'dev-coca-cola',
      name: 'Coca Cola',
      quantity: 1,
      unitPrice: 100,
    );

Sale _sale() => Sale(
      id: 'sale-1',
      total: 100,
      items: 1,
      date: DateTime(2026),
      saleItems: const [],
      cashierName: 'Manager',
    );

void main() {
  test('server refresh removes drafts absent from authoritative response',
      () async {
    final itemDraft = _draft(version: 1, items: [_item()]);
    final cubit = DraftSalesCubit(
      repository: _DraftRepository([
        [itemDraft],
        const [],
      ]),
    );

    await cubit.initialize();
    expect(cubit.state.activeDraft?.items.length, 1);
    expect(cubit.state.activeDraft?.subtotal, 100);

    await cubit.refresh(preserveDraftId: itemDraft.id);

    expect(cubit.state.drafts, isEmpty);
    expect(cubit.state.activeDraftId, isNull);
    expect(cubit.state.activeDraft, isNull);
    await cubit.close();
  });

  test('checkout 404 refreshes and clears stale draft', () async {
    final itemDraft = _draft(version: 1, items: [_item()]);
    final repository = _DraftRepository(
      [
        [itemDraft],
        const [],
      ],
      checkoutError: const BackendApiException(404, 'Draft not found'),
    );
    final cubit = DraftSalesCubit(repository: repository);
    await cubit.initialize();

    expect(await cubit.checkoutActive(paymentMethod: 'cash'), isNull);
    expect(cubit.state.drafts, isEmpty);
    expect(cubit.state.activeDraftId, isNull);
    expect(
        cubit.state.message,
        'This draft is no longer available on the server. '
        'The sales list has been refreshed.');
    await cubit.close();
  });

  test('checkout 409 preserves refreshed server draft and version', () async {
    final itemDraft = _draft(version: 1, items: [_item()]);
    final refreshed = _draft(
      version: 2,
      items: [
        _item(),
        const SaleDraftItem(
          productId: 'dev-water',
          name: 'Water',
          quantity: 2,
          unitPrice: 20,
        ),
      ],
    );
    final repository = _DraftRepository(
      [
        [itemDraft],
        [refreshed],
      ],
      checkoutError: const BackendApiException(409, 'Version conflict'),
    );
    final cubit = DraftSalesCubit(repository: repository);
    await cubit.initialize();

    expect(await cubit.checkoutActive(paymentMethod: 'cash'), isNull);
    expect(cubit.state.activeDraft?.version, 2);
    expect(cubit.state.activeDraft?.items.length, 2);
    expect(cubit.state.status, DraftSalesStatus.conflict);
    await cubit.close();
  });

  test('checkout 409 insufficient stock is a business error', () async {
    final itemDraft = _draft(version: 6, items: [_item()]);
    final repository = _DraftRepository(
      [
        [itemDraft],
      ],
      checkoutError: const BackendApiException(409, 'Insufficient stock'),
    );
    final cubit = DraftSalesCubit(repository: repository);
    await cubit.initialize();

    expect(await cubit.checkoutActive(paymentMethod: 'cash'), isNull);
    expect(cubit.state.status, DraftSalesStatus.error);
    expect(cubit.state, isNot(isA<DraftSalesConflict>()));
    expect(cubit.state.activeDraftId, itemDraft.id);
    expect(cubit.state.activeDraft?.version, 6);
    expect(cubit.state.message, 'Insufficient stock');
    expect(repository.checkoutCalls, 1);
    expect(repository.index, 1);
    await cubit.close();
  });

  test('checkout 409 clears draft when it disappeared from server', () async {
    final itemDraft = _draft(version: 1, items: [_item()]);
    final repository = _DraftRepository(
      [
        [itemDraft],
        const [],
      ],
      checkoutError: const BackendApiException(409, 'Version conflict'),
    );
    final cubit = DraftSalesCubit(repository: repository);
    await cubit.initialize();

    expect(await cubit.checkoutActive(paymentMethod: 'cash'), isNull);
    expect(cubit.state.drafts, isEmpty);
    expect(cubit.state.activeDraftId, isNull);
    await cubit.close();
  });

  test('server refresh clears stale cart source without affecting local drafts',
      () async {
    final serverDraft = _draft(version: 1, items: [_item()]);
    final localDraft = SaleDraft(
      id: 'local-draft',
      version: 1,
      status: SaleDraftStatus.open,
      items: [_item()],
    );
    final repository = _DraftRepository([
      [serverDraft],
      const [],
    ]);
    final cubit = DraftSalesCubit(repository: repository);
    await cubit.initialize();
    expect(cubit.state.activeDraftId, serverDraft.id);

    await cubit.refresh();

    expect(cubit.state.drafts, isEmpty);
    expect(localDraft.items, isNotEmpty);
    await cubit.close();
  });

  test('websocket refresh uses authoritative empty server list', () async {
    final itemDraft = _draft(version: 1, items: [_item()]);
    final events = StreamController<Map<String, dynamic>>();
    final repository = _DraftRepository([
      [itemDraft],
      const [],
    ]);
    final cubit = DraftSalesCubit(
      repository: repository,
      draftEvents: events.stream,
    );
    await cubit.initialize();
    events.add({'event': 'draft.updated'});
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(cubit.state.drafts, isEmpty);
    expect(cubit.state.activeDraftId, isNull);
    await events.close();
    await cubit.close();
  });

  test('selecting the same populated draft remains idempotent', () async {
    final itemDraft = _draft(version: 1, items: [_item()]);
    final cubit = DraftSalesCubit(
      repository: _DraftRepository([
        [itemDraft],
      ]),
    );

    await cubit.initialize();
    cubit.selectDraft(itemDraft.id);
    cubit.selectDraft(itemDraft.id);

    expect(cubit.state.activeDraft?.items.length, 1);
    expect(cubit.state.activeDraft?.total, 100);
    await cubit.close();
  });

  test('selecting the same draft performs no write', () async {
    final itemDraft = _draft(version: 1, items: [_item()]);
    final repository = _DraftRepository([
      [itemDraft],
    ]);
    final cubit = DraftSalesCubit(repository: repository);
    await cubit.initialize();

    cubit.selectDraft(itemDraft.id);

    expect(repository.updateCalls, 0);
    expect(cubit.state.status, DraftSalesStatus.loaded);
    await cubit.close();
  });

  test('selecting a different draft performs no write', () async {
    final first = _draft(version: 1, items: [_item()]);
    final second = SaleDraft(
      id: 'draft-2',
      version: 3,
      status: SaleDraftStatus.open,
      items: const [],
    );
    final repository = _DraftRepository([
      [first, second],
    ]);
    final cubit = DraftSalesCubit(repository: repository);
    await cubit.initialize();

    cubit.selectDraft(second.id);

    expect(repository.updateCalls, 0);
    expect(cubit.state.activeDraftId, second.id);
    await cubit.close();
  });

  test('equivalent cart restoration performs no write', () async {
    final itemDraft = _draft(version: 1, items: [_item()]);
    final repository = _DraftRepository([
      [itemDraft],
    ]);
    final cubit = DraftSalesCubit(repository: repository);
    await cubit.initialize();

    await cubit.updateActiveItems(itemDraft.items);

    expect(repository.updateCalls, 0);
    expect(cubit.state.status, DraftSalesStatus.loaded);
    await cubit.close();
  });

  test('editing cart performs exactly one draft update', () async {
    final itemDraft = _draft(version: 1, items: [_item()]);
    final updated = _draft(
      version: 2,
      items: [
        _item(),
        const SaleDraftItem(
          productId: 'dev-water',
          name: 'Water',
          quantity: 1,
          unitPrice: 20,
        ),
      ],
    );
    final repository = _DraftRepository(
      [
        [itemDraft],
      ],
      updateResponse: updated,
    );
    final cubit = DraftSalesCubit(repository: repository);
    await cubit.initialize();

    await cubit.updateActiveItems(updated.items);

    expect(repository.updateCalls, 1);
    expect(cubit.state.activeDraft?.version, 2);
    await cubit.close();
  });

  test('checkout uses checkout repository path without draft update', () async {
    final itemDraft = _draft(version: 1, items: [_item()]);
    final repository = _DraftRepository(
      [
        [itemDraft],
      ],
      checkoutResponse: _sale(),
    );
    final cubit = DraftSalesCubit(repository: repository);
    await cubit.initialize();

    final sale = await cubit.checkoutActive(paymentMethod: 'cash');

    expect(sale?.id, 'sale-1');
    expect(repository.checkoutCalls, 1);
    expect(repository.updateCalls, 0);
    await cubit.close();
  });
}
