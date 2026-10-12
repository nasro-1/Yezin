class BackendAuthContext {
  const BackendAuthContext({
    required this.accessToken,
    this.userId,
    this.shopId,
    this.deviceId,
    this.role,
  });

  final String accessToken;
  final String? userId;
  final String? shopId;
  final String? deviceId;
  final String? role;

  BackendAuthContext copyWith({
    String? accessToken,
    String? userId,
    String? shopId,
    String? deviceId,
    String? role,
  }) {
    return BackendAuthContext(
      accessToken: accessToken ?? this.accessToken,
      userId: userId ?? this.userId,
      shopId: shopId ?? this.shopId,
      deviceId: deviceId ?? this.deviceId,
      role: role ?? this.role,
    );
  }
}

class BackendServerContext {
  const BackendServerContext({
    this.shopId,
    this.userId,
    this.deviceId,
    this.role,
  });

  final String? shopId;
  final String? userId;
  final String? deviceId;
  final String? role;
}

class ServerIdentityMapping {
  const ServerIdentityMapping(this.displayValue, this.serverId);

  final String displayValue;
  final String serverId;
}

class IdentityMapping<T> {
  IdentityMapping(Map<String, T> values) : _values = Map.unmodifiable(values);

  final Map<String, T> _values;

  T? serverIdFor(String displayValue) => _values[displayValue];

  String? displayValueFor(T serverId) {
    for (final entry in _values.entries) {
      if (entry.value == serverId) return entry.key;
    }
    return null;
  }

  Map<String, T> get values => _values;
}
