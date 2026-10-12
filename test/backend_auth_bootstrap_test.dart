import 'dart:convert';

import 'package:bayaa_pos/core/network/backend_api_client.dart';
import 'package:bayaa_pos/core/network/backend_auth_bootstrap.dart';
import 'package:bayaa_pos/core/network/backend_token_store.dart';
import 'package:flutter_test/flutter_test.dart';

class _Transport implements BackendHttpTransport {
  Map<String, String>? headers;

  @override
  Future<BackendHttpResponse> post(Uri uri,
      {Map<String, String> headers = const {}, String? body}) async {
    this.headers = headers;
    return BackendHttpResponse(
        200,
        jsonEncode({
          'access_token': 'test-token',
          'user_id': 'user-1',
          'shop_id': 'shop-1',
          'role': 'manager',
        }));
  }

  @override
  Future<BackendHttpResponse> get(Uri uri,
          {Map<String, String> headers = const {}}) async =>
      throw UnimplementedError();
  @override
  Future<BackendHttpResponse> put(Uri uri,
          {Map<String, String> headers = const {}, String? body}) async =>
      throw UnimplementedError();
  @override
  Future<BackendHttpResponse> patch(Uri uri,
          {Map<String, String> headers = const {}, String? body}) async =>
      throw UnimplementedError();
  @override
  Future<BackendHttpResponse> delete(Uri uri,
          {Map<String, String> headers = const {}}) async =>
      throw UnimplementedError();
}

void main() {
  test('server bootstrap authenticates before repositories use context',
      () async {
    final transport = _Transport();
    final store = BackendTokenStore();
    final client = BackendApiClient(tokenStore: store, transport: transport);

    final ready = await BackendAuthBootstrap(
      client,
      authorityEnabled: true,
      username: 'testadmin',
      password: 'test-password',
    ).initialize();

    expect(ready, isTrue);
    expect(store.accessToken, 'test-token');
    expect(store.userId, 'user-1');
    expect(store.shopId, 'shop-1');
    expect(store.role, 'manager');
    expect(transport.headers?['X-Device-ID'], isNotEmpty);
  });

  test('local mode does not authenticate against backend', () async {
    final transport = _Transport();
    final client = BackendApiClient(
      tokenStore: BackendTokenStore(),
      transport: transport,
    );

    expect(
      await BackendAuthBootstrap(client, authorityEnabled: false).initialize(),
      isTrue,
    );
    expect(client.tokenStore.accessToken, isNull);
    expect(transport.headers, isNull);
  });
}
