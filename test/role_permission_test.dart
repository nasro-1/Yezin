import 'package:bayaa_pos/core/security/permission_guard.dart';
import 'package:bayaa_pos/features/auth/data/models/user_model.dart';
import 'package:flutter_test/flutter_test.dart';

User _user(UserType type) => User(
      username: type.name,
      name: type.name,
      phone: '',
      userType: type,
      password: '',
    );

void main() {
  test('admin and manager can access analytics reporting and stock summary',
      () {
    for (final role in [UserType.admin, UserType.manager]) {
      final user = _user(role);
      expect(PermissionGuard.canViewAnalytics(user), isTrue);
      expect(PermissionGuard.canViewReports(user), isTrue);
      expect(PermissionGuard.canViewSessions(user), isTrue);
      expect(PermissionGuard.canViewStockSummary(user), isTrue);
    }
  });

  test('cashier cannot access analytics reporting sessions or stock summary',
      () {
    final user = _user(UserType.cashier);
    expect(PermissionGuard.canViewAnalytics(user), isFalse);
    expect(PermissionGuard.canViewReports(user), isFalse);
    expect(PermissionGuard.canViewSessions(user), isFalse);
    expect(PermissionGuard.canViewStockSummary(user), isFalse);
    expect(PermissionGuard.canManageUsers(user), isFalse);
    expect(PermissionGuard.canAccessSettings(user), isFalse);
  });

  test('all application roles can view commercial product prices', () {
    for (final role in [
      UserType.admin,
      UserType.manager,
      UserType.cashier,
    ]) {
      expect(
        PermissionGuard.canViewWholesaleAndMinimumPrices(_user(role)),
        isTrue,
      );
    }
  });

  test('only admin can manage users while manager retains operations', () {
    expect(PermissionGuard.canManageUsers(_user(UserType.admin)), isTrue);
    expect(PermissionGuard.canManageUsers(_user(UserType.manager)), isFalse);
    expect(PermissionGuard.canAccessCustomerModule(_user(UserType.manager)),
        isTrue);
    expect(PermissionGuard.canAccessSupplierModule(_user(UserType.manager)),
        isTrue);
    expect(PermissionGuard.canManageOrdersAndProformas(_user(UserType.manager)),
        isTrue);
  });
}
