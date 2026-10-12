enum ServerMode {
  local,
  server,
}

class ServerAuthority {
  const ServerAuthority(this.mode);

  final ServerMode mode;

  bool get isServer => mode == ServerMode.server;
  bool get isLocal => mode == ServerMode.local;
}
