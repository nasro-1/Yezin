import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:bayaa_pos/core/data/services/background_write_queue.dart';
import 'package:bayaa_pos/core/data/services/checkpoint_service.dart';
import 'package:bayaa_pos/core/data/services/persistence_initializer.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  test('checkpoint waits for an active write and copies its committed data',
      () async {
    final scenario = await Directory.systemTemp.createTemp('bayaa_checkpoint_');
    final dataRoot = Directory(p.join(scenario.path, 'data'));
    await dataRoot.create(recursive: true);
    final configFile = File(p.join(scenario.path, 'system_config.json'));
    await configFile.writeAsString(
      jsonEncode({'data_root_path': dataRoot.path}),
      flush: true,
    );

    try {
      expect(
        await PersistenceInitializer.initialize(systemConfigFile: configFile),
        isTrue,
      );
      final manager = PersistenceInitializer.persistenceManager!;
      final gate = DatabaseLifecycleCoordinator.instance;
      final writeStarted = Completer<void>();
      final releaseWrite = Completer<void>();

      final write = gate.withWriteAccess(() async {
        await manager.sqliteManager.transaction((transaction) async {
          await transaction.insert('users', {
            'id': 'checkpoint-sentinel',
            'username': 'checkpoint-sentinel',
            'display_name': 'Checkpoint Sentinel',
            'password_hash': 'test-only',
            'role': 'manager',
            'is_active': 1,
            'created_at': DateTime.now().toIso8601String(),
          });
          writeStarted.complete();
          await releaseWrite.future;
        });
      });

      await writeStarted.future;
      final checkpointPath = manager.pathResolver.checkpointsPath;
      final checkpoint = CheckpointService().createCheckpoint(
        reason: 'concurrency-test',
      );
      expect(await Directory(checkpointPath).list().isEmpty, isTrue);

      releaseWrite.complete();
      await write;
      expect(await checkpoint, isTrue);

      final checkpointDirectory = Directory(checkpointPath)
          .listSync()
          .whereType<Directory>()
          .single;
      final databaseFile = File(
        p.join(checkpointDirectory.path, p.basename(manager.sqliteManager.databasePath)),
      );
      final snapshot = await databaseFactoryFfi.openDatabase(
        databaseFile.path,
        options: OpenDatabaseOptions(readOnly: true),
      );
      try {
        final rows = await snapshot.query(
          'users',
          columns: ['id'],
          where: 'id = ?',
          whereArgs: ['checkpoint-sentinel'],
        );
        expect(rows, hasLength(1));
      } finally {
        await snapshot.close();
      }
    } finally {
      final manager = PersistenceInitializer.persistenceManager;
      if (manager != null) {
        await manager.shutdown();
      }
      try {
        await scenario.delete(recursive: true);
      } on FileSystemException {
        // The file logger may retain its sink until the test process exits.
      }
    }
  });
}
