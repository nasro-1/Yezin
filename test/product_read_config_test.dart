import 'package:flutter_test/flutter_test.dart';

import 'package:bayaa_pos/core/network/backend_api_config.dart';
import 'package:bayaa_pos/features/products/data/repository/product_repository_imp.dart';

void main() {
  test('local mode remains the default', () {
    expect(
      ProductRepositoryImp().readMode,
      ProductReadMode.local,
    );
    expect(
      BackendApiConfig.productReadMode,
      BackendApiConfig.rawProductReadMode == 'server'
          ? ProductReadMode.server
          : ProductReadMode.local,
    );
  });

  test('server mode can be selected explicitly', () {
    final repository = ProductRepositoryImp(
      readMode: ProductReadMode.server,
    );

    expect(repository.readMode, ProductReadMode.server);
  });

  test('API base URL accepts dart-define configuration', () {
    const config = BackendApiConfig(
      baseUrl: 'https://example.com/api/v1',
    );

    expect(config.baseUrl, 'https://example.com/api/v1');
  });

  test('compile-time environment values resolve consistently', () {
    expect(
      BackendApiConfig.productReadMode,
      BackendApiConfig.rawProductReadMode == 'server'
          ? ProductReadMode.server
          : ProductReadMode.local,
    );
    expect(
      BackendApiConfig.defaultBaseUrl,
      BackendApiConfig.rawApiBaseUrl,
    );
  });
}
