import 'package:flutter/foundation.dart';

import '../data/models/product_model.dart';
import '../data/models/selling_unit_model.dart';

typedef SellingUnitsLoader = Future<List<SellingUnit>> Function(
    String productId);

class PackagedDisplayUnitLoader {
  int _requestVersion = 0;

  Future<Map<String, List<SellingUnit>>?> load(
    List<Product> products,
    SellingUnitsLoader loadUnits,
  ) async {
    final requestVersion = ++_requestVersion;
    final packagedProducts = products
        .where((product) => product.productType == ProductType.packaged)
        .toList();
    try {
      final unitResults = await Future.wait(
        packagedProducts.map(
          (product) async {
            final units = await loadUnits(product.id);
            if (units.isEmpty) return null;
            return MapEntry(product.id, units);
          },
        ),
      );
      if (requestVersion != _requestVersion) return null;
      return {
        for (final entry in unitResults)
          if (entry != null) entry.key: entry.value,
      };
    } catch (error, stackTrace) {
      FlutterError.reportError(FlutterErrorDetails(
        exception: error,
        stack: stackTrace,
        library: 'products',
        context: ErrorDescription('loading packaged display units'),
      ));
      return null;
    }
  }
}
