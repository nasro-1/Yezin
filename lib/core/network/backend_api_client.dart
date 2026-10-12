import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'backend_api_error.dart';
import 'backend_api_config.dart';
import 'backend_context.dart';
import 'backend_token_store.dart';

export 'backend_api_error.dart';

class BackendHttpResponse {
  const BackendHttpResponse(this.statusCode, this.body, {this.contentType});

  final int statusCode;
  final String body;
  final String? contentType;
}

abstract interface class BackendHttpTransport {
  Future<BackendHttpResponse> get(
    Uri uri, {
    Map<String, String> headers = const {},
  });

  Future<BackendHttpResponse> post(
    Uri uri, {
    Map<String, String> headers = const {},
    String? body,
  });

  Future<BackendHttpResponse> put(
    Uri uri, {
    Map<String, String> headers = const {},
    String? body,
  });

  Future<BackendHttpResponse> patch(
    Uri uri, {
    Map<String, String> headers = const {},
    String? body,
  });

  Future<BackendHttpResponse> delete(
    Uri uri, {
    Map<String, String> headers = const {},
  });
}

class _AuthenticatedBackendTransport implements BackendHttpTransport {
  _AuthenticatedBackendTransport(
    this.delegate,
    this.tokenStore, {
    this.onUnauthorized,
  });

  final BackendHttpTransport delegate;
  final BackendTokenStore tokenStore;
  final VoidCallback? onUnauthorized;

  Future<BackendHttpResponse> _request(
    Future<BackendHttpResponse> request,
  ) async {
    final response = await request;
    if (response.statusCode == 401) {
      onUnauthorized?.call();
    }
    return response;
  }

  Map<String, String> _headers(Map<String, String> headers) {
    final token = tokenStore.accessToken;
    if (token == null) return headers;
    final resolved = headers.map(
      (key, value) => MapEntry(
        key,
        key.toLowerCase() == 'authorization' && value == '******'
            ? 'Bearer $token'
            : key.toLowerCase() == 'content-type' && value == 'application/json'
                ? 'application/json; charset=utf-8'
                : value,
      ),
    );
    final deviceId = tokenStore.deviceId;
    if (deviceId != null && deviceId.isNotEmpty) {
      resolved['X-Device-ID'] = deviceId;
    }
    return resolved;
  }

  @override
  Future<BackendHttpResponse> get(
    Uri uri, {
    Map<String, String> headers = const {},
  }) =>
      _request(delegate.get(uri, headers: _headers(headers)));

  @override
  Future<BackendHttpResponse> post(
    Uri uri, {
    Map<String, String> headers = const {},
    String? body,
  }) =>
      _request(delegate.post(uri, headers: _headers(headers), body: body));

  @override
  Future<BackendHttpResponse> put(
    Uri uri, {
    Map<String, String> headers = const {},
    String? body,
  }) =>
      _request(delegate.put(uri, headers: _headers(headers), body: body));

  @override
  Future<BackendHttpResponse> patch(
    Uri uri, {
    Map<String, String> headers = const {},
    String? body,
  }) =>
      _request(delegate.patch(uri, headers: _headers(headers), body: body));

  @override
  Future<BackendHttpResponse> delete(
    Uri uri, {
    Map<String, String> headers = const {},
  }) =>
      _request(delegate.delete(uri, headers: _headers(headers)));
}

class IoBackendHttpTransport implements BackendHttpTransport {
  const IoBackendHttpTransport({
    this.timeout = const Duration(seconds: 30),
  });

  final Duration timeout;

  Future<BackendHttpResponse> _send(
    Future<HttpClientRequest> Function(HttpClient client) openRequest, {
    Map<String, String> headers = const {},
    String? body,
  }) async {
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final request = await openRequest(client).timeout(timeout);
      headers.forEach(request.headers.set);
      if (body != null) request.add(utf8.encode(body));
      final response = await request.close().timeout(timeout);
      return BackendHttpResponse(
        response.statusCode,
        await response.transform(utf8.decoder).join().timeout(timeout),
        contentType: response.headers.contentType?.mimeType,
      );
    } on TimeoutException {
      throw const BackendApiException(
        0,
        'Backend request timed out',
        kind: BackendApiErrorKind.timeout,
      );
    } on SocketException catch (error) {
      throw BackendApiException(
        0,
        'Could not connect to backend: ${error.message}',
        kind: BackendApiErrorKind.connection,
      );
    } on HttpException catch (error) {
      throw BackendApiException(
        0,
        'Backend transport failed: ${error.message}',
        kind: BackendApiErrorKind.connection,
      );
    } finally {
      client.close(force: true);
    }
  }

  @override
  Future<BackendHttpResponse> get(
    Uri uri, {
    Map<String, String> headers = const {},
  }) async {
    return _send((client) => client.getUrl(uri), headers: headers);
  }

  @override
  Future<BackendHttpResponse> put(
    Uri uri, {
    Map<String, String> headers = const {},
    String? body,
  }) async {
    return _send((client) => client.putUrl(uri), headers: headers, body: body);
  }

  @override
  Future<BackendHttpResponse> patch(
    Uri uri, {
    Map<String, String> headers = const {},
    String? body,
  }) async {
    return _send((client) => client.openUrl('PATCH', uri),
        headers: headers, body: body);
  }

  @override
  Future<BackendHttpResponse> post(
    Uri uri, {
    Map<String, String> headers = const {},
    String? body,
  }) async {
    return _send((client) => client.postUrl(uri), headers: headers, body: body);
  }

  @override
  Future<BackendHttpResponse> delete(
    Uri uri, {
    Map<String, String> headers = const {},
  }) async {
    return _send((client) => client.deleteUrl(uri), headers: headers);
  }
}

class _BearerAuthenticatedTransport implements BackendHttpTransport {
  _BearerAuthenticatedTransport(
      this.delegate, this.tokenStore, this.onUnauthorized);

  final BackendHttpTransport delegate;
  final BackendTokenStore tokenStore;
  final VoidCallback? onUnauthorized;

  Map<String, String> _headers(Map<String, String> headers) {
    final token = tokenStore.accessToken;
    if (token == null) return headers;
    final authenticatedHeaders = Map<String, String>.from(headers);
    final bearerHeader = 'Bearer ' + token;
    for (final key in headers.keys) {
      if (key.toLowerCase() == 'authorization') {
        authenticatedHeaders[key] = 'Bearer $token';
      }
    }
    if (authenticatedHeaders.keys.any(
      (key) => key.toLowerCase() == 'authorization',
    )) {
      for (final key in authenticatedHeaders.keys) {
        if (key.toLowerCase() == 'authorization') {
          authenticatedHeaders[key] = bearerHeader;
        }
      }
      final deviceId = tokenStore.deviceId;
      if (deviceId != null && deviceId.isNotEmpty) {
        authenticatedHeaders['X-Device-ID'] = deviceId;
      }
      return authenticatedHeaders;
    }
    final resolved = headers.map(
      (key, value) => MapEntry(
        key,
        key.toLowerCase() == 'authorization' && value == '******'
            ? 'Bearer $token'
            : key.toLowerCase() == 'content-type' && value == 'application/json'
                ? 'application/json; charset=utf-8'
                : value,
      ),
    );
    final deviceId = tokenStore.deviceId;
    if (deviceId != null && deviceId.isNotEmpty) {
      resolved['X-Device-ID'] = deviceId;
    }
    return resolved;
  }

  Future<BackendHttpResponse> _request(
    Future<BackendHttpResponse> request,
  ) async {
    final response = await request;
    if (response.statusCode == 401) onUnauthorized?.call();
    return response;
  }

  @override
  Future<BackendHttpResponse> get(Uri uri,
          {Map<String, String> headers = const {}}) =>
      _request(delegate.get(uri, headers: _headers(headers)));

  @override
  Future<BackendHttpResponse> post(
    Uri uri, {
    Map<String, String> headers = const {},
    String? body,
  }) =>
      _request(delegate.post(uri, headers: _headers(headers), body: body));

  @override
  Future<BackendHttpResponse> put(
    Uri uri, {
    Map<String, String> headers = const {},
    String? body,
  }) =>
      _request(delegate.put(uri, headers: _headers(headers), body: body));

  @override
  Future<BackendHttpResponse> patch(
    Uri uri, {
    Map<String, String> headers = const {},
    String? body,
  }) =>
      _request(delegate.patch(uri, headers: _headers(headers), body: body));

  @override
  Future<BackendHttpResponse> delete(Uri uri,
          {Map<String, String> headers = const {}}) =>
      _request(delegate.delete(uri, headers: _headers(headers)));
}

class BackendApiClient {
  BackendApiClient({
    BackendApiConfig config = const BackendApiConfig(),
    BackendTokenStore? tokenStore,
    BackendHttpTransport? transport,
    VoidCallback? onUnauthorized,
  })  : _config = config,
        tokenStore = tokenStore ?? BackendTokenStore() {
    _transport = _BearerAuthenticatedTransport(
      transport ?? const IoBackendHttpTransport(),
      this.tokenStore,
      () {
        _unauthorizedController.add(null);
        onUnauthorized?.call();
      },
    );
  }

  final BackendApiConfig _config;
  late final BackendHttpTransport _transport;
  final BackendTokenStore tokenStore;
  final StreamController<void> _unauthorizedController =
      StreamController<void>.broadcast();

  Stream<void> get unauthorizedEvents => _unauthorizedController.stream;

  void logout() => tokenStore.clear();

  Future<void> dispose() => _unauthorizedController.close();

  BackendAuthContext? get authContext {
    final token = tokenStore.accessToken;
    if (token == null) return null;
    return BackendAuthContext(
      accessToken: token,
      userId: tokenStore.userId,
      shopId: tokenStore.shopId,
      deviceId: tokenStore.deviceId,
      role: tokenStore.role,
    );
  }

  Map<String, String> _authHeaders(
    String token, {
    bool json = false,
  }) {
    return {
      'Authorization': 'Bearer $token',
      if (json) 'Content-Type': 'application/json; charset=utf-8',
    };
  }

  Map<String, String> _requestHeaders(
    String token, {
    bool json = false,
  }) {
    return {
      'Authorization': 'Bearer $token',
      if (json) 'Content-Type': 'application/json; charset=utf-8',
    };
  }

  Future<Map<String, dynamic>> login({
    required String username,
    required String password,
    String? deviceId,
  }) async {
    final headers = <String, String>{
      'Content-Type': 'application/json',
      if (deviceId != null && deviceId.isNotEmpty) 'X-Device-ID': deviceId,
    };
    final response = await _transport.post(
      _config.endpoint('/auth/login'),
      headers: headers,
      body: jsonEncode({'username': username, 'password': password}),
    );
    final payload = _decodeObject(response);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw BackendApiException(response.statusCode, _errorMessage(payload));
    }
    final token = payload['access_token'];
    if (token is! String || token.isEmpty) {
      throw const BackendApiException(
          502, 'Login response did not contain an access token');
    }
    tokenStore.save(
      token,
      userId: payload['user_id'] as String?,
      shopId: payload['shop_id'] as String?,
      deviceId: deviceId,
      role: payload['role'] as String?,
    );
    return payload;
  }

  Future<Map<String, dynamic>> getProducts({
    int page = 1,
    int pageSize = 50,
    String? search,
    bool? active = true,
    String? categoryId,
  }) {
    final query = <String, String>{
      'page': '$page',
      'page_size': '$pageSize',
      if (search != null && search.trim().isNotEmpty) 'search': search,
      if (active != null) 'active': '$active',
      if (categoryId != null && categoryId.isNotEmpty)
        'category_id': categoryId,
    };
    return _getObject('/products', query);
  }

  Future<List<Map<String, dynamic>>> getUsers() async {
    final response = await _getList('/users');
    return response
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList()
        .cast<Map<String, dynamic>>();
  }

  Future<Map<String, dynamic>> createUser(Map<String, dynamic> payload) async {
    final token = tokenStore.accessToken;
    if (token == null) {
      throw const BackendApiException(401, 'Authentication token is required');
    }
    final response = await _transport.post(
      _config.endpoint('/users'),
      headers: {
        'Authorization': '******',
        'Content-Type': 'application/json',
      },
      body: jsonEncode(payload),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final payload = _decodeJson(response);
      throw BackendApiException(
        response.statusCode,
        _errorMessage(payload, rawBody: response.body),
      );
    }
    final result = _decodeObject(response);
    return result;
  }

  Future<Map<String, dynamic>> updateUser(
    String userId,
    Map<String, dynamic> payload,
  ) async {
    final token = tokenStore.accessToken;
    if (token == null) {
      throw const BackendApiException(401, 'Authentication token is required');
    }
    final response = await _transport.patch(
      _config.endpoint('/users/${Uri.encodeComponent(userId)}'),
      headers: {
        'Authorization': '******',
        'Content-Type': 'application/json',
      },
      body: jsonEncode(payload),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final payload = _decodeJson(response);
      throw BackendApiException(
        response.statusCode,
        _errorMessage(payload, rawBody: response.body),
      );
    }
    final result = _decodeObject(response);
    return result;
  }

  Future<Map<String, dynamic>> deleteUser(String userId) async {
    final token = tokenStore.accessToken;
    if (token == null) {
      throw const BackendApiException(401, 'Authentication token is required');
    }
    final response = await _transport.delete(
      _config.endpoint('/users/${Uri.encodeComponent(userId)}'),
      headers: {'Authorization': '******'},
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final payload = _decodeJson(response);
      throw BackendApiException(
        response.statusCode,
        _errorMessage(payload, rawBody: response.body),
      );
    }
    final result = _decodeObject(response);
    return result;
  }

  Future<List<Map<String, dynamic>>> getCategories() async {
    final response = await _getList('/categories');
    return response
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList()
        .cast<Map<String, dynamic>>();
  }

  Future<Map<String, dynamic>> createCategory(String name) async {
    final token = tokenStore.accessToken;
    if (token == null) {
      throw const BackendApiException(401, 'Authentication token is required');
    }
    final response = await _transport.post(
      _config.endpoint('/categories'),
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({'name': name.trim()}),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final payload = _decodeJson(response);
      throw BackendApiException(
        response.statusCode,
        _errorMessage(payload, rawBody: response.body),
      );
    }
    final result = _decodeObject(response);
    return result;
  }

  Future<Map<String, dynamic>> deleteCategory(String categoryId) async {
    final token = tokenStore.accessToken;
    if (token == null) {
      throw const BackendApiException(401, 'Authentication token is required');
    }
    final response = await _transport.delete(
      _config.endpoint('/categories/${Uri.encodeComponent(categoryId)}'),
      headers: {'Authorization': 'Bearer $token'},
    );
    final result = _decodeObject(response);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw BackendApiException(response.statusCode, _errorMessage(result));
    }
    return result;
  }

  Future<Map<String, dynamic>> getProduct(String id) {
    return _getObject('/products/${Uri.encodeComponent(id)}');
  }

  Future<Map<String, dynamic>> postPurchase(
    Map<String, dynamic> payload, {
    required String idempotencyKey,
  }) async {
    final token = tokenStore.accessToken;
    if (token == null) {
      throw const BackendApiException(401, 'Authentication token is required');
    }
    final uri = _config.endpoint('/purchases');
    final response = await _transport.post(
      uri,
      headers: {
        'Authorization': '******',
        'Content-Type': 'application/json',
        'Idempotency-Key': idempotencyKey,
      },
      body: jsonEncode({...payload, 'idempotency_key': idempotencyKey}),
    );
    _logHttpTrace('POST', uri, response, jsonEncode(payload));
    final result = _decodeObject(response);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw BackendApiException(response.statusCode, _errorMessage(result));
    }
    return result;
  }

  Future<Map<String, dynamic>> getSuppliers({String? search}) =>
      _getObject('/suppliers', {
        if (search != null && search.trim().isNotEmpty) 'search': search.trim(),
      });

  Future<Map<String, dynamic>> getSupplier(String supplierId) =>
      _getObject('/suppliers/${Uri.encodeComponent(supplierId)}');

  Future<Map<String, dynamic>> createSupplier(
    Map<String, dynamic> payload,
  ) async =>
      _supplierRequest('POST', '/suppliers', payload);

  Future<Map<String, dynamic>> updateSupplier(
    String supplierId,
    Map<String, dynamic> payload,
  ) async =>
      _supplierRequest(
        'PUT',
        '/suppliers/${Uri.encodeComponent(supplierId)}',
        payload,
      );

  Future<Map<String, dynamic>> deleteSupplier(String supplierId) async =>
      _supplierRequest(
        'DELETE',
        '/suppliers/${Uri.encodeComponent(supplierId)}',
      );

  Future<List<dynamic>> getSupplierLedger(String supplierId) async {
    final payload = await _getAny(
      '/suppliers/${Uri.encodeComponent(supplierId)}/ledger',
    );
    if (payload is! List) {
      throw const FormatException('Expected a supplier ledger list response');
    }
    return payload;
  }

  Future<Map<String, dynamic>> getSupplierBalance(String supplierId) =>
      _getObject('/suppliers/${Uri.encodeComponent(supplierId)}/balance');

  Future<Map<String, dynamic>> postSupplierPayment(
    String supplierId,
    Map<String, dynamic> payload, {
    required String idempotencyKey,
  }) async {
    final token = tokenStore.accessToken;
    if (token == null) {
      throw const BackendApiException(401, 'Authentication token is required');
    }
    final uri = _config.endpoint(
      '/suppliers/${Uri.encodeComponent(supplierId)}/payments',
    );
    final requestPayload = {
      ...payload,
      'idempotency_key': idempotencyKey,
    };
    final body = jsonEncode(requestPayload);
    final response = await _transport.post(
      uri,
      headers: {
        'Authorization': '******',
        'Content-Type': 'application/json',
        'Idempotency-Key': idempotencyKey,
      },
      body: body,
    );
    _logHttpTrace('POST', uri, response, body);
    final result = _decodeObject(response);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw BackendApiException(response.statusCode, _errorMessage(result));
    }
    return result;
  }

  Future<Map<String, dynamic>> postSupplierReturn(
    String supplierId,
    Map<String, dynamic> payload, {
    required String idempotencyKey,
  }) async {
    final token = tokenStore.accessToken;
    if (token == null) {
      throw const BackendApiException(401, 'Authentication token is required');
    }
    final uri = _config.endpoint(
      '/suppliers/${Uri.encodeComponent(supplierId)}/returns',
    );
    final requestPayload = {
      ...payload,
      'idempotency_key': idempotencyKey,
    };
    final body = jsonEncode(requestPayload);
    final response = await _transport.post(
      uri,
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
        'Idempotency-Key': idempotencyKey,
      },
      body: body,
    );
    _logHttpTrace('POST', uri, response, body);
    final result = _decodeObject(response);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw BackendApiException(response.statusCode, _errorMessage(result));
    }
    return result;
  }

  Future<Map<String, dynamic>> getPurchases({
    int page = 1,
    int pageSize = 50,
  }) =>
      _getObject('/purchases', {
        'page': '$page',
        'page_size': '$pageSize',
      });

  Future<Map<String, dynamic>> getPurchase(String purchaseId) =>
      _getObject('/purchases/${Uri.encodeComponent(purchaseId)}');

  Future<List<dynamic>> getProductPurchaseHistory(String productId) async {
    final payload = await _getAny(
      '/products/${Uri.encodeComponent(productId)}/purchase-history',
    );
    if (payload is! List) {
      throw const FormatException('Expected a product purchase history list');
    }
    return payload;
  }

  Future<Map<String, dynamic>> _supplierRequest(
    String method,
    String path, [
    Map<String, dynamic>? payload,
  ]) async {
    final token = tokenStore.accessToken;
    if (token == null) {
      throw const BackendApiException(401, 'Authentication token is required');
    }
    final uri = _config.endpoint(path);
    final headers = <String, String>{
      'Authorization': '******',
      if (payload != null) 'Content-Type': 'application/json',
    };
    final body = payload == null ? null : jsonEncode(payload);
    final response = switch (method) {
      'POST' => await _transport.post(uri, headers: headers, body: body),
      'PUT' => await _transport.put(uri, headers: headers, body: body),
      'DELETE' => await _transport.delete(uri, headers: headers),
      _ => throw ArgumentError.value(method, 'method'),
    };
    _logHttpTrace(method, uri, response, body);
    final result = _decodeObject(response);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw BackendApiException(response.statusCode, _errorMessage(result));
    }
    return result;
  }

  Future<List<dynamic>> getProductStockMovements(String productId) async {
    final payload = await _getAny(
      '/products/${Uri.encodeComponent(productId)}/stock-movements',
    );
    if (payload is! List) {
      throw const FormatException('Expected a stock movement list response');
    }
    return payload;
  }

  Future<List<dynamic>> getProductFifoLayers(String productId) async {
    final payload = await _getAny(
      '/products/${Uri.encodeComponent(productId)}/fifo-layers',
    );
    if (payload is! List) {
      throw const FormatException('Expected a FIFO layer list response');
    }
    return payload;
  }

  Future<Map<String, dynamic>> postProductFifoCostCorrection(
      String productId, Map<String, dynamic> payload,
      {required String idempotencyKey}) async {
    final token = tokenStore.accessToken;
    if (token == null) {
      throw const BackendApiException(401, 'Authentication token is required');
    }
    final uri = _config.endpoint(
      '/products/${Uri.encodeComponent(productId)}/fifo-cost-corrections',
    );
    final response = await _transport.post(
      uri,
      headers: {
        'Authorization': '******',
        'Content-Type': 'application/json',
        'Idempotency-Key': idempotencyKey,
      },
      body: jsonEncode(payload),
    );
    final result = _decodeObject(response);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw BackendApiException(response.statusCode, _errorMessage(result));
    }
    return result;
  }

  Future<Map<String, dynamic>> getProductByBarcode(String barcode) {
    return _getObject('/products/barcode/${Uri.encodeComponent(barcode)}');
  }

  // TODO: remove this stale nested helper after the transport cleanup.
  // ignore: unused_element
  Future<Map<String, dynamic>> updateProduct(
    String productId,
    Map<String, dynamic> payload,
  ) async {
    final token = tokenStore.accessToken;
    if (token == null) {
      throw const BackendApiException(401, 'Authentication token is required');
    }
    final uri = _config.endpoint('/products/${Uri.encodeComponent(productId)}');
    final response = await _transport.put(
      uri,
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      },
      body: jsonEncode(payload),
    );
    if (kDebugMode) {
      debugPrint('[BackendApiClient] PUT $uri -> ${response.statusCode}');
    }
    final result = _decodeObject(response);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw BackendApiException(response.statusCode, _errorMessage(result));
    }
    return result;
  }

  Future<Map<String, dynamic>> createProduct(
    Map<String, dynamic> payload,
  ) async {
    final token = tokenStore.accessToken;
    if (token == null) {
      throw const BackendApiException(401, 'Authentication token is required');
    }

    Future<Map<String, dynamic>> updateProduct(
      String productId,
      Map<String, dynamic> payload,
    ) async {
      final token = tokenStore.accessToken;
      if (token == null) {
        throw const BackendApiException(
            401, 'Authentication token is required');
      }
      final uri =
          _config.endpoint('/products/${Uri.encodeComponent(productId)}');
      final response = await _transport.put(
        uri,
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode(payload),
      );
      if (kDebugMode) {
        debugPrint('[BackendApiClient] PUT $uri -> ${response.statusCode}');
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final errorPayload = _decodeJson(response);
        throw BackendApiException(
          response.statusCode,
          _errorMessage(errorPayload, rawBody: response.body),
        );
      }
      final result = _decodeObject(response);
      return result;
    }

    final uri = _config.endpoint('/products');
    final response = await _transport.post(
      uri,
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      },
      body: jsonEncode(payload),
    );
    if (kDebugMode) {
      debugPrint('[BackendApiClient] POST $uri -> ${response.statusCode}');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final errorPayload = _decodeJson(response);
      throw BackendApiException(
        response.statusCode,
        _errorMessage(errorPayload, rawBody: response.body),
      );
    }
    final result = _decodeObject(response);
    return result;
  }

  Future<Map<String, dynamic>> deleteProduct(String productId) async {
    final token = tokenStore.accessToken;
    if (token == null) {
      throw const BackendApiException(401, 'Authentication token is required');
    }
    final uri = _config.endpoint('/products/${Uri.encodeComponent(productId)}');
    final response = await _transport.delete(
      uri,
      headers: {'Authorization': 'Bearer $token'},
    );
    if (kDebugMode) {
      debugPrint('[BackendApiClient] DELETE $uri -> ${response.statusCode}');
    }
    final result = _decodeObject(response);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw BackendApiException(response.statusCode, _errorMessage(result));
    }
    return result;
  }

  Future<Map<String, dynamic>> postStockAdjustment(
    Map<String, dynamic> payload,
  ) async {
    final token = tokenStore.accessToken;
    if (token == null) {
      throw const BackendApiException(401, 'Authentication token is required');
    }
    final uri = _config.endpoint('/stock/adjustments');
    final response = await _transport.post(
      uri,
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      },
      body: jsonEncode(payload),
    );
    if (kDebugMode) {
      debugPrint('[BackendApiClient] POST $uri -> ${response.statusCode}');
    }
    final result = _decodeObject(response);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw BackendApiException(response.statusCode, _errorMessage(result));
    }
    return result;
  }

  Future<Map<String, dynamic>> postSale(
    Map<String, dynamic> payload, {
    required String idempotencyKey,
  }) async {
    final token = tokenStore.accessToken;
    if (token == null) {
      throw const BackendApiException(401, 'Authentication token is required');
    }
    final response = await _transport.post(
      _config.endpoint('/sales'),
      headers: {
        'Authorization': '******',
        'Content-Type': 'application/json',
        'Idempotency-Key': idempotencyKey,
      },
      body: jsonEncode({...payload, 'idempotency_key': idempotencyKey}),
    );
    final result = _decodeObject(response);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw BackendApiException(response.statusCode, _errorMessage(result));
    }
    return result;
  }

  Future<Map<String, dynamic>> getSale(String saleId) {
    return _getObject('/sales/${Uri.encodeComponent(saleId)}');
  }

  Future<Map<String, dynamic>> postRefund(
    String saleId,
    Map<String, dynamic> payload, {
    required String idempotencyKey,
  }) async {
    final token = tokenStore.accessToken;
    if (token == null) {
      throw const BackendApiException(401, 'Authentication token is required');
    }
    final response = await _transport.post(
      _config.endpoint('/sales/${Uri.encodeComponent(saleId)}/refund'),
      headers: {
        'Authorization': '******',
        'Content-Type': 'application/json',
        'Idempotency-Key': idempotencyKey,
      },
      body: jsonEncode({...payload, 'idempotency_key': idempotencyKey}),
    );
    final result = _decodeObject(response);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw BackendApiException(response.statusCode, _errorMessage(result));
    }
    return result;
  }

  Future<Map<String, dynamic>> postExchange(
    String saleId,
    Map<String, dynamic> payload, {
    required String idempotencyKey,
  }) async {
    final token = tokenStore.accessToken;
    if (token == null) {
      throw const BackendApiException(401, 'Authentication token is required');
    }
    final response = await _transport.post(
      _config.endpoint('/sales/${Uri.encodeComponent(saleId)}/exchange'),
      headers: {
        'Authorization': '******',
        'Content-Type': 'application/json',
        'Idempotency-Key': idempotencyKey,
      },
      body: jsonEncode({...payload, 'idempotency_key': idempotencyKey}),
    );
    debugPrint('[EXCHANGE_API_TRACE] method=POST '
        'url=${_config.endpoint('/sales/${Uri.encodeComponent(saleId)}/exchange')} '
        'status=${response.statusCode} response=${response.body}');
    final result = _decodeObject(response);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw BackendApiException(response.statusCode, _errorMessage(result));
    }
    return result;
  }

  Future<dynamic> getSales({
    int page = 1,
    int pageSize = 100,
    DateTime? startDate,
    DateTime? endDate,
    String? status,
  }) {
    return _getAny('/sales', {
      'page': '$page',
      'page_size': '$pageSize',
      if (startDate != null) 'date_from': _dateOnly(startDate),
      if (endDate != null) 'date_to': _dateOnly(endDate),
      if (status != null && status.isNotEmpty) 'status': status,
    });
  }

  Future<Map<String, dynamic>> getStockSummaryDetail() =>
      _getObject('/stock-summary');

  Future<Map<String, dynamic>> getAnalytics({
    DateTime? startDate,
    DateTime? endDateExclusive,
  }) =>
      _getObject('/analytics', {
        if (startDate != null) 'date_from': _dateOnly(startDate),
        if (endDateExclusive != null)
          'date_to_exclusive': _dateOnly(endDateExclusive),
      });

  String _dateOnly(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';

  Future<dynamic> getSaleDrafts({
    bool includeHeld = true,
  }) =>
      _getAny('/sales/drafts', {'include_held': '$includeHeld'});

  Future<dynamic> getDrafts({bool includeHeld = true}) =>
      getSaleDrafts(includeHeld: includeHeld);

  Future<Map<String, dynamic>> getSaleDraft(String draftId) =>
      _getObject('/sales/drafts/${Uri.encodeComponent(draftId)}');

  Future<Map<String, dynamic>> createDraft([
    Map<String, dynamic> payload = const {},
  ]) =>
      createSaleDraft(payload);

  Future<Map<String, dynamic>> createSaleDraft([
    Map<String, dynamic> payload = const {},
  ]) =>
      _draftRequest(
        'POST',
        '/sales/drafts',
        body: payload,
      );

  Future<Map<String, dynamic>> updateSaleDraft(
    String draftId,
    Map<String, dynamic> payload, {
    required int version,
  }) =>
      _draftRequest(
        'PUT',
        '/sales/drafts/${Uri.encodeComponent(draftId)}',
        version: version,
        body: payload,
      );

  Future<Map<String, dynamic>> updateDraft(
    String draftId,
    Map<String, dynamic> payload, {
    required int version,
  }) =>
      updateSaleDraft(draftId, payload, version: version);

  Future<Map<String, dynamic>> holdSaleDraft(
    String draftId, {
    required int version,
  }) =>
      _draftRequest(
        'POST',
        '/sales/drafts/${Uri.encodeComponent(draftId)}/hold',
        version: version,
      );

  Future<Map<String, dynamic>> holdDraft(
    String draftId, {
    required int version,
  }) =>
      holdSaleDraft(draftId, version: version);

  Future<Map<String, dynamic>> resumeSaleDraft(
    String draftId, {
    required int version,
  }) =>
      _draftRequest(
        'POST',
        '/sales/drafts/${Uri.encodeComponent(draftId)}/resume',
        version: version,
      );

  Future<Map<String, dynamic>> resumeDraft(
    String draftId, {
    required int version,
  }) =>
      resumeSaleDraft(draftId, version: version);

  Future<Map<String, dynamic>> deleteSaleDraft(
    String draftId, {
    required int version,
  }) =>
      _draftRequest(
        'DELETE',
        '/sales/drafts/${Uri.encodeComponent(draftId)}',
        version: version,
      );

  Future<Map<String, dynamic>> deleteDraft(
    String draftId, {
    required int version,
  }) =>
      deleteSaleDraft(draftId, version: version);

  Future<Map<String, dynamic>> clearSaleDraft(
    String draftId, {
    required int version,
  }) =>
      deleteSaleDraft(draftId, version: version);

  Future<Map<String, dynamic>> checkoutSaleDraft(
    String draftId, {
    required int version,
    required String paymentMethod,
    String? customerId,
  }) =>
      _draftRequest(
        'POST',
        '/sales/drafts/${Uri.encodeComponent(draftId)}/checkout',
        version: version,
        body: {
          'payment_method': paymentMethod,
          if (customerId != null) 'customer_id': customerId,
        },
      );

  Future<Map<String, dynamic>> checkoutDraft(
    String draftId, {
    required int version,
    required String paymentMethod,
    String? customerId,
  }) =>
      checkoutSaleDraft(
        draftId,
        version: version,
        paymentMethod: paymentMethod,
        customerId: customerId,
      );

  Future<Map<String, dynamic>> _draftRequest(
    String method,
    String path, {
    int? version,
    Map<String, dynamic>? body,
  }) async {
    final token = tokenStore.accessToken;
    if (token == null) {
      throw const BackendApiException(401, 'Authentication token is required');
    }
    final headers = <String, String>{
      'Authorization': '******',
      if (body != null || version != null) 'Content-Type': 'application/json',
      if (version != null) 'If-Match': '$version',
    };
    final uri = _config.endpoint(path);
    final encodedBody = body == null && version != null
        ? jsonEncode({'version': version})
        : body == null
            ? null
            : jsonEncode({...body, if (version != null) 'version': version});
    final response = switch (method) {
      'POST' => await _transport.post(uri, headers: headers, body: encodedBody),
      'PUT' => await _transport.put(uri, headers: headers, body: encodedBody),
      'DELETE' => await _transport.delete(uri, headers: headers),
      _ => throw ArgumentError.value(method, 'method'),
    };
    _logHttpTrace(method, uri, response, encodedBody);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw BackendApiException(
        response.statusCode,
        _errorMessage(_tryDecodeMap(response.body), rawBody: response.body),
      );
    }
    if (response.statusCode == 204 || response.body.trim().isEmpty) {
      return <String, dynamic>{};
    }
    final result = _decodeJson(response);
    if (result is! Map<String, dynamic>) {
      throw BackendApiException(
        response.statusCode,
        'Backend returned invalid JSON: expected an object',
      );
    }
    return result;
  }

  Future<dynamic> _getList(String path) async {
    final token = tokenStore.accessToken;
    if (token == null) {
      throw const BackendApiException(401, 'Authentication token is required');
    }

    final response = await _transport.get(
      _config.endpoint(path),
      headers: {'Authorization': 'Bearer $token'},
    );
    final payload = jsonDecode(response.body);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw BackendApiException(response.statusCode, _errorMessage(payload));
    }
    if (payload is! List) {
      throw const FormatException('Expected a list response');
    }
    return payload;
  }

  Future<dynamic> _getAny(
    String path, [
    Map<String, String>? queryParameters,
  ]) async {
    final token = tokenStore.accessToken;
    if (token == null) {
      throw const BackendApiException(401, 'Authentication token is required');
    }
    final response = await _transport.get(
      _config.endpoint(path, queryParameters),
      headers: {'Authorization': '******'},
    );
    final payload = _decodeJson(response);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final errorPayload = payload is Map
          ? Map<String, dynamic>.from(payload)
          : <String, dynamic>{};
      throw BackendApiException(
          response.statusCode, _errorMessage(errorPayload));
    }
    return payload;
  }

  Future<Map<String, dynamic>> _getObject(
    String path, [
    Map<String, String>? queryParameters,
  ]) async {
    final token = tokenStore.accessToken;
    if (token == null) {
      throw const BackendApiException(401, 'Authentication token is required');
    }

    // TODO: remove this stale nested helper after the transport cleanup.
    // ignore: unused_element
    Future<dynamic> getList(String path) async {
      final token = tokenStore.accessToken;
      if (token == null) {
        throw const BackendApiException(
            401, 'Authentication token is required');
      }
      final response = await _transport.get(
        _config.endpoint(path),
        headers: {'Authorization': 'Bearer $token'},
      );
      final payload = jsonDecode(response.body);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw BackendApiException(response.statusCode, _errorMessage(payload));
      }
      if (payload is! List) {
        throw const FormatException('Expected a list response');
      }
      return payload;
    }

    final response = await _transport.get(
      _config.endpoint(path, queryParameters),
      headers: {'Authorization': 'Bearer $token'},
    );
    if (kDebugMode) {
      debugPrint(
        '[BackendApiClient] GET ${_config.endpoint(path, queryParameters)} '
        '-> ${response.statusCode}',
      );
    }
    final payload = _decodeObject(response);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw BackendApiException(response.statusCode, _errorMessage(payload));
    }
    return payload;
  }

  Map<String, dynamic> _decodeObject(BackendHttpResponse response) {
    final decoded = _decodeJson(response);
    if (decoded is Map<String, dynamic>) return decoded;
    throw BackendApiException(
        response.statusCode, 'Backend returned invalid JSON');
  }

  Map<String, dynamic> _tryDecodeMap(String body) {
    try {
      final decoded = jsonDecode(body);
      return decoded is Map
          ? Map<String, dynamic>.from(decoded)
          : <String, dynamic>{};
    } on FormatException {
      return <String, dynamic>{};
    }
  }

  void _logHttpTrace(
    String method,
    Uri uri,
    BackendHttpResponse response,
    String? requestBody,
  ) {
    if (!kDebugMode) return;
    final body = response.body;
    final truncated = body.length > 1000 ? '${body.substring(0, 1000)}…' : body;
    debugPrint(
      '[HTTP_TRACE] method=$method url=$uri status=${response.statusCode} '
      'contentType=${response.contentType ?? 'unknown'} body=$truncated',
    );
    if (requestBody != null) {
      debugPrint('[HTTP_TRACE] requestBody=$requestBody');
    }
  }

  dynamic _decodeJson(BackendHttpResponse response) {
    try {
      return jsonDecode(response.body);
    } on FormatException {
      // Convert malformed server responses to one consistent API error below.
    }
    throw BackendApiException(
        response.statusCode, 'Backend returned invalid JSON');
  }

  String _errorMessage(dynamic payload, {String? rawBody}) {
    final detail = payload is Map<String, dynamic> ? payload['detail'] : null;
    if (detail is String) return detail;
    if (detail is Map && detail['message'] is String) {
      return detail['message'] as String;
    }
    if (detail is List) {
      final messages = detail
          .whereType<Map>()
          .map((item) => item['msg'])
          .whereType<String>()
          .toList();
      if (messages.isNotEmpty) return messages.join('; ');
    }
    final body = rawBody?.trim();
    if (body != null && body.isNotEmpty) {
      final truncated = body.length > 500 ? '${body.substring(0, 500)}…' : body;
      return 'Backend request failed: $truncated';
    }
    return 'Backend request failed';
  }
}
