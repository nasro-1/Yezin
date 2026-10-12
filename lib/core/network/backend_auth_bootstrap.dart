import 'dart:io';

import 'backend_api_client.dart';
import 'backend_api_config.dart';

class BackendAuthBootstrap {
  BackendAuthBootstrap(
    this.client, {
    bool? authorityEnabled,
    String? username,
    String? password,
  })  : _authorityEnabled = authorityEnabled,
        _username = username,
        _password = password;

  final BackendApiClient client;
  final bool? _authorityEnabled;
  final String? _username;
  final String? _password;

  bool get isReady => client.tokenStore.accessToken != null;

  Future<bool> initialize() async {
    final authorityEnabled = _authorityEnabled ??
        (BackendApiConfig.productReadMode == ProductReadMode.server ||
            BackendApiConfig.productWriteMode == ProductWriteMode.server);
    if (!authorityEnabled) {
      return true;
    }
    if (isReady) return true;
    final username = (_username ?? BackendApiConfig.username).trim();
    final password = _password ?? BackendApiConfig.password;
    if (username.isEmpty || password.isEmpty) return false;

    final deviceId = 'bayaa-${Platform.localHostname}';
    await client.login(
      username: username,
      password: password,
      deviceId: deviceId,
    );
    return isReady;
  }
}
