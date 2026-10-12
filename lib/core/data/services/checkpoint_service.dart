// lib/core/data/services/checkpoint_service.dart

import 'dart:io';
import 'dart:convert';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as path;

import '../../di/dependency_injection.dart';
import '../../security/permission_guard.dart';
import '../../services/activity_logger.dart';
import '../../../features/auth/data/models/user_model.dart';
import '../../../features/auth/presentation/cubit/user_cubit.dart';
import '../../logging/file_logger.dart';
import '../models/activity_log.dart';
import 'background_write_queue.dart';
import 'persistence_initializer.dart';

/// Automatic checkpoint service for crash recovery.
///
/// Creates named checkpoints of the database at key moments:
/// - On login
/// - On logout / session close
/// - Before reset
/// - Before restore
/// - Before update
class CheckpointService {
  static final CheckpointService _instance = CheckpointService._internal();
  factory CheckpointService() => _instance;
  CheckpointService._internal();

  static const int _maxCheckpoints = 10;

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
  }) async {
    final user = actingUser ?? _resolveCurrentUser();
    try {
      await getIt<ActivityLogger>().logActivity(
        type: type,
        description: description,
        userName: user?.name ?? 'system',
        eventKey: target != null ? 'checkpoint_${type.name}' : null,
        parameters: {
          if (target != null) 'target': target,
          if (reason != null) 'reason': reason,
        },
      );
    } catch (_) {}
  }

  String get _checkpointsPath {
    return PersistenceInitializer.persistenceManager!.pathResolver.checkpointsPath;
  }

  String get _databasePath {
    return PersistenceInitializer.persistenceManager!.pathResolver.mainDatabaseFile;
  }

  /// Create a checkpoint with a reason tag.
  Future<bool> createCheckpoint({
    required String reason,
    String userName = 'system',
  }) {
    return DatabaseLifecycleCoordinator.instance.withExclusiveAccess(
      () => _createCheckpoint(reason: reason, userName: userName),
    );
  }

  Future<bool> _createCheckpoint({
    required String reason,
    required String userName,
  }) async {
    try {
      if (!PersistenceInitializer.isEnabled) {
        FileLogger.warning('Checkpoint skipped: persistence not enabled', source: 'Checkpoint');
        return false;
      }

      FileLogger.info('Creating checkpoint: $reason (user: $userName)', source: 'Checkpoint');

      // Ensure checkpoints directory exists
      final dir = Directory(_checkpointsPath);
      if (!dir.existsSync()) {
        await dir.create(recursive: true);
      }

      // WAL checkpoint first to flush pending writes
      try {
        await PersistenceInitializer.persistenceManager!.sqliteManager.checkpoint();
      } catch (e) {
        FileLogger.warning('WAL checkpoint warning: $e', source: 'Checkpoint');
      }

      // Create timestamped checkpoint folder
      final timestamp = DateFormat('yyyy_MM_dd_HH_mm_ss').format(DateTime.now());
      final chkName = 'chk_${timestamp}_${reason.replaceAll(' ', '_')}';
      final chkPath = path.join(_checkpointsPath, chkName);
      await Directory(chkPath).create();

      final dbFile = File(_databasePath);
      if (await dbFile.exists()) {
        await dbFile.copy(path.join(chkPath, path.basename(_databasePath)));
      }

      final metadata = {
        'user': userName,
        'timestamp': DateTime.now().toIso8601String(),
        'reason': reason,
        'dbSize': await dbFile.exists() ? await dbFile.length() : 0,
        'version': '2.0',
        'backup_type': 'auto-save',
      };
      await File(path.join(chkPath, 'metadata.json'))
          .writeAsString(const JsonEncoder.withIndent('  ').convert(metadata));

      // Update config
      try {
        final config = PersistenceInitializer.persistenceManager!.config;
        config.set('lastCheckpoint', DateTime.now().toIso8601String());
        config.set('lastCheckpointReason', reason);
        await config.save();
      } catch (_) {}

      FileLogger.info('Checkpoint created: $chkName', source: 'Checkpoint');
      print('✅ Checkpoint created: $chkName');

      // Clean old checkpoints
      await _cleanOldCheckpoints();

      return true;
    } catch (e, stack) {
      FileLogger.error('Checkpoint creation failed', error: e, stackTrace: stack, source: 'Checkpoint');
      print('❌ Checkpoint failed: $e');
      return false;
    }
  }

  /// Restore from the latest checkpoint.
  Future<bool> restoreFromLatestCheckpoint({User? actingUser}) async {
    try {
      final latest = await getLatestCheckpoint();
      if (latest == null) {
        FileLogger.warning('No checkpoints available for restore', source: 'Checkpoint');
        return false;
      }
      return await restoreFromCheckpoint(latest.path, actingUser: actingUser);
    } catch (e, stack) {
      FileLogger.error('Restore from checkpoint failed', error: e, stackTrace: stack, source: 'Checkpoint');
      return false;
    }
  }

  /// Restore from a specific checkpoint folder.
  Future<bool> restoreFromCheckpoint(String checkpointPath, {User? actingUser}) async {
    return DatabaseLifecycleCoordinator.instance.withExclusiveAccess(() async {
      final currentUser = _resolveCurrentUser(actingUser: actingUser);
      if (currentUser != null) {
        try {
          PermissionGuard.requireDataManagementAccess(currentUser);
        } on PermissionDeniedException catch (e) {
          await _logActivity(
            type: ActivityType.backupRestoreDenied,
            description: 'Denied checkpoint restore for ${currentUser.name}',
            actingUser: currentUser,
            target: path.basename(checkpointPath),
            reason: e.message,
          );
          throw e;
        }
      }

      try {
        FileLogger.info('Restoring from checkpoint: ${path.basename(checkpointPath)}', source: 'Checkpoint');

        final dbFileName = path.basename(_databasePath);
        final backupDb = File(path.join(checkpointPath, dbFileName));
        if (!await backupDb.exists()) {
          FileLogger.error('Checkpoint DB file not found', source: 'Checkpoint');
          return false;
        }

        final currentDbFile = File(_databasePath);
        final safetyPath = '${_databasePath}.checkpoint_restore_backup_${DateTime.now().millisecondsSinceEpoch}';
        if (await currentDbFile.exists()) {
          await currentDbFile.copy(safetyPath);
        }

        final manager = PersistenceInitializer.persistenceManager?.sqliteManager;
        if (manager != null) {
          await manager.close();
        }

        try {
          if (await currentDbFile.exists()) {
            await currentDbFile.delete();
          }
          await backupDb.copy(_databasePath);
          for (final candidate in [
            File('$_databasePath-wal'),
            File('$_databasePath-shm'),
          ]) {
            if (await candidate.exists()) {
              await candidate.delete();
            }
          }

          if (manager != null) {
            await manager.initialize();
          }

          final ok = await PersistenceInitializer.persistenceManager!.sqliteManager.checkIntegrity();
          if (!ok) {
            throw StateError('Post-restore checkpoint integrity check failed');
          }

          FileLogger.info('Checkpoint restored successfully', source: 'Checkpoint');
          await _logActivity(
            type: ActivityType.backupRestored,
            description: 'Restored checkpoint: ${path.basename(checkpointPath)}',
            actingUser: currentUser,
            target: path.basename(checkpointPath),
          );
          return true;
        } catch (e, stack) {
          FileLogger.error('Checkpoint restore failed; reverting', error: e, stackTrace: stack, source: 'Checkpoint');
          await _logActivity(
            type: ActivityType.backupRestoreFailed,
            description: 'Checkpoint restore failed: ${e.toString()}',
            actingUser: currentUser,
            target: path.basename(checkpointPath),
            reason: e.toString(),
          );
          if (await File(safetyPath).exists()) {
            if (await currentDbFile.exists()) {
              await currentDbFile.delete();
            }
            await File(safetyPath).copy(_databasePath);
          }
          return false;
        }
      } catch (e, stack) {
        FileLogger.error('Checkpoint restore failed', error: e, stackTrace: stack, source: 'Checkpoint');
        await _logActivity(
          type: ActivityType.backupRestoreFailed,
          description: 'Checkpoint restore failed: ${e.toString()}',
          actingUser: currentUser,
          target: path.basename(checkpointPath),
          reason: e.toString(),
        );
        return false;
      }
    });
  }

  /// Get the latest checkpoint directory.
  Future<Directory?> getLatestCheckpoint() async {
    final dir = Directory(_checkpointsPath);
    if (!dir.existsSync()) return null;

    final checkpoints = <Directory>[];
    await for (final entity in dir.list()) {
      if (entity is Directory && path.basename(entity.path).startsWith('chk_')) {
        checkpoints.add(entity);
      }
    }

    if (checkpoints.isEmpty) return null;
    checkpoints.sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
    return checkpoints.first;
  }

  /// Get all checkpoints with metadata.
  Future<List<Map<String, dynamic>>> getAllCheckpoints() async {
    final dir = Directory(_checkpointsPath);
    if (!dir.existsSync()) return [];

    final results = <Map<String, dynamic>>[];
    await for (final entity in dir.list()) {
      if (entity is Directory && path.basename(entity.path).startsWith('chk_')) {
        final metaFile = File(path.join(entity.path, 'metadata.json'));
        Map<String, dynamic> meta = {'path': entity.path, 'name': path.basename(entity.path)};
        if (await metaFile.exists()) {
          try {
            final content = await metaFile.readAsString();
            meta.addAll(jsonDecode(content) as Map<String, dynamic>);
          } catch (_) {}
        }
        results.add(meta);
      }
    }

    results.sort((a, b) => (b['timestamp'] ?? '').compareTo(a['timestamp'] ?? ''));
    return results;
  }

  /// Remove old checkpoints beyond max limit.
  Future<void> _cleanOldCheckpoints() async {
    try {
      final dir = Directory(_checkpointsPath);
      if (!dir.existsSync()) return;

      final checkpoints = <Directory>[];
      await for (final entity in dir.list()) {
        if (entity is Directory && path.basename(entity.path).startsWith('chk_')) {
          checkpoints.add(entity);
        }
      }

      if (checkpoints.length <= _maxCheckpoints) return;

      checkpoints.sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));

      // Delete oldest beyond limit
      for (var i = _maxCheckpoints; i < checkpoints.length; i++) {
        await checkpoints[i].delete(recursive: true);
        FileLogger.debug('Deleted old checkpoint: ${path.basename(checkpoints[i].path)}', source: 'Checkpoint');
      }
    } catch (e) {
      FileLogger.warning('Failed to clean old checkpoints', error: e, source: 'Checkpoint');
    }
  }
}
