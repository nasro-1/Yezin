"""Reset and seed a coherent local development dataset.

This script only targets the configured development database and the ``dev-shop``
tenant. Stock, sales, refunds, and exchanges are posted through the same domain
services used by the API.
"""

import os
import sys
from datetime import datetime
from decimal import Decimal
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from sqlalchemy import select

from app.config import settings
from app.database import SessionLocal
from app.development_safety import require_development_data_reset
from app.models import (
    Category,
    CashMovement,
    CustomerLedger,
    ExchangeDocument,
    ExchangeItem,
    ExchangeSettlement,
    FifoCostCorrection,
    IdempotencyRecord,
    InventoryLotRecord,
    OpeningStockDocument,
    OpeningStockLine,
    Payment,
    Product,
    ProductSellingUnit,
    RefundDocument,
    RefundItem,
    SaleDraft,
    SaleDraftItem,
    SaleDocument,
    SaleItem,
    SaleItemFifoAllocation,
    SaleItemFifoRestoration,
    Shop,
    StockAdjustmentDocument,
    StockAdjustmentLine,
    StockMovement,
    SupplierLedger,
    User,
)
from app.returns_service import post_exchange, post_refund
from app.sales_service import post_sale
from app.schemas import (
    ExchangeCreate,
    ExchangeLineCreate,
    RefundCreate,
    RefundLineCreate,
    SaleCreate,
    SaleItemCreate,
)
from app.security import hash_password


DEV_SHOP_ID = "dev-shop"
ADMIN_ID = "admin"


def seed() -> None:
    require_development_data_reset(
        settings.environment, os.environ.get("BAYAA_ALLOW_DEV_DATA_RESET")
    )
    with SessionLocal() as db:
        shop = db.get(Shop, DEV_SHOP_ID)
        if shop is None:
            shop = Shop(id=DEV_SHOP_ID, name="Yezin Demo Shop")
            db.add(shop)
            db.flush()

        _reset_shop(db)
        _ensure_users(db)
        categories = _create_categories(db)
        products = _create_products(db, categories)
        db.commit()

        sale_ids = _create_sales(db, products)
        _create_refunds(db, sale_ids)
        _create_exchanges(db, sale_ids, products)
        db.commit()
        _print_report(db)


def _reset_shop(db) -> None:
    sale_ids = list(
        db.scalars(select(SaleDocument.id).where(SaleDocument.shop_id == DEV_SHOP_ID))
    )
    exchange_ids = list(
        db.scalars(
            select(ExchangeDocument.id).where(ExchangeDocument.shop_id == DEV_SHOP_ID)
        )
    )
    refund_ids = list(
        db.scalars(
            select(RefundDocument.id).where(RefundDocument.shop_id == DEV_SHOP_ID)
        )
    )
    product_ids = list(
        db.scalars(select(Product.id).where(Product.shop_id == DEV_SHOP_ID))
    )
    adjustment_ids = list(
        db.scalars(
            select(StockAdjustmentDocument.id).where(
                StockAdjustmentDocument.shop_id == DEV_SHOP_ID
            )
        )
    )
    opening_document_ids = list(
        db.scalars(
            select(OpeningStockDocument.id).where(
                OpeningStockDocument.shop_id == DEV_SHOP_ID
            )
        )
    )

    if db.query(FifoCostCorrection).filter(
        FifoCostCorrection.shop_id == DEV_SHOP_ID
    ).first():
        raise RuntimeError(
            "Refusing to reset dev-shop because it contains immutable FIFO cost "
            "corrections. Use a fresh development database instead."
        )
    if db.query(SupplierLedger).filter(
        SupplierLedger.shop_id == DEV_SHOP_ID
    ).first():
        raise RuntimeError(
            "Refusing to reset dev-shop while supplier accounting history exists."
        )

    db.query(SaleItemFifoRestoration).filter(
        SaleItemFifoRestoration.shop_id == DEV_SHOP_ID
    ).delete(synchronize_session=False)
    db.query(SaleItemFifoAllocation).filter(
        SaleItemFifoAllocation.shop_id == DEV_SHOP_ID
    ).delete(synchronize_session=False)
    if exchange_ids:
        db.query(ExchangeSettlement).filter(
            ExchangeSettlement.exchange_id.in_(exchange_ids)
        ).delete(synchronize_session=False)
        db.query(ExchangeItem).filter(
            ExchangeItem.exchange_id.in_(exchange_ids)
        ).delete(synchronize_session=False)
    db.query(ExchangeDocument).filter(
        ExchangeDocument.shop_id == DEV_SHOP_ID
    ).delete(synchronize_session=False)
    if refund_ids:
        db.query(RefundItem).filter(RefundItem.refund_id.in_(refund_ids)).delete(
            synchronize_session=False
        )
    db.query(RefundDocument).filter(
        RefundDocument.shop_id == DEV_SHOP_ID
    ).delete(synchronize_session=False)
    if sale_ids:
        db.query(Payment).filter(Payment.sale_id.in_(sale_ids)).delete(
            synchronize_session=False
        )
        db.query(CashMovement).filter(CashMovement.sale_id.in_(sale_ids)).delete(
            synchronize_session=False
        )
        db.query(SaleItem).filter(SaleItem.sale_id.in_(sale_ids)).delete(
            synchronize_session=False
        )
        db.query(CustomerLedger).filter(
            CustomerLedger.sale_id.in_(sale_ids)
        ).delete(synchronize_session=False)
    draft_ids = list(
        db.scalars(
            select(SaleDraft.id).where(SaleDraft.shop_id == DEV_SHOP_ID)
        )
    )
    if draft_ids:
        db.query(SaleDraftItem).filter(
            SaleDraftItem.draft_id.in_(draft_ids)
        ).delete(synchronize_session=False)
        db.query(SaleDraft).filter(SaleDraft.id.in_(draft_ids)).delete(
            synchronize_session=False
        )
    db.query(SaleDocument).filter(
        SaleDocument.shop_id == DEV_SHOP_ID
    ).delete(synchronize_session=False)
    db.query(IdempotencyRecord).filter(
        IdempotencyRecord.shop_id == DEV_SHOP_ID
    ).delete(synchronize_session=False)
    db.query(InventoryLotRecord).filter(
        InventoryLotRecord.shop_id == DEV_SHOP_ID
    ).delete(synchronize_session=False)
    db.query(StockMovement).filter(
        StockMovement.shop_id == DEV_SHOP_ID
    ).delete(synchronize_session=False)
    db.query(OpeningStockLine).filter(
        OpeningStockLine.product_id.in_(product_ids)
        | OpeningStockLine.document_id.in_(opening_document_ids)
    ).delete(synchronize_session=False)
    db.query(OpeningStockDocument).filter(
        OpeningStockDocument.shop_id == DEV_SHOP_ID
    ).delete(synchronize_session=False)
    if adjustment_ids:
        db.query(StockAdjustmentLine).filter(
            StockAdjustmentLine.document_id.in_(adjustment_ids)
        ).delete(synchronize_session=False)
    db.query(StockAdjustmentDocument).filter(
        StockAdjustmentDocument.shop_id == DEV_SHOP_ID
    ).delete(synchronize_session=False)
    if product_ids:
        db.query(ProductSellingUnit).filter(
            ProductSellingUnit.product_id.in_(product_ids)
        ).delete(synchronize_session=False)
    db.query(Product).filter(Product.shop_id == DEV_SHOP_ID).delete(
        synchronize_session=False
    )
    db.query(Category).filter(Category.shop_id == DEV_SHOP_ID).delete(
        synchronize_session=False
    )
    db.query(User).filter(User.shop_id == DEV_SHOP_ID).delete(
        synchronize_session=False
    )
    db.flush()


def _ensure_users(db) -> None:
    users = (
        ("admin", "System Administrator", "admin", "admin"),
        ("manager", "Development Manager", "manager", "manager"),
        ("cashier-1", "Cashier", "cashier", "cashier-1"),
        ("cashier", "Trial Cashier", "cashier", "cashier"),
    )
    for user_id, display_name, role, password in users:
        db.add(
            User(
                id=user_id,
                shop_id=DEV_SHOP_ID,
                username=user_id,
                display_name=display_name,
                password_hash=hash_password(password),
                role=role,
                is_active=True,
            )
        )


def _create_categories(db) -> dict[str, Category]:
    values = {
        "soft-drinks": "Soft Drinks",
        "food": "Food",
        "electronics": "Electronics",
        "general": "General",
    }
    categories = {
        category_id: Category(id=category_id, shop_id=DEV_SHOP_ID, name=name)
        for category_id, name in values.items()
    }
    db.add_all(categories.values())
    db.flush()
    return categories


def _create_products(db, categories: dict[str, Category]) -> dict[str, Product]:
    definitions = (
        ("coca-cola", "Test Coca Cola", "soft-drinks", 50, 70, 100, 10),
        ("packaged-soda", "Test Packaged Soda", "soft-drinks", 50, 70, 100, 8),
        ("chips", "Test Chips", "food", 30, 40, 60, 20),
        ("keyboard", "Test Keyboard", "electronics", 300, 400, 500, 5),
        ("zero-stock", "Test Zero Stock", "general", 20, 30, 40, 3),
    )
    products: dict[str, Product] = {}
    for product_id, name, category_id, cost, wholesale, price, quantity in definitions:
        product = Product(
            id=f"dev-{product_id}",
            shop_id=DEV_SHOP_ID,
            category_id=categories[category_id].id,
            name=name,
            code=f"DEMO-{product_id.upper()}",
            barcode=f"900000{len(products) + 1:04d}",
            product_type="STANDARD",
            price=price,
            min_price=price,
            wholesale_price=wholesale,
            cost=cost,
            stock=0,
            min_stock=2,
        )
        db.add(product)
        db.flush()
        _post_opening_stock(db, product, quantity, cost)
        products[product_id] = product
    db.flush()
    return products


def _post_opening_stock(db, product: Product, quantity: float, unit_cost: float) -> None:
    document_id = f"opening-{product.id}"
    movement_id = f"{document_id}-movement"
    created_at = datetime.utcnow()
    db.add(
        OpeningStockDocument(
            id=document_id,
            shop_id=DEV_SHOP_ID,
            product_id=product.id,
            idempotency_key=document_id,
            reference_number=f"OS-{product.id}",
            quantity=quantity,
            unit_cost=unit_cost,
            reason="Initial demo inventory",
            notes="Created through the opening-stock ledger",
            posted_by=ADMIN_ID,
            created_at=created_at,
        )
    )
    db.add(
        OpeningStockLine(
            id=f"{document_id}-line",
            document_id=document_id,
            product_id=product.id,
            quantity=quantity,
            unit_cost=unit_cost,
            line_total=quantity * unit_cost,
            created_at=created_at,
        )
    )
    product.stock = quantity
    db.add(
        StockMovement(
            id=movement_id,
            shop_id=DEV_SHOP_ID,
            product_id=product.id,
            movement_type="opening_stock",
            quantity_change=quantity,
            unit_cost=unit_cost,
            running_stock=quantity,
            reference_type="opening_stock",
            reference_id=document_id,
            notes="Initial demo inventory",
            user_id=ADMIN_ID,
            created_at=created_at,
        )
    )
    db.add(
        InventoryLotRecord(
            id=f"fifo-lot-{DEV_SHOP_ID}-{product.id}-{movement_id}",
            shop_id=DEV_SHOP_ID,
            product_id=product.id,
            movement_id=movement_id,
            source_type="opening_stock",
            source_id=document_id,
            source_reference=document_id,
            received_quantity=quantity,
            remaining_quantity=quantity,
            unit_cost=unit_cost,
            acquired_at=created_at,
        )
    )


def _create_sales(db, products: dict[str, Product]) -> dict[str, str]:
    sale_ids: dict[str, str] = {}
    requests = (
        ("cash-multi", (("coca-cola", 2), ("chips", 3)), "cashier"),
        ("cash-soda", (("packaged-soda", 2),), "cashier-1"),
        ("cash-keyboard", (("keyboard", 1),), "manager"),
        ("exchange-same", (("coca-cola", 1),), "cashier"),
        ("exchange-difference", (("chips", 1),), "cashier-1"),
        ("zero-stock-sale", (("zero-stock", 3),), "cashier"),
    )
    for key, lines, user_id in requests:
        payload = SaleCreate(
            idempotency_key=f"demo-{key}",
            payment_method="cash",
            items=[
                SaleItemCreate(product_id=products[product_id].id, quantity=quantity)
                for product_id, quantity in lines
            ],
        )
        response = post_sale(db, payload, DEV_SHOP_ID, user_id, "demo-seed")
        db.flush()
        sale_ids[key] = response.sale_id
    return sale_ids


def _create_refunds(db, sale_ids: dict[str, str]) -> None:
    _refund_sale(db, sale_ids["cash-soda"], "partial-refund", 1)
    _refund_sale(db, sale_ids["cash-keyboard"], "full-refund", 1)


def _refund_sale(db, sale_id: str, key: str, quantity: int) -> None:
    item = db.scalar(select(SaleItem).where(SaleItem.sale_id == sale_id))
    response = post_refund(
        db,
        RefundCreate(
            idempotency_key=f"demo-{key}",
            items=[RefundLineCreate(sale_item_id=item.id, quantity=quantity)],
            payment_method="cash",
        ),
        DEV_SHOP_ID,
        "cashier",
    )
    db.flush()
    assert response.sale_id == sale_id


def _create_exchanges(db, sale_ids: dict[str, str], products: dict[str, Product]) -> None:
    _exchange(
        db,
        sale_ids["exchange-same"],
        "same-value",
        products["packaged-soda"],
    )
    _exchange(
        db,
        sale_ids["exchange-difference"],
        "customer-pays-difference",
        products["keyboard"],
    )


def _exchange(db, sale_id: str, key: str, replacement: Product) -> None:
    item = db.scalar(select(SaleItem).where(SaleItem.sale_id == sale_id))
    response = post_exchange(
        db,
        ExchangeCreate(
            idempotency_key=f"demo-{key}",
            items=[
                ExchangeLineCreate(
                    sale_item_id=item.id,
                    replacement_product_id=replacement.id,
                    returned_quantity=1,
                    replacement_quantity=1,
                )
            ],
            payment_method="cash",
        ),
        sale_id,
        DEV_SHOP_ID,
        "cashier",
    )
    db.flush()
    assert response.replacement_sale_id


def _print_report(db) -> None:
    products = list(db.scalars(select(Product).where(Product.shop_id == DEV_SHOP_ID)))
    sales = list(db.scalars(select(SaleDocument).where(SaleDocument.shop_id == DEV_SHOP_ID)))
    exchanges = list(
        db.scalars(select(ExchangeDocument).where(ExchangeDocument.shop_id == DEV_SHOP_ID))
    )
    refunds = list(
        db.scalars(select(RefundDocument).where(RefundDocument.shop_id == DEV_SHOP_ID))
    )
    movements = list(
        db.scalars(select(StockMovement).where(StockMovement.shop_id == DEV_SHOP_ID))
    )
    current_cost = sum(Decimal(str(p.stock)) * Decimal(str(p.cost)) for p in products)
    sell_value = sum(Decimal(str(p.stock)) * Decimal(str(p.price)) for p in products)
    historic_cost = sum(
        Decimal(str(m.quantity_change)) * Decimal(str(m.unit_cost))
        for m in movements
        if m.quantity_change > 0
        and m.movement_type in {"opening_stock", "purchase", "stock_adjustment"}
    )
    expenses_supported = False
    print("Seeded development server data.")
    print(f"SHOP COUNT: {db.query(Shop).count()}")
    print(f"USER COUNT: {db.query(User).filter(User.shop_id == DEV_SHOP_ID).count()}")
    print(f"CATEGORY COUNT: {len(list(db.scalars(select(Category).where(Category.shop_id == DEV_SHOP_ID))))}")
    print(f"PRODUCT COUNT: {len(products)}")
    print("CUSTOMER COUNT: unsupported by current backend schema")
    print("SUPPLIER COUNT: unsupported by current backend schema")
    print("PURCHASE COUNT: unsupported by current backend schema")
    print(f"SALE COUNT: {len(sales)}")
    print(f"REFUND COUNT: {len(refunds)}")
    print(f"EXCHANGE COUNT: {len(exchanges)}")
    print(f"EXPENSE COUNT: {'unsupported by current backend schema' if not expenses_supported else '0'}")
    print(f"STOCK MOVEMENT COUNT: {len(movements)}")
    print(f"TOTAL CURRENT STOCK: {sum(Decimal(str(p.stock)) for p in products)}")
    print(f"TOTAL CURRENT INVENTORY COST: {current_cost}")
    print(f"TOTAL EXPECTED SELL VALUE: {sell_value}")
    print(f"TOTAL EXPECTED GROSS PROFIT: {sell_value - current_cost}")
    print(f"TOTAL HISTORICAL PURCHASE COST: {historic_cost}")
    print("TOTAL EXPENSES: unsupported by current backend schema")
    assert all(p.stock >= 0 for p in products)
    print("VALIDATION: product stock non-negative; opening, sale, refund, and exchange ledgers created.")
    print("LIMITATION: backend currently has no customer, supplier, purchase, or expense tables/API.")


if __name__ == "__main__":
    seed()
