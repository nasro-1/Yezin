"""Server-authoritative sale posting and stock integration."""
from datetime import datetime
from decimal import Decimal
from threading import RLock
from uuid import uuid4

from sqlalchemy import select, update
from sqlalchemy.orm import Session

from app.models import (
    CashMovementRecord, CustomerLedgerRecord, PaymentRecord, Product,
    InventoryLotRecord, ProductSellingUnit, SaleDocument,
    SaleItem, SaleItemFifoAllocation, StockMovement,
)
from app.schemas import SaleCreate, SaleResponse, SaleItemResponse
from app.stock_contract import StockPostingCommand, StockPostingLine
from app.fifo_inventory import FifoInventoryCostingService

sqlite_write_lock = RLock()


def post_stock_command(db: Session, command: StockPostingCommand, shop_id: str, user_id: str, device_id: str | None) -> None:
    """Apply the canonical stock command; callers provide the surrounding transaction."""
    fifo_service = FifoInventoryCostingService()
    for line in command.lines:
        product = db.scalar(select(Product).where(Product.id == line.product_id, Product.shop_id == shop_id))
        if product is None:
            raise ValueError("Product not found")
        required_quantity = -line.quantity_delta
        if required_quantity < 0:
            raise ValueError("Stock increases are not supported for sale posting")
        result = db.execute(
            update(Product)
            .where(
                Product.id == line.product_id,
                Product.shop_id == shop_id,
                Product.stock >= required_quantity,
            )
            .values(stock=Product.stock - required_quantity)
            .execution_options(synchronize_session=False)
        )
        if result.rowcount != 1:
            raise ValueError("Insufficient stock")
        db.refresh(product)
        new_stock = Decimal(str(product.stock))
        effective_unit_cost = line.unit_cost
        fifo_result = None
        if command.source_type in {"sale", "supplier_return"} and line.quantity_delta < 0:
            if command.source_type == "sale" and line.sale_item_id:
                fifo_result = fifo_service.consume_and_persist_for_sale_item(
                    db,
                    product_id=product.id,
                    sale_item_id=line.sale_item_id,
                    requested_quantity=abs(line.quantity_delta),
                    shop_id=shop_id,
                )
                effective_unit_cost = fifo_result.average_cost
            else:
                fifo_result = fifo_service.consume_and_persist(
                    db,
                    product.id,
                    abs(line.quantity_delta),
                    shop_id=shop_id,
                )
                effective_unit_cost = fifo_result.average_cost
            if effective_unit_cost == 0 and command.source_type != "sale":
                effective_unit_cost = line.unit_cost
        db.add(StockMovement(
            id=f"sale-movement-{uuid4().hex}", shop_id=shop_id, product_id=product.id,
            movement_type=command.source_type, quantity_change=float(line.quantity_delta),
            unit_cost=float(effective_unit_cost), running_stock=float(new_stock),
            reference_type=command.source_type, reference_id=command.source_id,
            notes=command.reason, user_id=user_id, device_id=device_id,
            created_at=datetime.utcnow(),
        ))
        db.flush()


def _historical_item_cost(db: Session, item: SaleItem) -> Decimal | None:
    rows = db.execute(
        select(SaleItemFifoAllocation, InventoryLotRecord)
        .join(
            InventoryLotRecord,
            InventoryLotRecord.id == SaleItemFifoAllocation.inventory_lot_id,
        )
        .where(SaleItemFifoAllocation.sale_item_id == item.id)
    ).all()
    allocated_quantity = sum(
        Decimal(str(allocation.allocated_quantity))
        for allocation, _ in rows
    )
    expected_quantity = Decimal(str(item.base_quantity))
    if (
        not rows
        or abs(allocated_quantity - expected_quantity) > Decimal("0.000001")
        or any(allocation.unit_cost_at_sale is None for allocation, _ in rows)
    ):
        return None
    return sum(
        Decimal(str(allocation.allocated_quantity))
        * Decimal(str(allocation.unit_cost_at_sale))
        for allocation, _ in rows
    )


def _item_response(db: Session | None, item: SaleItem) -> SaleItemResponse:
    historical_cost = (
        _historical_item_cost(db, item) if db is not None else None
    )
    return SaleItemResponse(
        id=item.id,
        product_id=item.product_id,
        unit=item.unit,
        quantity=Decimal(item.quantity),
        base_quantity=Decimal(item.base_quantity),
        unit_price=Decimal(item.unit_price),
        line_total=Decimal(item.line_total),
        historical_cost=historical_cost,
        historical_cost_available=historical_cost is not None,
        refunded_quantity=Decimal(item.refunded_quantity or 0),
        exchanged_quantity=Decimal(item.exchanged_quantity or 0),
    )


def _response(
    sale: SaleDocument,
    items: list[SaleItem],
    db: Session | None = None,
) -> SaleResponse:
    return SaleResponse(
        sale_id=sale.id, shop_id=sale.shop_id, status=sale.status,
        document_reference=sale.document_reference,
        customer_id=sale.customer_id, payment_method=sale.payment_method,
        subtotal=Decimal(sale.subtotal), discount=Decimal(sale.discount),
        total=Decimal(sale.total), payment_result=Decimal(sale.payment_result),
        remaining_amount=Decimal(sale.remaining_amount),
        stock_posting_reference=sale.stock_posting_reference, posted_at=sale.posted_at,
        posted_by=sale.posted_by,
        items=[_item_response(db, item) for item in items],
        is_refund=False,
        original_sale_id=None,
        refunded_total=Decimal("0"),
    )


def post_sale(db: Session, payload: SaleCreate, shop_id: str, user_id: str, device_id: str | None) -> SaleResponse:
    method = payload.payment_method.strip().lower()
    if method not in {"cash", "credit"}:
        raise ValueError("Payment method must be cash or credit")
    if method == "credit" and not payload.customer_id:
        raise ValueError("A customer is required for credit sales")
    now = datetime.utcnow()
    discount = payload.discount.quantize(Decimal("0.01"))
    sale = SaleDocument(
        id=f"sale-{uuid4().hex}", shop_id=shop_id, idempotency_key=payload.idempotency_key.strip(),
        document_reference=f"SALE-{uuid4().hex[:12].upper()}",
        status="POSTED", customer_id=payload.customer_id, payment_method=method,
        subtotal=Decimal("0"), discount=discount, total=Decimal("0"),
        payment_result=Decimal("0"), remaining_amount=Decimal("0"),
        stock_posting_reference="", posted_by=user_id, posted_at=now,
    )
    db.add(sale)
    lines = []
    items = []
    total = Decimal("0")
    for request in payload.items:
        product = db.scalar(select(Product).where(Product.id == request.product_id, Product.shop_id == shop_id, Product.is_active.is_(True)))
        if product is None:
            raise ValueError("Product not found")
        unit_name = request.unit.strip()
        conversion = Decimal("1") if unit_name == product.base_unit else None
        unit_row = None
        if conversion is None:
            unit_row = db.scalar(select(ProductSellingUnit).where(
                ProductSellingUnit.product_id == product.id,
                ProductSellingUnit.name == unit_name,
                ProductSellingUnit.is_active.is_(True),
            ))
            if unit_row is None:
                raise ValueError(f"Unit {unit_name} is not valid for product {product.id}")
            conversion = Decimal(str(unit_row.conversion_to_base))
        if conversion <= 0:
            raise ValueError("Invalid unit conversion")
        if product.product_type.upper() == "PACKAGED":
            if not product.allow_partial_package_sale and request.quantity != request.quantity.to_integral_value():
                raise ValueError("Partial package sales are not allowed")
        price = request.unit_price if request.unit_price is not None else Decimal(str(unit_row.selling_price if unit_row else product.price))
        line_total = (request.quantity * price).quantize(Decimal("0.01"))
        base_quantity = request.quantity * conversion
        item = SaleItem(
            id=f"sale-item-{uuid4().hex}", sale_id=sale.id, product_id=product.id,
            unit=unit_name, quantity=request.quantity, base_quantity=base_quantity,
            unit_price=price, line_total=line_total,
            refunded_quantity=Decimal("0"), exchanged_quantity=Decimal("0"),
        )
        db.add(item)
        items.append(item)
        lines.append(StockPostingLine(
            product.id,
            unit_name,
            -base_quantity,
            Decimal(str(product.cost)),
            item.id,
        ))
        total += line_total
    if discount > total:
        raise ValueError("Discount cannot exceed subtotal")
    sale.subtotal = total
    sale.total = total - discount
    sale.stock_posting_reference = f"sale:{sale.id}"
    paid = payload.paid_amount if payload.paid_amount is not None else (
        sale.total if method == "cash" else Decimal("0")
    )
    if paid > sale.total:
        raise ValueError("Payment cannot exceed total")
    if method == "credit" and paid != 0:
        raise ValueError("Credit sales cannot include payment")
    sale.payment_result = paid.quantize(Decimal("0.01"))
    sale.remaining_amount = (sale.total - paid).quantize(Decimal("0.01"))
    post_stock_command(db, StockPostingCommand("sale", sale.id, now, tuple(lines), "Sale posting"), shop_id, user_id, device_id)
    db.add(PaymentRecord(id=f"payment-{uuid4().hex}", sale_id=sale.id, shop_id=shop_id, amount=paid, method=method, paid_at=now))
    if method == "cash":
        db.add(CashMovementRecord(id=f"cash-{uuid4().hex}", sale_id=sale.id, shop_id=shop_id, amount=paid, movement_type="sale", occurred_at=now))
    elif payload.customer_id:
        db.add(CustomerLedgerRecord(id=f"ledger-{uuid4().hex}", customer_id=payload.customer_id, sale_id=sale.id, shop_id=shop_id, amount=sale.remaining_amount, direction="debit", posted_at=now))
    return _response(sale, items, db)
