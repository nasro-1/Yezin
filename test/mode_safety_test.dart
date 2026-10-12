import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:bayaa_pos/core/data/services/configuration_storage.dart';
import 'package:bayaa_pos/core/data/services/debug_seeder.dart';
import 'package:bayaa_pos/core/data/services/persistence_initializer.dart';
import 'package:bayaa_pos/core/data/services/sqlite_manager.dart';
import 'package:bayaa_pos/core/di/dependency_injection.dart';
import 'package:bayaa_pos/core/security/permission_guard.dart';
import 'package:bayaa_pos/core/services/activity_logger.dart';
import 'package:bayaa_pos/core/session/session_manager.dart';
import 'package:bayaa_pos/features/auth/data/models/user_model.dart';

class _Scenario {
  final Directory baseDir;
  final Directory productionRoot;
  final Directory developmentRoot;
  final File systemConfigFile;

  const _Scenario({
    required this.baseDir,
    required this.productionRoot,
    required this.developmentRoot,
    required this.systemConfigFile,
  });
}

Future<_Scenario> _createScenario() async {
  final bayaaDir = await Directory.systemTemp.createTemp('bayaa_test_mode_');

  final productionRoot = Directory(p.join(bayaaDir.path, 'BayaaData-Production'));
  final developmentRoot = Directory(p.join(bayaaDir.path, 'BayaaData-Development'));
  await productionRoot.create(recursive: true);
  await developmentRoot.create(recursive: true);

  for (final child in ['config', 'ledger', 'ledger/archived', 'db', 'checkpoints', 'logs', 'assets']) {
    await Directory(p.join(productionRoot.path, child)).create(recursive: true);
    await Directory(p.join(developmentRoot.path, child)).create(recursive: true);
  }

  await Directory(p.join(bayaaDir.path, 'BayaaBackup')).create(recursive: true);

  return _Scenario(
    baseDir: bayaaDir,
    productionRoot: productionRoot,
    developmentRoot: developmentRoot,
    systemConfigFile: File(p.join(bayaaDir.path, 'system_config.json')),
  );
}

Future<int> _countRows(String tableName) async {
  final db = PersistenceInitializer.persistenceManager!.sqliteManager;
  final result = await db.query(tableName, columns: ['COUNT(*) as count']);
  return (result.first['count'] as int?) ?? 0;
}

Future<void> _tearDownScenario(_Scenario scenario) async {
  if (getIt.isRegistered<SessionManager>()) {
    getIt<SessionManager>().clearCurrentSession();
  }
  final existing = PersistenceInitializer.persistenceManager;
  if (existing != null) {
    try {
      await existing.shutdown();
    } catch (_) {}
  }

  await Future<void>.delayed(const Duration(milliseconds: 250));

  if (await scenario.baseDir.exists()) {
    try {
      await scenario.baseDir.delete(recursive: true);
    } catch (_) {
      // Best-effort cleanup: the test uses isolated directories and the app may still be releasing handles.
    }
  }

}

Future<bool> _initializeScenario(_Scenario scenario) async {
  await scenario.systemConfigFile.writeAsString(
    jsonEncode({'data_root_path': scenario.productionRoot.path}),
    flush: true,
  );
  final initialized = await PersistenceInitializer.initialize(
    systemConfigFile: scenario.systemConfigFile,
  );
  if (!getIt.isRegistered<ActivityLogger>()) {
    getIt.registerSingleton<ActivityLogger>(ActivityLogger());
  }
  if (initialized && getIt.isRegistered<ActivityLogger>()) {
    await getIt<ActivityLogger>().rebind();
  }
  if (getIt.isRegistered<SessionManager>()) {
    getIt<SessionManager>().clearCurrentSession();
  }
  return initialized;
}

void main() {
  group('mode safety', () {
    test('production mode is default and destructive reseed is refused', () async {
      final scenario = await _createScenario();
      try {
        final initialized = await _initializeScenario(scenario);
        expect(initialized, isTrue);

        final manager = PersistenceInitializer.persistenceManager!;
        expect(manager.config.appMode, ConfigurationStorage.productionMode);

        await DebugSeeder.clearAndReSeed();
        expect(await _countRows('users'), 0);

        await DebugSeeder.seedIfNeeded();
        expect(await _countRows('users'), 0);
      } finally {
        await _tearDownScenario(scenario);
      }
    });

    test('development mode requires a separate data root and cannot mutate production data', () async {
      final scenario = await _createScenario();
      try {
        final initialized = await _initializeScenario(scenario);
        expect(initialized, isTrue);

        final manager = PersistenceInitializer.persistenceManager!;
        await manager.sqliteManager.insert('users', {
          'id': 'prod-user',
          'username': 'prod-user',
          'display_name': 'Production user',
          'password_hash': 'secret',
          'role': 'cashier',
          'is_active': 1,
          'created_at': DateTime.now().toIso8601String(),
        }, conflictAlgorithm: ConflictAlgorithm.replace);
        expect(await _countRows('users'), 1);

        manager.config.appMode = ConfigurationStorage.developmentMode;
        manager.config.developmentDataRootPath = scenario.developmentRoot.path;
        await manager.config.save();

        await DebugSeeder.seedIfNeeded();
        expect(await _countRows('users'), 1);

        await DebugSeeder.clearAndReSeed();
        expect(await _countRows('users'), 1);
      } finally {
        await _tearDownScenario(scenario);
      }
    });

    test('development mode can seed only when the app is already using the dev root', () async {
      final scenario = await _createScenario();
      try {
        final initialized = await _initializeScenario(scenario);
        expect(initialized, isTrue);

        final manager = PersistenceInitializer.persistenceManager!;
        manager.config.appMode = ConfigurationStorage.developmentMode;
        manager.config.developmentDataRootPath = scenario.developmentRoot.path;
        await manager.config.save();
        await manager.pathResolver.applyModeSpecificDataRoot(
          appMode: ConfigurationStorage.developmentMode,
          developmentDataRootPath: scenario.developmentRoot.path,
        );
        await manager.sqliteManager.close();
        manager.sqliteManager = SQLiteManager(databasePath: manager.pathResolver.mainDatabaseFile);
        await manager.sqliteManager.initialize();

        await DebugSeeder.seedAll();
        expect(await _countRows('users'), 3);

        await DebugSeeder.seedAll();
        expect(await _countRows('users'), 3);
      } finally {
        await _tearDownScenario(scenario);
      }
    });
  });

  group('data management authorization and audit', () {
    test('cashier is blocked from administrative actions before destructive work executes', () async {
      final scenario = await _createScenario();
      try {
        final initialized = await _initializeScenario(scenario);
        expect(initialized, isTrue);

        final manager = PersistenceInitializer.persistenceManager!;
        final cashier = User(
          username: 'cashier-test',
          name: 'Cashier',
          phone: '111',
          userType: UserType.cashier,
          password: 'cashier',
        );

        await manager.sqliteManager.insert('users', {
          'id': 'cashier-user',
          'username': cashier.username,
          'display_name': cashier.name,
          'password_hash': cashier.password,
          'role': 'cashier',
          'is_active': 1,
          'created_at': DateTime.now().toIso8601String(),
        }, conflictAlgorithm: ConflictAlgorithm.replace);

        expect(await _countRows('users'), 1);
        await expectLater(
          manager.backupManager.createBackup(actingUser: cashier),
          throwsA(isA<PermissionDeniedException>()),
        );
        await expectLater(
          manager.backupManager.restoreFromBackup('unused', actingUser: cashier),
          throwsA(isA<PermissionDeniedException>()),
        );
        await expectLater(
          manager.backupManager.deleteBackup('unused', actingUser: cashier),
          throwsA(isA<PermissionDeniedException>()),
        );
        await expectLater(
          manager.changeAppMode('development', actingUser: cashier),
          throwsA(isA<PermissionDeniedException>()),
        );

        await expectLater(
          DebugSeeder.clearAndReSeed(actingUser: cashier),
          throwsA(isA<PermissionDeniedException>()),
        );

        expect(await _countRows('users'), 1);

        final logs = await manager.sqliteManager.query('activity_logs', orderBy: 'timestamp DESC');
        expect(logs.any((row) => row['type'] == 'backupCreateDenied'), isTrue);
        expect(logs.any((row) => row['type'] == 'demoResetDenied'), isTrue);
      } finally {
        await _tearDownScenario(scenario);
      }
    });

    test('manager actions succeed and emit audit records', () async {
      final scenario = await _createScenario();
      try {
        final initialized = await _initializeScenario(scenario);
        expect(initialized, isTrue);

        final manager = PersistenceInitializer.persistenceManager!;
        final admin = User(
          username: 'manager-test',
          name: 'Manager',
          phone: '222',
          userType: UserType.manager,
          password: 'admin',
        );

        expect(await manager.backupManager.createBackup(actingUser: admin), isTrue);
        final logsAfterBackup = await manager.sqliteManager.query('activity_logs', orderBy: 'timestamp DESC');
        expect(logsAfterBackup.any((row) => row['type'] == 'backupCreated'), isTrue);

        await manager.changeAppMode('development', actingUser: admin);
        expect(manager.config.appMode, ConfigurationStorage.developmentMode);
        final modeLogs = await manager.sqliteManager.query('activity_logs', orderBy: 'timestamp DESC');
        expect(modeLogs.any((row) => row['type'] == 'appModeChanged'), isTrue);

        final backupFolder = await manager.backupManager.getLatestBackup();
        if (backupFolder != null) {
          expect(await manager.backupManager.deleteBackup(backupFolder.path, actingUser: admin), isTrue);
        }

        manager.config.appMode = ConfigurationStorage.productionMode;
        await manager.config.save();
        await expectLater(
          () => DebugSeeder.clearAndReSeed(actingUser: admin),
          returnsNormally,
        );
      } finally {
        await _tearDownScenario(scenario);
      }
    });
  });
}
