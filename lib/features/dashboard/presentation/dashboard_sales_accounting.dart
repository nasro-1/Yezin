import 'package:flutter/foundation.dart';

import '../../../core/data/models/activity_log.dart';
import '../../../core/di/dependency_injection.dart';
import '../../../core/services/activity_logger.dart';
import '../../sales/data/models/sale_model.dart';

double calculateDashboardNetSales(Iterable<Sale> sales) {
  final replacementSaleIds = getIt.isRegistered<ActivityLogger>()
      ? getIt<ActivityLogger>()
          .recentActivities
          .where((activity) => activity.type == ActivityType.exchange)
          .map((activity) => activity.details?['replacement_sale_id'])
          .whereType<String>()
          .toSet()
      : <String>{};

  var total = 0.0;
  for (final sale in sales) {
    final contribution = sale.accountingContribution;
    final isOriginalExchangeSale = sale.isExchanged;
    final isReplacementSale = replacementSaleIds.contains(sale.id);
    debugPrint(
      '[DASHBOARD_ACCOUNTING] saleId=${sale.id} '
      'reference=${sale.referenceNumber} total=${sale.total} '
      'isRefund=${sale.isRefund} '
      'effectiveRefundedTotal=${sale.effectiveRefundedTotal} '
      'effectiveExchangedTotal=${sale.effectiveExchangedTotal} '
      'accountingContribution=$contribution '
      'isOriginalExchangeSale=$isOriginalExchangeSale '
      'isReplacementSale=$isReplacementSale',
    );
    total += contribution;
  }
  return total;
}
