import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:bayaa_pos/core/constants/app_brand.dart';
import 'package:bayaa_pos/l10n/app_localizations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Yezin is the application brand in English and Arabic', () async {
    final english = await AppLocalizations.delegate.load(const Locale('en'));
    final arabic = await AppLocalizations.delegate.load(const Locale('ar'));

    expect(english.appName, AppBrand.name);
    expect(english.loginBrandName, AppBrand.name);
    expect(arabic.appName, AppBrand.name);
    expect(arabic.loginBrandName, AppBrand.name);
  });

  test('default legacy store names render as the current app brand', () {
    expect(AppBrand.isDefaultStoreName('Yezin'), isTrue);
    expect(AppBrand.isDefaultStoreName('Bayaa'), isTrue);
    expect(AppBrand.isDefaultStoreName('Bayaa POS'), isTrue);
    expect(AppBrand.isDefaultStoreName('Bayaa Store'), isTrue);
    expect(AppBrand.isDefaultStoreName('Corner Shop'), isFalse);
  });

  test('Material and Lucide icon fonts are present in the asset bundle',
      () async {
    final materialIcons =
        await rootBundle.load('fonts/MaterialIcons-Regular.otf');
    final lucideIcons = await rootBundle
        .load('packages/lucide_icons_flutter/assets/lucide.ttf');

    expect(materialIcons.lengthInBytes, greaterThan(0));
    expect(lucideIcons.lengthInBytes, greaterThan(0));
    expect(Icons.search.fontFamily, 'MaterialIcons');
    expect(LucideIcons.search.fontPackage, 'lucide_icons_flutter');
  });
}
