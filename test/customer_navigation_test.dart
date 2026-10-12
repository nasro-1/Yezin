import 'package:flutter_test/flutter_test.dart';

import 'package:bayaa_pos/features/customers/presentation/customer_workspace.dart';

void main() {
  test('customer navigation exposes one grouped workspace with three tabs', () {
    expect(customerWorkspaceTabs, [
      CustomerWorkspaceTab.customers,
      CustomerWorkspaceTab.payments,
      CustomerWorkspaceTab.returns,
    ]);
    expect(
      customerWorkspaceTabTitle(CustomerWorkspaceTab.customers),
      'Customers',
    );
    expect(
      customerWorkspaceTabTitle(CustomerWorkspaceTab.payments),
      'Customer Payments',
    );
    expect(
      customerWorkspaceTabTitle(CustomerWorkspaceTab.returns),
      'Customer Returns',
    );
  });

  test('customer workspace defaults to the Customers tab', () {
    expect(customerWorkspaceTabs.first, CustomerWorkspaceTab.customers);
  });
}
