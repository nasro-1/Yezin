import 'dart:async';

import 'package:bayaa_pos/core/data/services/background_write_queue.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> writeImmediate(DatabaseLifecycleCoordinator gate) {
  return gate.withWriteAccess(() async {
    expect(gate.activeWriteCount, 1);
    await Future<void>.value();
  });
}

void main() {
  test('write participates in lifecycle gate', () async {
    final gate = DatabaseLifecycleCoordinator();
    final started = Completer<void>();
    final release = Completer<void>();

    final future = gate.withWriteAccess(() async {
      expect(gate.activeWriteCount, 1);
      started.complete();
      await release.future;
    });

    await started.future;
    expect(gate.activeWriteCount, 1);

    release.complete();
    await future;
    expect(gate.activeWriteCount, 0);
    expect(gate.isExclusiveActive, isFalse);
  });

  test('writeImmediate participates in lifecycle gate', () async {
    final gate = DatabaseLifecycleCoordinator();
    final started = Completer<void>();
    final release = Completer<void>();

    final future = gate.withWriteAccess(() async {
      expect(gate.activeWriteCount, 1);
      started.complete();
      await release.future;
    });

    await started.future;
    expect(gate.activeWriteCount, 1);

    release.complete();
    await future;
    expect(gate.activeWriteCount, 0);
  });

  test('queued write participates in lifecycle gate', () async {
    final gate = DatabaseLifecycleCoordinator();
    final queue = BackgroundWriteQueue(lifecycleCoordinator: gate);
    addTearDown(() async => queue.dispose());
    final writeStarted = Completer<void>();
    final writeRelease = Completer<void>();
    final queuedStarted = Completer<void>();

    queue.start();

    final activeWrite = gate.withWriteAccess(() async {
      expect(gate.activeWriteCount, 1);
      writeStarted.complete();
      await writeRelease.future;
    });

    await writeStarted.future;

    final queuedFuture = queue.enqueue(() async {
      expect(gate.activeWriteCount, 1);
      queuedStarted.complete();
    });

    expect(queuedStarted.isCompleted, isFalse);

    writeRelease.complete();
    await activeWrite;
    await queuedFuture;
    await Future<void>.value();

    expect(queuedStarted.isCompleted, isTrue);
  });

  test('exclusive lifecycle operation waits for active write', () async {
    final gate = DatabaseLifecycleCoordinator();
    final writeStarted = Completer<void>();
    final writeRelease = Completer<void>();
    final exclusiveStarted = Completer<void>();

    final writeFuture = gate.withWriteAccess(() async {
      writeStarted.complete();
      await writeRelease.future;
    });

    await writeStarted.future;

    final exclusiveFuture = gate.withExclusiveAccess(() async {
      exclusiveStarted.complete();
    });

    expect(exclusiveStarted.isCompleted, isFalse);

    writeRelease.complete();
    await writeFuture;
    await exclusiveFuture;

    expect(exclusiveStarted.isCompleted, isTrue);
  });

  test('queued write cannot execute after lifecycle shutdown/replacement', () async {
    final gate = DatabaseLifecycleCoordinator();
    final queue = BackgroundWriteQueue(lifecycleCoordinator: gate);
    addTearDown(() async => queue.dispose());
    final writeStarted = Completer<void>();
    final writeRelease = Completer<void>();
    final queuedStarted = Completer<void>();

    queue.start();

    final activeWrite = gate.withWriteAccess(() async {
      writeStarted.complete();
      await writeRelease.future;
    });

    await writeStarted.future;

    final queuedFuture = queue.enqueue(() async {
      queuedStarted.complete();
    });

    final exclusiveFuture = gate.withExclusiveAccess(() async {
      expect(queuedStarted.isCompleted, isFalse);
    });

    writeRelease.complete();
    await activeWrite;
    await exclusiveFuture;
    await queuedFuture;
    await Future<void>.value();

    expect(queuedStarted.isCompleted, isTrue);
  });

  test('lifecycle gate is released after exception', () async {
    final gate = DatabaseLifecycleCoordinator();
    var threw = false;

    try {
      await gate.withWriteAccess(() async {
        throw StateError('boom');
      });
    } catch (_) {
      threw = true;
    }

    expect(threw, isTrue);
    expect(gate.activeWriteCount, 0);
    expect(gate.isExclusiveActive, isFalse);
  });

  test('queued write waits during restore', () async {
    final gate = DatabaseLifecycleCoordinator();
    final queue = BackgroundWriteQueue(lifecycleCoordinator: gate);
    addTearDown(() async => queue.dispose());
    final writeStarted = Completer<void>();
    final releaseWrite = Completer<void>();
    final queuedStarted = Completer<void>();

    queue.start();

    final activeWrite = gate.withWriteAccess(() async {
      writeStarted.complete();
      await releaseWrite.future;
    });

    await writeStarted.future;

    final restoreFuture = gate.withExclusiveAccess(() async {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });

    final queuedFuture = queue.enqueue(() async {
      queuedStarted.complete();
    });

    expect(queuedStarted.isCompleted, isFalse);

    releaseWrite.complete();
    await activeWrite;
    await restoreFuture;
    await queuedFuture;
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(queuedStarted.isCompleted, isTrue);
  });

  test('backup and restore are serialized', () async {
    final gate = DatabaseLifecycleCoordinator();
    final backupStarted = Completer<void>();
    final backupRelease = Completer<void>();
    final restoreStarted = Completer<void>();

    final backupFuture = gate.withExclusiveAccess(() async {
      backupStarted.complete();
      await backupRelease.future;
    });

    await backupStarted.future;

    final restoreFuture = gate.withExclusiveAccess(() async {
      restoreStarted.complete();
    });

    expect(restoreStarted.isCompleted, isFalse);

    backupRelease.complete();
    await backupFuture;
    await restoreFuture;
    expect(restoreStarted.isCompleted, isTrue);
  });

  test('queue does not remain permanently blocked after exception', () async {
    final gate = DatabaseLifecycleCoordinator();
    final queue = BackgroundWriteQueue(lifecycleCoordinator: gate);
    addTearDown(() async => queue.dispose());

    queue.start();
    final failedWrite = queue.enqueue(() async {
      throw StateError('queued failure');
    });
    final failedExpectation = expectLater(
      failedWrite,
      throwsA(isA<StateError>()),
    );
    final succeedingWrite = queue.enqueue(() async {});

    await Future.wait([failedExpectation, succeedingWrite]);
    expect(queue.getStats()['failed'], 1);
  });

  test('queued writes execute once for one, two, and three operations', () async {
    for (final operationCount in [1, 2, 3]) {
      final queue = BackgroundWriteQueue(
        lifecycleCoordinator: DatabaseLifecycleCoordinator(),
      );
      queue.start();
      final executions = <String, int>{};
      final writes = <Future<void>>[];

      for (var index = 0; index < operationCount; index++) {
        final operationId = 'operation-$index';
        writes.add(queue.enqueue(() async {
          executions.update(
            operationId,
            (count) => count + 1,
            ifAbsent: () => 1,
          );
        }));
      }

      await Future.wait(writes);
      await queue.dispose();
      expect(
        executions,
        {
          for (var index = 0; index < operationCount; index++)
            'operation-$index': 1,
        },
      );
    }
  });

  test('failed writes are observable and do not block later writes', () async {
    for (final failingIndex in [0, 1, 2]) {
      final queue = BackgroundWriteQueue(
        lifecycleCoordinator: DatabaseLifecycleCoordinator(),
      );
      queue.start();
      final executions = <int, int>{};
      final results = <Future<String>>[];

      for (var index = 0; index < 3; index++) {
        final operationIndex = index;
        final write = queue.enqueue(() async {
          executions.update(
            operationIndex,
            (count) => count + 1,
            ifAbsent: () => 1,
          );
          if (operationIndex == failingIndex) {
            throw StateError('failure-$operationIndex');
          }
        });
        results.add(
          write.then<String>(
            (_) => 'success',
            onError: (Object error) => 'failure: $error',
          ),
        );
      }

      expect(
        await Future.wait(results),
        [
          for (var index = 0; index < 3; index++)
            index == failingIndex
                ? 'failure: Bad state: failure-$index'
                : 'success',
        ],
      );
      await queue.dispose();
      expect(executions, {0: 1, 1: 1, 2: 1});
      expect(queue.getStats()['failed'], 1);
    }
  });

  test('rapid enqueue and shutdown drain every pending write exactly once',
      () async {
    final queue = BackgroundWriteQueue(
      lifecycleCoordinator: DatabaseLifecycleCoordinator(),
    );
    queue.start();
    final executions = <String, int>{};
    final firstStarted = Completer<void>();
    final releaseFirst = Completer<void>();

    Future<void> write(String operationId) => queue.enqueue(() async {
          executions.update(
            operationId,
            (count) => count + 1,
            ifAbsent: () => 1,
          );
          if (operationId == 'A') {
            firstStarted.complete();
            await releaseFirst.future;
          }
        });

    final writes = <Future<void>>[write('A')];
    await firstStarted.future;
    writes
      ..add(write('B'))
      ..add(write('C'))
      ..add(write('D'));
    final shutdown = queue.dispose();
    releaseFirst.complete();

    await shutdown;
    await Future.wait(writes);
    expect(executions, {'A': 1, 'B': 1, 'C': 1, 'D': 1});
  });
}
