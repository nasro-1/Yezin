import 'package:bayaa_pos/features/auth/data/models/user_model.dart';
import 'package:bayaa_pos/features/auth/presentation/cubit/user_states.dart';
import 'package:bayaa_pos/features/products/data/models/product_model.dart';
import 'package:bayaa_pos/features/products/presentation/widgets/product_details_dialog.dart';
import 'package:bayaa_pos/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('server-auth empty user state is strongly typed', () {
    final state = UsersLoaded(const <User>[]);

    expect(state.users, isA<List<User>>());
    expect(state.users, isEmpty);
  });

  testWidgets('product details dialog lays out with bounded history area',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final product = Product(
      id: 'product-details-test',
      name: 'Test Product',
      barcode: 'details-test',
      price: 100,
      minPrice: 90,
      wholesalePrice: 70,
      cost: 50,
      quantity: 8,
      minQuantity: 1,
      category: 'General',
    );

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: ProductDetailsDialog(product: product),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(ProductDetailsDialog), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
