import 'package:bayaa_pos/features/auth/data/models/user_model.dart';

class PermissionDeniedException implements Exception {
  final String message;
  PermissionDeniedException(
      [this.message =
          "Access denied: You don't have permission to perform this action."]);

  @override
  String toString() => message;
}

class PermissionGuard {
  static bool canViewAnalytics(User user) =>
      user.userType == UserType.admin || user.userType == UserType.manager;

  static bool canViewWholesaleAndMinimumPrices(User user) =>
      switch (user.userType) {
        UserType.admin || UserType.manager || UserType.cashier => true,
      };

  static bool canViewReports(User user) => canViewAnalytics(user);

  static bool canViewSessions(User user) => canViewAnalytics(user);

  static bool canViewStockSummary(User user) => canViewAnalytics(user);

  static bool canManageUsers(User user) => user.userType == UserType.admin;

  static bool canAccessSettings(User user) =>
      user.userType == UserType.admin || user.userType == UserType.manager;

  static bool canManageDataAdministration(User user) =>
      user.userType == UserType.manager || user.userType == UserType.admin;

  static void requireDataManagementAccess(User user) {
    if (!canManageDataAdministration(user)) {
      throw PermissionDeniedException(
        'Data management actions require manager or admin privileges.',
      );
    }
  }

  static bool canAccessCustomerModule(User user) =>
      user.userType == UserType.manager || user.userType == UserType.admin;

  static bool canAccessSupplierModule(User user) =>
      user.userType == UserType.manager || user.userType == UserType.admin;

  static bool canAdjustStock(User user) =>
      (user.userType == UserType.manager || user.userType == UserType.admin) &&
      user.hasPermission('stock.adjust');

  static bool canManageOpeningStock(User user) =>
      (user.userType == UserType.manager || user.userType == UserType.admin) &&
      user.hasPermission('stock.opening_stock');

  static bool canExecuteCompatibilityRepair(User user) =>
      user.userType == UserType.admin;

  static bool canReviewHistoricalFindings(User user) =>
      user.userType == UserType.manager || user.userType == UserType.admin;

  static bool canApproveHistoricalFindings(User user) =>
      user.userType == UserType.admin;

  static void requireCompatibilityRepairAccess(User user) {
    if (!canExecuteCompatibilityRepair(user)) {
      throw PermissionDeniedException(
        'Legacy compatibility repair execution requires admin privileges.',
      );
    }
  }

  static void requireHistoricalReviewAccess(User user) {
    if (!canReviewHistoricalFindings(user)) {
      throw PermissionDeniedException(
        'Historical review access requires manager or admin privileges.',
      );
    }
  }

  static void requireHistoricalReviewApproval(User user) {
    if (!canApproveHistoricalFindings(user)) {
      throw PermissionDeniedException(
        'Historical review approval requires admin privileges.',
      );
    }
  }

  static void requireAdminCompatibilityRepair(User user) =>
      requireCompatibilityRepairAccess(user);

  static void requireAdminHistoricalRepair(User user) =>
      requireCompatibilityRepairAccess(user);

  static void requireOpeningStockPermission(User user) {
    if (!canManageOpeningStock(user)) {
      throw PermissionDeniedException(
        'Opening stock requires manager or admin privileges.',
      );
    }
  }

  static bool canCreatePurchase(User user) =>
      user.userType == UserType.manager || user.userType == UserType.admin;

  static bool canManageOrdersAndProformas(User user) =>
      user.userType == UserType.manager || user.userType == UserType.admin;

  static void requireOrdersAndProformasAccess(User user) {
    if (!canManageOrdersAndProformas(user)) {
      throw PermissionDeniedException(
        'Orders and proformas require manager or admin privileges.',
      );
    }
  }

  static void requirePurchaseAccess(User user) {
    if (!canCreatePurchase(user)) {
      throw PermissionDeniedException(
        'Purchase creation requires manager or admin privileges.',
      );
    }
  }

  static bool canCreateSupplierPayment(User user) =>
      user.userType == UserType.manager || user.userType == UserType.admin;

  static void requireSupplierPaymentAccess(User user) {
    if (!canCreateSupplierPayment(user)) {
      throw PermissionDeniedException(
        'Supplier payments require manager or admin privileges.',
      );
    }
  }

  static bool canCreateCustomerPayment(User user) =>
      user.userType == UserType.manager || user.userType == UserType.admin;

  static void requireCustomerPaymentAccess(User user) {
    if (!canCreateCustomerPayment(user)) {
      throw PermissionDeniedException(
        'Customer payments require manager or admin privileges.',
      );
    }
  }

  static bool canCreateCustomerReturn(User user) =>
      user.userType == UserType.manager || user.userType == UserType.admin;

  static void requireCustomerReturnAccess(User user) {
    if (!canCreateCustomerReturn(user)) {
      throw PermissionDeniedException(
        'Customer returns require manager or admin privileges.',
      );
    }
  }

  static bool canCreateSupplierReturn(User user) =>
      user.userType == UserType.manager || user.userType == UserType.admin;

  static void requireSupplierReturnAccess(User user) {
    if (!canCreateSupplierReturn(user)) {
      throw PermissionDeniedException(
        'Supplier returns require manager or admin privileges.',
      );
    }
  }

  static bool canViewLedger(User user) =>
      user.userType == UserType.manager ||
      user.userType == UserType.admin ||
      user.userType == UserType.cashier;

  static void checkRefundPermission(User user) {
    return;
  }

  static void checkReportAccess(User user) {
    if (!canViewReports(user)) {
      throw PermissionDeniedException(
        'Reports require manager or admin privileges.',
      );
    }
  }

  static void checkDayClosePermission(User user) {
    return;
  }

  static void requireCustomerAccess(User user) {
    if (!canAccessCustomerModule(user)) {
      throw PermissionDeniedException(
        'Customer management is restricted to managers and admins.',
      );
    }
  }

  static void requireSupplierAccess(User user) {
    if (!canAccessSupplierModule(user)) {
      throw PermissionDeniedException(
        'Supplier management is restricted to managers and admins.',
      );
    }
  }

  static void requireStockAdjustmentPermission(User user) {
    if (!canAdjustStock(user)) {
      throw PermissionDeniedException(
        'Stock adjustment requires manager or admin privileges.',
      );
    }
  }
}
