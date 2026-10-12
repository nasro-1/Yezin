import 'dart:async';

import 'package:bayaa_pos/features/products/data/models/product_model.dart';
import 'package:bayaa_pos/features/products/data/models/selling_unit_model.dart';
import 'package:bayaa_pos/features/products/presentation/packaged_display_unit_loader.dart';
import 'package:bayaa_pos/features/products/presentation/widgets/product_table_view.dart';
import 'package:bayaa_pos/features/auth/data/models/user_model.dart';
import 'package:bayaa_pos/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
      'packaged list updates from selling unit and ignores stale async data',
      (tester) async {
    final product = Product(
      id: 'water',
      name: 'water',
      productType: ProductType.packaged,
      baseUnit: 'pieces',
      price: 0,
      minPrice: 0,
      wholesalePrice: 0,
      quantity: 300,
      minQuantity: 0,
      category: 'General',
    );
    final firstResponse = Completer<List<SellingUnit>>();
    final secondResponse = Completer<List<SellingUnit>>();
    var request = 0;
    final loader = PackagedDisplayUnitLoader();

    Future<List<SellingUnit>> loadUnits(String productId) {
      request++;
      return request == 1 ? firstResponse.future : secondResponse.future;
    }

    Map<String, List<SellingUnit>> displayUnits = {};
    await tester.pumpWidget(
      _table(product, displayUnits),
    );
    expect(find.text('— DA'), findsNWidgets(2));
    expect(find.text('300 pieces'), findsOneWidget);

    final olderLoad = loader.load([product], loadUnits);
    final currentLoad = loader.load([product], loadUnits);
    secondResponse.complete([_pack('water', 240, 220)]);
    displayUnits = await currentLoad.then((value) => value!);
    await tester.pumpWidget(_table(product, displayUnits));

    expect(find.textContaining('240.00'), findsOneWidget);
    expect(find.textContaining('220.00'), findsOneWidget);
    expect(find.text('300 pieces'), findsOneWidget);

    firstResponse.complete([_pack('water', 0, 0)]);
    expect(await olderLoad, isNull);
    await tester.pumpWidget(_table(product, displayUnits));
    expect(find.textContaining('240.00'), findsOneWidget);
    expect(find.textContaining('220.00'), findsOneWidget);
  });
}

SellingUnit _pack(
    String productId, double sellingPrice, double wholesalePrice) {
  return SellingUnit(
    id: 'pack',
    productId: productId,
    name: 'Pack',
    conversionToBase: 30,
    cost: 200,
    sellingPrice: sellingPrice,
    wholesalePrice: wholesalePrice,
    isDefault: true,
  );
}

Widget _table(Product product, Map<String, List<SellingUnit>> displayUnits) {
  return MaterialApp(
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    home: Scaffold(
      body: ProductsTableView(
        products: [product],
        onDelete: (_) {},
        onEdit: (_) {},
        onAdjustStock: (_) {},
        onStockHistory: (_) {},
        onView: (_) {},
        statusColorFn: (_, __) => Colors.green,
        statusTextFn: (_, __) => 'Available',
        currentUser: User(
          username: 'manager',
          name: 'Manager',
          phone: '',
          userType: UserType.manager,
          password: '',
        ),
        isManager: true,
        packagedDisplayUnits: displayUnits,
      ),
    ),
  );
}
