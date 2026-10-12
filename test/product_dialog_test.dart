import 'package:bayaa_pos/features/products/presentation/widgets/enhanced_add_edit_Dialog.dart';
import 'package:bayaa_pos/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrapDialog({
  Locale locale = const Locale('en'),
  List<String> categories = const ['General'],
}) {
  return MaterialApp(
    locale: locale,
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    home: Scaffold(
      body: Center(
        child: EnhancedAddEditProductDialog(categories: categories),
      ),
    ),
  );
}

void main() {
  testWidgets(
      'localized All category does not trigger initState lifecycle error',
      (tester) async {
    await tester.pumpWidget(
      _wrapDialog(
        locale: const Locale('ar'),
        categories: ['الكل', 'General'],
      ),
    );

    expect(find.byType(EnhancedAddEditProductDialog), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'STANDARD hides unit-management sections and keeps barcode optional',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_wrapDialog());

    expect(find.text('PRODUCT TYPE'), findsOneWidget);
    expect(find.text('STANDARD'), findsOneWidget);
    expect(find.text('WEIGHTED PRODUCT'), findsNothing);
    expect(find.text('PACKAGING & SELLING UNITS'), findsNothing);
    expect(find.text('Barcode Number'), findsOneWidget);
  });

  testWidgets('Add Product header has no subtitle', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_wrapDialog());

    expect(find.text('Add New Product'), findsOneWidget);
    expect(find.text('Create and configure a product'), findsNothing);
  });

  testWidgets('switching to WEIGHTED shows base-unit pricing controls',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_wrapDialog());

    await tester.tap(find.text('WEIGHTED').last);
    await tester.pumpAndSettle();

    expect(find.text('WEIGHTED PRODUCT'), findsOneWidget);
    expect(find.text('Base Unit'), findsOneWidget);
    expect(find.text('Quantity Precision'), findsNothing);
    expect(find.text('Price per kg'), findsOneWidget);
    expect(find.textContaining('0.300'), findsNothing);
    expect(find.textContaining('90.00'), findsNothing);
    expect(find.byType(DropdownButtonFormField<String>), findsNWidgets(2));
    expect(find.text('PACKAGING & SELLING UNITS'), findsNothing);
  });

  testWidgets(
      'Opening Stock is collapsed and expands to canonical reason dropdown',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_wrapDialog());

    await tester.ensureVisible(find.text('Add opening stock'));
    expect(find.text('Initial quantity (piece)'), findsNothing);
    expect(find.text('Cost price / piece'), findsNothing);
    expect(find.text('Reason'), findsNothing);

    await tester.tap(find.text('Add opening stock'));
    await tester.pumpAndSettle();

    expect(find.text('Initial quantity (piece)'), findsOneWidget);
    expect(find.text('Cost price / piece'), findsOneWidget);
    expect(find.byType(DropdownButtonFormField<String>), findsNWidgets(2));
  });

  testWidgets(
      'PACKAGED add dialog renders Initial Stock in the active widget tree',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_wrapDialog());

    await tester.tap(find.text('PACKAGED').last);
    await tester.pumpAndSettle();

    expect(find.text('PACKAGING & SELLING UNITS'), findsOneWidget);
    expect(find.text('INITIAL STOCK'), findsOneWidget);
    expect(find.text('Add Stock Line'), findsOneWidget);
    expect(find.text('Selling Unit'), findsWidgets);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('packaged-initial-stock')),
        matching: find.text('piece'),
      ),
      findsNothing,
    );
    expect(find.text('Reason'), findsWidgets);

    final texts = tester.widgetList<Text>(find.byType(Text)).toList();
    final packagedIndex = texts
        .indexWhere((widget) => widget.data == 'PACKAGING & SELLING UNITS');
    final initialStockIndex =
        texts.indexWhere((widget) => widget.data == 'INITIAL STOCK');
    final footerIndex =
        texts.indexWhere((widget) => widget.data == 'Add Product');

    expect(packagedIndex, isNot(equals(-1)));
    expect(initialStockIndex, isNot(equals(-1)));
    expect(footerIndex, isNot(equals(-1)));
    expect(initialStockIndex, greaterThan(packagedIndex));
    expect(initialStockIndex, lessThan(footerIndex));
  });

  testWidgets(
      'switching to PACKAGED keeps selling units and removes extra packaged UI',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_wrapDialog());

    await tester.tap(find.text('PACKAGED').last);
    await tester.pumpAndSettle();

    expect(find.text('Barcode Number'), findsOneWidget);
    expect(find.text('PACKAGING & SELLING UNITS'), findsOneWidget);
    expect(find.text('Base Unit'), findsNothing);
    expect(find.text('Inventory & Pricing'), findsNothing);
    expect(find.text('Contains'), findsOneWidget);
    expect(find.text('Minimum Stock'), findsNothing);
    expect(find.text('Add opening stock'), findsNothing);
    expect(find.text('Can this package be opened and sold as smaller units?'),
        findsNothing);
    expect(
      find.text(
          'Only explicitly configured smaller selling units are available.'),
      findsNothing,
    );

    await tester.ensureVisible(find.text('Add Selling Unit'));
    await tester.tap(find.text('Add Selling Unit'));
    await tester.pumpAndSettle();
    expect(find.text('Add Selling Unit'), findsNWidgets(2));
    expect(find.text('Selling Unit'), findsWidgets);
    expect(find.textContaining('Cost Price /'), findsNothing);
    expect(find.text('Unit Name'), findsNothing);
    expect(find.text('Cost Price'), findsNothing);
    expect(find.text('Save Unit'), findsOneWidget);
    expect(find.text('Barcode (optional)'), findsNothing);
    expect(find.text('Unit icon'), findsNothing);
    expect(find.textContaining('Selling Price'), findsWidgets);
    expect(find.text('Minimum Stock'), findsNothing);
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Cost'),
      ),
      findsNothing,
    );
    final unitSelectors = find.byType(DropdownButtonFormField<String>);
    await tester.tap(unitSelectors.last);
    await tester.pumpAndSettle();
    expect(find.text('pack'), findsWidgets);
    expect(find.text('box'), findsWidgets);
    expect(find.text('carton'), findsNothing);
    await tester.tap(find.text('pack').last);
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.layers_outlined), findsOneWidget);
    expect(find.textContaining('Selling Price'), findsWidgets);
    expect(find.text('Minimum Stock'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Cost'),
      ),
      findsNothing,
    );

    await tester.tap(unitSelectors.last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('box').last);
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.all_inbox_outlined), findsOneWidget);
    expect(find.text('Minimum Stock'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Cost'),
      ),
      findsNothing,
    );
  });

  testWidgets('packaged initial stock allows one Pack and one Box only',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_wrapDialog());

    await tester.tap(find.text('PACKAGED').last);
    await tester.pumpAndSettle();

    final section = find.byKey(const ValueKey('packaged-initial-stock'));
    final firstUnitSelector = tester.widget<DropdownButton<String>>(
      find
          .descendant(
            of: section,
            matching: find.byType(DropdownButton<String>),
          )
          .first,
    );
    expect(
      firstUnitSelector.items!.map((item) => item.value),
      containsAll(<String>['pack', 'box']),
    );
    expect(
      firstUnitSelector.items!.map((item) => item.value),
      isNot(contains('piece')),
    );

    final addButton = find.ancestor(
      of: find.text('Add Stock Line'),
      matching: find.byWidgetPredicate((widget) => widget is OutlinedButton),
    );
    await tester.ensureVisible(addButton);
    await tester.tap(addButton);
    await tester.pumpAndSettle();

    final secondUnitSelector = tester.widget<DropdownButton<String>>(
      find
          .descendant(
            of: section,
            matching: find.byType(DropdownButton<String>),
          )
          .at(1),
    );
    expect(
      secondUnitSelector.items!.map((item) => item.value),
      contains('box'),
    );
    expect(
      secondUnitSelector.items!.map((item) => item.value),
      isNot(contains('pack')),
    );
    final addWidget = tester.widget<OutlinedButton>(addButton);
    expect(addWidget.onPressed, isNull);
    expect(
      firstUnitSelector.items!.map((item) => item.value),
      isNot(contains('piece')),
    );
  });

  testWidgets('unit selectors update weighted price and stock wording',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_wrapDialog());
    await tester.tap(find.text('WEIGHTED').last);
    await tester.pumpAndSettle();

    final selectors = find.byType(DropdownButtonFormField<String>);
    await tester.ensureVisible(selectors.last);
    await tester.tap(selectors.last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('g').last);
    await tester.pumpAndSettle();

    expect(find.text('Price per g'), findsOneWidget);
    expect(find.text('Minimum Stock (g)'), findsOneWidget);
    expect(find.textContaining('g'), findsWidgets);
  });

  testWidgets(
      'packaged product hides base-unit and inventory details from the form',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_wrapDialog());
    await tester.tap(find.text('PACKAGED').last);
    await tester.pumpAndSettle();

    expect(find.text('Base Unit'), findsNothing);
    expect(find.text('Inventory & Pricing'), findsNothing);
    expect(find.text('Minimum Stock'), findsNothing);
    expect(find.text('Contains'), findsOneWidget);
  });

  testWidgets('packaged validation messages are specific and not generic',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_wrapDialog());
    await tester.tap(find.text('PACKAGED').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, 'Packaged Item');
    await tester.pump();

    await tester.tap(find.text('Add Product'));
    await tester.pump();

    expect(find.text('Add at least one active selling unit.'), findsOneWidget);
    expect(find.text('Please enter a valid number'), findsNothing);
  });

  testWidgets('Arabic Product dialog renders localized labels in RTL',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_wrapDialog(locale: const Locale('ar')));

    expect(find.text('نوع المنتج'), findsOneWidget);
    expect(find.text('رقم الباركود'), findsOneWidget);
    expect(find.byType(Directionality), findsWidgets);
  });

  testWidgets('invalid general form shows a submission-level explanation',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_wrapDialog());

    await tester.tap(find.text('Add Product'));
    await tester.pump();

    expect(
      find.text('Please correct the highlighted fields before saving.'),
      findsOneWidget,
    );
    expect(find.text('Add Product'), findsOneWidget);
  });

  testWidgets('invalid weighted configuration shows its exact reason',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_wrapDialog());
    await tester.tap(find.text('WEIGHTED').last);
    await tester.pumpAndSettle();

    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), 'Potato');
    await tester.enterText(fields.at(2), '0');
    await tester.enterText(fields.at(3), '200');
    await tester.enterText(fields.at(4), '250');
    await tester.enterText(fields.at(5), '10');
    await tester.tap(find.text('Add Product'));
    await tester.pump();

    expect(
      find.text('Price per base unit must be greater than zero.'),
      findsOneWidget,
    );
  });
}
