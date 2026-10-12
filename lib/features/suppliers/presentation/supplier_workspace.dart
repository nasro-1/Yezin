import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/di/dependency_injection.dart';
import '../../purchases/presentation/purchases_screen.dart';
import '../../purchases/data/repository/purchase_repository_impl.dart';
import '../data/repository/supplier_payment_repository_impl.dart';
import '../data/repository/supplier_repository_impl.dart';
import '../data/repository/supplier_return_repository_impl.dart';
import 'supplier_payments_screen.dart';
import 'supplier_returns_screen.dart';
import 'suppliers_screen.dart';

enum SupplierWorkspaceTab {
  suppliers,
  purchases,
  payments,
  returns,
}

const supplierWorkspaceTabs = <SupplierWorkspaceTab>[
  SupplierWorkspaceTab.suppliers,
  SupplierWorkspaceTab.purchases,
  SupplierWorkspaceTab.payments,
  SupplierWorkspaceTab.returns,
];

String supplierWorkspaceTabTitle(SupplierWorkspaceTab tab) {
  switch (tab) {
    case SupplierWorkspaceTab.suppliers:
      return 'Suppliers';
    case SupplierWorkspaceTab.purchases:
      return 'Purchases';
    case SupplierWorkspaceTab.payments:
      return 'Supplier Payments';
    case SupplierWorkspaceTab.returns:
      return 'Supplier Returns';
  }
}

class SupplierWorkspace extends StatefulWidget {
  const SupplierWorkspace({super.key, this.onTabChanged});

  final ValueChanged<SupplierWorkspaceTab>? onTabChanged;

  @override
  State<SupplierWorkspace> createState() => _SupplierWorkspaceState();
}

class _SupplierWorkspaceState extends State<SupplierWorkspace>
    with SingleTickerProviderStateMixin {
  late final TabController _controller;
  late final List<Widget> _screens;

  @override
  void initState() {
    super.initState();
    _controller =
        TabController(length: supplierWorkspaceTabs.length, vsync: this)
          ..addListener(_handleTabChanged);
    _screens = [
      SuppliersScreen(repository: getIt<SupplierRepository>()),
      PurchasesScreen(repository: getIt<PurchaseRepository>()),
      SupplierPaymentsScreen(repository: getIt<SupplierPaymentRepository>()),
      SupplierReturnsScreen(repository: getIt<SupplierReturnRepository>()),
    ];
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.onTabChanged?.call(supplierWorkspaceTabs[_controller.index]);
    });
  }

  void _handleTabChanged() {
    if (!_controller.indexIsChanging) {
      widget.onTabChanged?.call(supplierWorkspaceTabs[_controller.index]);
    }
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_handleTabChanged)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: AppColors.borderColor.withOpacity(0.8),
                width: 1.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.02),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            padding: const EdgeInsets.all(4),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final isSmall = constraints.maxWidth < 500;
                final tabs = [
                  _SupplierTabOption(
                    SupplierWorkspaceTab.suppliers,
                    'Suppliers',
                    LucideIcons.users,
                  ),
                  _SupplierTabOption(
                    SupplierWorkspaceTab.purchases,
                    'Purchases',
                    LucideIcons.shoppingBag,
                  ),
                  _SupplierTabOption(
                    SupplierWorkspaceTab.payments,
                    'Supplier Payments',
                    LucideIcons.wallet,
                  ),
                  _SupplierTabOption(
                    SupplierWorkspaceTab.returns,
                    'Supplier Returns',
                    LucideIcons.undo2,
                  ),
                ];
                return Row(
                  children: tabs.map((tab) {
                    final isSelected = _controller.index ==
                        supplierWorkspaceTabs.indexOf(tab.id);
                    return Expanded(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => _controller.animateTo(
                          supplierWorkspaceTabs.indexOf(tab.id),
                        ),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 250),
                          curve: Curves.easeOutCubic,
                          padding: EdgeInsets.symmetric(
                            vertical: isSmall ? 10 : 12,
                          ),
                          decoration: BoxDecoration(
                            color: isSelected
                                ? AppColors.primaryColor
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(12),
                            boxShadow: isSelected
                                ? [
                                    BoxShadow(
                                      color: AppColors.primaryColor
                                          .withOpacity(0.2),
                                      blurRadius: 8,
                                      offset: const Offset(0, 3),
                                    ),
                                  ]
                                : null,
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                tab.icon,
                                size: isSmall ? 16 : 18,
                                color: isSelected
                                    ? Colors.white
                                    : AppColors.mutedColor,
                              ),
                              const SizedBox(width: 8),
                              Flexible(
                                child: Text(
                                  tab.label,
                                  overflow: TextOverflow.ellipsis,
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontSize: isSmall ? 12 : 14,
                                    fontWeight: isSelected
                                        ? FontWeight.bold
                                        : FontWeight.w600,
                                    color: isSelected
                                        ? Colors.white
                                        : AppColors.textSecondary,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                );
              },
            ),
          ),
        ),
        Expanded(
          child: TabBarView(
            controller: _controller,
            children: _screens,
          ),
        ),
      ],
    );
  }
}

class _SupplierTabOption {
  const _SupplierTabOption(this.id, this.label, this.icon);

  final SupplierWorkspaceTab id;
  final String label;
  final IconData icon;
}
