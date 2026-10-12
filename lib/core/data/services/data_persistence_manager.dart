// lib/core/data/services/data_persistence_manager.dart

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:io';

import '../../di/dependency_injection.dart';
import '../../../features/auth/data/models/user_model.dart';
import '../../security/permission_guard.dart';
import '../../services/activity_logger.dart';
import '../../session/session_manager.dart';
import '../../../features/auth/presentation/cubit/user_cubit.dart';
import '../models/activity_log.dart';
import 'data_path_resolver.dart';
import 'configuration_storage.dart';
import 'append_only_ledger.dart';
import 'sqlite_manager.dart';
import 'background_write_queue.dart';
import 'backup_manager.dart';
import '../../logging/file_logger.dart';
import '../../logging/crash_logger.dart';

/// Main orchestrator for the data persistence architecture.
class DataPersistenceManager {
  DataPersistenceManager({File? systemConfigFile})
      : _systemConfigFile = systemConfigFile;

  final File? _systemConfigFile;

  late DataPathResolver pathResolver;
  late ConfigurationStorage config;
  late SQLiteManager sqliteManager;
  late AppendOnlyLedger ledger;
  late BackgroundWriteQueue writeQueue;
  late BackupManager backupManager;
  final DatabaseLifecycleCoordinator lifecycleCoordinator =
      DatabaseLifecycleCoordinator.instance;

  bool _initialized = false;
  bool _enabled = false;

  /// Check if persistence system is enabled
  bool get isEnabled => _enabled;

  /// Initialize the entire data persistence system.
  Future<bool> initialize() async {
    if (_initialized) {
      print('  ℹ️ Already initialized');
      return true;
    }

    try {
      print('  📂 Initializing DataPathResolver...');
      // Step 1: Resolve data paths
      pathResolver = DataPathResolver(systemConfigFile: _systemConfigFile);
      final pathConfigured = await pathResolver.initialize();

      if (!pathConfigured) {
        print('  ⚠️ Data path not configured');
        _enabled = false;
        return false;
      }
      print('  ✅ DataPathResolver ready');
      print('     Path: ${pathResolver.dataRootPath}');

      // Step 1.5: Initialize logging system
      print('  📝 Initializing logging system...');
      await FileLogger.instance.initialize(pathResolver.logsPath);
      await CrashLogger.instance.initialize(pathResolver.logsPath);
      FileLogger.info('Data persistence system initializing',
          source: 'PersistenceManager');
      print('  ✅ Logging system ready');

      print('  ⚙️ Loading configuration...');
      // Step 2: Load configuration
      config = ConfigurationStorage(pathResolver.configFile);
      await config.load();
      print('  ✅ Configuration loaded');
      print(
          '     Checkpoint interval: ${config.checkpointIntervalMinutes} min');
      print('     Ledger max size: ${config.ledgerMaxSizeMB} MB');

      if (config.appMode == ConfigurationStorage.developmentMode) {
        final currentParent = File(pathResolver.dataRootPath).parent.path;
        final devRoot = config.developmentDataRootPath ??
            '${currentParent}${Platform.pathSeparator}BayaaData-Development';
        config.developmentDataRootPath = devRoot;
        await pathResolver.applyModeSpecificDataRoot(
          appMode: config.appMode,
          developmentDataRootPath: devRoot,
        );
        await config.save();
      }

      print('  ✅ Active data root: ${pathResolver.dataRootPath}');

      print('  🗄️ Initializing SQLite database...');
      // Step 3: Initialize SQLite
      sqliteManager =
          SQLiteManager(databasePath: pathResolver.mainDatabaseFile);
      await sqliteManager.initialize();
      print('  ✅ SQLite ready (WAL mode enabled)');

      print('  📝 Initializing append-only ledger...');
      // Step 4: Initialize ledger
      ledger = AppendOnlyLedger(
        ledgerDirectoryPath: pathResolver.ledgerPath,
        maxSizeMB: config.ledgerMaxSizeMB,
      );
      await ledger.initialize();
      final ledgerFiles = await ledger.getAllLedgerFiles();
      print('  ✅ Ledger ready (${ledgerFiles.length} file(s))');

      print('  ⚡ Starting background write queue...');
      // Step 5: Start background write queue
      writeQueue =
          BackgroundWriteQueue(lifecycleCoordinator: lifecycleCoordinator);
      writeQueue.start();
      print('  ✅ Background queue active');

      // Step 6: Initialize backup manager
      print('  💾 Initializing backup manager...');
      backupManager = BackupManager(
        databasePath: pathResolver.mainDatabaseFile,
        backupsPath: pathResolver.backupsPath,
        retentionDays: 30,
      );
      print('  ✅ Backup manager ready');

      _initialized = true;
      _enabled = true;

      print('  🎉 All systems initialized successfully!');
      FileLogger.info('All persistence systems initialized successfully',
          source: 'PersistenceManager');
      return true;
    } catch (e, stackTrace) {
      print('  ❌ Initialization failed: $e');
      print('     Stack: $stackTrace');
      FileLogger.critical('Persistence initialization failed',
          error: e, stackTrace: stackTrace, source: 'PersistenceManager');
      _enabled = false;
      return false;
    }
  }

  /// Prompt user to select data storage path.
  Future<bool> promptForDataPath({bool allowCancel = true}) async {
    return pathResolver.promptUserForDataPath(allowCancel: allowCancel);
  }

  Future<void> changeAppMode(String newMode, {User? actingUser}) async {
    await lifecycleCoordinator.withExclusiveAccess(() async {
      final normalizedMode =
          newMode == 'development' ? 'development' : 'production';
      final previousMode = config.appMode;
      final modeSource = actingUser;
      if (modeSource != null) {
        try {
          PermissionGuard.requireDataManagementAccess(modeSource);
        } on PermissionDeniedException catch (e) {
          if (getIt.isRegistered<ActivityLogger>()) {
            await getIt<ActivityLogger>().logActivity(
              type: ActivityType.appModeChangeDenied,
              description: 'Denied app mode change for ${modeSource.name}',
              userName: modeSource.name,
              eventKey: 'app_mode_change_denied',
              parameters: {
                'previousMode': previousMode,
                'newMode': normalizedMode,
                'reason': e.message
              },
            );
          }
          rethrow;
        }
      }

      config.appMode = normalizedMode;
      if (normalizedMode == 'development') {
        final currentParent = Directory(pathResolver.dataRootPath).parent.path;
        final devRoot = config.developmentDataRootPath ??
            '${currentParent}${Platform.pathSeparator}BayaaData-Development';
        config.developmentDataRootPath = devRoot;
        await pathResolver.applyModeSpecificDataRoot(
          appMode: normalizedMode,
          developmentDataRootPath: devRoot,
        );
      } else {
        await pathResolver.applyModeSpecificDataRoot(appMode: 'production');
      }

      if (sqliteManager.databasePath != pathResolver.mainDatabaseFile) {
        await sqliteManager.close();
        sqliteManager =
            SQLiteManager(databasePath: pathResolver.mainDatabaseFile);
        await sqliteManager.initialize();
      }

      await config.save();
      await rebindServicesAfterLifecycleSwap(reason: 'application mode switch');

      if (getIt.isRegistered<ActivityLogger>()) {
        await getIt<ActivityLogger>().logActivity(
          type: ActivityType.appModeChanged,
          description: 'App mode changed from $previousMode to $normalizedMode',
          userName: actingUser?.name ?? 'system',
          eventKey: 'app_mode_change',
          parameters: {'previousMode': previousMode, 'newMode': normalizedMode},
        );
      }
    });
  }

  Future<void> rebindServicesAfterLifecycleSwap(
      {required String reason}) async {
    if (getIt.isRegistered<ActivityLogger>()) {
      await getIt<ActivityLogger>().rebind();
    }

    if (getIt.isRegistered<SessionManager>()) {
      final sessionManager = getIt<SessionManager>();
      sessionManager.clearCurrentSession();
      await sessionManager.loadSession();
    }

    if (getIt.isRegistered<UserCubit>()) {
      await getIt<UserCubit>().reloadAuthenticatedUserFromDatabase();
    }
  }

  /// Write data with full persistence guarantees (for critical operations).
  Future<void> writeImmediate({
    required String operation,
    required String entity,
    required String id,
    required Map<String, dynamic> data,
    required Future<void> Function() sqliteWrite,
  }) async {
    await lifecycleCoordinator.withWriteAccess(() async {
      if (!_enabled) {
        // If persistence not enabled, just execute SQLite write
        await sqliteWrite();
        return;
      }

      try {
        print('  💾 Writing $entity:$id to ledger...');
        print('     📋 Data: $data');
        // Write to ledger first
        await ledger.write(
          operation: operation,
          entity: entity,
          id: id,
          data: data,
          immediate: true,
        );
        print('  ✅ Ledger write complete');

        print('  🗄️ Writing to SQLite...');
        // Then write to SQLite
        await sqliteWrite();
        print('  ✅ SQLite write complete');
      } catch (e) {
        print('  ❌ Write immediate failed: $e');
        rethrow;
      }
    });
  }

  /// Write data using background queue (for non-critical operations).
  Future<void> writeAsync({
    required String operation,
    required String entity,
    required String id,
    required Map<String, dynamic> data,
    required Future<void> Function() sqliteWrite,
  }) async {
    if (!_enabled) {
      await sqliteWrite();
      return;
    }

    final queuedWrite = writeQueue.enqueue(() async {
      await ledger.write(
        operation: operation,
        entity: entity,
        id: id,
        data: data,
      );

      await sqliteWrite();
    });
    unawaited(
      queuedWrite.catchError((Object error, StackTrace stackTrace) {
        FileLogger.error(
          'Background persistence write failed '
          '(operation=$operation, entity=$entity, id=$id)',
          error: error,
          stackTrace: stackTrace,
          source: 'PersistenceManager',
        );
      }),
    );
  }

  /// Graceful shutdown.
  Future<void> shutdown() async {
    if (!_enabled) return;

    backupManager.stopPeriodicBackup();
    await writeQueue.dispose();

    try {
      FileLogger.info('Shutting down persistence system',
          source: 'PersistenceManager');

      // Create backup before shutdown
      print('💾 Creating backup before shutdown...');
      final backupSuccess = await backupManager.createBackup();
      if (backupSuccess) {
        print('✅ Backup created successfully');
      } else {
        print('⚠️ Backup creation failed');
      }
    } catch (e) {
      print('Shutdown backup error: $e');
    }

    await lifecycleCoordinator.withExclusiveAccess(() async {
      try {
        await ledger.close();
        await sqliteManager.close();

        // Shutdown logging last
        await FileLogger.instance.shutdown();

        _initialized = false;
        _enabled = false;
      } catch (e) {
        print('Shutdown error: $e');
        FileLogger.error('Shutdown error',
            error: e, source: 'PersistenceManager');
      }
    });
  }
}
