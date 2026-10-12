import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/di/dependency_injection.dart';
import '../../sales/domain/sales_repository.dart';
import '../data/repository/customer_payment_repository_impl.dart';
import '../data/repository/customer_repository_impl.dart';
import '../presentation/customer_payments_screen.dart';
import '../presentation/customer_returns_screen.dart';
import 'customers_screen.dart';

enum CustomerWorkspaceTab {
  customers,
  payments,
  returns,
}

const customerWorkspaceTabs = <CustomerWorkspaceTab>[
  CustomerWorkspaceTab.customers,
  CustomerWorkspaceTab.payments,
  CustomerWorkspaceTab.returns,
];

String customerWorkspaceTabTitle(CustomerWorkspaceTab tab) {
  switch (tab) {
    case CustomerWorkspaceTab.customers:
      return 'Customers';
    case CustomerWorkspaceTab.payments:
      return 'Customer Payments';
    case CustomerWorkspaceTab.returns:
      return 'Customer Returns';
  }
}

class CustomerWorkspace extends StatefulWidget {
  const CustomerWorkspace({super.key, this.onTabChanged});

  final ValueChanged<CustomerWorkspaceTab>? onTabChanged;

  @override
  State<CustomerWorkspace> createState() => _CustomerWorkspaceState();
}

class _CustomerWorkspaceState extends State<CustomerWorkspace>
    with SingleTickerProviderStateMixin {
  late final TabController _controller;
  late final List<Widget> _screens;

  @override
  void initState() {
    super.initState();
    _controller = TabController(
      length: customerWorkspaceTabs.length,
      vsync: this,
    )..addListener(_handleTabChanged);
    _screens = [
      CustomersScreen(repository: getIt<CustomerRepository>()),
      CustomerPaymentsScreen(
        repository: getIt<CustomerPaymentRepository>(),
      ),
      CustomerReturnsScreen(repository: getIt<SalesRepository>()),
    ];
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.onTabChanged?.call(customerWorkspaceTabs[_controller.index]);
    });
  }

  void _handleTabChanged() {
    if (!_controller.indexIsChanging) {
      widget.onTabChanged?.call(customerWorkspaceTabs[_controller.index]);
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
                  _CustomerTabOption(
                    CustomerWorkspaceTab.customers,
                    'Customers',
                    LucideIcons.users,
                  ),
                  _CustomerTabOption(
                    CustomerWorkspaceTab.payments,
                    'Customer Payments',
                    LucideIcons.wallet,
                  ),
                  _CustomerTabOption(
                    CustomerWorkspaceTab.returns,
                    'Customer Returns',
                    LucideIcons.undo2,
                  ),
                ];
                return Row(
                  children: tabs.map((tab) {
                    final isSelected = _controller.index ==
                        customerWorkspaceTabs.indexOf(tab.id);
                    return Expanded(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => _controller.animateTo(
                          customerWorkspaceTabs.indexOf(tab.id),
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

class _CustomerTabOption {
  const _CustomerTabOption(this.id, this.label, this.icon);

  final CustomerWorkspaceTab id;
  final String label;
  final IconData icon;
}
