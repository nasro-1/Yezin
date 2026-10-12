from dataclasses import dataclass
from datetime import datetime
from decimal import Decimal


@dataclass(frozen=True)
class StockPostingLine:
    product_id: str
    unit: str
    quantity_delta: Decimal
    unit_cost: Decimal
    sale_item_id: str | None = None


@dataclass(frozen=True)
class StockPostingCommand:
    """Canonical input contract for every future stock-affecting command."""

    source_type: str
    source_id: str
    posted_at: datetime
    lines: tuple[StockPostingLine, ...]
    reason: str


STOCK_SOURCE_TYPES = frozenset(
    {
        "opening_stock",
        "adjustment",
        "sale",
        "purchase",
        "sales_return",
        "supplier_return",
        "transfer",
        "correction",
    }
)
