enum BackendApiErrorKind {
  authentication,
  authorization,
  notFound,
  conflict,
  validation,
  server,
  connection,
  timeout,
  protocol,
}

BackendApiErrorKind backendApiErrorKindForStatus(int statusCode) {
  if (statusCode == 401) return BackendApiErrorKind.authentication;
  if (statusCode == 403) return BackendApiErrorKind.authorization;
  if (statusCode == 404) return BackendApiErrorKind.notFound;
  if (statusCode == 409) return BackendApiErrorKind.conflict;
  if (statusCode == 422 || statusCode == 400) {
    return BackendApiErrorKind.validation;
  }
  if (statusCode >= 500) return BackendApiErrorKind.server;
  return BackendApiErrorKind.protocol;
}

class BackendApiException implements Exception {
  const BackendApiException(
    this.statusCode,
    this.message, {
    this.kind,
    this.requestId,
  });

  final int statusCode;
  final String message;
  final BackendApiErrorKind? kind;
  final String? requestId;

  BackendApiErrorKind get errorKind =>
      kind ?? backendApiErrorKindForStatus(statusCode);

  bool get isAuthenticationError =>
      errorKind == BackendApiErrorKind.authentication;

  @override
  String toString() => 'BackendApiException($statusCode): $message';
}
