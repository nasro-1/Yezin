import 'backend_api_config.dart';

enum AuthorityMode { local, server }

class AuthorityContext {
  factory AuthorityContext({
    required AuthorityMode readMode,
    required AuthorityMode writeMode,
  }) {
    return AuthorityContext._(
      readMode: readMode,
      writeMode: writeMode,
    );
  }

  static void requireConsistent({
    required AuthorityMode readMode,
    required AuthorityMode writeMode,
  }) {
    if (readMode != writeMode) {
      throw ArgumentError(
        'Read and write authority must use the same mode.',
      );
    }
  }

  const AuthorityContext._({
    required this.readMode,
    required this.writeMode,
  });

  factory AuthorityContext.fromProductConfig() {
    final context = AuthorityContext(
      readMode: BackendApiConfig.productReadMode == ProductReadMode.server
          ? AuthorityMode.server
          : AuthorityMode.local,
      writeMode: BackendApiConfig.productWriteMode == ProductWriteMode.server
          ? AuthorityMode.server
          : AuthorityMode.local,
    );
    requireConsistent(
      readMode: context.readMode,
      writeMode: context.writeMode,
    );
    return context;
  }

  final AuthorityMode readMode;
  final AuthorityMode writeMode;

  bool get readsFromServer => readMode == AuthorityMode.server;
  bool get writesToServer => writeMode == AuthorityMode.server;

  /// Sales drafts follow the write authority, so local mode remains entirely
  /// on the existing SQLite/cart path.
  bool get usesServerDrafts => writesToServer;
  bool get allowsLocalRead => !readsFromServer;
  bool get allowsLocalWrite => !writesToServer;
}
