import 'package:flutter_test/flutter_test.dart';

import 'package:bayaa_pos/core/network/authority_context.dart';

void main() {
  test('mixed read and write authority is rejected', () {
    expect(
      () => AuthorityContext.requireConsistent(
        readMode: AuthorityMode.local,
        writeMode: AuthorityMode.server,
      ),
      throwsArgumentError,
    );
  });

  test('local authority remains explicitly local', () {
    final context = AuthorityContext(
      readMode: AuthorityMode.local,
      writeMode: AuthorityMode.local,
    );

    expect(context.allowsLocalRead, isTrue);
    expect(context.allowsLocalWrite, isTrue);
    expect(context.readsFromServer, isFalse);
    expect(context.writesToServer, isFalse);
  });
}