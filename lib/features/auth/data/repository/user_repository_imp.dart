import 'package:bayaa_pos/core/data/services/persistence_initializer.dart';
import 'package:bayaa_pos/core/data/services/repository_persistence_mixin.dart';
import 'package:bayaa_pos/core/error/failure.dart';
import 'package:bayaa_pos/core/error/error_handler.dart';
import 'package:bayaa_pos/core/network/backend_api_client.dart';
import 'package:bayaa_pos/core/network/backend_api_config.dart';
import 'package:bayaa_pos/core/state/state_synchronizer.dart';
import 'package:bayaa_pos/features/auth/data/models/user_model.dart';
import 'package:bayaa_pos/features/auth/domain/repository/user_repository_int.dart';
import 'package:either_dart/either.dart';
import 'package:get_it/get_it.dart';

class UserRepositoryImp extends UserRepositoryInt
    with RepositoryPersistenceMixin {
  UserRepositoryImp();

  @override
  Future<Either<Failure, void>> deleteUser(String username) async {
    if (BackendApiConfig.serverAuthEnabled) {
      return _deleteUserFromServer(username);
    }

    try {
      await deleteCritical(
        entity: 'user',
        id: username,
        sqliteWrite: () async {
          final db = PersistenceInitializer.persistenceManager!.sqliteManager;
          await db
              .delete('users', where: 'username = ?', whereArgs: [username]);
        },
      );
      return const Right(null);
    } on Exception catch (e) {
      return Left(CacheFailure("Failed to delete user: ${e.toString()}"));
    }
  }

  Future<Either<Failure, void>> _deleteUserFromServer(String username) async {
    try {
      final client = GetIt.instance<BackendApiClient>();
      await client.deleteUser(username);
      return const Right(null);
    } on BackendApiException catch (e) {
      return Left(CacheFailure(e.message));
    } on Exception catch (e) {
      return Left(CacheFailure("Failed to delete user: ${e.toString()}"));
    }
  }

  @override
  Future<Either<Failure, List<User>>> getAllUsers() async {
    if (BackendApiConfig.serverAuthEnabled) {
      return _getAllUsersFromServer();
    }

    try {
      print('👥 === LOADING USERS (SQLite) ===');

      final db = PersistenceInitializer.persistenceManager!.sqliteManager;
      final results = await db.query('users', where: 'is_active = 1');
      print('  👤 Users found in SQL: ${results.length}');

      final users = results
          .map((m) => User(
                name: m['display_name'] as String,
                username: m['username'] as String,
                password: m['password_hash'] as String? ?? '',
                userType: _mapRoleToUserType(m['role'] as String),
                phone: m['phone'] as String? ?? '',
                imagePath: m['image_path'] as String?,
              ))
          .toList();

      for (var user in users) {
        print(' - ${user.name} (@${user.username}) - ${user.userType.name}');
      }

      return Right(users);
    } on Exception catch (e) {
      print('  ❌ Failed to load users: $e');
      return Left(CacheFailure("Failed to fetch users: ${e.toString()}"));
    }
  }

  Future<Either<Failure, List<User>>> _getAllUsersFromServer() async {
    try {
      final client = GetIt.instance<BackendApiClient>();
      final results = await client.getUsers();
      final users = results.map(User.fromServerMap).toList();
      return Right(users);
    } on BackendApiException catch (e) {
      return Left(CacheFailure(e.message));
    } on Exception catch (e) {
      return Left(CacheFailure("Failed to fetch users: ${e.toString()}"));
    }
  }

  UserType _mapRoleToUserType(String role) {
    switch (role.trim().toLowerCase()) {
      case 'manager':
        return UserType.manager;
      case 'admin':
        return UserType.admin;
      default:
        return UserType.cashier;
    }
  }

  String _roleFromUserType(UserType userType) {
    switch (userType) {
      case UserType.admin:
        return 'admin';
      case UserType.manager:
        return 'manager';
      case UserType.cashier:
        return 'cashier';
    }
  }

  Map<String, dynamic> _serverUserPayload(User user) {
    return {
      'username': user.username,
      'display_name': user.name,
      'phone': user.phone,
      'password': user.password,
      'role': _roleFromUserType(user.userType),
      'is_active': true,
    };
  }

  Map<String, dynamic> _serverUserUpdatePayload(User user) {
    final payload = <String, dynamic>{
      'display_name': user.name,
      'phone': user.phone,
      'role': _roleFromUserType(user.userType),
      'is_active': true,
    };
    if (user.password.trim().isNotEmpty) {
      payload['password'] = user.password;
    }
    return payload;
  }

  @override
  Future<Either<Failure, User>> getUser(String username) async {
    if (BackendApiConfig.serverAuthEnabled) {
      final result = await getAllUsers();
      return result.fold(
        (failure) => Left(failure),
        (users) {
          for (final user in users) {
            if (user.username == username) {
              return Right(user);
            }
          }
          return Left(CacheFailure('User not found'));
        },
      );
    }

    try {
      print('👤 === GETTING USER: $username (SQLite) ===');

      final db = PersistenceInitializer.persistenceManager!.sqliteManager;
      final results = await db.query('users',
          where: 'username = ? AND is_active = 1', whereArgs: [username]);

      if (results.isNotEmpty) {
        final userMap = results.first;
        final user = User(
          name: userMap['display_name'] as String,
          username: userMap['username'] as String,
          password: userMap['password_hash'] as String,
          userType: _mapRoleToUserType(userMap['role'] as String),
          phone: userMap['phone'] as String? ?? '',
          imagePath: userMap['image_path'] as String?,
        );

        print('  ✅ User found: ${user.name}');
        return Right(user);
      } else {
        print('  ❌ User not found');
        return Left(CacheFailure("User not found"));
      }
    } on Exception catch (e) {
      print('  ❌ Failed to get user: $e');
      return Left(CacheFailure("Failed to fetch user: ${e.toString()}"));
    }
  }

  @override
  Future<Either<Failure, void>> saveUser(User user) async {
    if (BackendApiConfig.serverAuthEnabled) {
      try {
        final client = GetIt.instance<BackendApiClient>();
        await client.createUser(_serverUserPayload(user));
        return const Right(null);
      } on BackendApiException catch (e) {
        return Left(CacheFailure(e.message));
      } on Exception catch (e) {
        return Left(CacheFailure("Failed to save user: ${e.toString()}"));
      }
    }

    return ErrorHandler.executeWithErrorHandlingEitherDart(
      operation: () async {
        print('👤 === SAVING USER (SQLite) ===');
        print('  📝 Name: ${user.name}');
        print('  👤 Username: ${user.username}');

        final isUpdate = await _userExists(user.username);

        await writeCritical(
          entity: 'user',
          id: user.username,
          data: user.toMap(),
          sqliteWrite: () async {
            final db = PersistenceInitializer.persistenceManager!.sqliteManager;

            final existing = await db.query('users',
                where: 'username = ?', whereArgs: [user.username]);
            print(
                '  🗄️ Database Action: ${existing.isNotEmpty ? "UPDATE" : "INSERT"}');

            final values = <String, Object?>{
              'username': user.username,
              'display_name': user.name,
              'phone': user.phone,
              'image_path': user.imagePath,
              'password_hash': user.password,
              'role': switch (user.userType) {
                UserType.admin => 'admin',
                UserType.manager => 'manager',
                UserType.cashier => 'cashier',
              },
              'is_active': 1,
            };
            if (existing.isNotEmpty) {
              await db.update(
                'users',
                values,
                where: 'username = ?',
                whereArgs: [user.username],
              );
            } else {
              await db.insert('users', {
                'id': user.username,
                ...values,
                'created_at': DateTime.now().toIso8601String(),
              });
            }
          },
        );

        StateSynchronizer.notify(DataChangeEvent(
          entityType: 'user',
          operation: isUpdate ? 'update' : 'create',
          id: user.username,
        ));

        print('  ✅ User saved successfully\n');
        return const Right(null);
      },
      operationName: 'saveUser',
      userFriendlyMessage: 'Failed to save user',
      source: 'UserRepository',
    );
  }

  Future<bool> _userExists(String username) async {
    try {
      final db = PersistenceInitializer.persistenceManager!.sqliteManager;
      final result =
          await db.query('users', where: 'username = ?', whereArgs: [username]);
      return result.isNotEmpty;
    } catch (e) {
      return false;
    }
  }

  @override
  Future<Either<Failure, void>> updateUser(User user) async {
    if (BackendApiConfig.serverAuthEnabled) {
      try {
        final client = GetIt.instance<BackendApiClient>();
        await client.updateUser(
          user.username,
          _serverUserUpdatePayload(user),
        );
        return const Right(null);
      } on BackendApiException catch (e) {
        return Left(CacheFailure(e.message));
      } on Exception catch (e) {
        return Left(CacheFailure("Failed to update user: ${e.toString()}"));
      }
    }
    return saveUser(user);
  }
}
