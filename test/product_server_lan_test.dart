import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:bayaa_pos/core/network/backend_api_client.dart';
import 'package:bayaa_pos/core/network/backend_api_config.dart';
import 'package:bayaa_pos/core/network/backend_token_store.dart';
import 'package:bayaa_pos/features/products/data/repository/product_api_repository.dart';
import 'package:bayaa_pos/features/products/data/repository/product_repository_imp.dart';

void main() {
  final baseUrl = Platform.environment['BAYAA_API_BASE_URL'];

  test('reads products from the real development server', () async {
    if (baseUrl == null || baseUrl.isEmpty) {
      return;
    }

    final tokenStore = BackendTokenStore();
    final apiRepository = ProductApiRepository(
      BackendApiClient(
        config: BackendApiConfig(baseUrl: baseUrl),
        tokenStore: tokenStore,
      ),
    );
    await apiRepository.client.login(
      username: Platform.environment['BAYAA_DEV_USERNAME'] ?? 'testadmin',
      password: Platform.environment['BAYAA_DEV_PASSWORD'] ?? 'admin',
    );

    final repository = ProductRepositoryImp(
      serverReadRepository: apiRepository,
      readMode: ProductReadMode.server,
    );
    final products = await repository.getProductsPaginated(
      page: 0,
      pageSize: 50,
    );
    expect(products.isRight, isTrue);
    expect(products.right.map((product) => product.name),
        contains('Test Coca Cola'));

    final barcodeProduct = await apiRepository.getProductByBarcode('123456789');
    expect(barcodeProduct.isRight, isTrue);
    expect(barcodeProduct.right.name, 'Test Coca Cola');
  });
}
