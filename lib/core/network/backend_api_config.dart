enum ProductReadMode {
  local,
  server,
}

enum ProductWriteMode {
  local,
  server,
}

class BackendApiConfig {
  static const String rawProductReadMode = String.fromEnvironment(
    'BAYAA_PRODUCT_READ_MODE',
    defaultValue: 'local',
  );
  static const String rawProductWriteMode = String.fromEnvironment(
    'BAYAA_PRODUCT_WRITE_MODE',
    defaultValue: 'local',
  );
  static const String rawApiBaseUrl = String.fromEnvironment(
    'BAYAA_API_BASE_URL',
    defaultValue: 'http://127.0.0.1:8000/api/v1',
  );
  static const String rawUsername = String.fromEnvironment(
    'BAYAA_API_USERNAME',
    defaultValue: '',
  );
  static const String rawPassword = String.fromEnvironment(
    'BAYAA_API_PASSWORD',
    defaultValue: '',
  );

  static ProductReadMode get productReadMode => switch (rawProductReadMode) {
        'server' => ProductReadMode.server,
        _ => ProductReadMode.local,
      };
  static ProductWriteMode get productWriteMode => switch (rawProductWriteMode) {
        'server' => ProductWriteMode.server,
        _ => ProductWriteMode.local,
      };

  static const String defaultBaseUrl = rawApiBaseUrl;
  static const String username = rawUsername;
  static const String password = rawPassword;

  static bool get serverAuthEnabled =>
      productReadMode == ProductReadMode.server ||
      productWriteMode == ProductWriteMode.server;

  const BackendApiConfig({
    this.baseUrl = defaultBaseUrl,
  });

  final String baseUrl;

  Uri endpoint(String path, [Map<String, String>? queryParameters]) {
    final normalizedBase = baseUrl.replaceFirst(RegExp(r'/$'), '');
    final normalizedPath = path.replaceFirst(RegExp(r'^/'), '');
    return Uri.parse('$normalizedBase/$normalizedPath').replace(
      queryParameters: queryParameters,
    );
  }
}
