import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'backend_api_config.dart';
import 'backend_token_store.dart';

typedef WebSocketConnector = Future<WebSocket> Function(
  Uri uri, {
  Map<String, dynamic>? headers,
});

/// Receives draft changes made by another terminal. It reconnects with a
/// bounded backoff and never starts a second socket while one is active.
class SaleDraftEventClient {
  SaleDraftEventClient({
    BackendApiConfig config = const BackendApiConfig(),
    required this.tokenStore,
    WebSocketConnector? connector,
    this.path = '/sales/drafts/events',
  })  : _config = config,
        _connector = connector ?? _connect;

  final BackendApiConfig _config;
  final BackendTokenStore tokenStore;
  final String path;
  final WebSocketConnector _connector;
  final StreamController<Map<String, dynamic>> _events =
      StreamController<Map<String, dynamic>>.broadcast();

  WebSocket? _socket;
  Timer? _reconnectTimer;
  bool _running = false;
  bool _connecting = false;
  int _attempt = 0;

  Stream<Map<String, dynamic>> get events => _events.stream;
  bool get isConnected => _socket != null;

  Future<void> connect() async {
    _running = true;
    _reconnectTimer?.cancel();
    await _connectNow();
  }

  Future<void> reconnect() async {
    if (!_running) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    final socket = _socket;
    _socket = null;
    await socket?.close();
    await _connectNow();
  }

  Future<void> _connectNow() async {
    if (!_running || _socket != null || _connecting) return;
    final token = tokenStore.accessToken;
    if (token == null || token.isEmpty) return;

    _connecting = true;
    final base = Uri.parse(_config.baseUrl);
    final scheme = base.scheme == 'https' ? 'wss' : 'ws';
    final basePath = base.path.replaceFirst(RegExp(r'/$'), '');
    final uri = base.replace(scheme: scheme, path: '$basePath$path');
    try {
      final socket = await _connector(
        uri,
        headers: {'Authorization': 'Bearer $token'},
      );
      if (!_running) {
        await socket.close();
        return;
      }
      _socket = socket;
      _attempt = 0;
      socket.listen(
        (message) {
          try {
            final decoded =
                jsonDecode(message is String ? message : '$message');
            if (decoded is Map) {
              _events.add(Map<String, dynamic>.from(decoded));
            }
          } on FormatException {
            // Ignore heartbeats and malformed messages; REST refresh is the
            // source of truth.
          }
        },
        onDone: _onDisconnected,
        onError: (_, __) => _onDisconnected(),
        cancelOnError: true,
      );
    } catch (_) {
      _scheduleReconnect();
    } finally {
      _connecting = false;
    }
  }

  void _onDisconnected() {
    _socket = null;
    if (_running) _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (!_running || _reconnectTimer?.isActive == true) return;
    final seconds = 1 << (_attempt > 5 ? 5 : _attempt);
    _attempt++;
    _reconnectTimer = Timer(Duration(seconds: seconds), _connectNow);
  }

  Future<void> close() async {
    _running = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    final socket = _socket;
    _socket = null;
    await socket?.close();
    await _events.close();
  }

  static Future<WebSocket> _connect(
    Uri uri, {
    Map<String, dynamic>? headers,
  }) =>
      WebSocket.connect(uri.toString(), headers: headers);
}

typedef DraftEventClient = SaleDraftEventClient;
