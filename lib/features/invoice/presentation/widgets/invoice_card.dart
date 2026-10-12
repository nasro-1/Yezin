import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../../core/localization/translation_helper.dart';
import '../../../../l10n/app_localizations.dart';
import '../../../sales/data/models/sale_model.dart';
import '../../../../core/utils/currency_formatter.dart';

class InvoiceCard extends StatefulWidget {
  final Sale sale;
  final VoidCallback onOpen;
  final VoidCallback? onDelete;
  final VoidCallback? onReturn;
  final VoidCallback? onExchange;
  final VoidCallback onPrint;
  final VoidCallback? onReceipt;
  final bool isManager;

  const InvoiceCard({
    super.key,
    required this.sale,
    required this.onOpen,
    this.onDelete,
    this.onReturn,
    this.onExchange,
    required this.onPrint,
    this.onReceipt,
    required this.isManager,
  });

  @override
  State<InvoiceCard> createState() => _InvoiceCardState();
}

class _InvoiceCardState extends State<InvoiceCard> {
  bool _hovered = false;

  String _reference(Sale sale, AppLocalizations l10n) =>
      sale.referenceNumber ??
      l10n.invoiceNumber(
        sale.id.length > 8 ? sale.id.substring(0, 8) : sale.id,
      );

  String _status(Sale sale, AppLocalizations l10n) {
    if (sale.isRefund || sale.isFullyRefunded) return l10n.refunded;
    if (sale.isPartiallyRefunded) return l10n.partiallyRefunded;
    if (sale.isExchanged) return 'EXCHANGED';
    return 'COMPLETED';
  }

  Color _statusColor(Sale sale) {
    if (sale.isRefund || sale.isFullyRefunded) return AppColors.errorColor;
    if (sale.isPartiallyRefunded) return AppColors.warningColor;
    if (sale.isExchanged) return AppColors.secondaryColor;
    return AppColors.successColor;
  }

  @override
  Widget build(BuildContext context) {
    final sale = widget.sale;
    final l10n = AppLocalizations.of(context);
    final cashier = TranslationHelper.translateUserName(
      context,
      sale.cashierName ?? l10n.cashier,
    );
    final compact = MediaQuery.sizeOf(context).width < 700;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: _hovered
                ? AppColors.primaryColor.withOpacity(.28)
                : AppColors.borderColor.withOpacity(.35),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(_hovered ? .06 : .025),
              blurRadius: _hovered ? 14 : 8,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: Stack(
            children: [
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                child: SizedBox(
                  width: 4,
                  child: ColoredBox(color: _statusColor(sale)),
                ),
              ),
              InkWell(
                onTap: widget.onOpen,
                borderRadius: BorderRadius.circular(14),
                child: Padding(
                  padding: EdgeInsetsDirectional.fromSTEB(
                    compact ? 18 : 22,
                    compact ? 14 : 18,
                    compact ? 14 : 18,
                    compact ? 14 : 18,
                  ),
                  child: compact
                      ? _buildCompact(context, sale, cashier, l10n)
                      : _buildDesktop(context, sale, cashier, l10n),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDesktop(
    BuildContext context,
    Sale sale,
    String cashier,
    AppLocalizations l10n,
  ) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: _buildDetails(sale, cashier, l10n)),
        const SizedBox(width: 24),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              CurrencyFormatter.format(sale.invoiceCardDisplayAmount),
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w800,
              ).copyWith(color: _statusColor(sale)),
            ),
            if (!sale.isRefund && sale.hasReturnedItems)
              _buildExchangeSummary(sale, l10n),
            const SizedBox(height: 14),
            _buildActions(context, compact: false),
          ],
        ),
      ],
    );
  }

  Widget _buildCompact(
    BuildContext context,
    Sale sale,
    String cashier,
    AppLocalizations l10n,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: _buildDetails(sale, cashier, l10n)),
            const SizedBox(width: 12),
            Text(
              CurrencyFormatter.format(sale.invoiceCardDisplayAmount),
              style: const TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w800,
              ).copyWith(color: _statusColor(sale)),
            ),
          ],
        ),
        if (!sale.isRefund && sale.hasReturnedItems)
          _buildExchangeSummary(sale, l10n),
        const SizedBox(height: 12),
        _buildActions(context, compact: true),
      ],
    );
  }

  Widget _buildDetails(Sale sale, String cashier, AppLocalizations l10n) {
    final statusColor = _statusColor(sale);
    final reference = _reference(sale, l10n);
    final date = DateFormat('yyyy-MM-dd  hh:mm a', 'en').format(sale.date);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 10,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              reference,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w800,
                color: AppColors.textPrimary,
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
              decoration: BoxDecoration(
                color: statusColor.withOpacity(.1),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                _status(sale, l10n),
                style: TextStyle(
                  color: statusColor,
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  letterSpacing: .3,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 9),
        Wrap(
          spacing: 14,
          runSpacing: 5,
          children: [
            _metadata(LucideIcons.calendar, date),
            _metadata(LucideIcons.user, cashier),
            _metadata(LucideIcons.package, l10n.itemsCount(sale.items)),
          ],
        ),
        if (sale.isRefund && sale.refundOriginalInvoiceReference != null)
          _relation(
            icon: LucideIcons.fileInput,
            text: 'Refund for ${sale.refundOriginalInvoiceReference}',
          ),
        if (!sale.isRefund && sale.replacementInvoiceReference != null)
          _relation(
            icon: LucideIcons.arrowLeftRight,
            text: 'Replacement: ${sale.replacementInvoiceReference}',
          ),
      ],
    );
  }

  Widget _buildExchangeSummary(Sale sale, AppLocalizations l10n) {
    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: AppColors.secondaryColor.withOpacity(.06),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Wrap(
        spacing: 14,
        runSpacing: 4,
        children: [
          Text('Original: ${sale.total.toStringAsFixed(2)} ${l10n.currencyEg}'),
          Text(
              'Exchanged: ${sale.effectiveExchangedTotal.toStringAsFixed(2)} ${l10n.currencyEg}'),
          Text(
              'Remaining: ${sale.remainingFinancialTotal.toStringAsFixed(2)} ${l10n.currencyEg}'),
        ],
      ),
    );
  }

  Widget _metadata(IconData icon, String text) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: AppColors.mutedColor),
          const SizedBox(width: 5),
          Text(
            text,
            style: const TextStyle(
              fontSize: 11,
              color: AppColors.textSecondary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      );

  Widget _relation({required IconData icon, required String text}) => Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Row(
          children: [
            Icon(icon, size: 14, color: AppColors.secondaryColor),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                text,
                style: const TextStyle(
                  fontSize: 11,
                  color: AppColors.secondaryColor,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      );

  Widget _buildActions(BuildContext context, {required bool compact}) {
    final actions = <Widget>[
      _action('View', LucideIcons.eye, widget.onOpen, AppColors.primaryColor),
      if (widget.onReturn != null)
        _action('Refund', LucideIcons.undo2, widget.onReturn!,
            AppColors.warningColor),
      if (widget.onExchange != null)
        _action('Exchange', LucideIcons.arrowLeftRight, widget.onExchange!,
            AppColors.successColor),
      _action(
          'Print', LucideIcons.printer, widget.onPrint, AppColors.primaryColor),
      if (widget.onReceipt != null)
        _action('Bon de Caisse', LucideIcons.receipt, widget.onReceipt!,
            AppColors.secondaryColor),
    ];
    if (!compact || actions.length <= 2) {
      return Wrap(spacing: 6, runSpacing: 6, children: actions);
    }
    return Row(
      children: [
        Expanded(child: actions.first),
        const SizedBox(width: 8),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: () => _showMore(context),
            icon: const Icon(LucideIcons.ellipsis, size: 16),
            label: const Text('More'),
          ),
        ),
      ],
    );
  }

  Widget _action(
    String label,
    IconData icon,
    VoidCallback onPressed,
    Color color,
  ) =>
      OutlinedButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, size: 15),
        label: Text(label),
        style: OutlinedButton.styleFrom(
          foregroundColor: color,
          side: BorderSide(color: color.withOpacity(.25)),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          minimumSize: Size.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          textStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
        ),
      );

  void _showMore(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      builder: (context) => SafeArea(
        child: Wrap(
          children: [
            if (widget.onReturn != null)
              ListTile(
                leading: const Icon(LucideIcons.undo2),
                title: const Text('Refund'),
                onTap: () {
                  Navigator.pop(context);
                  widget.onReturn!();
                },
              ),
            if (widget.onExchange != null)
              ListTile(
                leading: const Icon(LucideIcons.arrowLeftRight),
                title: const Text('Exchange'),
                onTap: () {
                  Navigator.pop(context);
                  widget.onExchange!();
                },
              ),
            ListTile(
              leading: const Icon(LucideIcons.printer),
              title: const Text('Print'),
              onTap: () {
                Navigator.pop(context);
                widget.onPrint();
              },
            ),
            if (widget.onReceipt != null)
              ListTile(
                leading: const Icon(LucideIcons.receipt),
                title: const Text('Bon de Caisse'),
                onTap: () {
                  Navigator.pop(context);
                  widget.onReceipt!();
                },
              ),
          ],
        ),
      ),
    );
  }
}
