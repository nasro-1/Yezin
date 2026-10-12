import 'dart:convert';
import 'dart:io';

import 'package:bayaa_pos/core/data/services/persistence_initializer.dart';
import 'package:bayaa_pos/core/di/dependency_injection.dart';
import 'package:bayaa_pos/core/session/session_manager.dart';
import 'package:bayaa_pos/features/auth/data/models/user_model.dart';
import 'package:bayaa_pos/features/exchange/presentation/exchange_dialog.dart';
import 'package:bayaa_pos/features/sales/data/models/sale_model.dart';
import 'package:bayaa_pos/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Directory? _testRoot;

Future<void> _initializeIsolatedPersistence() async {
  if (getIt.isRegistered<SessionManager>()) {
    getIt<SessionManager>().clearCurrentSession();
  }

  final existing = PersistenceInitializer.persistenceManager;
  if (existing != null) {
    await existing.shutdown();
  }

  final testDirectory = Directory(
    p.join(
      Directory.systemTemp.path,
      'bayaa_exchange_ui_test_${DateTime.now().microsecondsSinceEpoch}',
    ),
  );
  _testRoot = testDirectory;
  final uniqueRoot = Directory(p.join(testDirectory.path, 'data'));
  await uniqueRoot.create(recursive: true);
  for (final child in [
    'config',
    'ledger',
    'ledger/archived',
    'db',
    'checkpoints',
    'logs',
    'assets'
  ]) {
    await Directory(p.join(uniqueRoot.path, child)).create(recursive: true);
  }

  final systemConfigFile =
      File(p.join(testDirectory.path, 'system_config.json'));
  await systemConfigFile.writeAsString(
    jsonEncode({'data_root_path': uniqueRoot.path}),
    flush: true,
  );
  await File(p.join(uniqueRoot.path, 'config', 'bayaa.json')).writeAsString(
    jsonEncode({
      'app_mode': 'development',
      'development_data_root_path': uniqueRoot.path,
    }),
    flush: true,
  );

  await PersistenceInitializer.initialize(systemConfigFile: systemConfigFile);
}

Future<void> _seedExchangeFixture({
  int originalCount = 6,
  int replacementCount = 10,
}) async {
  final db = PersistenceInitializer.persistenceManager!.sqliteManager;
  await db.delete('sale_items');
  await db.delete('sales');
  await db.delete('products');
  await db.delete('categories');
  await db.delete('users');
  await db.delete('customers');

  await db.insert(
      'customers',
      {
        'id': 'cust-1',
        'code': 'CUST-001',
        'name': 'Customer 1',
        'phone': '01000000000',
        'address': '',
        'email': '',
        'created_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace);

  await db.insert(
      'users',
      {
        'id': 'cashier-1',
        'username': 'cashier-1',
        'display_name': 'Cashier',
        'password_hash': 'x',
        'role': 'cashier',
        'is_active': 1,
        'created_at': DateTime.now().toIso8601String(),
        'created_by': null,
      },
      conflictAlgorithm: ConflictAlgorithm.replace);

  await db.insert(
      'categories',
      {
        'id': 'exchange-category',
        'name': 'Exchange Category',
        'color': '#000000',
        'sort_order': 0,
      },
      conflictAlgorithm: ConflictAlgorithm.replace);

  final saleId = 'sale-exchange';
  final saleTotal = 0.0;
  await db.insert(
      'sales',
      {
        'id': saleId,
        'reference_number': 'INV-EX-1000',
        'total': saleTotal,
        'items_count': originalCount,
        'created_at': DateTime.now().toIso8601String(),
        'cashier_name': 'Cashier',
        'user_id': 'cashier-1',
        'customer_id': 'cust-1',
        'shift_id': null,
        'is_refund': 0,
        'original_sale_id': null,
        'payment_method': 'cash',
      },
      conflictAlgorithm: ConflictAlgorithm.replace);

  for (var i = 1; i <= originalCount; i++) {
    final productId = 'origin-$i';
    final name = 'Item $i';
    await db.insert(
        'products',
        {
          'id': productId,
          'barcode': 'ORIG-$i',
          'name': name,
          'price': (100 + i * 10).toDouble(),
          'min_price': 10.0,
          'wholesale_price': 60.0,
          'stock': 10.0,
          'min_stock': 1.0,
          'category_id': 'exchange-category',
          'is_active': 1,
          'created_at': DateTime.now().toIso8601String(),
          'updated_at': DateTime.now().toIso8601String(),
        },
        conflictAlgorithm: ConflictAlgorithm.replace);

    await db.insert(
        'sale_items',
        {
          'id': 'sale-${saleId}-item-$i',
          'sale_id': saleId,
          'product_id': productId,
          'product_barcode': 'ORIG-$i',
          'product_name': name,
          'quantity': 5.0,
          'price': (100 + i * 10).toDouble(),
          'wholesale_price': 60.0,
          'subtotal': (100 + i * 10).toDouble() * 5,
          'refunded_quantity': 0.0,
          'exchanged_quantity': 0.0,
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  for (var i = 1; i <= replacementCount; i++) {
    final productId = 'replacement-$i';
    final name = 'Replacement $i';
    await db.insert(
        'products',
        {
          'id': productId,
          'barcode': 'REPL-$i',
          'name': name,
          'price': (120 + i * 10).toDouble(),
          'min_price': 10.0,
          'wholesale_price': 70.0,
          'stock': 10.0,
          'min_stock': 1.0,
          'category_id': 'exchange-category',
          'is_active': 1,
          'created_at': DateTime.now().toIso8601String(),
          'updated_at': DateTime.now().toIso8601String(),
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
  }
}

Widget _wrapExchangeDialog(Widget child, {Locale locale = const Locale('en')}) {
  return MaterialApp(
    locale: locale,
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    home: child,
  );
}

Future<void> _waitForFinder(WidgetTester tester, Finder finder,
    {int attempts = 50}) async {
  for (var i = 0; i < attempts; i++) {
    final exception = tester.takeException();
    if (exception != null) {
      throw exception;
    }
    if (finder.evaluate().isNotEmpty) {
      return;
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
  throw FlutterError('Timed out waiting for $finder');
}

Future<void> _dragUntilVisible(
  WidgetTester tester,
  Finder scrollable,
  Finder target,
) async {
  for (var attempt = 0; attempt < 12; attempt++) {
    if (target.evaluate().isNotEmpty) {
      return;
    }
    await tester.drag(scrollable, const Offset(0, -400));
    await tester.pump(const Duration(milliseconds: 100));
  }
  throw FlutterError('Timed out waiting for $target');
}

Sale _createSaleWithItems({int count = 6}) {
  return Sale(
    id: 'sale-exchange',
    total: 0,
    items: count,
    date: DateTime(2026, 9, 3),
    saleItems: List.generate(count, (index) {
      final number = index + 1;
      return SaleItem(
        productId: 'origin-$number',
        name: 'Item $number',
        price: 100 + number * 10,
        quantity: 5,
        total: (100 + number * 10) * 5,
        wholesalePrice: 60,
      );
    }),
    cashierName: 'Cashier',
    cashierUsername: 'cashier-1',
    customerId: 'cust-1',
    paymentMethod: 'cash',
    referenceNumber: 'INV-EX-1000',
  );
}

void main() {
  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await _initializeIsolatedPersistence();
    await _seedExchangeFixture();
  });

  tearDown(() async {
    final persistence = PersistenceInitializer.persistenceManager;
    if (persistence != null) {
      await persistence.shutdown();
    }
    await Future<void>.delayed(const Duration(milliseconds: 250));
    if (_testRoot != null && await _testRoot!.exists()) {
      FileSystemException? lastError;
      for (var attempt = 0; attempt < 20; attempt++) {
        try {
          await _testRoot!.delete(recursive: true);
          lastError = null;
          break;
        } on FileSystemException catch (error) {
          lastError = error;
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }
      if (lastError != null) {
        print('Test root cleanup deferred: $lastError');
      }
      _testRoot = null;
    }
  });

  testWidgets('returning list scrolls and last original item is selectable',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1600, 700));
    final sale = _createSaleWithItems();
    await tester.pumpWidget(
      _wrapExchangeDialog(
        ExchangeDialog(
          originalSale: sale,
          currentUser: User(
            username: 'cashier-1',
            name: 'Cashier',
            phone: '010',
            userType: UserType.cashier,
            password: 'pass',
          ),
        ),
      ),
    );
    final returningList = find.byKey(const ValueKey('exchange-returning-list'));
    await _waitForFinder(tester, returningList, attempts: 100);
    expect(returningList, findsOneWidget);
    expect(find.text('Item 1'), findsWidgets);

    await tester.scrollUntilVisible(
      find.text('Item 6'),
      400,
      scrollable: find.descendant(
        of: returningList,
        matching: find.byType(Scrollable),
      ),
    );
    expect(find.text('Item 6'), findsOneWidget);

    final increaseButtons = tester
        .widgetList<IconButton>(find.byType(IconButton))
        .where(
          (button) =>
              button.icon is Icon &&
              (button.icon as Icon).icon == Icons.add_circle_outline &&
              button.onPressed != null,
        )
        .toList();
    expect(increaseButtons, isNotEmpty);
    for (final button in increaseButtons) {
      button.onPressed!();
      await tester.pump();
    }

    final replacementSelects = find.widgetWithText(OutlinedButton, 'Select');
    final enabledReplacementIndex = Iterable<int>.generate(
      replacementSelects.evaluate().length,
    ).firstWhere(
      (index) =>
          tester
              .widget<OutlinedButton>(
                replacementSelects.at(index),
              )
              .onPressed !=
          null,
    );
    await tester.tap(replacementSelects.at(enabledReplacementIndex));
    await tester.pump();

    expect(find.text('Replacement 1', skipOffstage: false), findsOneWidget);
    expect(find.byIcon(Icons.add_circle_outline), findsWidgets);
  });

  testWidgets('receiving list scrolls and shows middle and last products',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1600, 500));
    final sale = _createSaleWithItems();
    await tester.pumpWidget(
      _wrapExchangeDialog(
        ExchangeDialog(
          originalSale: sale,
          currentUser: User(
            username: 'cashier-1',
            name: 'Cashier',
            phone: '010',
            userType: UserType.cashier,
            password: 'pass',
          ),
        ),
      ),
    );
    final receivingList = find.byKey(const ValueKey('exchange-receiving-list'));
    await _waitForFinder(tester, receivingList, attempts: 100);
    expect(receivingList, findsOneWidget);
    final receivingScrollable = find.descendant(
      of: receivingList,
      matching: find.byType(Scrollable),
    );
    await tester.enterText(find.byType(TextField), 'Replacement');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final receivingState = tester.state<ScrollableState>(receivingScrollable);
    receivingState.position.jumpTo(0);
    await tester.pump();
    expect(find.text('Replacement 1', skipOffstage: false), findsOneWidget);
    receivingState.position.jumpTo(receivingState.position.maxScrollExtent / 2);
    await tester.pump();
    expect(find.text('Replacement 6', skipOffstage: false), findsOneWidget);
    receivingState.position.jumpTo(receivingState.position.maxScrollExtent);
    await tester.pump();
    expect(
      find.text('Replacement 10', skipOffstage: false),
      findsOneWidget,
    );
  });

  testWidgets('English and Arabic locales render the correct directionality',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1600, 700));
    final sale = _createSaleWithItems();

    await tester.pumpWidget(
      _wrapExchangeDialog(
        ExchangeDialog(
          originalSale: sale,
          currentUser: User(
            username: 'cashier-1',
            name: 'Cashier',
            phone: '010',
            userType: UserType.cashier,
            password: 'pass',
          ),
        ),
        locale: const Locale('en'),
      ),
    );
    await _waitForFinder(tester, find.text('Product Exchange'), attempts: 100);
    expect(Directionality.of(tester.element(find.text('Product Exchange'))),
        TextDirection.ltr);

    await tester.pumpWidget(
      _wrapExchangeDialog(
        ExchangeDialog(
          originalSale: sale,
          currentUser: User(
            username: 'cashier-1',
            name: 'Cashier',
            phone: '010',
            userType: UserType.cashier,
            password: 'pass',
          ),
        ),
        locale: const Locale('ar'),
      ),
    );
    await _waitForFinder(tester, find.text('استبدال المنتج'), attempts: 100);
    expect(Directionality.of(tester.element(find.text('استبدال المنتج'))),
        TextDirection.rtl);
  });

  testWidgets('invalid state keeps summary incomplete and disables submit',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1600, 700));
    final sale = _createSaleWithItems();
    await tester.pumpWidget(
      _wrapExchangeDialog(
        ExchangeDialog(
          originalSale: sale,
          currentUser: User(
            username: 'cashier-1',
            name: 'Cashier',
            phone: '010',
            userType: UserType.cashier,
            password: 'pass',
          ),
        ),
      ),
    );
    await _waitForFinder(
      tester,
      find.text('Select an item and quantity to continue'),
      attempts: 100,
    );
    expect(
        find.text('Select an item and quantity to continue'), findsOneWidget);
    expect(find.textContaining('Customer pays'), findsNothing);
    expect(find.textContaining('Customer receives'), findsNothing);
  });
}
