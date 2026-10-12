"""Supplier payment posting against the tenant-scoped supplier ledger."""

from datetime import datetime
from decimal import Decimal, ROUND_HALF_UP

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.models import Supplier, SupplierLedger
from app.purchase_service import supplier_balance
from app.schemas import SupplierPaymentCreate, SupplierPaymentResponse

_CENT = Decimal("0.01")


def post_supplier_payment(
    db: Session,
    supplier_id: str,
    payload: SupplierPaymentCreate,
    shop_id: str,
) -> SupplierPaymentResponse:
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

    amount = payload.amount.quantize(_CENT, rounding=ROUND_HALF_UP)
    if amount <= 0:
        raise ValueError("Payment amount must be at least 0.01")
    balance = supplier_balance(db, supplier.id, shop_id)
    if amount > balance:
        raise ValueError("Payment exceeds supplier outstanding balance")

    payment_id = f"supplier-payment-{payload.idempotency_key.strip()}"
    if payment_id == "supplier-payment-":
        raise ValueError("Idempotency key is required")
    now = datetime.utcnow()
    reference = payload.reference.strip() or payment_id
    balance_after = balance - amount
    db.add(
        SupplierLedger(
            id=f"{payment_id}-supplier-ledger",
            shop_id=shop_id,
            supplier_id=supplier.id,
            entry_type="supplier_payment",
            amount=-amount,
            balance_after=balance_after,
            reference_type="supplier_payment",
            reference_id=payment_id,
            notes=payload.notes,
            created_at=payload.payment_date.replace(tzinfo=None),
        )
    )
    db.flush()
    return SupplierPaymentResponse(
        payment_id=payment_id,
        supplier_id=supplier.id,
        amount=amount,
        payment_date=payload.payment_date,
        payment_method=payload.payment_method,
        reference=reference,
        notes=payload.notes,
        balance_after=balance_after,
        created_at=now,
    )
