"""Atomic server-authoritative purchase posting and supplier accounting."""

from datetime import datetime
from decimal import Decimal, ROUND_HALF_UP
from uuid import uuid4

from sqlalchemy import func, select, update
from sqlalchemy.orm import Session, selectinload

from app.fifo_inventory import _fifo_order
from app.models import (
    IdempotencyRecord,
    InventoryLotRecord,
    Product,
    ProductSellingUnit,
    PurchaseDocument,
    PurchaseLine,
    StockMovement,
    Supplier,
    SupplierLedger,
)
from app.schemas import (
    PurchaseCreate,
    PurchaseLineResponse,
    PurchaseResponse,
    SupplierCreate,
    SupplierResponse,
    SupplierUpdate,
)

_CENT = Decimal("0.01")


def _money(value: Decimal) -> Decimal:
    return value.quantize(_CENT, rounding=ROUND_HALF_UP)


def supplier_balance(db: Session, supplier_id: str, shop_id: str) -> Decimal:
    return Decimal(str(db.scalar(
        select(func.coalesce(func.sum(SupplierLedger.amount), 0)).where(
            SupplierLedger.supplier_id == supplier_id,
            SupplierLedger.shop_id == shop_id,
        )
    ) or 0))


def supplier_response(db: Session, supplier: Supplier) -> SupplierResponse:
    return SupplierResponse(
        id=supplier.id,
        shop_id=supplier.shop_id,
        code=supplier.code,
        name=supplier.name,
        registration_name=supplier.registration_name,
        activity=supplier.activity,
        address=supplier.address,
        phone=supplier.phone,
        mobile=supplier.mobile,
        email=supplier.email,
        tax_number=supplier.tax_number,
        registration_number=supplier.registration_number,
        supplier_reference=supplier.supplier_reference,
        contact_person=supplier.contact_person,
        commercial_register=supplier.commercial_register,
        tax_id=supplier.tax_id,
        nis=supplier.nis,
        ai=supplier.ai,
        bank_name=supplier.bank_name,
        bank_account=supplier.bank_account,
        currency=supplier.currency,
        credit_limit=Decimal(supplier.credit_limit),
        opening_balance=Decimal(str(db.scalar(
            select(func.coalesce(func.sum(SupplierLedger.amount), 0)).where(
                SupplierLedger.supplier_id == supplier.id,
                SupplierLedger.shop_id == supplier.shop_id,
                SupplierLedger.entry_type == "opening_balance",
            )
        ) or 0)),
        current_balance=supplier_balance(db, supplier.id, supplier.shop_id),
        notes=supplier.notes,
        is_active=supplier.is_active,
        created_at=supplier.created_at,
        updated_at=supplier.updated_at,
    )


def next_supplier_code(db: Session, shop_id: str) -> str:
    codes = db.scalars(select(Supplier.code).where(Supplier.shop_id == shop_id)).all()
    sequence = max(
        (
            int(code.rsplit("-", 1)[1])
            for code in codes
            if code.startswith("SUP-") and code.rsplit("-", 1)[1].isdigit()
        ),
        default=0,
    )
    return f"SUP-{sequence + 1:06d}"


def create_supplier(
    db: Session, payload: SupplierCreate, shop_id: str
) -> SupplierResponse:
    if not payload.name.strip():
        raise ValueError("Supplier name is required")
    if db.get(Supplier, payload.id) is not None:
        raise ValueError("Supplier already exists")
    now = datetime.utcnow()
    code = payload.code.strip() or next_supplier_code(db, shop_id)
    duplicate = db.scalar(select(Supplier.id).where(
        Supplier.shop_id == shop_id, Supplier.code == code
    ))
    if duplicate is not None:
        raise ValueError("Supplier code already exists")
    supplier = Supplier(
        id=payload.id,
        shop_id=shop_id,
        code=code,
        name=payload.name.strip(),
        registration_name=payload.registration_name.strip(),
        activity=payload.activity.strip(),
        address=payload.address.strip(),
        phone=payload.phone.strip(),
        mobile=payload.mobile.strip(),
        email=payload.email,
        tax_number=payload.tax_number,
        registration_number=payload.registration_number,
        supplier_reference=payload.supplier_reference,
        contact_person=payload.contact_person,
        commercial_register=payload.commercial_register,
        tax_id=payload.tax_id,
        nis=payload.nis,
        ai=payload.ai,
        bank_name=payload.bank_name,
        bank_account=payload.bank_account,
        currency=payload.currency.strip() or "DZD",
        credit_limit=payload.credit_limit,
        notes=payload.notes,
        is_active=payload.is_active,
        created_at=now,
        updated_at=now,
    )
    db.add(supplier)
    if payload.opening_balance:
        db.add(SupplierLedger(
            id=f"supplier-opening-{uuid4().hex}",
            shop_id=shop_id,
            supplier_id=supplier.id,
            entry_type="opening_balance",
            amount=_money(payload.opening_balance),
            balance_after=_money(payload.opening_balance),
            reference_type="supplier",
            reference_id=supplier.id,
            notes="Opening balance",
            created_at=now,
        ))
    db.flush()
    return supplier_response(db, supplier)


def update_supplier(
    db: Session, supplier: Supplier, payload: SupplierUpdate
) -> SupplierResponse:
    supplier.name = payload.name.strip()
    supplier.registration_name = payload.registration_name.strip()
    supplier.activity = payload.activity.strip()
    supplier.address = payload.address.strip()
    supplier.phone = payload.phone.strip()
    supplier.mobile = payload.mobile.strip()
    supplier.email = payload.email
    supplier.tax_number = payload.tax_number
    supplier.registration_number = payload.registration_number
    supplier.supplier_reference = payload.supplier_reference
    supplier.contact_person = payload.contact_person
    supplier.commercial_register = payload.commercial_register
    supplier.tax_id = payload.tax_id
    supplier.nis = payload.nis
    supplier.ai = payload.ai
    supplier.bank_name = payload.bank_name
    supplier.bank_account = payload.bank_account
    supplier.currency = payload.currency.strip() or "DZD"
    supplier.credit_limit = payload.credit_limit
    supplier.notes = payload.notes
    supplier.is_active = payload.is_active
    supplier.updated_at = datetime.utcnow()
    db.flush()
    return supplier_response(db, supplier)


def _purchase_line_response(line: PurchaseLine) -> PurchaseLineResponse:
    return PurchaseLineResponse(
        id=line.id,
        product_id=line.product_id,
        quantity=Decimal(line.quantity),
        unit_cost=Decimal(line.unit_cost),
        line_total=Decimal(line.line_total),
        selling_unit_id=line.selling_unit_id,
        selling_quantity=(
            Decimal(line.selling_quantity)
            if line.selling_quantity is not None
            else None
        ),
        conversion_factor=Decimal(line.conversion_factor_snapshot),
        selling_unit_name=line.selling_unit_name_snapshot,
        base_unit=line.base_unit_snapshot,
    )


def purchase_response(purchase: PurchaseDocument, lines: list[PurchaseLine]) -> PurchaseResponse:
    return PurchaseResponse(
        id=purchase.id,
        shop_id=purchase.shop_id,
        reference=purchase.reference,
        supplier_id=purchase.supplier_id,
        purchase_date=purchase.purchase_date,
        notes=purchase.notes,
        subtotal=Decimal(purchase.subtotal),
        total=Decimal(purchase.total),
        status=purchase.status,
        created_by=purchase.created_by,
        created_at=purchase.created_at,
        items=[_purchase_line_response(line) for line in lines],
    )


def post_purchase(
    db: Session,
    payload: PurchaseCreate,
    shop_id: str,
    user_id: str,
    device_id: str | None,
) -> PurchaseResponse:
    supplier = db.scalar(select(Supplier).where(
        Supplier.id == payload.supplier_id,
        Supplier.shop_id == shop_id,
        Supplier.is_active.is_(True),
    ))
    if supplier is None:
        raise LookupError("Supplier not found")
    if len({
        (line.product_id, line.selling_unit_id)
        for line in payload.lines
    }) != len(payload.lines):
        raise ValueError("A product and purchase unit can only appear once")

    now = datetime.utcnow()
    purchase_id = f"purchase-{uuid4().hex}"
    reference = payload.reference.strip()
    purchase = PurchaseDocument(
        id=purchase_id,
        shop_id=shop_id,
        reference=reference,
        supplier_id=supplier.id,
        purchase_date=payload.purchase_date.replace(tzinfo=None),
        notes=payload.notes.strip() if payload.notes and payload.notes.strip() else None,
        subtotal=Decimal("0"),
        total=Decimal("0"),
        status="POSTED",
        created_by=user_id,
        idempotency_key=payload.idempotency_key.strip(),
        created_at=now,
    )
    db.add(purchase)
    db.flush()

    line_responses: list[PurchaseLine] = []
    subtotal = Decimal("0")
    for index, request_line in enumerate(payload.lines):
        product = db.scalar(select(Product).where(
            Product.id == request_line.product_id,
            Product.shop_id == shop_id,
            Product.is_active.is_(True),
        ))
        if product is None:
            raise LookupError(f"Product {request_line.product_id} not found")
        unit_id = request_line.selling_unit_id
        unit: ProductSellingUnit | None = None
        if unit_id is not None:
            unit = db.scalar(select(ProductSellingUnit).where(
                ProductSellingUnit.id == unit_id,
                ProductSellingUnit.product_id == product.id,
                ProductSellingUnit.is_active.is_(True),
            ))
            if unit is None:
                raise ValueError(f"Purchase unit is not valid for product {product.id}")
        if product.product_type.upper() == "PACKAGED" and unit is None:
            raise ValueError(f"Purchase unit is required for packaged product {product.id}")
        if product.product_type.upper() != "PACKAGED" and unit is not None:
            raise ValueError(f"Purchase units are only valid for packaged product {product.id}")
        quantity = request_line.quantity
        if product.product_type.upper() != "WEIGHTED" and quantity != quantity.to_integral_value():
            raise ValueError(f"Product {product.id} requires a whole purchase quantity")
        conversion = Decimal(str(unit.conversion_to_base)) if unit else Decimal("1")
        if conversion <= 0:
            raise ValueError(f"Purchase unit has invalid conversion for product {product.id}")
        base_quantity = quantity * conversion
        base_unit_cost = request_line.unit_cost / conversion
        line_total = _money(quantity * request_line.unit_cost)
        line_id = f"{purchase_id}-line-{index + 1}"
        line = PurchaseLine(
            id=line_id,
            purchase_id=purchase_id,
            product_id=product.id,
            quantity=base_quantity,
            unit_cost=base_unit_cost,
            line_total=line_total,
            selling_unit_id=unit.id if unit else None,
            selling_quantity=quantity if unit else None,
            conversion_factor_snapshot=conversion,
            selling_unit_name_snapshot=unit.name if unit else product.base_unit,
            base_unit_snapshot=product.base_unit,
        )
        db.add(line)
        line_responses.append(line)
        subtotal += line_total

        stock_result = db.execute(
            update(Product)
            .where(Product.id == product.id, Product.shop_id == shop_id)
            .values(stock=Product.stock + float(base_quantity), updated_at=now)
            .execution_options(synchronize_session=False)
        )
        if stock_result.rowcount != 1:
            raise LookupError(f"Product {product.id} not found")
        db.refresh(product)
        movement_id = f"{line_id}-movement"
        db.add(StockMovement(
            id=movement_id,
            shop_id=shop_id,
            product_id=product.id,
            movement_type="purchase",
            quantity_change=float(base_quantity),
            unit_cost=float(base_unit_cost),
            running_stock=float(product.stock),
            reference_type="purchase",
            reference_id=purchase_id,
            reference_line_id=line_id,
            notes=f"Purchase {reference}",
            user_id=user_id,
            device_id=device_id,
            created_at=now,
        ))
        db.add(InventoryLotRecord(
            id=f"fifo-lot-{shop_id}-{product.id}-{movement_id}",
            shop_id=shop_id,
            product_id=product.id,
            movement_id=movement_id,
            source_type="purchase",
            source_id=purchase_id,
            source_reference=reference,
            received_quantity=float(base_quantity),
            remaining_quantity=float(base_quantity),
            unit_cost=float(base_unit_cost),
            acquired_at=now,
            fifo_order=_fifo_order(now, movement_id),
        ))

    purchase.subtotal = _money(subtotal)
    purchase.total = _money(subtotal)
    balance = supplier_balance(db, supplier.id, shop_id)
    db.add(SupplierLedger(
        id=f"{purchase_id}-ledger",
        shop_id=shop_id,
        supplier_id=supplier.id,
        entry_type="purchase",
        amount=purchase.total,
        balance_after=balance + purchase.total,
        reference_type="purchase",
        reference_id=purchase_id,
        notes=f"Purchase {reference}",
        created_at=now,
    ))
    db.flush()
    return purchase_response(purchase, line_responses)
