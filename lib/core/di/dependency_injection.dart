import 'package:bayaa_pos/features/auth/data/repository/user_repository_imp.dart';
import 'package:bayaa_pos/features/auth/domain/repository/user_repository_int.dart';
import 'package:bayaa_pos/features/auth/presentation/cubit/user_cubit.dart';
import 'package:bayaa_pos/features/products/data/repository/product_repository_imp.dart';
import 'package:bayaa_pos/features/products/data/repository/product_api_repository.dart';
import 'package:bayaa_pos/features/products/domain/product_repository_int.dart';
import 'package:bayaa_pos/features/products/presentation/cubit/product_cubit.dart';
import 'package:bayaa_pos/features/stock/presentation/cubit/stock_cubit.dart';
import '../../features/invoice/presentation/cubit/invoice_cubit.dart';
import '../../features/sales/domain/sales_repository.dart';
import '../../features/stock_summary/presentation/cubit/stock_summary_cubit.dart';
import 'package:get_it/get_it.dart';
import 'package:flutter/foundation.dart';
import '../../core/network/backend_api_client.dart';
import '../../core/network/backend_api_config.dart';
import '../../core/network/backend_token_store.dart';
import '../../core/network/backend_auth_bootstrap.dart';
import '../../core/network/authority_context.dart';

import '../../features/analytics/data/analytics_repository_impl.dart';
import '../../features/analytics/domain/analytics_repository.dart';
import '../../features/analytics/presentation/cubit/analytics_cubit.dart';
import '../../features/customers/data/repository/customer_repository_impl.dart';
import '../../features/notifications/presentation/cubit/notifications_cubit.dart';
import '../../features/sales/data/repository/sales_repository_impl.dart';
import '../../features/sales/data/repository/sales_api_repository.dart';
import '../../features/sales/data/repository/sale_draft_api_repository.dart';
import '../../features/sales/domain/draft_sales_repository.dart';
import '../../features/sales/presentation/cubit/sales_cubit.dart';
import '../../features/sales/presentation/cubit/draft_sales_cubit.dart';
import '../../core/network/sale_draft_event_client.dart';
import '../../features/settings/data/data_source/store_info_data_source.dart';
import '../../features/settings/data/repository/settings_repository_imp.dart';
import '../../features/settings/presentation/cubit/settings_cubit.dart';
import '../../features/sessions/data/repositories/session_repository_impl.dart';
import '../../features/stock/data/repository/stock_movement_repository.dart';
import '../../features/stock/data/repository/opening_stock_repository.dart';
import '../../features/stock/services/opening_stock_service.dart';
import '../../features/stock/data/repository/stock_adjustment_repository.dart';
import '../../features/stock/data/repository/stock_adjustment_api_repository.dart';
import '../../features/stock/services/stock_adjustment_service.dart';
import '../../features/suppliers/data/repository/supplier_repository_impl.dart';
import '../../features/suppliers/data/repository/supplier_api_repository.dart';
import '../../features/purchases/data/repository/purchase_repository_impl.dart';
import '../../features/purchases/data/repository/purchase_api_repository.dart';
import '../../features/suppliers/data/repository/supplier_payment_repository_impl.dart';
import '../../features/suppliers/data/repository/supplier_payment_api_repository.dart';
import '../../features/suppliers/data/repository/supplier_return_repository_impl.dart';
import '../../features/suppliers/data/repository/supplier_return_api_repository.dart';
import '../../features/customers/data/repository/customer_payment_repository_impl.dart';
import '../../core/services/activity_logger.dart';
import '../../core/session/session_manager.dart';
import '../../core/localization/locale_provider.dart';
import '../../features/orders/data/repository/orders_proformas_repository.dart';
import '../../features/orders/domain/order_proforma_service.dart';

final getIt = GetIt.instance;

void setup() {
  // Core Services
  getIt.registerSingleton<ActivityLogger>(ActivityLogger());
  getIt.registerSingleton<LocaleProvider>(LocaleProvider());
  final authorityContext = AuthorityContext.fromProductConfig();
  getIt.registerSingleton<AuthorityContext>(authorityContext);

  // Repositories
  getIt.registerSingleton<SessionRepositoryImpl>(SessionRepositoryImpl(
    serverMode: authorityContext.readsFromServer,
  ));
  getIt.registerSingleton<CustomerRepository>(CustomerRepositoryImpl());
  getIt.registerSingleton<CustomerPaymentRepository>(
      CustomerPaymentRepositoryImpl());
  final ordersProformasRepository = OrdersProformasRepository(
    authorityContext: authorityContext,
  );
  getIt.registerSingleton<OrdersProformasRepository>(ordersProformasRepository);
  getIt.registerSingleton<OrderProformaService>(
      OrderProformaService(ordersProformasRepository));
  getIt.registerSingleton<StockMovementRepository>(StockMovementRepository());
  getIt.registerSingleton<OpeningStockRepository>(OpeningStockRepository());
  getIt.registerSingleton<OpeningStockService>(
    OpeningStockService(
      repository: getIt<OpeningStockRepository>(),
      authorityContext: authorityContext,
    ),
  );
  getIt.registerSingleton<StockAdjustmentRepository>(
      StockAdjustmentRepository());

  // Session Manager (wraps SessionRepositoryImpl)
  final sessionManager = SessionManager();
  sessionManager.initialize(getIt<SessionRepositoryImpl>());
  getIt.registerSingleton<SessionManager>(sessionManager);

  final userRepo = UserRepositoryImp();
  getIt.registerSingleton<UserRepositoryInt>(userRepo);

  getIt.registerSingleton<UserCubit>(UserCubit(
      userRepository: userRepo,
      sessionRepository: getIt<SessionRepositoryImpl>()));

  final backendTokenStore = BackendTokenStore();
  final backendApiClient = BackendApiClient(
    config: const BackendApiConfig(),
    tokenStore: backendTokenStore,
  );
  final productApiRepository = ProductApiRepository(backendApiClient);
  final productRepository = ProductRepositoryImp(
    serverReadRepository: productApiRepository,
    authorityContext: authorityContext,
  );
  if (kDebugMode) {
    debugPrint(
      '[DI] ProductReadMode=${BackendApiConfig.productReadMode}, '
      'ProductWriteMode=${BackendApiConfig.productWriteMode}, '
      'apiBaseUrl=${BackendApiConfig.rawApiBaseUrl}',
    );
  }
  getIt.registerSingleton<BackendTokenStore>(backendTokenStore);
  getIt.registerSingleton<BackendApiClient>(backendApiClient);
  final supplierRepository = supplierRepositoryForAuthority(
    authorityContext: authorityContext,
    client: backendApiClient,
  );
  getIt.registerSingleton<SupplierRepository>(supplierRepository);
  if (supplierRepository is SupplierApiRepository) {
    getIt.registerSingleton<SupplierApiRepository>(supplierRepository);
  }
  final supplierPaymentRepository = supplierPaymentRepositoryForAuthority(
    authorityContext: authorityContext,
    client: backendApiClient,
  );
  getIt.registerSingleton<SupplierPaymentRepository>(supplierPaymentRepository);
  if (supplierPaymentRepository is SupplierPaymentApiRepository) {
    getIt.registerSingleton<SupplierPaymentApiRepository>(
        supplierPaymentRepository);
  }
  final purchaseRepository = purchaseRepositoryForAuthority(
    authorityContext: authorityContext,
    client: backendApiClient,
  );
  getIt.registerSingleton<PurchaseRepository>(purchaseRepository);
  if (purchaseRepository is PurchaseApiRepository) {
    getIt.registerSingleton<PurchaseApiRepository>(purchaseRepository);
  }
  final supplierReturnRepository = supplierReturnRepositoryForAuthority(
    authorityContext: authorityContext,
    client: backendApiClient,
  );
  getIt.registerSingleton<SupplierReturnRepository>(supplierReturnRepository);
  if (supplierReturnRepository is SupplierReturnApiRepository) {
    getIt.registerSingleton<SupplierReturnApiRepository>(
        supplierReturnRepository);
  }
  final draftEventClient = SaleDraftEventClient(
    config: const BackendApiConfig(),
    tokenStore: backendTokenStore,
  );
  final draftRepository = SaleDraftApiRepository(backendApiClient);
  getIt.registerSingleton<SaleDraftEventClient>(draftEventClient);
  getIt.registerSingleton<DraftSalesRepository>(draftRepository);
  getIt.registerSingleton<SaleDraftApiRepository>(draftRepository);
  getIt.registerSingleton<DraftSalesCubit>(DraftSalesCubit(
    repository: draftRepository,
    eventClient: draftEventClient,
  ));
  getIt.registerSingleton<BackendAuthBootstrap>(
    BackendAuthBootstrap(backendApiClient),
  );
  getIt.registerSingleton<ProductApiRepository>(productApiRepository);
  getIt.registerSingleton<StockAdjustmentApiRepository>(
    StockAdjustmentApiRepository(backendApiClient),
  );
  getIt.registerSingleton<StockAdjustmentService>(
    StockAdjustmentService(
      repository: getIt<StockAdjustmentRepository>(),
      apiRepository: getIt<StockAdjustmentApiRepository>(),
    ),
  );
  getIt.registerSingleton<ProductRepositoryImp>(productRepository);
  getIt.registerSingleton<ProductRepositoryInt>(productRepository);
  getIt.registerSingleton<ProductCubit>(
      ProductCubit(productRepositoryInt: productRepository));

  final SalesRepository salesRepo = authorityContext.writesToServer
      ? SalesApiRepository(backendApiClient)
      : SalesRepositoryImpl();

  getIt.registerSingleton<SalesRepository>(salesRepo);
  if (salesRepo is SalesApiRepository) {
    getIt.registerSingleton<SalesApiRepository>(salesRepo);
  }
  if (salesRepo is SalesRepositoryImpl) {
    getIt.registerSingleton<SalesRepositoryImpl>(salesRepo);
  }

  getIt.registerSingleton<SalesCubit>(SalesCubit(repository: salesRepo));

  getIt.registerSingleton<StockCubit>(
      StockCubit(productRepository: getIt<ProductRepositoryInt>()));

  getIt.registerSingleton<InvoiceCubit>(InvoiceCubit(salesRepo));

  getIt.registerSingleton<NotificationsCubit>(NotificationsCubit());

  final analyticsRepo = AnalyticsRepositoryImpl(
    client: getIt<BackendApiClient>(),
    serverMode: getIt<AuthorityContext>().readsFromServer,
  );
  getIt.registerSingleton<AnalyticsRepository>(analyticsRepo);

  getIt.registerSingleton<AnalyticsCubit>(AnalyticsCubit(analyticsRepo));

  getIt.registerFactory<StockSummaryCubit>(() => StockSummaryCubit(
        client: getIt<BackendApiClient>(),
        authorityContext: getIt<AuthorityContext>(),
      ));

  final storeInfoRepo = StoreInfoRepository(
    dataSource: StoreInfoDataSource(),
  );
  getIt.registerSingleton<StoreInfoRepository>(storeInfoRepo);

  getIt.registerLazySingleton<SettingsCubit>(() => SettingsCubit(
        userCubit: getIt<UserCubit>(),
        storeRepository: storeInfoRepo,
      ));
}
