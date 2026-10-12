import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:bayaa_pos/core/data/models/activity_log.dart';
import 'package:bayaa_pos/core/data/services/configuration_storage.dart';
import 'package:bayaa_pos/core/data/services/persistence_initializer.dart';
import 'package:bayaa_pos/core/di/dependency_injection.dart';
import 'package:bayaa_pos/core/services/activity_logger.dart';
import 'package:bayaa_pos/features/auth/data/models/user_model.dart';
import 'package:bayaa_pos/features/auth/presentation/cubit/user_cubit.dart';
import 'package:bayaa_pos/features/auth/data/repository/user_repository_imp.dart';
import 'package:bayaa_pos/core/session/session_manager.dart';
import 'package:bayaa_pos/features/sessions/data/repositories/session_repository_impl.dart';

class _Scenario {
  const _Scenario({
    required this.base,
    required this.production,
    required this.development,
    required this.configFile,
  });

  final Directory base;
  final Directory production;
  final Directory development;
  final File configFile;
}

Future<_Scenario> _createScenario() async {
  final base = await Directory.systemTemp.createTemp('bayaa_task_3_');
  final production = Directory(p.join(base.path, 'BayaaData-Production'));
  final development = Directory(p.join(base.path, 'BayaaData-Development'));
  await production.create(recursive: true);
  await development.create(recursive: true);

  for (final root in [production, development]) {
    for (final child in [
      'config',
      'ledger',
      'ledger/archived',
      'db',
      'checkpoints',
      'logs',
      'assets',
    ]) {
      await Directory(p.join(root.path, child)).create(recursive: true);
    }
  }
  await Directory(p.join(base.path, 'BayaaBackup')).create(recursive: true);

  final configFile = File(p.join(base.path, 'system_config.json'));

  return _Scenario(
    base: base,
    production: production,
    development: development,
    configFile: configFile,
  );
}

Future<void> _insertUser(
  String username, {
  String name = 'Manager',
  String role = 'manager',
}) async {
  final db = PersistenceInitializer.persistenceManager!.sqliteManager;
  await db.insert(
    'users',
    {
      'id': username,
      'username': username,
      'display_name': name,
      'password_hash': 'password',
      'role': role,
      'is_active': 1,
      'created_at': DateTime.now().toIso8601String(),
    },
    conflictAlgorithm: ConflictAlgorithm.replace,
  );
}

Future<void> _insertOpenShift(String id, String userId) async {
  final db = PersistenceInitializer.persistenceManager!.sqliteManager;
  await db.insert('shifts', {
    'id': id,
    'user_id': userId,
    'open_time':
        DateTime.now().subtract(const Duration(days: 3)).toIso8601String(),
    'is_open': 1,
  });
}

Future<void> _insertActivity(String sessionId, String userName) async {
  final db = PersistenceInitializer.persistenceManager!.sqliteManager;
  await db.insert('activity_logs', {
    'id': 'activity-$sessionId',
    'session_id': sessionId,
    'timestamp': DateTime.now().toIso8601String(),
    'type': 'login',
    'description': '$userName logged in',
    'user_name': userName,
  });
}

Future<bool> _initializeScenario(_Scenario scenario) async {
  await scenario.configFile.writeAsString(
    jsonEncode({'data_root_path': scenario.production.path}),
    flush: true,
  );
  return PersistenceInitializer.initialize(systemConfigFile: scenario.configFile);
}

User _managerUser(String username) => User(
      username: username,
      name: 'Manager',
      phone: '1',
      password: 'password',
      userType: UserType.manager,
    );

Future<void> _tearDownScenario(_Scenario scenario) async {
  final manager = PersistenceInitializer.persistenceManager;
  if (manager != null) {
    try {
      await manager.shutdown();
    } catch (_) {}
  }
  if (await scenario.base.exists()) {
    try {
      await scenario.base.delete(recursive: true);
    } catch (_) {
      // Windows may release SQLite sidecar handles after the test completes.
    }
  }
}

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  setup();

  group('Task 3 session and logger integration', () {
    test('active sessions are restored and isolated by authenticated user',
        () async {
      final scenario = await _createScenario();
      try {
        expect(await _initializeScenario(scenario), isTrue);
        await _insertUser('admin',
            name: 'System Administrator', role: 'manager');
        await _insertUser('manager', name: 'Manager');
        await _insertUser('cashier-1', name: 'Cashier', role: 'cashier');
        await _insertOpenShift('manager-session', 'manager');

        final repository = getIt<SessionRepositoryImpl>();
        final manager = getIt<SessionManager>();

        await manager.loadSession(userId: 'admin');
        expect(manager.currentSession, isNull);
        final adminSession = await manager.getOrCreateSession(
          userId: 'admin',
          userName: 'System Administrator',
        );
        expect(adminSession.openedByUserId, 'admin');

        manager.clearCurrentSession();
        await manager.loadSession(userId: 'cashier-1');
        expect(manager.currentSession, isNull);

        manager.clearCurrentSession();
        await manager.loadSession(userId: 'manager');
        expect(manager.currentSession?.id, 'manager-session');

        final rows = await PersistenceInitializer
            .persistenceManager!.sqliteManager
            .query('shifts', where: 'id = ?', whereArgs: ['manager-session']);
        expect(rows, hasLength(1));
        expect(repository.getCurrentSession()?.openedByUserId, 'manager');
      } finally {
        await _tearDownScenario(scenario);
      }
    });

    test('local development admin role remains distinct from manager',
        () async {
      final scenario = await _createScenario();
      try {
        expect(await _initializeScenario(scenario), isTrue);
        await _insertUser('admin', name: 'System Administrator', role: 'admin');
        await _insertUser('manager', name: 'Manager', role: 'manager');
        await _insertUser('cashier-1', name: 'Cashier', role: 'cashier');
        await _insertUser('cashier', name: 'Trial Cashier', role: 'cashier');

        final result = await UserRepositoryImp().getAllUsers();
        expect(result.isRight, isTrue);
        final users = result.right;
        expect(
          users.singleWhere((user) => user.username == 'admin').userType,
          UserType.admin,
        );
        expect(
          users.singleWhere((user) => user.username == 'manager').userType,
          UserType.manager,
        );
        expect(
          users.where((user) => user.username == 'cashier-1').single.userType,
          UserType.cashier,
        );
      } finally {
        await _tearDownScenario(scenario);
      }
    });

    test('dashboard active session never exposes another user session',
        () async {
      final scenario = await _createScenario();
      try {
        expect(await _initializeScenario(scenario), isTrue);
        await _insertUser('admin',
            name: 'System Administrator', role: 'manager');
        await _insertUser('manager', name: 'Manager');
        await _insertUser('cashier-1', name: 'Cashier', role: 'cashier');
        await _insertOpenShift('manager-session', 'manager');
        await _insertActivity('manager-session', 'Manager');

        final logger = getIt<ActivityLogger>();
        await logger.rebind();

        final adminGroups = await logger.getActivitiesGroupedBySession(
          activeUserId: 'admin',
        );
        expect(adminGroups.where((group) => group.isOpen), isEmpty);

        final managerGroups = await logger.getActivitiesGroupedBySession(
          activeUserId: 'manager',
        );
        expect(
          managerGroups
              .where((group) => group.isOpen)
              .map((group) => group.openedBy),
          ['manager'],
        );

        await _insertOpenShift('admin-session', 'admin');
        await _insertActivity('admin-session', 'admin');
        final adminWithSession =
            await logger.getActivitiesGroupedBySession(activeUserId: 'admin');
        expect(
          adminWithSession
              .where((group) => group.isOpen)
              .map((group) => group.openedBy),
          ['admin'],
        );

        final cashierGroups = await logger.getActivitiesGroupedBySession(
          activeUserId: 'cashier-1',
        );
        expect(cashierGroups.where((group) => group.isOpen), isEmpty);
      } finally {
        await _tearDownScenario(scenario);
      }
    });

    test('restore with same user refreshes authenticated identity', () async {
      final scenario = await _createScenario();
      try {
        expect(await _initializeScenario(scenario), isTrue);
        await _insertUser('user-a', name: 'Original');
        final cubit = getIt<UserCubit>();
        final staleUser = User(
          username: 'user-a',
          name: 'Stale Name',
          phone: '1',
          password: 'password',
          userType: UserType.cashier,
        );
        cubit.currentUser = staleUser;
        final manager = PersistenceInitializer.persistenceManager!;
        expect(
            await manager.backupManager
                .createBackup(actingUser: _managerUser('user-a')),
            isTrue);
        await manager.sqliteManager.update(
          'users',
          {'display_name': 'Restored Name', 'role': 'cashier'},
          where: 'username = ?',
          whereArgs: ['user-a'],
        );

        final backup = await manager.backupManager.getLatestBackup();
        expect(backup, isNotNull);
        expect(
            await manager.backupManager.restoreFromBackup(
              backup!.path,
              actingUser: _managerUser('user-a'),
            ),
            isTrue);

        expect(cubit.currentUser.name, 'Original');
        expect(cubit.currentUser, isNot(same(staleUser)));
        await getIt<ActivityLogger>().logActivity(
          type: ActivityType.sale,
          description: 'restored-log',
          userName: 'user-a',
        );
        expect(
          await manager.sqliteManager.query(
            'activity_logs',
            where: 'description = ?',
            whereArgs: ['restored-log'],
          ),
          hasLength(1),
        );
      } finally {
        await _tearDownScenario(scenario);
      }
    });

    test('restore without previous user fails closed', () async {
      final scenario = await _createScenario();
      try {
        expect(await _initializeScenario(scenario), isTrue);
        await _insertUser('user-a');
        final cubit = getIt<UserCubit>()..currentUser = _managerUser('user-a');
        final manager = PersistenceInitializer.persistenceManager!;
        expect(
            await manager.backupManager
                .createBackup(actingUser: _managerUser('user-a')),
            isTrue);
        await manager.sqliteManager
            .delete('users', where: 'username = ?', whereArgs: ['user-a']);
        expect(
            await manager.backupManager
                .createBackup(actingUser: _managerUser('user-a')),
            isTrue);
        final backup = await manager.backupManager.getLatestBackup();
        expect(
            await manager.backupManager.restoreFromBackup(
              backup!.path,
              actingUser: _managerUser('user-a'),
            ),
            isTrue);
        expect(cubit.currentUser.username, isEmpty);
        expect(cubit.currentUser.userType, UserType.cashier);
      } finally {
        await _tearDownScenario(scenario);
      }
    });

    test('restore refreshes changed user role and permissions', () async {
      final scenario = await _createScenario();
      try {
        expect(await _initializeScenario(scenario), isTrue);
        await _insertUser('user-a', role: 'manager');
        final cubit = getIt<UserCubit>()
          ..currentUser = User(
            username: 'user-a',
            name: 'Stale',
            phone: '1',
            password: 'password',
            userType: UserType.cashier,
          );
        final manager = PersistenceInitializer.persistenceManager!;
        expect(
            await manager.backupManager
                .createBackup(actingUser: _managerUser('user-a')),
            isTrue);
        await manager.sqliteManager.update(
          'users',
          {'role': 'cashier'},
          where: 'username = ?',
          whereArgs: ['user-a'],
        );
        final backup = await manager.backupManager.getLatestBackup();
        expect(
            await manager.backupManager.restoreFromBackup(
              backup!.path,
              actingUser: _managerUser('user-a'),
            ),
            isTrue);
        expect(cubit.currentUser.userType, UserType.manager);
        expect(cubit.currentUser.hasPermission('stock.adjust'), isTrue);
      } finally {
        await _tearDownScenario(scenario);
      }
    });

    test('mode switch refreshes identity and logger uses new root', () async {
      final scenario = await _createScenario();
      try {
        expect(await _initializeScenario(scenario), isTrue);
        await _insertUser('production-user');
        final cubit = getIt<UserCubit>()
          ..currentUser = _managerUser('production-user');
        final manager = PersistenceInitializer.persistenceManager!;
        manager.config.developmentDataRootPath = scenario.development.path;
        await manager.config.save();
        await manager.changeAppMode(
          ConfigurationStorage.developmentMode,
          actingUser: _managerUser('production-user'),
        );
        expect(cubit.currentUser.username, isEmpty);

        await getIt<ActivityLogger>().logActivity(
          type: ActivityType.sale,
          description: 'development-log',
          userName: 'system',
        );
        final rows = await manager.sqliteManager.query(
          'activity_logs',
          where: 'description = ?',
          whereArgs: ['development-log'],
        );
        expect(rows, hasLength(1));
      } finally {
        await _tearDownScenario(scenario);
      }
    });

    test('failed restore preserves current identity and logger usability',
        () async {
      final scenario = await _createScenario();
      try {
        expect(await _initializeScenario(scenario), isTrue);
        await _insertUser('user-a');
        final cubit = getIt<UserCubit>()..currentUser = _managerUser('user-a');
        final manager = PersistenceInitializer.persistenceManager!;
        expect(
            await manager.backupManager.restoreFromBackup(
              p.join(scenario.base.path, 'missing-backup'),
              actingUser: _managerUser('user-a'),
            ),
            isFalse);
        expect(cubit.currentUser.username, 'user-a');
        await getIt<ActivityLogger>().logActivity(
          type: ActivityType.sale,
          description: 'failure-log',
          userName: 'user-a',
        );
        expect(
          await manager.sqliteManager.query(
            'activity_logs',
            where: 'description = ?',
            whereArgs: ['failure-log'],
          ),
          hasLength(1),
        );
      } finally {
        await _tearDownScenario(scenario);
      }
    });

    test('restore lifecycle keeps exclusive access through service refresh',
        () async {
      final gate =
          PersistenceInitializer.persistenceManager!.lifecycleCoordinator;
      final refreshStarted = Completer<void>();
      final refreshRelease = Completer<void>();
      final restore = gate.withExclusiveAccess(() async {
        refreshStarted.complete();
        await refreshRelease.future;
      });
      await refreshStarted.future;

      var writeStarted = false;
      final write = gate.withWriteAccess(() async {
        writeStarted = true;
      });
      expect(writeStarted, isFalse);
      refreshRelease.complete();
      await restore;
      await write;
      expect(writeStarted, isTrue);
    });
  });
}
