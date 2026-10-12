import 'dart:convert';
import 'dart:io';

import 'package:bayaa_pos/core/data/services/persistence_initializer.dart';
import 'package:bayaa_pos/core/di/dependency_injection.dart';
import 'package:bayaa_pos/core/network/backend_api_config.dart';
import 'package:bayaa_pos/features/auth/data/models/user_model.dart';
import 'package:bayaa_pos/features/auth/presentation/cubit/user_cubit.dart';
import 'package:bayaa_pos/features/products/data/models/product_model.dart';
import 'package:bayaa_pos/features/products/data/models/selling_unit_model.dart';
import 'package:bayaa_pos/features/products/data/repository/product_repository_imp.dart';
import 'package:bayaa_pos/features/products/presentation/widgets/product_grid_view.dart';
import 'package:bayaa_pos/features/products/presentation/widgets/product_details_dialog.dart';
import 'package:bayaa_pos/features/products/presentation/widgets/product_table_view.dart';
import 'package:bayaa_pos/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _categoryId = 'category-4b05821fb0614afa90f8e13bf212840f';

Product _cola({
  String? categoryId = _categoryId,
  String? categoryName,
  double wholesalePrice = 90,
  double minPrice = 80,
}) =>
    Product(
      id: 'product-cola',
      name: 'Test Standard Cola',
      barcode: 'cola-001',
      price: 100,
      minPrice: minPrice,
      wholesalePrice: wholesalePrice,
      quantity: 5,
      minQuantity: 0,
      category: categoryId ?? 'General',
      categoryName: categoryName,
    );

Widget _localized(Widget child) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: child),
    );

User _user(UserType role) => User(
      username: role.name,
      name: role.name,
      phone: '',
      userType: role,
      password: '',
    );

class _TestUserCubit implements UserCubit {
  _TestUserCubit(this.role);

  final UserType role;

  @override
  User get currentUser => _user(role);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _registerUser(UserType role) async {
  if (getIt.isRegistered<UserCubit>()) {
    await getIt.unregister<UserCubit>();
  }
  getIt.registerSingleton<UserCubit>(_TestUserCubit(role));
}

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  tearDown(() async {
    if (getIt.isRegistered<UserCubit>()) {
      await getIt.unregister<UserCubit>();
    }
  });

  test('product model keeps category ID and resolves the display name', () {
    final product = Product.fromMap({
      'id': 'product-cola',
      'name': 'Test Standard Cola',
      'category_id': _categoryId,
      'category_name': 'Beverages',
      'price': 10,
      'min_price': 0,
      'wholesale_price': 0,
      'stock': 5,
      'min_stock': 0,
    });

    expect(product.category, _categoryId);
    expect(product.displayCategoryName, 'Beverages');
  });

  test('null and unresolved category IDs use a safe display fallback', () {
    final unassigned = Product.fromMap({
      'id': 'product-unassigned',
      'name': 'Unassigned',
      'category_id': null,
      'price': 10,
      'min_price': 0,
      'wholesale_price': 0,
      'stock': 0,
      'min_stock': 0,
    });
    final unresolved = _cola(categoryName: '');
    final identifierAsName = _cola(categoryName: _categoryId);

    expect(unassigned.displayCategoryName, 'General');
    expect(unresolved.displayCategoryName, isEmpty);
    expect(unresolved.displayCategoryName, isNot(_categoryId));
    expect(identifierAsName.displayCategoryName, isEmpty);
  });

  test('local mode resolves category IDs through the local category table',
      () async {
    final sandbox = await Directory.systemTemp.createTemp(
      'yezin-product-category-',
    );
    final dataRoot = Directory(p.join(sandbox.path, 'data'));
    for (final directory in [
      'config',
      'db',
      'assets',
      'checkpoints',
      'ledger',
      'ledger/archived',
      'logs',
    ]) {
      await Directory(p.join(dataRoot.path, directory)).create(recursive: true);
    }
    final configFile = File(p.join(sandbox.path, 'system_config.json'));
    await configFile.writeAsString(
      jsonEncode({'data_root_path': dataRoot.path}),
      flush: true,
    );
    await File(p.join(dataRoot.path, 'config', 'bayaa.json')).writeAsString(
      jsonEncode({
        'app_mode': 'development',
        'development_data_root_path': dataRoot.path,
      }),
      flush: true,
    );

    try {
      expect(
        await PersistenceInitializer.initialize(systemConfigFile: configFile),
        isTrue,
      );
      final db = PersistenceInitializer.persistenceManager!.sqliteManager;
      await db.insert('categories', {
        'id': 'local-category-id',
        'name': 'Beverages',
        'sort_order': 0,
      });

      final result = await ProductRepositoryImp(
        readMode: ProductReadMode.local,
      ).getCategoryNamesById();

      expect(result.isRight, isTrue);
      expect(result.right['local-category-id'], 'Beverages');
    } finally {
      await PersistenceInitializer.persistenceManager?.shutdown();
    }
  });

  testWidgets('product details show the category name, never the category ID',
      (tester) async {
    final product = _cola(categoryName: 'Beverages');
    await tester.pumpWidget(_localized(ProductDetailsDialog(product: product)));
    await tester.pump();

    expect(find.text('Category: Beverages'), findsOneWidget);
    expect(find.textContaining(_categoryId), findsNothing);
  });

  testWidgets('product table shows the category name, never the category ID',
      (tester) async {
    final product = _cola(categoryName: 'Beverages');
    await tester.pumpWidget(
      _localized(
        ProductsTableView(
          products: [product],
          onDelete: (_) {},
          onEdit: (_) {},
          onAdjustStock: (_) {},
          onStockHistory: (_) {},
          onView: (_) {},
          statusColorFn: (_, __) => Colors.green,
          statusTextFn: (_, __) => 'Available',
          currentUser: _user(UserType.manager),
        ),
      ),
    );

    expect(find.text('Beverages'), findsOneWidget);
    expect(find.textContaining(_categoryId), findsNothing);
  });

  testWidgets('packaged product table shows each selling unit commercial price',
      (tester) async {
    final product = Product(
      id: 'packaged-biscuit',
      name: 'Test Biscuit',
      barcode: 'biscuit-001',
      productType: ProductType.packaged,
      price: 0,
      minPrice: 0,
      wholesalePrice: 0,
      quantity: 1020,
      minQuantity: 0,
      category: _categoryId,
      categoryName: 'Beverages',
    );
    final units = [
      SellingUnit(
        id: 'piece',
        productId: product.id,
        name: 'Piece',
        conversionToBase: 1,
        sellingPrice: 100,
        minimumStock: 0,
      ),
      SellingUnit(
        id: 'pack',
        productId: product.id,
        name: 'Pack',
        conversionToBase: 30,
        sellingPrice: 1200,
        wholesalePrice: 1100,
        minimumStock: 5,
      ),
      SellingUnit(
        id: 'box',
        productId: product.id,
        name: 'Box',
        conversionToBase: 360,
        sellingPrice: 13500,
        wholesalePrice: 12500,
        minimumStock: 2,
      ),
    ];

    await tester.pumpWidget(
      _localized(
        ProductsTableView(
          products: [product],
          packagedDisplayUnits: {product.id: units},
          onDelete: (_) {},
          onEdit: (_) {},
          onAdjustStock: (_) {},
          onStockHistory: (_) {},
          onView: (_) {},
          statusColorFn: (_, __) => Colors.green,
          statusTextFn: (_, __) => 'Available',
          currentUser: _user(UserType.manager),
        ),
      ),
    );

    expect(find.textContaining('Pack: 1100.00 DA'), findsOneWidget);
    expect(find.textContaining('Box: 12500.00 DA'), findsOneWidget);
    expect(find.textContaining('Piece: 100.00'), findsOneWidget);
    expect(find.textContaining('Pack: 1200.00'), findsOneWidget);
    expect(find.textContaining('Box: 13500.00'), findsOneWidget);
    expect(find.textContaining('Pack: 5.00'), findsNothing);
    expect(find.textContaining('Box: 2.00'), findsNothing);
  });

  testWidgets(
      'ProductsGridView card shows commercial prices and category for every role',
      (tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    for (final role in [
      UserType.admin,
      UserType.manager,
      UserType.cashier,
    ]) {
      await _registerUser(role);
      await tester.pumpWidget(
        _localized(
          ProductsGridView(
            products: [_cola(categoryName: 'Beverages')],
            onDelete: (_) {},
            onEdit: (_) {},
            onAdjustStock: (_) {},
            onStockHistory: (_) {},
            onView: (_) {},
            statusColorFn: (_, __) => Colors.green,
            statusTextFn: (_, __) => 'Available',
          ),
        ),
      );

      expect(find.text('Beverages'), findsOneWidget);
      expect(find.text('Wholesale Price'), findsOneWidget);
      expect(find.text('Min Price'), findsOneWidget);
      expect(find.textContaining('100.00'), findsOneWidget);
      expect(find.text('90.00'), findsOneWidget);
      expect(find.text('80.00'), findsOneWidget);
      expect(find.text('Cost'), findsNothing);
      expect(find.textContaining(_categoryId), findsNothing);
    }
  });

  testWidgets('every role sees commercial prices on mobile product cards',
      (tester) async {
    tester.view.physicalSize = const Size(600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    for (final role in [
      UserType.admin,
      UserType.manager,
      UserType.cashier,
    ]) {
      await _registerUser(role);

      await tester.pumpWidget(
        _localized(
          ProductsGridView(
            products: [_cola(categoryName: 'Beverages')],
            onDelete: (_) {},
            onEdit: (_) {},
            onAdjustStock: (_) {},
            onStockHistory: (_) {},
            onView: (_) {},
            statusColorFn: (_, __) => Colors.green,
            statusTextFn: (_, __) => 'Available',
          ),
        ),
      );

      expect(find.text('Beverages'), findsOneWidget);
      expect(find.textContaining('Selling Price'), findsOneWidget);
      expect(find.textContaining('Wholesale Price'), findsOneWidget);
      expect(find.textContaining('Min Price'), findsOneWidget);
      expect(find.textContaining('100.00'), findsOneWidget);
      expect(find.text('90.00'), findsOneWidget);
      expect(find.text('80.00'), findsOneWidget);
      expect(find.textContaining(_categoryId), findsNothing);
    }
  });

  testWidgets('product table exposes commercial prices to every role',
      (tester) async {
    for (final role in [
      UserType.admin,
      UserType.manager,
      UserType.cashier,
    ]) {
      await tester.pumpWidget(
        _localized(
          ProductsTableView(
            products: [_cola(categoryName: 'Beverages')],
            onDelete: (_) {},
            onEdit: (_) {},
            onAdjustStock: (_) {},
            onStockHistory: (_) {},
            onView: (_) {},
            statusColorFn: (_, __) => Colors.green,
            statusTextFn: (_, __) => 'Available',
            currentUser: _user(role),
          ),
        ),
      );

      expect(find.text('Wholesale Price'), findsOneWidget);
      expect(find.text('Min Price'), findsOneWidget);
      expect(find.textContaining('100.00'), findsOneWidget);
      expect(find.textContaining('90.00'), findsOneWidget);
      expect(find.textContaining('80.00'), findsOneWidget);
      expect(find.text('Beverages'), findsOneWidget);
      expect(find.textContaining(_categoryId), findsNothing);
    }
  });
}
