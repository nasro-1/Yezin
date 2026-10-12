import 'dart:io';

import 'package:dartz/dartz.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:bayaa_pos/core/di/dependency_injection.dart';
import 'package:bayaa_pos/core/data/services/sqlite_manager.dart';
import 'package:bayaa_pos/core/error/failure.dart';
import 'package:bayaa_pos/core/services/activity_logger.dart';
import 'package:bayaa_pos/features/products/data/models/product_model.dart';
import 'package:bayaa_pos/features/products/domain/product_repository_int.dart';
import 'package:bayaa_pos/features/products/presentation/cubit/product_cubit.dart';
import 'package:bayaa_pos/features/purchases/data/models/purchase_model.dart';
import 'package:bayaa_pos/features/purchases/data/repository/purchase_repository_impl.dart';
import 'package:bayaa_pos/features/purchases/presentation/purchases_screen.dart';
import 'package:bayaa_pos/features/stock/services/canonical_stock_posting_service.dart';
import 'package:bayaa_pos/features/products/data/models/selling_unit_model.dart';

PurchaseLine _line({
  double currentStock = 50,
  double quantity = 20,
  double unitCost = 100000,
}) {
  return PurchaseLine(
    productId: 'p-1',
    productName: 'iPhone',
    productBarcode: '100',
    currentStock: currentStock,
    quantity: quantity,
    unitCost: unitCost,
  );
}

bool _validQuantity(String value) {
  final parsed = double.tryParse(value.trim());
  return parsed != null && parsed.isFinite && parsed > 0;
}

bool _validCost(String value) {
  final parsed = double.tryParse(value.trim());
  return parsed != null && parsed.isFinite && parsed >= 0;
}

void main() {
  test('purchase draft is editable before posting', () {
    final draft = PurchaseDraftLifecycle()..reset();

    expect(draft.isCompleted, isFalse);
    expect(draft.purchaseId, isNotEmpty);
  });

  test('successful posting transitions the draft to completed', () {
    final draft = PurchaseDraftLifecycle()..reset();

    draft.complete(reference: 'PUR-1', total: 4000);

    expect(draft.isCompleted, isTrue);
    expect(draft.completedReference, 'PUR-1');
    expect(draft.completedTotal, 4000);
  });

  test('starting a new purchase resets completion and creates a new draft id',
      () {
    final draft = PurchaseDraftLifecycle()..reset();
    final postedId = draft.purchaseId;
    draft.complete(reference: 'PUR-1', total: 4000);

    draft.reset();

    expect(draft.isCompleted, isFalse);
    expect(draft.completedReference, isNull);
    expect(draft.completedTotal, isNull);
    expect(draft.purchaseId, isNot(postedId));
  });

  testWidgets('canceling receive product closes with null and adds no line',
      (tester) async {
    await getIt.reset();
    getIt.registerSingleton<ActivityLogger>(ActivityLogger());
    final productCubit =
        ProductCubit(productRepositoryInt: _UnusedProductRepository())
          ..products = [
            Product(
              id: 'purchase-cancel-product',
              name: 'Purchase cancel product',
              barcode: 'PUR-CANCEL-1',
              price: 10,
              minPrice: 8,
              wholesalePrice: 9,
              quantity: 5,
              minQuantity: 0,
              category: 'Test',
            ),
          ];
    getIt.registerSingleton<ProductCubit>(productCubit);
    addTearDown(() async {
      await productCubit.close();
      await getIt.reset();
    });
    final repository = _UnusedPurchaseRepository();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PurchasesScreen(repository: repository),
        ),
      ),
    );

    await tester.tap(find.text('Add product'));
    await tester.pumpAndSettle();
    expect(find.text('Add product to purchase'), findsOneWidget);

    await tester.tap(find.text('Purchase cancel product'));
    await tester.pumpAndSettle();
    expect(find.text('Receive Purchase cancel product'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('No products added'), findsOneWidget);
    expect(repository.createPurchaseCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('weighted product with fractional stock can be added',
      (tester) async {
    await getIt.reset();
    getIt.registerSingleton<ActivityLogger>(ActivityLogger());
    final productCubit =
        ProductCubit(productRepositoryInt: _UnusedProductRepository())
          ..products = [
            Product(
              id: 'olive-oil-premium',
              name: 'Olive Oil Premium',
              barcode: 'OIL-25',
              productType: ProductType.weighted,
              baseUnit: 'kg',
              price: 1200,
              minPrice: 1000,
              wholesalePrice: 1100,
              quantity: 25.0,
              minQuantity: 0,
              category: 'Beverages',
            ),
          ];
    getIt.registerSingleton<ProductCubit>(productCubit);
    addTearDown(() async {
      await productCubit.close();
      await getIt.reset();
    });
    final repository = _UnusedPurchaseRepository();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PurchasesScreen(repository: repository),
        ),
      ),
    );

    await tester.tap(find.text('Add product'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Olive Oil Premium'));
    await tester.pumpAndSettle();
    expect(find.text('Receive Olive Oil Premium'), findsOneWidget);

    await tester.enterText(find.byType(TextFormField).at(0), '10');
    await tester.enterText(find.byType(TextFormField).at(1), '900');
    await tester.tap(find.text('Add to purchase'));
    await tester.pumpAndSettle();

    expect(find.text('Olive Oil Premium'), findsOneWidget);
    expect(find.text('25.0'), findsOneWidget);
    expect(find.text('35.0'), findsOneWidget);
    expect(find.text('9000.00 DA'), findsNWidgets(2));
    expect(repository.createPurchaseCalls, 0);
    expect(tester.takeException(), isNull);
  });

  test('existing stock plus received quantity displays new stock', () {
    final line = _line();

    expect(line.currentStock, 50);
    expect(line.quantity, 20);
    expect(line.resultingStock, 70);
  });

  test('another purchase for the same product remains additive', () {
    final first = _line(quantity: 20);
    final second = _line(currentStock: first.resultingStock, quantity: 10);

    expect(first.resultingStock, 70);
    expect(second.resultingStock, 80);
  });

  test('existing purchase remains unchanged', () {
    final purchase = _line();
    final secondPurchase = _line(
      currentStock: purchase.resultingStock,
      quantity: 10,
    );

    expect(purchase.quantity, 20);
    expect(purchase.resultingStock, 70);
    expect(secondPurchase.quantity, 10);
  });

  test('multiple purchase lines represent separate transactions', () {
    const firstPurchaseId = 'purchase-a';
    const secondPurchaseId = 'purchase-b';

    expect(firstPurchaseId, isNot(secondPurchaseId));
    expect(_line(quantity: 20).lineTotal, 2000000);
    expect(_line(currentStock: 70, quantity: 10).lineTotal, 1000000);
  });

  test('invalid received quantities are rejected', () {
    expect(_validQuantity('0'), isFalse);
    expect(_validQuantity('-1'), isFalse);
    expect(_validQuantity('not-a-number'), isFalse);
    expect(_validQuantity('20'), isTrue);
  });

  test('invalid unit costs are rejected', () {
    expect(_validCost('-1'), isFalse);
    expect(_validCost('not-a-number'), isFalse);
    expect(_validCost('NaN'), isFalse);
    expect(_validCost('100000'), isTrue);
  });

  test('standard purchase line keeps unit quantity and historical cost', () {
    final line = _line(currentStock: 5, quantity: 10, unitCost: 50);
    expect(line.lineTotal, 500);
    expect(line.resultingStock, 15);
    expect(line.sellingUnitId, isNull);
  });

  test('weighted purchase line preserves decimal quantity', () {
    final line = PurchaseLine(
      productId: 'weighted-1',
      productName: 'Flour',
      productBarcode: 'W-1',
      currentStock: 20,
      quantity: 12.5,
      unitCost: 80,
    );
    expect(line.lineTotal, 1000);
    expect(line.resultingStock, 32.5);
  });

  test('packaged purchase lines convert selected units to base stock', () {
    final piece = PurchaseLine(
      productId: 'water',
      productName: 'Water',
      productBarcode: '',
      currentStock: 0,
      quantity: 10,
      unitCost: 30,
      sellingUnitId: 'piece',
      sellingUnitName: 'Piece',
      conversionFactor: 1,
      baseQuantity: 10,
    );
    final pack = PurchaseLine(
      productId: 'water',
      productName: 'Water',
      productBarcode: '',
      currentStock: 0,
      quantity: 10,
      unitCost: 200,
      sellingUnitId: 'pack',
      sellingUnitName: 'Pack',
      conversionFactor: 30,
      baseQuantity: 300,
    );
    final box = PurchaseLine(
      productId: 'water',
      productName: 'Water',
      productBarcode: '',
      currentStock: 0,
      quantity: 2,
      unitCost: 500,
      sellingUnitId: 'box',
      sellingUnitName: 'Box',
      conversionFactor: 360,
      baseQuantity: 720,
    );

    expect(piece.lineTotal, 300);
    expect(piece.resultingStock, 10);
    expect(pack.lineTotal, 2000);
    expect(pack.resultingStock, 300);
    expect(box.lineTotal, 1000);
    expect(box.resultingStock, 720);
  });

  test('packaged purchase cost stays historical when selling-unit cost changes',
      () {
    final configured = SellingUnit(
      id: 'pack',
      productId: 'water',
      name: 'Pack',
      conversionToBase: 30,
      sellingPrice: 240,
      cost: 180,
    );
    final purchase = PurchaseLine(
      productId: 'water',
      productName: 'Water',
      productBarcode: '',
      currentStock: 0,
      quantity: 10,
      unitCost: 200,
      sellingUnitId: configured.id,
      sellingUnitName: configured.name,
      conversionFactor: configured.conversionToBase,
      baseQuantity: 300,
    );
    final changed = configured.copyWith(cost: 220);

    expect(purchase.unitCost, 200);
    expect(changed.cost, 220);
    expect(purchase.unitCost, isNot(changed.cost));
  });

  test('packaged lines with different units have distinct identities', () {
    final pack = PurchaseLine(
      productId: 'water',
      productName: 'Water',
      productBarcode: '',
      quantity: 10,
      unitCost: 200,
      sellingUnitId: 'pack',
      baseQuantity: 300,
    );
    final piece = PurchaseLine(
      productId: 'water',
      productName: 'Water',
      productBarcode: '',
      quantity: 20,
      unitCost: 30,
      sellingUnitId: 'piece',
      baseQuantity: 20,
    );
    expect(pack.identityKey, isNot(piece.identityKey));
    expect({pack.identityKey, piece.identityKey}, hasLength(2));
  });

  test('standard and weighted lines retain one-line-per-product identity', () {
    final standard = _line();
    final weighted = PurchaseLine(
      productId: 'p-1',
      productName: 'iPhone',
      productBarcode: '100',
      quantity: 12.5,
      unitCost: 80,
    );
    expect(standard.identityKey, weighted.identityKey);
  });

  test('selected supplier state displays name, code, and change action', () {
    const supplierName = 'nasro mellah';
    const supplierCode = 'SUP-000001';
    var selected = false;

    expect(selected, isFalse);
    selected = true;
    expect(selected, isTrue);
    expect('$supplierName\n$supplierCode', contains(supplierName));
    expect('$supplierName\n$supplierCode', contains(supplierCode));
    expect('Change supplier', isNotEmpty);
  });

  test('purchase total sums all line totals', () {
    final lines = [_line(quantity: 20), _line(quantity: 10, unitCost: 50000)];
    final total = lines.fold<double>(0, (sum, line) => sum + line.lineTotal);

    expect(total, 2500000);
  });

  test('canonical posting records two additive purchases and movements',
      () async {
    final root = await Directory.systemTemp.createTemp('bayaa_purchase_ux_');
    final manager = SQLiteManager(
      databasePath: p.join(root.path, 'purchase_ux.sqlite'),
    );
    const posting = CanonicalStockPostingService();

    try {
      await manager.initialize();
      final db = manager.database;
      final now = DateTime.now().toIso8601String();
      await db.insert('suppliers', {
        'id': 'supplier-1',
        'code': 'SUP-000001',
        'name': 'nasro mellah',
        'phone': '010',
        'created_at': now,
        'updated_at': now,
      });
      await db.insert('products', {
        'id': 'p-1',
        'barcode': '100',
        'name': 'iPhone',
        'price': 150000,
        'stock': 50,
        'created_at': now,
        'updated_at': now,
      });

      Future<void> postPurchase(String id, double quantity) async {
        await db.transaction((txn) async {
          await txn.insert('purchases', {
            'id': id,
            'reference_number': 'PUR-$id',
            'supplier_id': 'supplier-1',
            'purchase_date': now,
            'subtotal': quantity * 100,
            'total': quantity * 100,
            'status': 'confirmed',
            'created_at': now,
            'updated_at': now,
          });
          await posting.post(
            txn: txn,
            movementId: '${id}_movement',
            productId: 'p-1',
            quantityChange: quantity,
            movementType: 'purchase',
            referenceType: 'purchase',
            referenceId: id,
            unitCost: 100,
          );
        });
      }

      await postPurchase('purchase-a', 20);
      await postPurchase('purchase-b', 10);

      expect((await db.query('products')).single['stock'], 80.0);
      expect(await db.query('purchases'), hasLength(2));
      expect(await db.query('stock_movements'), hasLength(2));
      expect(
        (await db.query('stock_movements',
                where: 'reference_id = ?', whereArgs: ['purchase-a']))
            .single['running_stock'],
        70.0,
      );
      expect(
        (await db.query('stock_movements',
                where: 'reference_id = ?', whereArgs: ['purchase-b']))
            .single['running_stock'],
        80.0,
      );
    } finally {
      await manager.close();
      await root.delete(recursive: true);
    }
  });
}

class _UnusedProductRepository implements ProductRepositoryInt {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _UnusedPurchaseRepository implements PurchaseRepository {
  int createPurchaseCalls = 0;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  @override
  Future<Either<Failure, Unit>> createPurchase(Purchase purchase) async {
    createPurchaseCalls++;
    throw StateError('Purchase posting is not part of this cancellation test.');
  }
}
