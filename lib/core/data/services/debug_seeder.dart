// lib/core/data/services/debug_seeder.dart

import 'dart:io';

import 'package:bayaa_pos/core/data/services/configuration_storage.dart';
import 'package:bayaa_pos/core/data/services/persistence_initializer.dart';
import 'package:bayaa_pos/core/di/dependency_injection.dart';
import 'package:bayaa_pos/core/security/permission_guard.dart';
import 'package:bayaa_pos/core/services/activity_logger.dart';
import 'package:bayaa_pos/features/auth/data/models/user_model.dart';
import 'package:bayaa_pos/features/auth/presentation/cubit/user_cubit.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../models/activity_log.dart';

class DebugSeeder {
  static User? _resolveCurrentUser({User? actingUser}) {
    if (actingUser != null) return actingUser;
    if (getIt.isRegistered<UserCubit>()) {
      return getIt<UserCubit>().currentUser;
    }
    return null;
  }

  static Future<void> _logActivity({
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
        eventKey: target != null ? 'demo_seed_${type.name}' : null,
        parameters: {
          if (target != null) 'target': target,
          if (reason != null) 'reason': reason,
          if (parameters != null) ...parameters,
        },
      );
    } catch (_) {}
  }

  static bool _isAllowedInDevelopment() {
    final manager = PersistenceInitializer.persistenceManager;
    if (manager == null) return false;

    final config = manager.config;
    if (config.appMode != ConfigurationStorage.developmentMode) return false;

    final devRoot = config.developmentDataRootPath;
    if (devRoot == null || devRoot.trim().isEmpty) return false;

    final currentRoot = manager.pathResolver.dataRootPath;
    return path.normalize(devRoot) == path.normalize(currentRoot);
  }

  static Future<void> seedIfNeeded() async {
    final manager = PersistenceInitializer.persistenceManager;
    if (manager == null) return;

    final config = manager.config;
    if (config.appMode != ConfigurationStorage.developmentMode) return;
    if (!_isAllowedInDevelopment()) {
      print(
          '🚫 Demo seeding blocked: Development mode is not using a safe, separate data root.');
      return;
    }

    final db = manager.sqliteManager;

    try {
      final requiredUsernames = <String>{
        'admin',
        'manager',
        'cashier-1',
        'cashier',
      };
      final existingUsers = await db.query(
        'users',
        columns: ['username'],
        where: 'username IN (${requiredUsernames.map((_) => '?').join(', ')})',
        whereArgs: requiredUsernames.toList(),
      );
      final existingUsernames = existingUsers
          .map((row) => row['username'] as String?)
          .whereType<String>()
          .toSet();

      final missingUsers = requiredUsernames.difference(existingUsernames);
      if (missingUsers.isNotEmpty) {
        print(
            '🔐 Demo users missing: ${missingUsers.join(', ')}. Seeding required credentials.');
        await _ensureRequiredDemoUsers();
        await _seedExpensesIfNeeded();
        return;
      }

      // Reconcile development credentials and roles on every startup so an
      // existing database cannot retain stale role mappings.
      await _ensureRequiredDemoUsers();

      // Check if products are already seeded
      final productsCount =
          await db.query('products', columns: ['COUNT(*) as count']);
      final count = productsCount.isNotEmpty
          ? (productsCount.first['count'] as int? ?? 0)
          : 0;
      if (count > 0) {
        await _seedExpensesIfNeeded();
        print('ℹ️ Products already seeded. Skipping auto-seeding.');
        return;
      }

      print('🌱 Empty database in debug mode. Seeding mock data...');
      await seedAll();
    } catch (e) {
      print('❌ Error checking / seeding database: $e');
    }
  }

  static Future<void> _ensureRequiredDemoUsers() async {
    final db = PersistenceInitializer.persistenceManager?.sqliteManager;
    if (db == null) return;

    final rows = [
      {
        'id': 'admin',
        'username': 'admin',
        'display_name': 'System Administrator',
        'password_hash': 'admin',
        'role': 'admin',
        'is_active': 1,
      },
      {
        'id': 'manager',
        'username': 'manager',
        'display_name': 'Manager',
        'password_hash': 'manager',
        'role': 'manager',
        'is_active': 1,
      },
      {
        'id': 'cashier-1',
        'username': 'cashier-1',
        'display_name': 'Cashier',
        'password_hash': 'cashier',
        'role': 'cashier',
        'is_active': 1,
      },
      {
        'id': 'cashier',
        'username': 'cashier',
        'display_name': 'Trial Cashier',
        'password_hash': 'cashier',
        'role': 'cashier',
        'is_active': 1,
      },
    ];

    for (final row in rows) {
      final existing = await db.query(
        'users',
        where: 'username = ?',
        whereArgs: [row['username']],
      );
      if (existing.isNotEmpty) {
        await db.update(
          'users',
          {
            'display_name': row['display_name'],
            'password_hash': row['password_hash'],
            'role': row['role'],
            'is_active': row['is_active'],
          },
          where: 'username = ?',
          whereArgs: [row['username']],
        );
      } else {
        await db.insert(
            'users',
            {
              ...row,
              'created_at': DateTime.now().toIso8601String(),
            },
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
    }
  }

  static Future<void> _seedExpensesIfNeeded() async {
    final db = PersistenceInitializer.persistenceManager?.sqliteManager;
    if (db == null) return;
    final result = await db.query('expenses', columns: ['COUNT(*) as count']);
    final count = result.isEmpty ? 0 : (result.first['count'] as int? ?? 0);
    if (count > 0) return;

    final now = DateTime.now();
    final samples = [
      ('rent', 'إيجار المحل', 6200.0, 'rent', 6),
      ('electricity', 'فاتورة الكهرباء', 1450.0, 'utilities', 4),
      ('internet', 'الإنترنت والاتصالات', 780.0, 'utilities', 3),
      ('delivery', 'شحن وتوصيل طلبات', 560.0, 'operations', 2),
      ('maintenance', 'صيانة وتجهيزات', 900.0, 'maintenance', 1),
      ('supplies', 'أدوات مكتبية وتغليف', 430.0, 'supplies', 0),
    ];
    for (final sample in samples) {
      await db.insert(
          'expenses',
          {
            'id': 'debug_expense_${sample.$1}',
            'title': sample.$2,
            'amount': sample.$3,
            'category': sample.$4,
            'notes': 'بيانات تجريبية لوضع التطوير',
            'created_at':
                now.subtract(Duration(days: sample.$5)).toIso8601String(),
            'user_id': 'admin',
          },
          conflictAlgorithm: ConflictAlgorithm.ignore);
    }
  }

  static Future<void> seedAll() async {
    final manager = PersistenceInitializer.persistenceManager;
    if (manager == null) return;

    final config = manager.config;
    if (config.appMode != ConfigurationStorage.developmentMode) {
      print(
          '🚫 Demo seeding rejected: only Development Mode may initialize demo data.');
      return;
    }
    if (!_isAllowedInDevelopment()) {
      print(
          '🚫 Demo seeding rejected: demo data must target a separate development data root.');
      return;
    }

    final db = manager.sqliteManager;

    await db.transaction((txn) async {
      final now = DateTime.now().toIso8601String();

      // 1. Seed Users
      await txn.insert(
          'users',
          {
            'id': 'admin',
            'username': 'admin',
            'display_name': 'System Administrator',
            'password_hash': 'admin',
            'role': 'admin',
            'is_active': 1,
            'created_at': now,
          },
          conflictAlgorithm: ConflictAlgorithm.replace);

      await txn.insert(
          'users',
          {
            'id': 'cashier-1',
            'username': 'cashier-1',
            'display_name': 'Cashier',
            'password_hash': 'cashier',
            'role': 'cashier',
            'is_active': 1,
            'created_at': now,
          },
          conflictAlgorithm: ConflictAlgorithm.replace);

      await txn.insert(
          'users',
          {
            'id': 'cashier',
            'username': 'cashier',
            'display_name': 'Trial Cashier',
            'password_hash': 'cashier',
            'role': 'cashier',
            'is_active': 1,
            'created_at': now,
          },
          conflictAlgorithm: ConflictAlgorithm.replace);

      // 2. Seed Categories
      final categories = [
        {'id': 'هواتف', 'name': 'هواتف', 'sort_order': 1},
        {'id': 'إكسسوارات', 'name': 'إكسسوارات', 'sort_order': 2},
        {'id': 'شواحن', 'name': 'شواحن', 'sort_order': 3},
        {'id': 'صيانة', 'name': 'صيانة', 'sort_order': 4},
        {'id': 'سماعات', 'name': 'سماعات', 'sort_order': 5},
      ];

      for (var cat in categories) {
        await txn.insert('categories', cat,
            conflictAlgorithm: ConflictAlgorithm.replace);
      }

      // 3. Seed Products
      final products = [
        {
          'id': '111111',
          'barcode': '111111',
          'name': 'iPhone 13 Pro Max',
          'price': 35000.0,
          'min_price': 34000.0,
          'wholesale_price': 32000.0,
          'cost': 32000.0,
          'stock': 15.0,
          'min_stock': 3.0,
          'category_id': 'هواتف',
          'is_active': 1,
          'created_at': now,
          'updated_at': now,
        },
        {
          'id': '222222',
          'barcode': '222222',
          'name': 'Samsung Galaxy S22 Ultra',
          'price': 28000.0,
          'min_price': 27000.0,
          'wholesale_price': 25000.0,
          'cost': 25000.0,
          'stock': 8.0,
          'min_stock': 2.0,
          'category_id': 'هواتف',
          'is_active': 1,
          'created_at': now,
          'updated_at': now,
        },
        {
          'id': '333333',
          'barcode': '333333',
          'name': 'Apple AirPods Pro 2',
          'price': 7500.0,
          'min_price': 7000.0,
          'wholesale_price': 6500.0,
          'cost': 6500.0,
          'stock': 25.0,
          'min_stock': 5.0,
          'category_id': 'سماعات',
          'is_active': 1,
          'created_at': now,
          'updated_at': now,
        },
        {
          'id': '444444',
          'barcode': '444444',
          'name': 'Anker PowerCore 20k',
          'price': 1800.0,
          'min_price': 1600.0,
          'wholesale_price': 1400.0,
          'cost': 1400.0,
          'stock': 3.0,
          'min_stock': 5.0,
          'category_id': 'شواحن',
          'is_active': 1,
          'created_at': now,
          'updated_at': now,
        },
        {
          'id': '555555',
          'barcode': '555555',
          'name': 'iPhone 14 Silicon Case',
          'price': 450.0,
          'min_price': 400.0,
          'wholesale_price': 300.0,
          'cost': 300.0,
          'stock': 50.0,
          'min_stock': 10.0,
          'category_id': 'إكسسوارات',
          'is_active': 1,
          'created_at': now,
          'updated_at': now,
        },
        {
          'id': '666666',
          'barcode': '666666',
          'name': 'Type-C to Lightning Cable',
          'price': 350.0,
          'min_price': 300.0,
          'wholesale_price': 200.0,
          'cost': 200.0,
          'stock': 0.0,
          'min_stock': 5.0,
          'category_id': 'شواحن',
          'is_active': 1,
          'created_at': now,
          'updated_at': now,
        },
        {
          'id': '777777',
          'barcode': '777777',
          'name': 'شاشة iPhone 12 Pro',
          'price': 4200.0,
          'min_price': 4000.0,
          'wholesale_price': 3500.0,
          'cost': 3500.0,
          'stock': 12.0,
          'min_stock': 2.0,
          'category_id': 'صيانة',
          'is_active': 1,
          'created_at': now,
          'updated_at': now,
        },
      ];

      for (var p in products) {
        await txn.insert('products', p,
            conflictAlgorithm: ConflictAlgorithm.replace);
      }

      // 4. Seed past Shifts & Sales (Last 7 days)
      final baseDate = DateTime.now().subtract(const Duration(days: 7));

      final randSalesTotals = [
        [35450.0, 7500.0, 1800.0], // Day 1
        [28450.0, 4200.0], // Day 2
        [35000.0, 7500.0, 1800.0, 450.0], // Day 3
        [28000.0, 7500.0, 4200.0], // Day 4
        [35450.0, 1800.0], // Day 5
        [28000.0, 7500.0, 1800.0, 450.0], // Day 6
        [35450.0, 7500.0, 4200.0, 1800.0, 450.0], // Day 7
      ];

      final itemsMap = {
        35450.0: [
          {
            'product_id': '111111',
            'product_name': 'iPhone 13 Pro Max',
            'quantity': 1.0,
            'price': 35000.0,
            'wholesale_price': 32000.0,
            'subtotal': 35000.0
          },
          {
            'product_id': '555555',
            'product_name': 'iPhone 14 Silicon Case',
            'quantity': 1.0,
            'price': 450.0,
            'wholesale_price': 300.0,
            'subtotal': 450.0
          },
        ],
        28450.0: [
          {
            'product_id': '222222',
            'product_name': 'Samsung Galaxy S22 Ultra',
            'quantity': 1.0,
            'price': 28000.0,
            'wholesale_price': 25000.0,
            'subtotal': 28000.0
          },
          {
            'product_id': '555555',
            'product_name': 'iPhone 14 Silicon Case',
            'quantity': 1.0,
            'price': 450.0,
            'wholesale_price': 300.0,
            'subtotal': 450.0
          },
        ],
        35000.0: [
          {
            'product_id': '111111',
            'product_name': 'iPhone 13 Pro Max',
            'quantity': 1.0,
            'price': 35000.0,
            'wholesale_price': 32000.0,
            'subtotal': 35000.0
          },
        ],
        28000.0: [
          {
            'product_id': '222222',
            'product_name': 'Samsung Galaxy S22 Ultra',
            'quantity': 1.0,
            'price': 28000.0,
            'wholesale_price': 25000.0,
            'subtotal': 28000.0
          },
        ],
        7500.0: [
          {
            'product_id': '333333',
            'product_name': 'Apple AirPods Pro 2',
            'quantity': 1.0,
            'price': 7500.0,
            'wholesale_price': 6500.0,
            'subtotal': 7500.0
          },
        ],
        4200.0: [
          {
            'product_id': '777777',
            'product_name': 'شاشة iPhone 12 Pro',
            'quantity': 1.0,
            'price': 4200.0,
            'wholesale_price': 3500.0,
            'subtotal': 4200.0
          },
        ],
        1800.0: [
          {
            'product_id': '444444',
            'product_name': 'Anker PowerCore 20k',
            'quantity': 1.0,
            'price': 1800.0,
            'wholesale_price': 1400.0,
            'subtotal': 1800.0
          },
        ],
        450.0: [
          {
            'product_id': '555555',
            'product_name': 'iPhone 14 Silicon Case',
            'quantity': 1.0,
            'price': 450.0,
            'wholesale_price': 300.0,
            'subtotal': 450.0
          },
        ],
      };

      for (int i = 0; i < 7; i++) {
        final dayDate = baseDate.add(Duration(days: i + 1));
        final shiftId = 'shift_day_${i + 1}';
        final openTime =
            DateTime(dayDate.year, dayDate.month, dayDate.day, 9, 0);
        final closeTime =
            DateTime(dayDate.year, dayDate.month, dayDate.day, 21, 0);

        final totals = randSalesTotals[i];
        double totalSales = 0.0;
        for (var t in totals) {
          totalSales += t;
        }

        // Insert closed Shift
        await txn.insert(
            'shifts',
            {
              'id': shiftId,
              'user_id': 'admin',
              'open_time': openTime.toIso8601String(),
              'close_time': closeTime.toIso8601String(),
              'closed_by': 'admin',
              'opening_cash': 1000.0,
              'closing_cash': 1000.0 + totalSales,
              'is_open': 0,
            },
            conflictAlgorithm: ConflictAlgorithm.replace);

        // Insert Sales
        for (int j = 0; j < totals.length; j++) {
          final saleTotal = totals[j];
          final saleId = 'INV_${shiftId}_$j';
          final saleDate = openTime.add(Duration(hours: j * 2 + 1));

          final saleItems = itemsMap[saleTotal] ?? [];

          await txn.insert(
              'sales',
              {
                'id': saleId,
                'total': saleTotal,
                'items_count': saleItems.length,
                'created_at': saleDate.toIso8601String(),
                'cashier_name': 'System Administrator',
                'user_id': 'admin',
                'shift_id': shiftId,
                'is_refund': 0,
              },
              conflictAlgorithm: ConflictAlgorithm.replace);

          for (var item in saleItems) {
            await txn.insert(
                'sale_items',
                {
                  'id': '${saleId}_${item['product_id']}_${j}_${item['price']}',
                  'sale_id': saleId,
                  'product_id': item['product_id'],
                  'product_barcode': item['product_id'],
                  'product_name': item['product_name'],
                  'quantity': item['quantity'],
                  'price': item['price'],
                  'wholesale_price': item['wholesale_price'],
                  'subtotal': item['subtotal'],
                  'refunded_quantity': 0.0,
                },
                conflictAlgorithm: ConflictAlgorithm.replace);
          }
        }
      }

      final expenseSamples = [
        ('rent', 'إيجار المحل', 6200.0, 'rent', 6),
        ('electricity', 'فاتورة الكهرباء', 1450.0, 'utilities', 4),
        ('internet', 'الإنترنت والاتصالات', 780.0, 'utilities', 3),
        ('delivery', 'شحن وتوصيل طلبات', 560.0, 'operations', 2),
        ('maintenance', 'صيانة وتجهيزات', 900.0, 'maintenance', 1),
        ('supplies', 'أدوات مكتبية وتغليف', 430.0, 'supplies', 0),
      ];
      for (final sample in expenseSamples) {
        await txn.insert(
            'expenses',
            {
              'id': 'debug_expense_${sample.$1}',
              'title': sample.$2,
              'amount': sample.$3,
              'category': sample.$4,
              'notes': 'بيانات تجريبية لوضع التطوير',
              'created_at': DateTime.now()
                  .subtract(Duration(days: sample.$5))
                  .toIso8601String(),
              'user_id': 'admin',
            },
            conflictAlgorithm: ConflictAlgorithm.ignore);
      }
    });

    print('🌱 Seeding complete successfully!');
  }

  static Future<void> clearAndReSeed({User? actingUser}) async {
    final manager = PersistenceInitializer.persistenceManager;
    if (manager == null) return;

    final currentUser = _resolveCurrentUser(actingUser: actingUser);
    if (currentUser != null) {
      try {
        PermissionGuard.requireDataManagementAccess(currentUser);
      } on PermissionDeniedException catch (e) {
        await _logActivity(
          type: ActivityType.demoResetDenied,
          description: 'Denied demo reset for ${currentUser.name}',
          actingUser: currentUser,
          target: 'demo_reset',
          reason: e.message,
        );
        throw e;
      }
    }

    final config = manager.config;
    if (config.appMode != ConfigurationStorage.developmentMode) {
      print(
          '🚫 Demo reset rejected: Destructive demo reset is disabled in Production Mode.');
      await _logActivity(
        type: ActivityType.demoResetDenied,
        description: 'Demo reset blocked in Production Mode',
        actingUser: currentUser,
        target: 'demo_reset',
        reason: 'production mode',
      );
      return;
    }

    if (!_isAllowedInDevelopment()) {
      print(
          '🚫 Demo reset rejected: No safe separate development data root is configured.');
      await _logActivity(
        type: ActivityType.demoResetDenied,
        description: 'Demo reset blocked: unsafe development root',
        actingUser: currentUser,
        target: 'demo_reset',
        reason: 'unsafe development root',
      );
      return;
    }

    final db = manager.sqliteManager;

    print('🗑️ Clearing database tables...');
    await db.transaction((txn) async {
      await txn.delete('sale_items');
      await txn.delete('sales');
      await txn.delete('shifts');
      await txn.delete('products');
      await txn.delete('categories');
      await txn.delete('users');
      await txn.delete('activity_logs');
      await txn.delete('expenses');
    });

    print('🌱 Re-seeding database...');
    await seedAll();
    await _logActivity(
      type: ActivityType.demoResetCompleted,
      description: 'Completed demo reset and reseed',
      actingUser: currentUser,
      target: 'demo_reset',
      parameters: {'result': 'success'},
    );
  }
}
