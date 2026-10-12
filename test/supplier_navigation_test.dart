import 'package:flutter_test/flutter_test.dart';

import 'package:bayaa_pos/features/suppliers/presentation/supplier_workspace.dart';

void main() {
  test('supplier navigation exposes one grouped workspace with four tabs', () {
    expect(supplierWorkspaceTabs, [
      SupplierWorkspaceTab.suppliers,
      SupplierWorkspaceTab.purchases,
      SupplierWorkspaceTab.payments,
      SupplierWorkspaceTab.returns,
    ]);
    expect(
        supplierWorkspaceTabTitle(SupplierWorkspaceTab.suppliers), 'Suppliers');
    expect(
      supplierWorkspaceTabTitle(SupplierWorkspaceTab.purchases),
      'Purchases',
    );
    expect(
      supplierWorkspaceTabTitle(SupplierWorkspaceTab.payments),
      'Supplier Payments',
    );
    expect(
      supplierWorkspaceTabTitle(SupplierWorkspaceTab.returns),
      'Supplier Returns',
    );
  });

  test('supplier workspace defaults to the Suppliers tab', () {
    expect(supplierWorkspaceTabs.first, SupplierWorkspaceTab.suppliers);
  });
}
