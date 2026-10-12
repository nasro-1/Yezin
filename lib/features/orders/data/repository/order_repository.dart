import 'orders_proformas_repository.dart';
export 'orders_proformas_repository.dart';

/// Compatibility name for integrations that address the order repository
/// separately. Both document types share one transaction boundary.
typedef OrderRepository = OrdersProformasRepository;
