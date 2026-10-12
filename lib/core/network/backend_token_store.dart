class BackendTokenStore {
  String? _accessToken;
  String? _userId;
  String? _shopId;
  String? _deviceId;
  String? _role;

  String? get accessToken => _accessToken;
  String? get userId => _userId;
  String? get shopId => _shopId;
  String? get deviceId => _deviceId;
  String? get role => _role;

  void save(
    String token, {
    String? userId,
    String? shopId,
    String? deviceId,
    String? role,
  }) {
    if (token.trim().isEmpty) {
      throw ArgumentError.value(token, 'token', 'Access token cannot be empty');
    }
    _accessToken = token;
    _userId = userId;
    _shopId = shopId;
    _deviceId = deviceId;
    _role = role;
  }

  void clear() {
    _accessToken = null;
    _userId = null;
    _shopId = null;
    _deviceId = null;
    _role = null;
  }
}
