import 'dart:io';

import 'package:bayaa_pos/features/auth/data/models/user_model.dart';
import 'package:bayaa_pos/features/auth/domain/repository/user_repository_int.dart';
import 'package:bayaa_pos/features/auth/presentation/cubit/user_states.dart';
import 'package:bayaa_pos/features/sessions/data/repositories/session_repository_impl.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/di/dependency_injection.dart';
import '../../../sales/domain/sales_repository.dart';
import '../../../../core/network/backend_api_config.dart';
import '../../../../core/network/backend_api_client.dart';

import '../../../../core/services/activity_logger.dart';
import '../../../../core/data/models/activity_log.dart';

import '../../../../core/session/session_manager.dart';
import '../../../../core/data/services/checkpoint_service.dart';
import '../../../sessions/data/models/product_performance_model.dart';
import '../../../sessions/data/models/session_model.dart';
import '../../../sales/presentation/cubit/draft_sales_cubit.dart';

class UserCubit extends Cubit<UserStates> {
  UserCubit({
    required this.userRepository,
    required this.sessionRepository,
  }) : super(UserInitial());

  final UserRepositoryInt userRepository;
  final SessionRepositoryImpl sessionRepository;

  static UserCubit get(context) => BlocProvider.of(context);
  late User currentUser;
  bool _isPasswordVisible = false;

  bool get isPasswordVisible => _isPasswordVisible;

  List<User> _users = [];
  List<User> get users =>
      _users; // Access cached users even if state is not Loaded

  Future<void> getAllUsers() async {
    emit(UserLoading());
    try {
      if (BackendApiConfig.serverAuthEnabled) {
        print('[AUTH_TRACE] server-auth user list loading from backend');
      } else {
        print('[AUTH_TRACE] local-user bootstrap started');
      }
      final result = await userRepository.getAllUsers();
      if (result.isLeft) {
        emit(UserFailure(result.left.message));
        return;
      }

      var usersList = result.right;
      if (!BackendApiConfig.serverAuthEnabled && usersList.isEmpty) {
        print('[AUTH_TRACE] no local users found; seeding local default admin');
        final defaultAdmin = User(
          username: 'admin',
          password: 'admin',
          name: 'System Administrator',
          userType: UserType.manager,
          phone: '000',
        );
        final saveResult = await userRepository.saveUser(defaultAdmin);
        if (saveResult.isLeft) {
          emit(UserFailure(saveResult.left.message));
          return;
        }
        final retryResult = await userRepository.getAllUsers();
        if (retryResult.isLeft) {
          emit(UserFailure(retryResult.left.message));
          return;
        }
        usersList = retryResult.right;
      }

      usersList.sort((a, b) {
        if (a.userType == UserType.manager && b.userType != UserType.manager) {
          return -1;
        }
        if (a.userType != UserType.manager && b.userType == UserType.manager) {
          return 1;
        }
        return 0;
      });
      _users = usersList;
      emit(UsersLoaded(List<User>.from(usersList)));
      print(
          '[AUTH_TRACE] ${BackendApiConfig.serverAuthEnabled ? 'server' : 'local'} user bootstrap completed (${usersList.length})');
    } catch (e, stackTrace) {
      print('[AUTH_TRACE] user bootstrap failed: $e\n$stackTrace');
      emit(UserFailure('Failed to initialize users: $e'));
    }
  }

  void deleteUser(String username) async {
    emit(UserLoading());
    final result = await userRepository.deleteUser(username);
    result.fold(
      (failure) => emit(UserFailure(failure.message)),
      (_) async {
        emit(UserSuccess("msgUserDeleted"));

        // Log activity with session (auto-creates session if closed)
        final sid = await getIt<SessionManager>().ensureSessionId(
          userName: currentUser.name,
        );
        await getIt<ActivityLogger>().logActivity(
          type: ActivityType.userDelete,
          description: 'Deleted user: $username',
          userName: currentUser.name,
          sessionId: sid,
          eventKey: 'userDeleted',
          parameters: {'user': currentUser.name, 'targetUser': username},
        );

        getAllUsers();
      },
    );
  }

  void saveUser(User user) async {
    emit(UserLoading());
    final result = await userRepository.saveUser(user);
    result.fold(
      (failure) => emit(UserFailure(failure.message)),
      (_) async {
        emit(UserSuccess("msgUserCreated"));

        // Check if update (simple check if username exists in list, though list might be empty if not loaded)
        // Since we just saved successfully, we can't check _users easily if username is same vs new?
        // Actually saveUser is usually Upsert.
        final isUpdate = _users.any((u) => u.username == user.username);

        // Log activity with session (auto-creates session if closed)
        final sid = await getIt<SessionManager>().ensureSessionId(
          userName: currentUser.name,
        );
        await getIt<ActivityLogger>().logActivity(
          type: isUpdate ? ActivityType.userUpdate : ActivityType.userAdd,
          description: isUpdate
              ? 'Updated user: ${user.name}'
              : 'Added user: ${user.name}',
          userName: currentUser.name,
          sessionId: sid,
          eventKey: isUpdate ? 'userUpdated' : 'userAdded',
          parameters: {'user': currentUser.name, 'targetUser': user.name},
        );

        getAllUsers();
      },
    );
  }

  void updateUser(User user) async {
    emit(UserLoading());
    final result = await userRepository.updateUser(user);
    result.fold(
      (failure) => emit(UserFailure(failure.message)),
      (_) async {
        if (currentUser.username == user.username) {
          currentUser = user;
        }
        emit(UserSuccess("msgUserUpdated"));

        // Log activity with session (auto-creates session if closed)
        final sid = await getIt<SessionManager>().ensureSessionId(
          userName: currentUser.name,
        );
        await getIt<ActivityLogger>().logActivity(
          type: ActivityType.userUpdate,
          description: 'Updated user: ${user.name}',
          userName: currentUser.name,
          sessionId: sid,
          eventKey: 'userUpdated',
          parameters: {'user': currentUser.name, 'targetUser': user.name},
        );

        getAllUsers();
      },
    );
  }

  void getUser(String username) async {
    emit(UserLoading());
    final result = await userRepository.getUser(username);
    result.fold(
      (failure) => emit(UserFailure(failure.message)),
      (user) =>
          emit(UserSuccess("User fetched successfully: ${user.username}")),
    );
  }

  Future<void> login(String username, String password) async {
    emit(UserLoading());
    final trimmedUsername = username.trim();
    final trimmedPassword = password.trim();
    print(
      '[AUTH_TRACE] auth mode=${BackendApiConfig.serverAuthEnabled ? 'server' : 'local'} '
      'login request username=$trimmedUsername',
    );
    try {
      if (BackendApiConfig.serverAuthEnabled) {
        final client = getIt<BackendApiClient>();
        final response = await client.login(
          username: trimmedUsername,
          password: trimmedPassword,
          deviceId: 'bayaa-${Platform.localHostname}',
        );
        final serverUserId = response['user_id'] as String? ??
            client.tokenStore.userId ??
            trimmedUsername;
        final serverRole =
            response['role'] as String? ?? client.tokenStore.role ?? '';
        final serverShopId =
            response['shop_id'] as String? ?? client.tokenStore.shopId ?? '';
        print(
          '[AUTH_TRACE] server login response '
          'user_id=$serverUserId shop_id=$serverShopId role=$serverRole',
        );
        print('[AUTH_TRACE] backend session cached in token store');
        final userType = switch (serverRole.trim().toLowerCase()) {
          'admin' => UserType.admin,
          'manager' => UserType.manager,
          'cashier' => UserType.cashier,
          _ => null,
        };
        if (userType == null) {
          client.logout();
          emit(UserFailure('Backend returned an unsupported user role'));
          return;
        }
        currentUser = User(
          name: serverUserId,
          username: serverUserId,
          password: '',
          phone: '',
          userType: userType,
        );
        if (getIt.isRegistered<DraftSalesCubit>()) {
          await getIt<DraftSalesCubit>().switchUser(
            client.tokenStore.userId ?? trimmedUsername,
          );
        }
        emit(LoginSuccess('loginNewSession'));
        return;
      }
      final result = await userRepository.getUser(trimmedUsername);
      if (result.isLeft) {
        emit(UserFailure(result.left.message));
        return;
      }
      final user = result.right;
      print("🔐 Login Attempt: '$trimmedUsername'");
      if (user.password == trimmedPassword) {
        currentUser = user;
        try {
          // Open Session on Login via SessionManager
          final sessionManager = getIt<SessionManager>();
          await sessionManager.loadSession(userId: user.username);
          final bool hadOpenSession =
              sessionManager.currentSession?.isOpen == true;

          final session = await sessionManager.getOrCreateSession(
            userId: user.username,
            userName: user.name,
          );

          // Log activity
          await getIt<ActivityLogger>().logActivity(
            type: ActivityType.login,
            description: 'Login',
            userName: user.name,
            sessionId: session.id,
            eventKey: 'login',
            parameters: {'user': user.name},
          );

          // Create checkpoint on login
          await CheckpointService().createCheckpoint(
              reason: 'login_${user.username}', userName: user.name);

          if (hadOpenSession) {
            emit(LoginSuccess("loginExistingSession", isExistingSession: true));
          } else {
            emit(LoginSuccess("loginNewSession", isExistingSession: false));
          }
        } catch (e) {
          emit(UserFailure("failedOpenDay:$e"));
        }
      } else {
        print('[AUTH] local authentication failed');
        emit(UserFailure("wrongPassword"));
      }
      print('[AUTH_TRACE] local authentication completed');
    } catch (e, stackTrace) {
      print('[AUTH_TRACE] authentication failed: $e\n$stackTrace');
      emit(UserFailure("failedOpenDay:$e"));
    }
  }

  Future<void> closeSession() async {
    emit(CloseSessionLoading());
    try {
      final sessionManager = getIt<SessionManager>();
      print('DEBUG_SESSION: UserCubit.closeSession called');
      print(
          'DEBUG_SESSION: Manager.currentSession: ${sessionManager.currentSession?.id}');
      print(
          'DEBUG_SESSION: Repo.getCurrentSession: ${sessionRepository.getCurrentSession()?.id}');

      final session =
          sessionManager.currentSession; // Get pure object from manager/repo

      if (session == null || !session.isOpen) {
        print(
            'DEBUG_SESSION: No open session found in manager. Attempting loadSession...');
        // Try forcing a load just in case (e.g. if started sealed)
        await sessionManager.loadSession();
        if (sessionManager.currentSession == null) {
          print(
              'DEBUG_SESSION: Still no session after load. Emitting failure.');
          emit(UserFailure("noOpenSession"));
          return;
        }
      }

      final currentSessionToClose = sessionManager.currentSession!;

      // if (currentSessionToClose.id == null) {
      //     emit(UserFailure("خطأ في معرف اليوم"));
      //     return;
      // }

      // Robust Session Capture: Time-Based + ID-Based
      // We explicitly scan recent sales to ensure nothing is missed
      final salesRepo = getIt<SalesRepository>();
      final legacyResult = await salesRepo.getRecentSales(limit: 200000);
      final allRecent = legacyResult.getOrElse(() => []);

      final sales = allRecent.where((s) {
        // 1. Explicit Session Match
        if (s.sessionId == currentSessionToClose.id) return true;

        // 2. Time Window Match (Fallback for orphans or missing IDs)
        // "From Start to End" as requested by user
        if (s.date.isAfter(currentSessionToClose.openTime) &&
            s.date.isBefore(DateTime.now())) {
          // If manual linking failed, time is the source of truth
          return true;
        }
        return false;
      }).toList();

      // Ensure all found sales are linked to this session in DB
      // This fixes "No Data" bug for orphans found by time-window
      if (sales.isNotEmpty) {
        await salesRepo.linkSalesToSession(
            sales.map((e) => e.id).toList(), currentSessionToClose.id);
      }

      double totalSales = 0.0;
      double totalRefunds = 0.0;
      final Map<String, ProductPerformanceModel> productStats = {};
      final Map<String, ProductPerformanceModel> refundStats = {};
      final historicalCosts =
          await sessionRepository.historicalCogsBySaleProduct(sales);
      final historicalCogsAvailable =
          historicalCosts.values.every((cost) => cost != null);
      final totalHistoricalCogs = historicalCogsAvailable
          ? historicalCosts.values.fold<double>(
              0,
              (total, cost) => total + cost!,
            )
          : null;
      final costProductsSeen = <String>{};

      for (final sale in sales) {
        final isRefund = sale.isRefund;
        final sign = isRefund ? -1.0 : 1.0;

        if (isRefund) {
          totalRefunds += sale.total.abs();
        } else {
          totalSales += sale.total;
        }

        for (final item in sale.saleItems) {
          final revenue = (item.price * item.quantity) * sign;
          final costKey = '${sale.id}::${item.productId}';
          final cost = costProductsSeen.add(costKey)
              ? historicalCosts[costKey] ?? 0.0
              : 0.0;

          // Main Stats (Net)
          if (productStats.containsKey(item.productId)) {
            final existing = productStats[item.productId]!;
            productStats[item.productId] = ProductPerformanceModel(
              productId: existing.productId,
              productName: existing.productName,
              quantitySold: (existing.quantitySold +
                  (item.quantity * (isRefund ? -1 : 1)).toInt()),
              revenue: existing.revenue + revenue,
              cost: existing.cost + cost,
              profit: 0,
              profitMargin: 0,
            );
          } else {
            productStats[item.productId] = ProductPerformanceModel(
              productId: item.productId,
              productName: item.name,
              quantitySold: (item.quantity * (isRefund ? -1 : 1)).toInt(),
              revenue: revenue,
              cost: cost,
              profit: 0,
              profitMargin: 0,
            );
          }

          // Refund Specific Stats
          if (isRefund) {
            if (refundStats.containsKey(item.productId)) {
              final existing = refundStats[item.productId]!;
              refundStats[item.productId] = existing.copyWith(
                quantitySold: existing.quantitySold + item.quantity.toInt(),
                revenue: existing.revenue + item.total, // Refund amount
                cost: existing.cost + cost.abs(), // Refund amount
              );
            } else {
              refundStats[item.productId] = ProductPerformanceModel(
                productId: item.productId,
                productName: item.name,
                quantitySold: item.quantity.toInt(),
                revenue: item.total, // Refunded Amount
                cost: cost.abs(),
                profit: 0,
                profitMargin: 0,
              );
            }
          }
        }
      }

      final List<ProductPerformanceModel> topProducts =
          productStats.values.map((p) {
        final profit = p.revenue - p.cost;
        final margin = p.revenue > 0 ? (profit / p.revenue) * 100 : 0.0;
        return p.copyWith(profit: profit, profitMargin: margin);
      }).toList()
            ..sort((a, b) => b.revenue.compareTo(a.revenue));

      final List<ProductPerformanceModel> refundedProducts =
          refundStats.values.toList();

      final netRevenue = totalSales - totalRefunds;

      // Close session via SessionManager
      final report = await sessionManager.closeCurrentSession(
        currentUser,
        totalSales: totalSales,
        totalRefunds: totalRefunds,
        netRevenue: netRevenue,
        totalTransactions: sales.length,
        topProducts: topProducts,
        refundedProducts: refundedProducts,
        transactions: sales,
        historicalCogs: totalHistoricalCogs,
        historicalCogsAvailable: historicalCogsAvailable,
      );

      // Log activity with session
      await getIt<ActivityLogger>().logActivity(
        type: ActivityType.sessionClose,
        description: 'Closed day: ${totalSales.toStringAsFixed(2)} DA',
        userName: currentUser.name,
        sessionId: currentSessionToClose.id,
        eventKey: 'sessionClosed',
        parameters: {'user': currentUser.name},
      );

      // Create checkpoint on session close
      await CheckpointService().createCheckpoint(
          reason: 'session_close_${currentUser.username}',
          userName: currentUser.name);

      // Create closed session for navigation
      final closedSession = Session(
        id: currentSessionToClose.id,
        openTime: currentSessionToClose.openTime,
        closeTime: report.date,
        isOpen: false,
        openedByUserId: currentSessionToClose.openedByUserId,
        closedByUserId: currentUser.username, // User model uses username as ID
        invoiceIds: currentSessionToClose.invoiceIds,
        dailyReportId: report.id,
      );

      emit(UserSuccessWithReport(
          "dayClosedSuccessReport", report, closedSession));
    } catch (e) {
      emit(UserFailure("failedCloseDay:$e"));
    }
  }

  void togglePasswordVisibility() {
    _isPasswordVisible = !_isPasswordVisible;
    emit(PasswordVisibilityChanged(_isPasswordVisible));
  }

  Future<void> invalidateCurrentSession({String? reason}) async {
    final previousUserName = currentUser.username;
    final sessionManager =
        getIt.isRegistered<SessionManager>() ? getIt<SessionManager>() : null;
    final sessionRepository = getIt.isRegistered<SessionRepositoryImpl>()
        ? getIt<SessionRepositoryImpl>()
        : null;

    sessionRepository?.clearCurrentSession();
    sessionManager?.clearCurrentSession();

    currentUser = User(
        name: '',
        phone: '',
        username: '',
        password: '',
        userType: UserType.cashier);
    emit(UserInitial());

    if (previousUserName.isNotEmpty &&
        getIt.isRegistered<ActivityLogger>() &&
        reason != null) {
      try {
        await getIt<ActivityLogger>().logActivity(
          type: ActivityType.login,
          description: 'Session invalidated: $reason',
          userName: previousUserName,
          eventKey: 'session_invalidated',
          parameters: {'reason': reason},
        );
      } catch (_) {
        // Session invalidation should fail closed without breaking the logout flow.
      }
    }
  }

  Future<void> reloadAuthenticatedUserFromDatabase() async {
    final username = currentUser.username;
    print('DEBUG_AUTH_RELOAD: currentUser.username=$username');
    if (username.isEmpty) {
      print('DEBUG_AUTH_RELOAD: username empty, return');
      return;
    }

    final result = await userRepository.getUser(username);
    var userMissing = false;
    User? refreshedUser;
    result.fold((_) {
      userMissing = true;
    }, (user) {
      refreshedUser = user;
    });

    print(
        'DEBUG_AUTH_RELOAD: userMissing=$userMissing refreshedUser=${refreshedUser?.username ?? "null"}');
    if (userMissing) {
      await invalidateCurrentSession(
        reason: 'user missing from current database',
      );
      print(
          'DEBUG_AUTH_RELOAD: invalidated currentUser=${currentUser.username}');
      return;
    }

    if (refreshedUser != null) {
      currentUser = refreshedUser!;
      print('DEBUG_AUTH_RELOAD: refreshed to ${currentUser.username}');
    }
  }

  void logout() {
    if (getIt.isRegistered<SessionManager>()) {
      getIt<SessionManager>().clearCurrentSession();
    }
    if (getIt.isRegistered<DraftSalesCubit>()) {
      getIt<DraftSalesCubit>().clearForLogout();
    }
    if (getIt.isRegistered<BackendApiClient>()) {
      getIt<BackendApiClient>().logout();
    }
    _users = <User>[];
    currentUser = User(
        name: '',
        phone: '',
        username: '',
        password: '',
        userType: UserType.cashier);
    emit(UserInitial());
  }
}
