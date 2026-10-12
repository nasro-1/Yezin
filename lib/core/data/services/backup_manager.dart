// lib/core/data/services/backup_manager.dart

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;

import '../../di/dependency_injection.dart';
import '../../../features/auth/data/models/user_model.dart';
import '../../../features/auth/presentation/cubit/user_cubit.dart';
import '../../logging/file_logger.dart';
import '../../security/permission_guard.dart';
import '../../services/activity_logger.dart';
import '../models/activity_log.dart';
import 'persistence_initializer.dart';
import 'sqlite_manager.dart';
import 'background_write_queue.dart';

class BackupManifest {
  const BackupManifest({
    required this.formatVersion,
    required this.generatedAt,
    required this.applicationVersion,
    required this.databaseSchemaVersion,
    required this.databaseFilename,
    required this.databaseSizeBytes,
    required this.checksumSha256,
    required this.backupType,
  });

  final String formatVersion;
  final DateTime generatedAt;
  final String applicationVersion;
  final int databaseSchemaVersion;
  final String databaseFilename;
  final int databaseSizeBytes;
  final String checksumSha256;
  final String backupType;

  Map<String, dynamic> toJson() => {
        'format_version': formatVersion,
        'generated_at': generatedAt.toUtc().toIso8601String(),
        'application_version': applicationVersion,
        'database_schema_version': databaseSchemaVersion,
        'database_filename': databaseFilename,
        'database_size_bytes': databaseSizeBytes,
        'checksum_sha256': checksumSha256,
        'backup_type': backupType,
      };

  factory BackupManifest.fromJson(Map<String, dynamic> json) {
    return BackupManifest(
      formatVersion: (json['format_version'] ?? '1.0') as String,
      generatedAt: DateTime.tryParse(json['generated_at']?.toString() ?? '') ?? DateTime.now().toUtc(),
      applicationVersion: (json['application_version'] ?? 'unknown') as String,
      databaseSchemaVersion: int.tryParse('${json['database_schema_version'] ?? 0}') ?? 0,
      databaseFilename: (json['database_filename'] ?? '') as String,
      databaseSizeBytes: int.tryParse('${json['database_size_bytes'] ?? 0}') ?? 0,
      checksumSha256: (json['checksum_sha256'] ?? '') as String,
      backupType: (json['backup_type'] ?? 'full') as String,
    );
  }
}

/// Backup manager for automatic database backups.
class BackupManager {
  final String databasePath;
  final String backupsPath;
  final int retentionDays;
  Timer? _periodicBackupTimer;

  BackupManager({
    required this.databasePath,
    required this.backupsPath,
    this.retentionDays = 30,
  });

  static const int _supportedBackupFormatVersion = 1;

  User? _resolveCurrentUser({User? actingUser}) {
    if (actingUser != null) return actingUser;
    if (getIt.isRegistered<UserCubit>()) {
      return getIt<UserCubit>().currentUser;
    }
    return null;
  }

  Future<void> _logActivity({
    required ActivityType type,
    required String description,
    User? actingUser,
    String? target,
    String? reason,
    Map<String, dynamic>? parameters,
  }) async {
    final user = actingUser ?? _resolveCurrentUser();
    try {
      await getIt<ActivityLogger>().logActivity(
        type: type,
        description: description,
        userName: user?.name ?? 'system',
        eventKey: target != null ? 'data_management_${type.name}' : null,
        parameters: {
          if (target != null) 'target': target,
          if (reason != null) 'reason': reason,
          if (parameters != null) ...parameters,
        },
      );
    } catch (_) {}
  }

  /// Start periodic auto-backup (default: every 30 minutes)
  void startPeriodicBackup({Duration interval = const Duration(minutes: 30)}) {
    stopPeriodicBackup();
    FileLogger.info('Starting periodic backup every ${interval.inMinutes} minutes', source: 'BackupManager');
    _periodicBackupTimer = Timer.periodic(interval, (_) async {
      FileLogger.info('Running periodic auto-backup...', source: 'BackupManager');
      await createBackup();
    });
  }

  /// Stop periodic auto-backup
  void stopPeriodicBackup() {
    _periodicBackupTimer?.cancel();
    _periodicBackupTimer = null;
  }

  Future<BackupManifest?> readManifest(String backupFolderPath) async {
    try {
      final manifestFile = File(path.join(backupFolderPath, 'backup_manifest.json'));
      if (!await manifestFile.exists()) return null;
      final content = await manifestFile.readAsString();
      final json = jsonDecode(content);
      if (json is! Map<String, dynamic>) return null;
      return BackupManifest.fromJson(json);
    } catch (e) {
      FileLogger.error('Unable to read backup manifest', error: e, source: 'BackupManager');
      return null;
    }
  }

  Future<String> _calculateChecksum(File file) async {
    final bytes = await file.readAsBytes();
    final digest = sha256.convert(bytes);
    return digest.toString();
  }

  Future<bool> _checkpointDatabase() async {
    try {
      final manager = PersistenceInitializer.persistenceManager?.sqliteManager;
      if (manager == null) {
        return true;
      }
      await manager.checkpoint();
      final integrityOk = await manager.checkIntegrity();
      if (!integrityOk) {
        FileLogger.warning('Database checkpoint integrity check failed before backup', source: 'BackupManager');
        return false;
      }
      return true;
    } catch (e) {
      FileLogger.warning('Database checkpoint failed before backup', error: e, source: 'BackupManager');
      return false;
    }
  }

  Future<bool> validateBackup(String backupFolderPath) async {
    try {
      final backupDir = Directory(backupFolderPath);
      if (!await backupDir.exists()) {
        return false;
      }

      final manifest = await readManifest(backupFolderPath);
      if (manifest == null) {
        FileLogger.warning('Backup validation failed: manifest missing', source: 'BackupManager');
        return false;
      }

      if (manifest.formatVersion != '$_supportedBackupFormatVersion.0' &&
          manifest.formatVersion != '1') {
        FileLogger.warning('Backup validation failed: unsupported backup format', source: 'BackupManager');
        return false;
      }

      if (manifest.databaseSchemaVersion <= 0 ||
          manifest.databaseSchemaVersion > SQLiteManager.databaseSchemaVersion) {
        FileLogger.warning(
          'Backup validation failed: incompatible schema version ${manifest.databaseSchemaVersion}',
          source: 'BackupManager',
        );
        return false;
      }

      final dbFileName = manifest.databaseFilename.isNotEmpty
          ? manifest.databaseFilename
          : path.basename(databasePath);
      final dbFile = File(path.join(backupFolderPath, dbFileName));
      if (!await dbFile.exists() || await dbFile.length() == 0) {
        FileLogger.warning('Backup validation failed: database file missing or empty', source: 'BackupManager');
        return false;
      }

      final actualChecksum = await _calculateChecksum(dbFile);
      if (actualChecksum != manifest.checksumSha256) {
        FileLogger.warning('Backup validation failed: checksum mismatch', source: 'BackupManager');
        return false;
      }

      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      final openDb = await openDatabase(dbFile.path, readOnly: true);
      try {
        final integrityResult = await openDb.rawQuery('PRAGMA integrity_check');
        final integrity = integrityResult.first.values.first?.toString();
        if (integrity != 'ok') {
          FileLogger.warning('Backup validation failed: integrity_check returned $integrity', source: 'BackupManager');
          return false;
        }

        final tables = await openDb.rawQuery("SELECT name FROM sqlite_master WHERE type = 'table'");
        if (tables.isEmpty) {
          FileLogger.warning('Backup validation failed: no tables present in backup', source: 'BackupManager');
          return false;
        }
      } finally {
        await openDb.close();
      }

      return true;
    } catch (e, stack) {
      FileLogger.error('Backup validation error', error: e, stackTrace: stack, source: 'BackupManager');
      return false;
    }
  }

  Future<bool> _createSqliteOnlineBackup(String sourceDbPath, String destinationDbPath) async {
    final sourceFile = File(sourceDbPath);
    if (!await sourceFile.exists()) {
      throw StateError('Source database file does not exist: $sourceDbPath');
    }

    final destinationFile = File(destinationDbPath);
    if (await destinationFile.exists()) {
      await destinationFile.delete();
    }

    final sourceConnection = sqlite3.sqlite3.open(sourceDbPath, mode: sqlite3.OpenMode.readOnly);
    final destinationConnection = sqlite3.sqlite3.open(
      destinationDbPath,
      mode: sqlite3.OpenMode.readWriteCreate,
    );

    try {
      final stream = sourceConnection.backup(destinationConnection, nPage: 50);
      await for (final _ in stream) {
        // Consume the backup stream until SQLite completes the snapshot.
      }
      return true;
    } finally {
      destinationConnection.dispose();
      sourceConnection.dispose();
    }
  }

  Future<bool> createBackup({String backupType = 'full', User? actingUser}) async {
    return DatabaseLifecycleCoordinator.instance.withExclusiveAccess(() async {
      final currentUser = _resolveCurrentUser(actingUser: actingUser);
      if (currentUser != null) {
        try {
          PermissionGuard.requireDataManagementAccess(currentUser);
        } on PermissionDeniedException catch (e) {
          await _logActivity(
            type: ActivityType.backupCreateDenied,
            description: 'Denied backup creation for ${currentUser.name}',
            actingUser: currentUser,
            target: backupType,
            reason: e.message,
          );
          rethrow;
        }
      }

      try {
        FileLogger.info('Starting SQLite online backup', source: 'BackupManager');

        final dbFile = File(databasePath);
        if (!await dbFile.exists()) {
          FileLogger.warning('Backup creation failed: database file is missing', source: 'BackupManager');
          await _logActivity(
            type: ActivityType.backupCreateFailed,
            description: 'Backup creation failed: database file missing',
            actingUser: currentUser,
            target: backupType,
            reason: 'database file missing',
          );
          return false;
        }

        final backupReady = await _checkpointDatabase();
        if (!backupReady) {
          FileLogger.warning('Backup creation failed: database could not be checkpointed cleanly', source: 'BackupManager');
          await _logActivity(
            type: ActivityType.backupCreateFailed,
            description: 'Backup creation failed: checkpoint validation failed',
            actingUser: currentUser,
            target: backupType,
            reason: 'checkpoint validation failed',
          );
          return false;
        }

        final backupsDir = Directory(backupsPath);
        if (!backupsDir.existsSync()) {
          await backupsDir.create(recursive: true);
        }

        final timestamp = DateTime.now().toUtc().microsecondsSinceEpoch.toString();
        final backupFolderName = 'backup_$timestamp';
        final backupFolderPath = path.join(backupsPath, backupFolderName);
        final backupFolder = Directory(backupFolderPath);
        await backupFolder.create(recursive: true);

        final targetDbFile = File(path.join(backupFolderPath, path.basename(databasePath)));
        final backupCreated = await _createSqliteOnlineBackup(databasePath, targetDbFile.path);
        if (!backupCreated) {
          FileLogger.error('SQLite online backup failed to create a snapshot', source: 'BackupManager');
          await backupFolder.delete(recursive: true);
          await _logActivity(
            type: ActivityType.backupCreateFailed,
            description: 'Backup creation failed: SQLite snapshot creation failed',
            actingUser: currentUser,
            target: backupFolderName,
            reason: 'sqlite snapshot failed',
          );
          return false;
        }

        final databaseSizeBytes = await targetDbFile.length();
        final checksum = await _calculateChecksum(targetDbFile);
        final manifest = BackupManifest(
          formatVersion: '1.0',
          generatedAt: DateTime.now().toUtc(),
          applicationVersion: 'unknown',
          databaseSchemaVersion: SQLiteManager.databaseSchemaVersion,
          databaseFilename: path.basename(databasePath),
          databaseSizeBytes: databaseSizeBytes,
          checksumSha256: checksum,
          backupType: backupType,
        );
        await File(path.join(backupFolderPath, 'backup_manifest.json'))
            .writeAsString(const JsonEncoder.withIndent('  ').convert(manifest.toJson()));

        final isValid = await validateBackup(backupFolderPath);
        if (!isValid) {
          FileLogger.error('Backup validation failed after SQLite online backup creation', source: 'BackupManager');
          await backupFolder.delete(recursive: true);
          await _logActivity(
            type: ActivityType.backupCreateFailed,
            description: 'Backup creation failed: post-write validation failed',
            actingUser: currentUser,
            target: backupFolderName,
            reason: 'validation failed',
          );
          return false;
        }

        FileLogger.info('Backup created successfully: $backupFolderName', source: 'BackupManager');
        await _cleanOldBackups();
        await _logActivity(
          type: ActivityType.backupCreated,
          description: 'Created database backup: $backupFolderName',
          actingUser: currentUser,
          target: backupFolderName,
          parameters: {'backupType': backupType, 'folder': backupFolderName},
        );
        return true;
      } catch (e, stack) {
        FileLogger.error('Backup creation failed', error: e, stackTrace: stack, source: 'BackupManager');
        await _logActivity(
          type: ActivityType.backupCreateFailed,
          description: 'Backup creation failed: ${e.toString()}',
          actingUser: currentUser,
          target: backupType,
          reason: e.toString(),
        );
        return false;
      }
    });
  }

  Future<void> _cleanOldBackups() async {
    try {
      final backupsDir = Directory(backupsPath);
      if (!backupsDir.existsSync()) return;

      final backups = <Directory>[];
      await for (final entity in backupsDir.list()) {
        if (entity is Directory && path.basename(entity.path).startsWith('backup_')) {
          backups.add(entity);
        }
      }

      if (backups.isEmpty) return;
      backups.sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));

      final maxBackups = 10;
      final toDelete = backups.skip(maxBackups).toList();
      for (final dir in toDelete) {
        await dir.delete(recursive: true);
      }
    } catch (e) {
      FileLogger.warning('Failed to clean old backups', error: e, source: 'BackupManager');
    }
  }

  Future<void> _rebindServicesAfterLifecycleSwap({required String reason}) async {
    await PersistenceInitializer.persistenceManager
        ?.rebindServicesAfterLifecycleSwap(reason: reason);
  }

  Future<bool> restoreFromLatestBackup({User? actingUser}) async {
    try {
      FileLogger.info('Starting database restore from latest backup', source: 'BackupManager');

      final latestBackup = await getLatestBackup();
      if (latestBackup == null) {
        FileLogger.error('No backups found for restore', source: 'BackupManager');
        return false;
      }

      return await restoreFromBackup(latestBackup.path, actingUser: actingUser);
    } catch (e, stack) {
      FileLogger.error('Restore failed', error: e, stackTrace: stack, source: 'BackupManager');
      return false;
    }
  }

  Future<bool> restoreFromBackup(String backupFolderPath, {User? actingUser}) async {
    return DatabaseLifecycleCoordinator.instance.withExclusiveAccess(() async {
      final currentUser = _resolveCurrentUser(actingUser: actingUser);
      if (currentUser != null) {
        try {
          PermissionGuard.requireDataManagementAccess(currentUser);
        } on PermissionDeniedException catch (e) {
          await _logActivity(
            type: ActivityType.backupRestoreDenied,
            description: 'Denied database restore for ${currentUser.name}',
            actingUser: currentUser,
            target: path.basename(backupFolderPath),
            reason: e.message,
          );
          rethrow;
        }
      }

      try {
        FileLogger.info('Restoring from backup: ${path.basename(backupFolderPath)}', source: 'BackupManager');

        final isValid = await validateBackup(backupFolderPath);
        if (!isValid) {
          FileLogger.error('Backup validation failed before restore', source: 'BackupManager');
          await _logActivity(
            type: ActivityType.backupRestoreFailed,
            description: 'Restore failed: backup validation failed',
            actingUser: currentUser,
            target: path.basename(backupFolderPath),
            reason: 'validation failed',
          );
          return false;
        }

        final manifest = await readManifest(backupFolderPath);
        final dbFileName = manifest?.databaseFilename ?? path.basename(databasePath);
        final backupDbFile = File(path.join(backupFolderPath, dbFileName));
        if (!await backupDbFile.exists()) {
          FileLogger.error('Backup database file not found', source: 'BackupManager');
          await _logActivity(
            type: ActivityType.backupRestoreFailed,
            description: 'Restore failed: backup database file missing',
            actingUser: currentUser,
            target: path.basename(backupFolderPath),
            reason: 'database file missing',
          );
          return false;
        }

        final currentDbFile = File(databasePath);
        final safetyFilename = '${path.basename(databasePath)}.pre_restore_${DateTime.now().millisecondsSinceEpoch}';
        final safetyPath = path.join(currentDbFile.parent.path, safetyFilename);
        if (await currentDbFile.exists()) {
          await currentDbFile.copy(safetyPath);
        }

        final stagingDbFile = File(path.join(currentDbFile.parent.path, '.restore_staging_${DateTime.now().millisecondsSinceEpoch}_${path.basename(databasePath)}'));
        await backupDbFile.copy(stagingDbFile.path);

        var databaseClosed = false;
        try {
          final manager = PersistenceInitializer.persistenceManager?.sqliteManager;
          if (manager != null) {
            await manager.close();
            databaseClosed = true;
          }

          if (await currentDbFile.exists()) {
            await currentDbFile.delete();
          }
          await stagingDbFile.copy(databasePath);
          await stagingDbFile.delete();

          for (final candidate in [
            File('$databasePath-wal'),
            File('$databasePath-shm'),
          ]) {
            if (await candidate.exists()) {
              await candidate.delete();
            }
          }

          if (manager != null) {
            await manager.initialize();
          }

          final restoredOk = await (PersistenceInitializer.persistenceManager?.sqliteManager.checkIntegrity() ?? Future.value(true));
          if (!restoredOk) {
            throw StateError('Post-restore integrity check failed');
          }

          await _rebindServicesAfterLifecycleSwap(reason: 'database restore');

          FileLogger.info('Database restored successfully', source: 'BackupManager');
          await _logActivity(
            type: ActivityType.backupRestored,
            description: 'Restored database from backup: ${path.basename(backupFolderPath)}',
            actingUser: currentUser,
            target: path.basename(backupFolderPath),
            parameters: {'backup': path.basename(backupFolderPath)},
          );
          return true;
        } catch (e, stack) {
          FileLogger.error('Restore operation failed; attempting rollback', error: e, stackTrace: stack, source: 'BackupManager');
          await _logActivity(
            type: ActivityType.backupRestoreFailed,
            description: 'Restore failed and rolled back: ${e.toString()}',
            actingUser: currentUser,
            target: path.basename(backupFolderPath),
            reason: e.toString(),
          );
          if (await File(safetyPath).exists()) {
            if (await currentDbFile.exists()) {
              await currentDbFile.delete();
            }
            await File(safetyPath).copy(databasePath);
          }
          if (databaseClosed) {
            final manager = PersistenceInitializer.persistenceManager?.sqliteManager;
            if (manager != null) {
              await manager.initialize();
            }
          }
          return false;
        }
      } catch (e, stack) {
        FileLogger.error('Restore operation failed', error: e, stackTrace: stack, source: 'BackupManager');
        await _logActivity(
          type: ActivityType.backupRestoreFailed,
          description: 'Restore failed: ${e.toString()}',
          actingUser: currentUser,
          target: path.basename(backupFolderPath),
          reason: e.toString(),
        );
        return false;
      }
    });
  }

  Future<bool> deleteBackup(String backupFolderPath, {User? actingUser}) async {
    return DatabaseLifecycleCoordinator.instance.withExclusiveAccess(() async {
      final currentUser = _resolveCurrentUser(actingUser: actingUser);
      if (currentUser != null) {
        try {
          PermissionGuard.requireDataManagementAccess(currentUser);
        } on PermissionDeniedException catch (e) {
          await _logActivity(
            type: ActivityType.backupDeleteDenied,
            description: 'Denied backup deletion for ${currentUser.name}',
            actingUser: currentUser,
            target: path.basename(backupFolderPath),
            reason: e.message,
          );
          rethrow;
        }
      }

      try {
        final dir = Directory(backupFolderPath);
        if (!await dir.exists()) {
          return false;
        }
        await dir.delete(recursive: true);
        await _logActivity(
          type: ActivityType.backupDeleted,
          description: 'Deleted database backup: ${path.basename(backupFolderPath)}',
          actingUser: currentUser,
          target: path.basename(backupFolderPath),
        );
        return true;
      } catch (e) {
        await _logActivity(
          type: ActivityType.backupDeleteFailed,
          description: 'Backup deletion failed: ${e.toString()}',
          actingUser: currentUser,
          target: path.basename(backupFolderPath),
          reason: e.toString(),
        );
        return false;
      }
    });
  }

  Future<Directory?> getLatestBackup() async {
    try {
      final backupsDir = Directory(backupsPath);
      if (!backupsDir.existsSync()) return null;

      final backups = <Directory>[];
      await for (final entity in backupsDir.list()) {
        if (entity is Directory && path.basename(entity.path).startsWith('backup_')) {
          backups.add(entity);
        }
      }

      if (backups.isEmpty) return null;
      backups.sort((a, b) {
        final aName = path.basename(a.path);
        final bName = path.basename(b.path);
        final nameComparison = bName.compareTo(aName);
        if (nameComparison != 0) {
          return nameComparison;
        }

        final aTime = a.statSync().modified.millisecondsSinceEpoch;
        final bTime = b.statSync().modified.millisecondsSinceEpoch;
        return bTime.compareTo(aTime);
      });
      return backups.first;
    } catch (e) {
      FileLogger.error('Failed to get latest backup', error: e, source: 'BackupManager');
      return null;
    }
  }

  Future<List<Directory>> getAllBackups() async {
    try {
      final backupsDir = Directory(backupsPath);
      if (!backupsDir.existsSync()) return [];

      final backups = <Directory>[];
      await for (final entity in backupsDir.list()) {
        if (entity is Directory && path.basename(entity.path).startsWith('backup_')) {
          backups.add(entity);
        }
      }

      backups.sort((a, b) {
        final aName = path.basename(a.path);
        final bName = path.basename(b.path);
        final nameComparison = bName.compareTo(aName);
        if (nameComparison != 0) {
          return nameComparison;
        }

        final aTime = a.statSync().modified.millisecondsSinceEpoch;
        final bTime = b.statSync().modified.millisecondsSinceEpoch;
        return bTime.compareTo(aTime);
      });
      return backups;
    } catch (e) {
      FileLogger.error('Failed to get backups list', error: e, source: 'BackupManager');
      return [];
    }
  }
}
