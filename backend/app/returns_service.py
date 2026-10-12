"""Atomic server-side refunds and exchanges."""
from datetime import datetime
from decimal import Decimal
from uuid import uuid4
from sqlalchemy import select
from sqlalchemy.orm import Session
from app.models import (
    CashMovement, CustomerLedger, ExchangeDocument, ExchangeItem,
    ExchangeSettlement, Payment, Product,
    ProductSellingUnit, RefundDocument, RefundItem, SaleDocument, SaleItem, StockMovement,
    InventoryLotRecord, SaleItemFifoAllocation, SaleItemFifoRestoration,
)
from app.fifo_inventory import FifoInventoryCostingService
from app.schemas import ExchangeCreate, ExchangeResponse, RefundCreate, RefundResponse


def _item_base(item: SaleItem, quantity: Decimal) -> Decimal:
    if item.quantity <= 0:
        raise ValueError("Invalid sale item quantity")
    return (quantity * item.base_quantity / item.quantity).quantize(Decimal("0.000001"))


def _restore_fifo_allocations(
    db: Session,
    *,
    item: SaleItem,
    base_quantity: Decimal,
    shop_id: str,
    refund_item_id: str | None = None,
    exchange_item_id: str | None = None,
) -> Decimal | None:
    allocations = db.execute(
        select(SaleItemFifoAllocation, InventoryLotRecord)
        .join(
            InventoryLotRecord,
            InventoryLotRecord.id == SaleItemFifoAllocation.inventory_lot_id,
        )
        .where(
            SaleItemFifoAllocation.sale_item_id == item.id,
            SaleItemFifoAllocation.shop_id == shop_id,
        )
        .order_by(
            InventoryLotRecord.acquired_at.desc(),
            SaleItemFifoAllocation.created_at.desc(),
            SaleItemFifoAllocation.id.desc(),
        )
    ).all()
    if not allocations:
        return None
    remaining = base_quantity
    cost = Decimal("0")
    cost_available = True
    for allocation, lot in allocations:
        available = Decimal(str(allocation.allocated_quantity)) - Decimal(
            str(allocation.restored_quantity)
        )
        restored = min(remaining, available)
        if restored <= 0:
            continue
        lot.remaining_quantity = float(
            Decimal(str(lot.remaining_quantity)) + restored
        )
        allocation.restored_quantity = float(
            Decimal(str(allocation.restored_quantity)) + restored
        )
        if allocation.unit_cost_at_sale is None:
            cost_available = False
        else:
            db.add(SaleItemFifoRestoration(
                id=f"fifo-restoration-{uuid4().hex}",
                shop_id=shop_id,
                sale_item_fifo_allocation_id=allocation.id,
                refund_item_id=refund_item_id,
                exchange_item_id=exchange_item_id,
                restored_quantity=float(restored),
                unit_cost=allocation.unit_cost_at_sale,
            ))
            cost += restored * Decimal(str(allocation.unit_cost_at_sale))
        remaining -= restored
        if remaining <= 0:
            break
    if remaining > 0:
        raise ValueError("FIFO allocation restoration exceeds original sale allocation")
    return cost if cost_available else None


def post_refund(db: Session, payload: RefundCreate, shop_id: str, user_id: str) -> RefundResponse:
    first = payload.items[0]
    sale_item_filter = SaleItem.id == first.sale_item_id if first.sale_item_id else SaleItem.product_id == first.product_id
    sale_id = db.scalar(select(SaleItem.sale_id).where(sale_item_filter))
    sale = db.scalar(select(SaleDocument).where(SaleDocument.id == sale_id, SaleDocument.shop_id == shop_id))
    if sale is None or sale.status != "POSTED":
        raise ValueError("Sale not found")
    method = (payload.payment_method or sale.payment_method).strip().lower()
    if method not in {"cash", "credit"} or method != sale.payment_method:
        raise ValueError("Refund payment method must match the original sale")
    refund = RefundDocument(id=f"refund-{uuid4().hex}", shop_id=shop_id, sale_id=sale.id,
        idempotency_key=payload.idempotency_key.strip(), amount=Decimal("0"), payment_method=method,
        posted_by=user_id, posted_at=datetime.utcnow())
    db.add(refund)
    total = Decimal("0")
    seen = set()
    fifo_restored = False
    for line in payload.items:
        if line.sale_item_id in seen:
            raise ValueError("A sale item may only appear once")
        seen.add(line.sale_item_id)
        item_filter = SaleItem.id == line.sale_item_id if line.sale_item_id else SaleItem.product_id == line.product_id
        item = db.scalar(select(SaleItem).where(item_filter, SaleItem.sale_id == sale.id))
        if item is None:
            raise ValueError("Sale item not found")
        available = (
            Decimal(item.quantity)
            - Decimal(item.refunded_quantity or 0)
            - Decimal(item.exchanged_quantity or 0)
        )
        if line.quantity > available:
            raise ValueError("Refund quantity exceeds available quantity")
        base = _item_base(item, line.quantity)
        amount = (line.quantity * Decimal(item.unit_price)).quantize(Decimal("0.01"))
        item.refunded_quantity = Decimal(item.refunded_quantity or 0) + line.quantity
        product = db.scalar(select(Product).where(Product.id == item.product_id, Product.shop_id == shop_id))
        if product is None:
            raise ValueError("Product not found")
        product.stock = Decimal(str(product.stock)) + base
        refund_item_id = f"refund-item-{uuid4().hex}"
        db.add(RefundItem(id=refund_item_id, refund_id=refund.id, sale_item_id=item.id,
            quantity=line.quantity, base_quantity=base, amount=amount))
        fifo_cost = _restore_fifo_allocations(
            db, item=item, base_quantity=base, shop_id=shop_id,
            refund_item_id=refund_item_id,
        )
        fifo_restored = fifo_restored or fifo_cost is not None
        movement_cost = (
            fifo_cost / base if fifo_cost is not None and base > 0 else Decimal("0")
        )
        db.add(StockMovement(id=f"refund-movement-{uuid4().hex}", shop_id=shop_id,
            product_id=product.id, movement_type="refund", quantity_change=float(base),
            unit_cost=float(movement_cost), running_stock=float(product.stock),
            reference_type="refund", reference_id=refund.id, lineage_id=sale.id,
            reference_line_id=refund_item_id,
            notes="Sale refund", user_id=user_id, created_at=refund.posted_at))
        total += amount
    if not fifo_restored:
        FifoInventoryCostingService.sync_persisted_lots(db, product.id, shop_id=shop_id)
    refund.amount = total
    if method == "cash":
        db.add(CashMovement(id=f"cash-{uuid4().hex}", sale_id=sale.id, shop_id=shop_id,
            amount=-total, movement_type="refund", occurred_at=refund.posted_at))
    if sale.customer_id:
        db.add(CustomerLedger(id=f"ledger-{uuid4().hex}", customer_id=sale.customer_id, sale_id=sale.id,
            shop_id=shop_id, amount=total, direction="credit", posted_at=refund.posted_at))
    return RefundResponse(refund_id=refund.id, sale_id=sale.id, amount=total, payment_method=method, posted_at=refund.posted_at)


def post_exchange(db: Session, payload: ExchangeCreate, sale_id: str, shop_id: str, user_id: str) -> ExchangeResponse:
    sale = db.scalar(select(SaleDocument).where(SaleDocument.id == sale_id, SaleDocument.shop_id == shop_id))
    if sale is None or sale.status != "POSTED":
        raise ValueError("Sale not found")
    method = (payload.payment_method or sale.payment_method).strip().lower()
    if method not in {"cash", "credit"} or method != sale.payment_method:
        raise ValueError("Exchange payment method must match the original sale")
    if payload.customer_id is not None and payload.customer_id != sale.customer_id:
        raise ValueError("Exchange customer must match the original sale")
    if method == "credit" and not sale.customer_id:
        raise ValueError("Credit exchange requires the original sale customer")

    resolved_lines: list[
        tuple[
            SaleItem,
            Product,
            str,
            Decimal,
            Decimal,
            Decimal,
            Decimal,
            Decimal,
            Decimal,
            Decimal,
        ]
    ] = []
    sale_items: dict[str, SaleItem] = {}
    replacement_products: dict[str, Product] = {}
    returned_by_sale_item: dict[str, Decimal] = {}
    replacement_base_by_product: dict[str, Decimal] = {}
    old_total = new_total = Decimal("0")

    for line in payload.items:
        item_id = line.sale_item_id or line.original_sale_item_id
        item_filter = SaleItem.id == item_id if item_id else SaleItem.product_id == line.product_id
        item = db.scalar(select(SaleItem).where(item_filter, SaleItem.sale_id == sale.id))
        if item is None:
            raise ValueError("Sale item not found")
        returned_base = _item_base(item, line.returned_quantity)
        replacement = db.scalar(select(Product).where(Product.id == line.replacement_product_id, Product.shop_id == shop_id, Product.is_active.is_(True)))
        if replacement is None:
            raise ValueError("Replacement product not found")
        factor = Decimal("1")
        if line.replacement_unit:
            unit = db.scalar(select(ProductSellingUnit).where(ProductSellingUnit.product_id == replacement.id,
                ProductSellingUnit.name == line.replacement_unit, ProductSellingUnit.is_active.is_(True)))
            if unit is None:
                raise ValueError("Replacement unit not found")
            factor = Decimal(str(unit.conversion_to_base))
            price = Decimal(str(unit.selling_price))
        else:
            price = Decimal(str(replacement.price))
        replacement_base = line.replacement_quantity * factor
        old_amount = (line.returned_quantity * Decimal(item.unit_price)).quantize(Decimal("0.01"))
        new_amount = (line.replacement_quantity * price).quantize(Decimal("0.01"))
        sale_items[item.id] = item
        replacement_products[replacement.id] = replacement
        returned_by_sale_item[item.id] = (
            returned_by_sale_item.get(item.id, Decimal("0")) + line.returned_quantity
        )
        replacement_base_by_product[replacement.id] = (
            replacement_base_by_product.get(replacement.id, Decimal("0")) + replacement_base
        )
        old_total += old_amount
        new_total += new_amount
        resolved_lines.append((
            item,
            replacement,
            line.replacement_unit or replacement.base_unit,
            line.returned_quantity,
            returned_base,
            line.replacement_quantity,
            replacement_base,
            price,
            old_amount,
            new_amount,
        ))

    for item_id, returned_quantity in returned_by_sale_item.items():
        item = sale_items[item_id]
        available = (
            Decimal(item.quantity)
            - Decimal(item.refunded_quantity or 0)
            - Decimal(item.exchanged_quantity or 0)
        )
        if returned_quantity > available:
            raise ValueError("Exchange quantity exceeds available quantity")

    for product_id, replacement_base in replacement_base_by_product.items():
        if Decimal(str(replacement_products[product_id].stock)) < replacement_base:
            raise ValueError("Insufficient replacement stock")

    exchange = ExchangeDocument(id=f"exchange-{uuid4().hex}", shop_id=shop_id, sale_id=sale.id,
        idempotency_key=payload.idempotency_key.strip(), difference_amount=Decimal("0"), payment_method=method,
        posted_by=user_id, posted_at=datetime.utcnow())
    db.add(exchange)
    replacement_sale_id = f"sale-{uuid4().hex}"
    replacement_sale = SaleDocument(
        id=replacement_sale_id,
        shop_id=shop_id,
        idempotency_key=f"exchange:{exchange.id}",
        document_reference=f"SALE-{uuid4().hex[:12].upper()}",
        status="POSTED",
        customer_id=sale.customer_id,
        payment_method=method,
        subtotal=new_total,
        discount=Decimal("0"),
        total=new_total,
        payment_result=new_total,
        remaining_amount=Decimal("0"),
        stock_posting_reference=f"exchange:{exchange.id}",
        posted_by=user_id,
        posted_at=exchange.posted_at,
    )
    db.add(replacement_sale)

    replacement_lines: list[tuple[SaleItem, str, Decimal, Decimal, Decimal]] = []
    for (
        item,
        replacement,
        unit_name,
        returned_quantity,
        returned_base,
        replacement_quantity,
        replacement_base,
        price,
        old_amount,
        new_amount,
    ) in resolved_lines:
        item.exchanged_quantity = Decimal(item.exchanged_quantity or 0) + returned_quantity
        replacement.stock = Decimal(str(replacement.stock)) - replacement_base
        original_product = db.scalar(select(Product).where(
            Product.id == item.product_id,
            Product.shop_id == shop_id,
        ))
        if original_product is None:
            raise ValueError("Original product not found")
        original_product.stock = Decimal(str(original_product.stock)) + returned_base
        exchange_item_id = f"exchange-item-{uuid4().hex}"
        exchange_item = ExchangeItem(
            id=exchange_item_id, exchange_id=exchange.id, sale_item_id=item.id,
            returned_quantity=returned_quantity, returned_base_quantity=returned_base,
            replacement_product_id=replacement.id, replacement_quantity=replacement_quantity,
            replacement_base_quantity=replacement_base, old_amount=old_amount, new_amount=new_amount,
        )
        db.add(exchange_item)
        original_fifo_cost = _restore_fifo_allocations(
            db, item=item, base_quantity=returned_base, shop_id=shop_id,
            exchange_item_id=exchange_item_id,
        )
        original_unit_cost = (
            original_fifo_cost / returned_base
            if original_fifo_cost is not None and returned_base > 0
            else Decimal("0")
        )
        replacement_item = SaleItem(
            id=f"sale-item-{uuid4().hex}",
            sale_id=replacement_sale.id,
            product_id=replacement.id,
            unit=unit_name,
            quantity=replacement_quantity,
            base_quantity=replacement_base,
            unit_price=price,
            line_total=(replacement_quantity * price).quantize(Decimal("0.01")),
            refunded_quantity=Decimal("0"),
            exchanged_quantity=Decimal("0"),
        )
        db.add(replacement_item)
        replacement_fifo = FifoInventoryCostingService.consume_and_persist_for_sale_item(
            db,
            product_id=replacement.id,
            sale_item_id=replacement_item.id,
            requested_quantity=replacement_base,
            shop_id=shop_id,
        )
        replacement_unit_cost = (
            replacement_fifo.average_cost
            if replacement_fifo.consumed_quantity > 0
            else Decimal("0")
        )
        db.add(StockMovement(id=f"exchange-return-{uuid4().hex}", shop_id=shop_id,
            product_id=original_product.id, movement_type="exchange",
            quantity_change=float(returned_base), unit_cost=float(original_unit_cost),
            running_stock=float(original_product.stock), reference_type="exchange",
            reference_id=exchange.id, reference_line_id=exchange_item_id,
            lineage_id=sale.id,
            notes="Exchange return", user_id=user_id,
            created_at=exchange.posted_at))
        db.add(StockMovement(id=f"exchange-sale-{uuid4().hex}", shop_id=shop_id,
            product_id=replacement.id, movement_type="exchange",
            quantity_change=float(-replacement_base), unit_cost=float(replacement_unit_cost),
            running_stock=float(replacement.stock), reference_type="exchange",
            reference_id=exchange.id, lineage_id=sale.id,
            notes="Exchange replacement", user_id=user_id,
            created_at=exchange.posted_at))
        replacement_lines.append(
            (replacement_item, unit_name, replacement_quantity, replacement_base, price)
        )
    difference = (new_total - old_total).quantize(Decimal("0.01"))
    exchange.difference_amount = difference
    exchange.replacement_sale_id = replacement_sale.id
    payment = Payment(
        id=f"payment-{uuid4().hex}",
        sale_id=replacement_sale.id,
        shop_id=shop_id,
        amount=new_total,
        method=method,
        paid_at=exchange.posted_at,
    )
    db.add(payment)
    cash_movement = None
    customer_ledger = None
    if difference:
        if method == "cash":
            cash_movement = CashMovement(
                id=f"cash-{uuid4().hex}",
                sale_id=replacement_sale.id,
                shop_id=shop_id,
                amount=difference,
                movement_type="exchange",
                occurred_at=exchange.posted_at,
            )
            db.add(cash_movement)
        elif sale.customer_id:
            customer_ledger = CustomerLedger(
                id=f"ledger-{uuid4().hex}",
                customer_id=sale.customer_id,
                sale_id=replacement_sale.id,
                shop_id=shop_id,
                amount=abs(difference),
                direction="debit" if difference > 0 else "credit",
                posted_at=exchange.posted_at,
            )
            db.add(customer_ledger)
    db.flush()
    db.add(ExchangeSettlement(
        id=f"exchange-settlement-{uuid4().hex}",
        exchange_id=exchange.id,
        replacement_sale_id=replacement_sale.id,
        shop_id=shop_id,
        payment_id=payment.id,
        cash_movement_id=cash_movement.id if cash_movement else None,
        customer_ledger_id=customer_ledger.id if customer_ledger else None,
        returned_amount=old_total,
        replacement_amount=new_total,
        difference_amount=difference,
        payment_method=method,
        posted_at=exchange.posted_at,
    ))
    return ExchangeResponse(
        exchange_id=exchange.id,
        sale_id=sale.id,
        replacement_sale_id=replacement_sale.id,
        replacement_document_reference=replacement_sale.document_reference,
        difference_amount=difference,
        payment_method=method,
        posted_at=exchange.posted_at,
    )
