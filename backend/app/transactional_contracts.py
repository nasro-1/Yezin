"""Reusable contracts for future transactional domains.

These contracts intentionally contain no endpoints or business-domain posting
logic. Monetary values are Decimal so future persistence can use SQLAlchemy
Numeric without introducing binary floating-point rounding.
"""

from dataclasses import dataclass
from datetime import datetime
from decimal import Decimal

from app.lifecycle import DocumentStatus
from app.stock_contract import StockPostingCommand


@dataclass(frozen=True)
class CustomerLedgerEntry:
    customer_id: str
    document_id: str
    amount: Decimal
    direction: str
    posted_at: datetime
    status: DocumentStatus = DocumentStatus.POSTED


@dataclass(frozen=True)
class Payment:
    document_id: str
    amount: Decimal
    method: str
    paid_at: datetime
    status: DocumentStatus = DocumentStatus.POSTED


@dataclass(frozen=True)
class CashMovement:
    document_id: str
    amount: Decimal
    movement_type: str
    occurred_at: datetime
    status: DocumentStatus = DocumentStatus.POSTED


@dataclass(frozen=True)
class TransactionalDocument:
    document_id: str
    status: DocumentStatus

    def with_status(self, status: DocumentStatus) -> "TransactionalDocument":
        from app.lifecycle import transition

        return TransactionalDocument(
            document_id=self.document_id,
            status=transition(self.status, status),
        )


__all__ = [
    "CashMovement",
    "CustomerLedgerEntry",
    "Payment",
    "StockPostingCommand",
    "TransactionalDocument",
]
