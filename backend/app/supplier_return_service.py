"""Atomic supplier-return posting and supplier accounting."""

from datetime import datetime, timezone
from decimal import Decimal, ROUND_HALF_UP
from uuid import uuid4

from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.models import (
    Product,
    PurchaseDocument,
    PurchaseLine,
    Supplier,
    SupplierLedger,
    SupplierReturnDocument,
    SupplierReturnLine,
)
from app.purchase_service import supplier_balance
from app.sales_service import post_stock_command
from app.schemas import (
    SupplierReturnCreate,
    SupplierReturnLineResponse,
    SupplierReturnResponse,
)
from app.stock_contract import StockPostingCommand, StockPostingLine

_CENT = Decimal("0.01")
_ZERO = Decimal("0")


def _money(value: Decimal) -> Decimal:
    return value.quantize(_CENT, rounding=ROUND_HALF_UP)


def post_supplier_return(
    db: Session,
    supplier_id: str,
    payload: SupplierReturnCreate,
    shop_id: str,
    user_id: str,
    device_id: str | None,
) -> SupplierReturnResponse:
    supplier = db.scalar(
        select(Supplier)
        .where(
            Supplier.id == supplier_id,
            Supplier.shop_id == shop_id,
            Supplier.is_active.is_(True),
        )
        .with_for_update()
    )
    if supplier is None:
        raise LookupError("Supplier not found")

    purchase = db.scalar(
        select(PurchaseDocument)
        .where(
            PurchaseDocument.id == payload.purchase_id,
            PurchaseDocument.shop_id == shop_id,
            PurchaseDocument.supplier_id == supplier_id,
        )
        .with_for_update()
    )
    if purchase is None:
        raise LookupError("Source purchase not found for this supplier")
    if purchase.status.upper() != "POSTED":
        raise ValueError("Only POSTED purchases can be returned")
    if len({line.purchase_item_id for line in payload.lines}) != len(payload.lines):
        raise ValueError("Duplicate purchase lines are not allowed")

    return_id = f"supplier-return-{uuid4().hex}"
    now = datetime.now(timezone.utc).replace(tzinfo=None)
    document = SupplierReturnDocument(
        id=return_id,
        shop_id=shop_id,
        reference=payload.reference.strip(),
        supplier_id=supplier_id,
        purchase_id=purchase.id,
        return_date=payload.return_date.replace(tzinfo=None),
        total=_ZERO,
        status="POSTED",
        notes=payload.notes.strip() if payload.notes and payload.notes.strip() else None,
        created_by=user_id,
        idempotency_key=payload.idempotency_key.strip(),
        created_at=now,
    )
    db.add(document)
    db.flush()

    prepared: list[tuple[PurchaseLine, Decimal, Decimal, Decimal, Decimal, str]] = []
    stock_lines: list[StockPostingLine] = []
    total = _ZERO
    for request_line in payload.lines:
        purchase_line = db.scalar(
            select(PurchaseLine)
            .where(
                PurchaseLine.id == request_line.purchase_item_id,
                PurchaseLine.purchase_id == purchase.id,
                PurchaseLine.product_id == request_line.product_id,
            )
            .with_for_update()
        )
        if purchase_line is None:
            raise ValueError("Product is not part of the source purchase")

        previously_returned = Decimal(
            str(
                db.scalar(
                    select(func.coalesce(func.sum(SupplierReturnLine.quantity), 0)).where(
                        SupplierReturnLine.purchase_line_id == purchase_line.id
                    )
                )
                or 0
            )
        )
        purchased_quantity = (
            Decimal(str(purchase_line.selling_quantity))
            if purchase_line.selling_quantity is not None
            else Decimal(str(purchase_line.quantity))
        )
        quantity = request_line.quantity
        if quantity > purchased_quantity - previously_returned:
            raise ValueError("Return quantity exceeds the remaining returnable quantity")

        conversion = Decimal(str(purchase_line.conversion_factor_snapshot))
        if conversion <= 0:
            raise ValueError("Source purchase has an invalid unit conversion")
        base_quantity = quantity * conversion
        base_unit_cost = Decimal(str(purchase_line.unit_cost))
        purchase_unit_cost = base_unit_cost * conversion
        line_value = _money(base_quantity * base_unit_cost)
        product = db.scalar(
            select(Product).where(
                Product.id == purchase_line.product_id,
                Product.shop_id == shop_id,
            )
        )
        if product is None:
            raise LookupError("Product not found in this shop")
        if base_quantity > Decimal(str(product.stock)):
            raise ValueError("Insufficient stock")
        unit_name = purchase_line.selling_unit_name_snapshot or purchase_line.base_unit_snapshot

        prepared.append(
            (
                purchase_line,
                quantity,
                base_quantity,
                purchase_unit_cost,
                line_value,
                unit_name,
            )
        )
        stock_lines.append(
            StockPostingLine(
                product_id=product.id,
                unit=unit_name,
                quantity_delta=-base_quantity,
                unit_cost=base_unit_cost,
            )
        )
        total += line_value

    document.total = _money(total)
    db.flush()
    post_stock_command(
        db,
        StockPostingCommand(
            source_type="supplier_return",
            source_id=return_id,
            posted_at=now,
            lines=tuple(stock_lines),
            reason=f"Supplier return {document.reference}",
        ),
        shop_id,
        user_id,
        device_id,
    )

    response_lines: list[SupplierReturnLineResponse] = []
    for index, (
        purchase_line,
        quantity,
        base_quantity,
        purchase_unit_cost,
        line_value,
        unit_name,
    ) in enumerate(prepared, start=1):
        db.add(
            SupplierReturnLine(
                id=f"{return_id}-line-{index}",
                return_id=return_id,
                purchase_line_id=purchase_line.id,
                product_id=purchase_line.product_id,
                quantity=quantity,
                base_quantity=base_quantity,
                unit_cost=purchase_unit_cost,
                return_value=line_value,
                unit_name=unit_name,
            )
        )
        response_lines.append(
            SupplierReturnLineResponse(
                purchase_item_id=purchase_line.id,
                product_id=purchase_line.product_id,
                quantity=quantity,
                base_quantity=base_quantity,
                unit_cost=purchase_unit_cost,
                return_value=line_value,
                unit_name=unit_name,
            )
        )

    balance_after = supplier_balance(db, supplier_id, shop_id) - document.total
    db.add(
        SupplierLedger(
            id=f"{return_id}-ledger",
            shop_id=shop_id,
            supplier_id=supplier_id,
            entry_type="supplier_return",
            amount=-document.total,
            balance_after=balance_after,
            reference_type="supplier_return",
            reference_id=return_id,
            notes=document.notes or f"Supplier return {document.reference}",
            created_at=now,
        )
    )
    return SupplierReturnResponse(
        return_id=return_id,
        reference=document.reference,
        supplier_id=supplier_id,
        source_purchase_id=purchase.id,
        source_purchase_reference=purchase.reference,
        return_date=document.return_date,
        status=document.status,
        total=document.total,
        balance_after=balance_after,
        lines=response_lines,
        created_at=document.created_at,
    )
