import 'dart:convert';
import 'dart:io';
import 'dart:async';

import 'package:bayaa_pos/core/network/backend_api_client.dart';
import 'package:bayaa_pos/core/network/backend_api_config.dart';
import 'package:bayaa_pos/core/network/backend_token_store.dart';
import 'package:bayaa_pos/core/network/sale_draft_event_client.dart';
import 'package:bayaa_pos/features/sales/data/models/sale_draft_model.dart';
import 'package:bayaa_pos/features/sales/data/models/sale_model.dart';
import 'package:bayaa_pos/features/sales/data/repository/sale_draft_api_repository.dart';
import 'package:bayaa_pos/features/sales/domain/draft_sales_repository.dart';
import 'package:bayaa_pos/features/sales/presentation/cubit/draft_sales_cubit.dart';
import 'package:bayaa_pos/features/sales/presentation/cubit/draft_sales_state.dart';
import 'package:bayaa_pos/features/sales/presentation/sale_draft_grouping.dart';
import 'package:flutter_test/flutter_test.dart';

class _Transport implements BackendHttpTransport {
  _Transport(this.response);
  final BackendHttpResponse response;
  Uri? uri;
  String? body;
  Map<String, String>? headers;

  void capture(
      Uri value, Map<String, String> requestHeaders, String? requestBody) {
    uri = value;
    headers = requestHeaders;
    body = requestBody;
  }

  @override
  Future<BackendHttpResponse> get(Uri uri,
      {Map<String, String> headers = const {}}) async {
    capture(uri, headers, null);
    return response;
  }

  @override
  Future<BackendHttpResponse> post(Uri uri,
      {Map<String, String> headers = const {}, String? body}) async {
    capture(uri, headers, body);
    return response;
  }

  @override
  Future<BackendHttpResponse> put(Uri uri,
      {Map<String, String> headers = const {}, String? body}) async {
    capture(uri, headers, body);
    return response;
  }

  @override
  Future<BackendHttpResponse> patch(Uri uri,
      {Map<String, String> headers = const {}, String? body}) async {
    capture(uri, headers, body);
    return response;
  }

  @override
  Future<BackendHttpResponse> delete(Uri uri,
      {Map<String, String> headers = const {}}) async {
    capture(uri, headers, null);
    return response;
  }
}

class _Repository implements DraftSalesRepository {
  _Repository(this.drafts);
  List<SaleDraft> drafts;
  bool conflictNextUpdate = false;
  int listCalls = 0;

  @override
  Future<List<SaleDraft>> listDrafts({bool includeHeld = true}) async {
    listCalls++;
    return drafts.where((draft) => includeHeld || !draft.isHeld).toList();
  }

  @override
  Future<List<SaleDraft>> getDrafts({bool includeHeld = true}) =>
      listDrafts(includeHeld: includeHeld);

  @override
  Future<SaleDraft> createDraft() async {
    final created = SaleDraft(
      id: 'new',
      version: 1,
      status: SaleDraftStatus.open,
      items: const [],
    );
    drafts = [...drafts, created];
    return created;
  }

  @override
  Future<SaleDraft> updateDraft(String id, List<SaleDraftItem> items,
      {required int version,
      String? customerId,
      String? customerName,
      double discount = 0,
      String paymentMethod = 'cash',
      SaleDraftVisibility? visibility}) async {
    if (conflictNextUpdate) {
      conflictNextUpdate = false;
      throw const BackendApiException(409, 'version conflict');
    }
    final current = drafts.firstWhere((draft) => draft.id == id);
    final updated = current.copyWith(
      version: version + 1,
      items: items,
      visibility: visibility,
    );
    drafts = drafts.map((draft) => draft.id == id ? updated : draft).toList();
    return updated;
  }

  @override
  Future<SaleDraft> holdDraft(String id, {required int version}) async => drafts
      .firstWhere((draft) => draft.id == id)
      .copyWith(version: version + 1, status: SaleDraftStatus.held);

  @override
  Future<SaleDraft> resumeDraft(String id, {required int version}) async =>
      drafts
          .firstWhere((draft) => draft.id == id)
          .copyWith(version: version + 1, status: SaleDraftStatus.open);

  @override
  Future<void> deleteDraft(String id, {required int version}) async {
    drafts = drafts.where((draft) => draft.id != id).toList();
  }

  @override
  Future<void> clearDraft(String id, {required int version}) =>
      deleteDraft(id, version: version);

  @override
  Future<Sale> checkoutDraft(String id,
          {required int version,
          required String paymentMethod,
          String? customerId}) async =>
      Sale(
        id: 'sale-1',
        total: 0,
        items: 0,
        date: DateTime.utc(2026),
        saleItems: const [],
        cashierName: null,
      );
}

class _DelayedRepository extends _Repository {
  _DelayedRepository(super.drafts);
  final updates = <String>[];
  final release = Completer<void>();

  @override
  Future<SaleDraft> updateDraft(String id, List<SaleDraftItem> items,
      {required int version,
      String? customerId,
      String? customerName,
      double discount = 0,
      String paymentMethod = 'cash',
      SaleDraftVisibility? visibility}) async {
    updates.add(id);
    await release.future;
    return super.updateDraft(
      id,
      items,
      version: version,
      customerId: customerId,
      customerName: customerName,
      discount: discount,
      paymentMethod: paymentMethod,
      visibility: visibility,
    );
  }
}

SaleDraft _draft(String id, {SaleDraftStatus status = SaleDraftStatus.open}) =>
    SaleDraft(
      id: id,
      version: 3,
      status: status,
      items: const [
        SaleDraftItem(
          productId: 'p1',
          name: 'Coffee',
          quantity: 2,
          unitPrice: 4.5,
          unit: 'box',
        ),
      ],
    );

void main() {
  test('maps draft and decimal item fields from server JSON', () {
    final draft = SaleDraft.fromJson({
      'draft_id': 'd1',
      'sale_number': 12,
      'revision': '7',
      'customer_id': 'customer-1',
      'customer_name': 'Ahmed Ben Ali',
      'status': 'HELD',
      'visibility': 'SHARED',
      'owner_id': 'owner-9',
      'owner_name': 'Samir',
      'items': [
        {
          'product_id': 'p1',
          'product_name': 'Coffee',
          'qty': '2.5',
          'unit_price': '4.50',
          'unit': 'box',
        }
      ],
    });
    expect(draft.id, 'd1');
    expect(draft.saleNumber, 12);
    expect(draft.version, 7);
    expect(draft.customerId, 'customer-1');
    expect(draft.customerName, 'Ahmed Ben Ali');
    expect(draft.visibility, SaleDraftVisibility.shared);
    expect(draft.ownerId, 'owner-9');
    expect(draft.ownerName, 'Samir');
    expect(draft.isHeld, isTrue);
    expect(draft.items.single.lineTotal, 11.25);
  });

  test('REST draft update routes version through If-Match and payload',
      () async {
    final transport = _Transport(BackendHttpResponse(
      200,
      jsonEncode(_draft('d1').toJson()),
    ));
    final repository = SaleDraftApiRepository(BackendApiClient(
      tokenStore: BackendTokenStore()..save('token'),
      transport: transport,
    ));
    await repository.updateDraft(
      'd1',
      const [],
      version: 3,
      customerId: 'customer-1',
      customerName: 'Ahmed Ben Ali',
    );
    expect(transport.uri?.path, '/api/v1/sales/drafts/d1');
    expect(transport.headers?['If-Match'], '3');
    final body = jsonDecode(transport.body!) as Map;
    expect(body['version'], 3);
    expect(body['customer_id'], 'customer-1');
    expect(body['customer_name'], 'Ahmed Ben Ali');
  });

  test('conflicts refresh drafts and exposes conflict state', () async {
    final repository = _Repository([_draft('d1')])..conflictNextUpdate = true;
    final cubit = DraftSalesCubit(repository: repository);
    addTearDown(cubit.close);
    await cubit.initialize();
    await cubit.updateActiveItems(const []);
    expect(cubit.state.status, DraftSalesStatus.conflict);
    expect(cubit.state.conflictDraftId, 'd1');
    expect(repository.listCalls, greaterThanOrEqualTo(2));
  });

  test('selecting a draft switches the active server workspace', () async {
    final cubit = DraftSalesCubit(
        repository: _Repository([_draft('one'), _draft('two')]));
    addTearDown(cubit.close);
    await cubit.initialize();
    cubit.selectDraft('two');
    expect(cubit.state.activeDraftId, 'two');
    expect(cubit.state.activeDraft?.items.single.productId, 'p1');
  });

  test('active draft visibility uses the existing versioned update path',
      () async {
    final cubit = DraftSalesCubit(repository: _Repository([_draft('one')]));
    addTearDown(cubit.close);
    await cubit.initialize();

    await cubit.toggleActiveVisibility();
    expect(cubit.state.activeDraft?.visibility, SaleDraftVisibility.shared);
    expect(cubit.state.activeDraft?.version, 4);

    await cubit.toggleActiveVisibility();
    expect(cubit.state.activeDraft?.visibility, SaleDraftVisibility.private);
    expect(cubit.state.activeDraft?.version, 5);
  });

  test('groups cashier drafts without duplicating own shared drafts', () {
    final drafts = [
      _draft('mine-private').copyWith(ownerId: 'user-1'),
      _draft('mine-shared').copyWith(
        ownerId: 'user-1',
        visibility: SaleDraftVisibility.shared,
      ),
      _draft('other-shared').copyWith(
        ownerId: 'user-2',
        visibility: SaleDraftVisibility.shared,
      ),
      _draft('other-private').copyWith(ownerId: 'user-2'),
    ];

    final groups = groupSaleDrafts(
      drafts,
      userId: 'user-1',
      role: 'cashier',
    );
    expect(groups.map((group) => group.title), [
      'My Open Sales',
      'Shared Sales',
    ]);
    expect(groups[0].drafts.map((draft) => draft.id), [
      'mine-private',
      'mine-shared',
    ]);
    expect(groups[1].drafts.map((draft) => draft.id), ['other-shared']);
  });

  test('deduplicates draft IDs while preserving the first draft order', () {
    final groups = groupSaleDrafts(
      [
        _draft('one').copyWith(ownerId: 'user-1'),
        _draft('one').copyWith(
          ownerId: 'user-2',
          visibility: SaleDraftVisibility.shared,
        ),
        _draft('two').copyWith(
          ownerId: 'user-2',
          visibility: SaleDraftVisibility.shared,
        ),
      ],
      userId: 'user-1',
      role: 'cashier',
    );
    expect(groups.map((group) => group.title), [
      'My Open Sales',
      'Shared Sales',
    ]);
    expect(groups[0].drafts.map((draft) => draft.id), ['one']);
    expect(groups[1].drafts.map((draft) => draft.id), ['two']);
  });

  test('cubit refresh keeps each draft ID once and active draft valid',
      () async {
    final cubit = DraftSalesCubit(
        repository: _Repository([
      _draft('one'),
      _draft('one').copyWith(version: 4),
      _draft('two'),
    ]));
    addTearDown(cubit.close);

    await cubit.initialize();

    expect(cubit.state.drafts.map((draft) => draft.id), ['one', 'two']);
    expect(cubit.state.activeDraftId, 'one');
  });

  test('switching authenticated users clears the previous draft state',
      () async {
    final adminPrivate = _draft('admin-private').copyWith(ownerId: 'admin');
    final cashierShared = _draft('cashier-shared').copyWith(
      ownerId: 'admin',
      visibility: SaleDraftVisibility.shared,
    );
    final repository = _Repository([adminPrivate]);
    final cubit = DraftSalesCubit(repository: repository);
    addTearDown(cubit.close);

    await cubit.initialize();
    expect(cubit.state.drafts.map((draft) => draft.id), ['admin-private']);

    repository.drafts = [cashierShared];
    await cubit.switchUser('cashier-1');

    expect(cubit.state.drafts.map((draft) => draft.id), ['cashier-shared']);
    expect(cubit.state.drafts, isNot(contains(adminPrivate)));
    expect(cubit.state.activeDraftId, 'cashier-shared');
    expect(cubit.state.activeDraft, isNotNull);
  });

  test('groups admin drafts into one all-sales section', () {
    final drafts = [_draft('one'), _draft('one'), _draft('two')];
    final groups = groupSaleDrafts(drafts, userId: 'admin', role: 'admin');
    expect(groups.single.title, 'All Open Sales');
    expect(groups.single.drafts.map((draft) => draft.id), ['one', 'two']);
  });

  test('selector values are unique and active selection remains valid', () {
    final groups = groupSaleDrafts(
      [_draft('one'), _draft('one'), _draft('two')],
      userId: null,
      role: 'admin',
    );
    final selectable = selectableSaleDrafts(groups);
    final values = selectable.map((draft) => draft.id).toList();

    expect(values, ['one', 'two']);
    const activeId = 'two';
    expect(values.where((id) => id == activeId), [activeId]);
  });

  test('late update response cannot reactivate an older selected draft',
      () async {
    final repository = _DelayedRepository([
      _draft('one'),
      _draft('two').copyWith(items: const []),
    ]);
    final cubit = DraftSalesCubit(repository: repository);
    addTearDown(cubit.close);
    await cubit.initialize();

    final update = cubit.updateActiveItems(const []);
    cubit.selectDraft('two');
    expect(cubit.state.activeDraftId, 'two');

    repository.release.complete();
    await update;

    expect(repository.updates, ['one']);
    expect(cubit.state.activeDraftId, 'two');
    expect(cubit.state.activeDraft?.items, isEmpty);
    expect(cubit.state.drafts.firstWhere((draft) => draft.id == 'one').items,
        isEmpty);
  });

  test('websocket draft event is authenticated and delivered', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    String? authorization;
    final accepted = server.first.then((request) {
      authorization = request.headers.value('authorization');
      return WebSocketTransformer.upgrade(request);
    });
    final client = SaleDraftEventClient(
      config:
          BackendApiConfig(baseUrl: 'http://127.0.0.1:${server.port}/api/v1'),
      tokenStore: BackendTokenStore()..save('event-token'),
      connector: (_, {headers}) => WebSocket.connect(
        'ws://127.0.0.1:${server.port}',
        headers: headers,
      ),
    );
    addTearDown(client.close);
    final event = client.events.first;
    await client.connect();
    final socket = await accepted;
    expect(authorization, 'Bearer event-token');
    socket.add(jsonEncode({'draft_id': 'd1', 'version': 4}));
    expect(await event, {'draft_id': 'd1', 'version': 4});
  });
}
