from decimal import Decimal

import pytest

from app.context import Permission, Role, ServerContext, require_permission
from app.finance import multiply_amount
from app.lifecycle import DocumentStatus, transition
from app.transactional_contracts import (
    CashMovement,
    CustomerLedgerEntry,
    Payment,
)


def test_role_permissions_are_centralized() -> None:
    context = ServerContext("u", "shop", Role.MANAGER)
    require_permission(context, Permission.POST_STOCK_ADJUSTMENT)
    with pytest.raises(PermissionError):
        require_permission(ServerContext("u", "shop", Role.CASHIER), Permission.MANAGE_CATALOG)


def test_document_lifecycle_only_allows_forward_transitions() -> None:
    assert transition(DocumentStatus.DRAFT, DocumentStatus.POSTED) is DocumentStatus.POSTED
    assert transition(DocumentStatus.DRAFT, DocumentStatus.CANCELLED) is DocumentStatus.CANCELLED
    assert transition(DocumentStatus.POSTED, DocumentStatus.REVERSED) is DocumentStatus.REVERSED
    with pytest.raises(ValueError):
        transition(DocumentStatus.CANCELLED, DocumentStatus.POSTED)


def test_decimal_arithmetic_avoids_binary_float_rounding() -> None:
    assert multiply_amount("0.1", "0.2") == Decimal("0.02")


def test_future_transactional_contracts_require_decimal_money() -> None:
    now = __import__("datetime").datetime.now()
    ledger = CustomerLedgerEntry("customer", "document", Decimal("10.01"), "debit", now)
    payment = Payment("document", Decimal("10.01"), "cash", now)
    cash = CashMovement("document", Decimal("10.01"), "sale", now)
    assert all(isinstance(item.amount, Decimal) for item in (ledger, payment, cash))
