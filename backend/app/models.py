from datetime import datetime
from decimal import Decimal

from sqlalchemy import Boolean, DateTime, Float, ForeignKey, Index, Integer, Numeric, String, Text, UniqueConstraint, func, text
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.database import Base


class Shop(Base):
    __tablename__ = "shops"
    id: Mapped[str] = mapped_column(String(100), primary_key=True)
    name: Mapped[str] = mapped_column(String(255))
    is_active: Mapped[bool] = mapped_column(Boolean, default=True, nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime, server_default=func.current_timestamp())


class StockAdjustmentDocument(Base):
    __tablename__ = "stock_adjustment_documents"
    __table_args__ = (UniqueConstraint("shop_id", "idempotency_key", name="uq_stock_adjustment_shop_key"),)
    id: Mapped[str] = mapped_column(String(100), primary_key=True)
    shop_id: Mapped[str] = mapped_column(ForeignKey("shops.id"), index=True)
    product_id: Mapped[str] = mapped_column(ForeignKey("products.id"), index=True)
    idempotency_key: Mapped[str] = mapped_column(String(255), index=True)
    reference_number: Mapped[str] = mapped_column(String(100), unique=True)
    adjustment_date: Mapped[datetime] = mapped_column(DateTime)
    reason: Mapped[str] = mapped_column(Text)
    notes: Mapped[str | None] = mapped_column(Text)
    posted_by: Mapped[str] = mapped_column(String(100))
    created_at: Mapped[datetime] = mapped_column(
        DateTime, server_default=func.current_timestamp()
    )


class StockAdjustmentLine(Base):
    __tablename__ = "stock_adjustment_lines"
    id: Mapped[str] = mapped_column(String(150), primary_key=True)
    document_id: Mapped[str] = mapped_column(
        ForeignKey("stock_adjustment_documents.id"), index=True
    )
    product_id: Mapped[str] = mapped_column(ForeignKey("products.id"), index=True)
    unit: Mapped[str] = mapped_column(String(100))
    current_quantity: Mapped[float] = mapped_column(Float)
    counted_quantity: Mapped[float] = mapped_column(Float)
    quantity_change: Mapped[float] = mapped_column(Float)
    unit_cost: Mapped[float] = mapped_column(Float)
    line_total: Mapped[float] = mapped_column(Float)
    created_at: Mapped[datetime] = mapped_column(
        DateTime, server_default=func.current_timestamp()
    )


class User(Base):
    __tablename__ = "users"
    id: Mapped[str] = mapped_column(String(100), primary_key=True)
    shop_id: Mapped[str] = mapped_column(ForeignKey("shops.id"), index=True)
    username: Mapped[str] = mapped_column(String(100), index=True)
    display_name: Mapped[str] = mapped_column(String(255))
    phone: Mapped[str | None] = mapped_column(String(50))
    password_hash: Mapped[str] = mapped_column(String(255))
    role: Mapped[str] = mapped_column(String(20), default="cashier")
    is_active: Mapped[bool] = mapped_column(Boolean, default=True, nullable=False)


class Device(Base):
    __tablename__ = "devices"
    id: Mapped[str] = mapped_column(String(100), primary_key=True)
    shop_id: Mapped[str] = mapped_column(ForeignKey("shops.id"), index=True)
    name: Mapped[str] = mapped_column(String(255))
    device_type: Mapped[str] = mapped_column(String(50), default="android")
    is_active: Mapped[bool] = mapped_column(Boolean, default=True, nullable=False)
    last_seen_at: Mapped[datetime | None] = mapped_column(DateTime)


class Category(Base):
    __tablename__ = "categories"
    __table_args__ = (
        Index(
            "uq_categories_shop_active_normalized_name",
            "shop_id",
            text("lower(trim(name))"),
            unique=True,
            sqlite_where=text("is_active = 1"),
        ),
    )
    id: Mapped[str] = mapped_column(String(100), primary_key=True)
    shop_id: Mapped[str] = mapped_column(ForeignKey("shops.id"), index=True)
    name: Mapped[str] = mapped_column(String(255))
    color: Mapped[str | None] = mapped_column(String(30))
    sort_order: Mapped[int] = mapped_column(Integer, default=0)
    is_active: Mapped[bool] = mapped_column(Boolean, default=True, nullable=False)
    products: Mapped[list["Product"]] = relationship(back_populates="category")


class Supplier(Base):
    __tablename__ = "suppliers"
    __table_args__ = (
        UniqueConstraint("shop_id", "code", name="uq_supplier_shop_code"),
    )
    id: Mapped[str] = mapped_column(String(100), primary_key=True)
    shop_id: Mapped[str] = mapped_column(ForeignKey("shops.id"), index=True)
    code: Mapped[str] = mapped_column(String(100), nullable=False)
    name: Mapped[str] = mapped_column(String(255), nullable=False)
    registration_name: Mapped[str] = mapped_column(String(255), nullable=False, default="")
    activity: Mapped[str] = mapped_column(String(255), nullable=False, default="Retail")
    address: Mapped[str] = mapped_column(Text, nullable=False, default="")
    phone: Mapped[str] = mapped_column(String(50), nullable=False, default="")
    mobile: Mapped[str] = mapped_column(String(50), nullable=False, default="")
    email: Mapped[str | None] = mapped_column(String(255))
    tax_number: Mapped[str | None] = mapped_column(String(100))
    registration_number: Mapped[str | None] = mapped_column(String(100))
    supplier_reference: Mapped[str | None] = mapped_column(String(100))
    contact_person: Mapped[str | None] = mapped_column(String(255))
    commercial_register: Mapped[str | None] = mapped_column(String(100))
    tax_id: Mapped[str | None] = mapped_column(String(100))
    nis: Mapped[str | None] = mapped_column(String(100))
    ai: Mapped[str | None] = mapped_column(String(100))
    bank_name: Mapped[str | None] = mapped_column(String(255))
    bank_account: Mapped[str | None] = mapped_column(String(100))
    currency: Mapped[str] = mapped_column(String(10), nullable=False, default="DZD")
    credit_limit: Mapped[Decimal] = mapped_column(Numeric(18, 2), nullable=False, default=0)
    notes: Mapped[str | None] = mapped_column(Text)
    is_active: Mapped[bool] = mapped_column(Boolean, default=True, nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime, server_default=func.current_timestamp())
    updated_at: Mapped[datetime] = mapped_column(DateTime, server_default=func.current_timestamp())


class Product(Base):
    __tablename__ = "products"
    __table_args__ = (
        Index(
            "uq_products_shop_active_normalized_barcode",
            "shop_id",
            text("trim(barcode)"),
            unique=True,
            sqlite_where=text(
                "is_active = 1 AND barcode IS NOT NULL AND trim(barcode) <> ''"
            ),
            postgresql_where=text(
                "is_active AND barcode IS NOT NULL AND trim(barcode) <> ''"
            ),
        ),
    )
    id: Mapped[str] = mapped_column(String(100), primary_key=True)
    shop_id: Mapped[str] = mapped_column(ForeignKey("shops.id"), index=True)
    category_id: Mapped[str | None] = mapped_column(ForeignKey("categories.id"), index=True)
    name: Mapped[str] = mapped_column(String(255))
    code: Mapped[str | None] = mapped_column(String(100), index=True)
    barcode: Mapped[str | None] = mapped_column(String(100), index=True)
    internal_reference: Mapped[str | None] = mapped_column(String(100))
    product_type: Mapped[str] = mapped_column(String(20), default="STANDARD")
    base_unit: Mapped[str] = mapped_column(String(50), default="piece")
    quantity_precision: Mapped[int] = mapped_column(Integer, default=3)
    allow_partial_package_sale: Mapped[bool] = mapped_column(Boolean, default=False)
    price: Mapped[float] = mapped_column(Float, default=0)
    min_price: Mapped[float] = mapped_column(Float, default=0)
    wholesale_price: Mapped[float] = mapped_column(Float, default=0)
    cost: Mapped[float] = mapped_column(Float, default=0)
    stock: Mapped[float] = mapped_column(Float, default=0)
    min_stock: Mapped[float] = mapped_column(Float, default=0)
    image_path: Mapped[str | None] = mapped_column(Text)
    is_active: Mapped[bool] = mapped_column(Boolean, default=True, nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime, server_default=func.current_timestamp())
    updated_at: Mapped[datetime] = mapped_column(DateTime, server_default=func.current_timestamp())
    category: Mapped[Category | None] = relationship(back_populates="products")
    selling_units: Mapped[list["ProductSellingUnit"]] = relationship(
        back_populates="product", cascade="all, delete-orphan"
    )


class ProductSellingUnit(Base):
    __tablename__ = "product_selling_units"
    id: Mapped[str] = mapped_column(String(100), primary_key=True)
    product_id: Mapped[str] = mapped_column(ForeignKey("products.id"), index=True)
    name: Mapped[str] = mapped_column(String(100))
    icon_key: Mapped[str | None] = mapped_column(String(50))
    conversion_to_base: Mapped[float] = mapped_column(Float)
    selling_price: Mapped[float] = mapped_column(Float)
    cost_price: Mapped[float] = mapped_column(Float, default=0)
    wholesale_price: Mapped[float | None] = mapped_column(Float)
    minimum_stock: Mapped[float] = mapped_column(Float, default=0, nullable=False)
    barcode: Mapped[str | None] = mapped_column(String(100), index=True)
    is_default: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)
    is_active: Mapped[bool] = mapped_column(Boolean, default=True, nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime, server_default=func.current_timestamp())
    updated_at: Mapped[datetime] = mapped_column(DateTime, server_default=func.current_timestamp())
    product: Mapped[Product] = relationship(back_populates="selling_units")


class OpeningStockDocument(Base):
    __tablename__ = "opening_stock_documents"
    id: Mapped[str] = mapped_column(String(100), primary_key=True)
    shop_id: Mapped[str] = mapped_column(ForeignKey("shops.id"), index=True)
    product_id: Mapped[str] = mapped_column(ForeignKey("products.id"), index=True)
    idempotency_key: Mapped[str] = mapped_column(String(255), index=True)
    reference_number: Mapped[str] = mapped_column(String(100), unique=True)
    quantity: Mapped[float] = mapped_column(Float)
    entered_unit: Mapped[str] = mapped_column(String(100), default="piece")
    conversion_to_base: Mapped[float] = mapped_column(Float, default=1)
    base_quantity: Mapped[float] = mapped_column(Float, default=0)
    unit_cost: Mapped[float] = mapped_column(Float)
    reason: Mapped[str] = mapped_column(Text)
    notes: Mapped[str | None] = mapped_column(Text)
    posted_by: Mapped[str] = mapped_column(String(100))
    created_at: Mapped[datetime] = mapped_column(
        DateTime, server_default=func.current_timestamp()
    )


class OpeningStockLine(Base):
    __tablename__ = "opening_stock_lines"
    id: Mapped[str] = mapped_column(String(100), primary_key=True)
    document_id: Mapped[str] = mapped_column(
        ForeignKey("opening_stock_documents.id"), index=True
    )
    product_id: Mapped[str] = mapped_column(ForeignKey("products.id"), index=True)
    quantity: Mapped[float] = mapped_column(Float)
    entered_unit: Mapped[str] = mapped_column(String(100), default="piece")
    conversion_to_base: Mapped[float] = mapped_column(Float, default=1)
    base_quantity: Mapped[float] = mapped_column(Float, default=0)
    unit_cost: Mapped[float] = mapped_column(Float)
    line_total: Mapped[float] = mapped_column(Float)
    created_at: Mapped[datetime] = mapped_column(
        DateTime, server_default=func.current_timestamp()
    )


class StockMovement(Base):
    __tablename__ = "stock_movements"
    id: Mapped[str] = mapped_column(String(150), primary_key=True)
    shop_id: Mapped[str] = mapped_column(ForeignKey("shops.id"), index=True)
    product_id: Mapped[str] = mapped_column(ForeignKey("products.id"), index=True)
    movement_type: Mapped[str] = mapped_column(String(50))
    quantity_change: Mapped[float] = mapped_column(Float)
    unit_cost: Mapped[float] = mapped_column(Float)
    running_stock: Mapped[float] = mapped_column(Float)
    reference_type: Mapped[str] = mapped_column(String(50))
    reference_id: Mapped[str] = mapped_column(String(100))
    reference_line_id: Mapped[str | None] = mapped_column(String(150), nullable=True, index=True)
    lineage_id: Mapped[str | None] = mapped_column(String(150), nullable=True, index=True)
    notes: Mapped[str | None] = mapped_column(Text)
    user_id: Mapped[str | None] = mapped_column(String(100))
    device_id: Mapped[str | None] = mapped_column(String(100))
    created_at: Mapped[datetime] = mapped_column(
        DateTime, server_default=func.current_timestamp()
    )


class InventoryLotRecord(Base):
    __tablename__ = "inventory_lots"
    __table_args__ = (
        UniqueConstraint("shop_id", "product_id", "movement_id", name="uq_inventory_lot_shop_product_movement"),
    )
    id: Mapped[str] = mapped_column(String(150), primary_key=True)
    shop_id: Mapped[str] = mapped_column(ForeignKey("shops.id"), index=True)
    product_id: Mapped[str] = mapped_column(ForeignKey("products.id"), index=True)
    movement_id: Mapped[str] = mapped_column(String(150), index=True)
    source_type: Mapped[str] = mapped_column(String(50), nullable=False)
    source_id: Mapped[str] = mapped_column(String(150), nullable=False)
    source_reference: Mapped[str | None] = mapped_column(String(150), nullable=True, index=True)
    received_quantity: Mapped[float] = mapped_column(Float, nullable=False)
    remaining_quantity: Mapped[float] = mapped_column(Float, nullable=False)
    unit_cost: Mapped[float] = mapped_column(Float, nullable=False)
    acquired_at: Mapped[datetime] = mapped_column(DateTime, nullable=False, index=True)
    lineage_id: Mapped[str | None] = mapped_column(String(150), nullable=True, index=True)
    fifo_order: Mapped[str | None] = mapped_column(String(500), nullable=True, index=True)
    parent_layer_id: Mapped[str | None] = mapped_column(
        ForeignKey("inventory_lots.id"), nullable=True, index=True
    )

    @property
    def quantity(self) -> float:
        return self.remaining_quantity

    @property
    def received_base_quantity(self) -> float:
        return self.received_quantity

    @property
    def remaining_base_quantity(self) -> float:
        return self.remaining_quantity


class SaleItemFifoAllocation(Base):
    __tablename__ = "sale_item_fifo_allocations"
    __table_args__ = (
        UniqueConstraint(
            "sale_item_id",
            "inventory_lot_id",
            name="uq_sale_item_fifo_allocation_lot",
        ),
    )
    id: Mapped[str] = mapped_column(String(150), primary_key=True)
    shop_id: Mapped[str] = mapped_column(ForeignKey("shops.id"), index=True)
    sale_item_id: Mapped[str] = mapped_column(ForeignKey("sale_items.id"), index=True)
    inventory_lot_id: Mapped[str] = mapped_column(
        ForeignKey("inventory_lots.id"), index=True
    )
    allocated_quantity: Mapped[float] = mapped_column(Float, nullable=False)
    unit_cost_at_sale: Mapped[float | None] = mapped_column(Float, nullable=True)
    restored_quantity: Mapped[float] = mapped_column(
        Float, nullable=False, default=0, server_default="0"
    )
    created_at: Mapped[datetime] = mapped_column(
        DateTime, server_default=func.current_timestamp()
    )

    @property
    def remaining_consumed_quantity(self) -> float:
        return max(0.0, self.allocated_quantity - self.restored_quantity)


class SaleItemFifoRestoration(Base):
    __tablename__ = "sale_item_fifo_restorations"
    id: Mapped[str] = mapped_column(String(150), primary_key=True)
    shop_id: Mapped[str] = mapped_column(ForeignKey("shops.id"), index=True)
    sale_item_fifo_allocation_id: Mapped[str] = mapped_column(
        ForeignKey("sale_item_fifo_allocations.id"), index=True
    )
    refund_item_id: Mapped[str | None] = mapped_column(
        ForeignKey("refund_items.id"), index=True, nullable=True
    )
    exchange_item_id: Mapped[str | None] = mapped_column(
        ForeignKey("exchange_items.id"), index=True, nullable=True
    )
    restored_quantity: Mapped[float] = mapped_column(Float, nullable=False)
    unit_cost: Mapped[float] = mapped_column(Float, nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime, server_default=func.current_timestamp()
    )


class FifoCostCorrection(Base):
    __tablename__ = "fifo_cost_corrections"
    __table_args__ = (
        UniqueConstraint(
            "shop_id",
            "idempotency_key",
            name="uq_fifo_cost_correction_shop_key",
        ),
    )
    id: Mapped[str] = mapped_column(String(150), primary_key=True)
    shop_id: Mapped[str] = mapped_column(ForeignKey("shops.id"), index=True)
    product_id: Mapped[str] = mapped_column(ForeignKey("products.id"), index=True)
    source_layer_id: Mapped[str] = mapped_column(
        ForeignKey("inventory_lots.id"), index=True
    )
    resulting_layer_id: Mapped[str] = mapped_column(
        ForeignKey("inventory_lots.id"), index=True
    )
    source_movement_id: Mapped[str] = mapped_column(String(150), nullable=False)
    correction_movement_id: Mapped[str] = mapped_column(String(150), nullable=False, unique=True)
    source_reference: Mapped[str] = mapped_column(String(150), nullable=False)
    quantity: Mapped[float] = mapped_column(Float, nullable=False)
    old_unit_cost: Mapped[float] = mapped_column(Float, nullable=False)
    new_unit_cost: Mapped[float] = mapped_column(Float, nullable=False)
    value_difference: Mapped[float] = mapped_column(Float, nullable=False)
    reason: Mapped[str] = mapped_column(Text, nullable=False)
    posted_by: Mapped[str] = mapped_column(ForeignKey("users.id"), nullable=False)
    idempotency_key: Mapped[str] = mapped_column(String(255), nullable=False)
    request_hash: Mapped[str] = mapped_column(String(64), nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime, server_default=func.current_timestamp()
    )


class IdempotencyRecord(Base):
    __tablename__ = "idempotency_records"
    __table_args__ = (UniqueConstraint("shop_id", "idempotency_key", name="uq_idempotency_shop_key"),)
    id: Mapped[str] = mapped_column(String(100), primary_key=True)
    shop_id: Mapped[str] = mapped_column(ForeignKey("shops.id"), index=True)
    idempotency_key: Mapped[str] = mapped_column(String(255))
    request_hash: Mapped[str] = mapped_column(String(64))
    response_json: Mapped[str] = mapped_column(Text)
    status_code: Mapped[int] = mapped_column(Integer)
    device_id: Mapped[str | None] = mapped_column(String(100))
    created_at: Mapped[datetime] = mapped_column(
        DateTime, server_default=func.current_timestamp()
    )


class RevokedToken(Base):
    __tablename__ = "revoked_tokens"
    jti: Mapped[str] = mapped_column(String(100), primary_key=True)
    revoked_at: Mapped[datetime] = mapped_column(
        DateTime, server_default=func.current_timestamp()
    )
    expires_at: Mapped[datetime] = mapped_column(DateTime)


class SaleDocument(Base):
    __tablename__ = "sale_documents"
    __table_args__ = (UniqueConstraint("shop_id", "idempotency_key", name="uq_sale_shop_key"),)
    id: Mapped[str] = mapped_column(String(100), primary_key=True)
    shop_id: Mapped[str] = mapped_column(ForeignKey("shops.id"), index=True)
    idempotency_key: Mapped[str] = mapped_column(String(255), nullable=False)
    document_reference: Mapped[str] = mapped_column(String(100), nullable=False, unique=True)
    status: Mapped[str] = mapped_column(String(20), nullable=False, default="POSTED")
    customer_id: Mapped[str | None] = mapped_column(String(100), index=True)
    payment_method: Mapped[str] = mapped_column(String(20), nullable=False)
    subtotal: Mapped[Decimal] = mapped_column(Numeric(18, 2), nullable=False, default=0)
    discount: Mapped[Decimal] = mapped_column(Numeric(18, 2), nullable=False, default=0)
    total: Mapped[Decimal] = mapped_column(Numeric(18, 2), nullable=False)
    payment_result: Mapped[Decimal] = mapped_column(Numeric(18, 2), nullable=False, default=0)
    remaining_amount: Mapped[Decimal] = mapped_column(Numeric(18, 2), nullable=False, default=0)
    stock_posting_reference: Mapped[str] = mapped_column(String(150), nullable=False)
    posted_by: Mapped[str] = mapped_column(String(100), nullable=False)
    posted_at: Mapped[datetime] = mapped_column(DateTime, nullable=False)


class PurchaseDocument(Base):
    __tablename__ = "purchase_documents"
    __table_args__ = (
        UniqueConstraint("shop_id", "reference", name="uq_purchase_shop_reference"),
        UniqueConstraint("shop_id", "idempotency_key", name="uq_purchase_shop_key"),
    )
    id: Mapped[str] = mapped_column(String(100), primary_key=True)
    shop_id: Mapped[str] = mapped_column(ForeignKey("shops.id"), index=True)
    reference: Mapped[str] = mapped_column(String(100), nullable=False)
    supplier_id: Mapped[str] = mapped_column(ForeignKey("suppliers.id"), index=True)
    purchase_date: Mapped[datetime] = mapped_column(DateTime, nullable=False)
    notes: Mapped[str | None] = mapped_column(Text)
    subtotal: Mapped[Decimal] = mapped_column(Numeric(18, 2), nullable=False)
    total: Mapped[Decimal] = mapped_column(Numeric(18, 2), nullable=False)
    status: Mapped[str] = mapped_column(String(20), nullable=False, default="POSTED")
    created_by: Mapped[str] = mapped_column(ForeignKey("users.id"), nullable=False)
    idempotency_key: Mapped[str] = mapped_column(String(255), nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime, nullable=False)


class PurchaseLine(Base):
    __tablename__ = "purchase_lines"
    id: Mapped[str] = mapped_column(String(150), primary_key=True)
    purchase_id: Mapped[str] = mapped_column(ForeignKey("purchase_documents.id"), index=True)
    product_id: Mapped[str] = mapped_column(ForeignKey("products.id"), index=True)
    quantity: Mapped[Decimal] = mapped_column(Numeric(18, 6), nullable=False)
    unit_cost: Mapped[Decimal] = mapped_column(Numeric(18, 6), nullable=False)
    line_total: Mapped[Decimal] = mapped_column(Numeric(18, 2), nullable=False)
    selling_unit_id: Mapped[str | None] = mapped_column(String(100))
    selling_quantity: Mapped[Decimal | None] = mapped_column(Numeric(18, 6))
    conversion_factor_snapshot: Mapped[Decimal] = mapped_column(Numeric(18, 6), nullable=False, default=1)
    selling_unit_name_snapshot: Mapped[str] = mapped_column(String(100), nullable=False)
    base_unit_snapshot: Mapped[str] = mapped_column(String(50), nullable=False)


class SupplierLedger(Base):
    __tablename__ = "supplier_ledger"
    id: Mapped[str] = mapped_column(String(150), primary_key=True)
    shop_id: Mapped[str] = mapped_column(ForeignKey("shops.id"), index=True)
    supplier_id: Mapped[str] = mapped_column(ForeignKey("suppliers.id"), index=True)
    entry_type: Mapped[str] = mapped_column(String(30), nullable=False)
    amount: Mapped[Decimal] = mapped_column(Numeric(18, 2), nullable=False)
    balance_after: Mapped[Decimal] = mapped_column(Numeric(18, 2), nullable=False)
    reference_type: Mapped[str] = mapped_column(String(50), nullable=False)
    reference_id: Mapped[str] = mapped_column(String(150), nullable=False)
    notes: Mapped[str | None] = mapped_column(Text)
    created_at: Mapped[datetime] = mapped_column(DateTime, nullable=False)


class SupplierReturnDocument(Base):
    __tablename__ = "supplier_return_documents"
    __table_args__ = (
        UniqueConstraint("shop_id", "reference", name="uq_supplier_return_shop_reference"),
        UniqueConstraint("shop_id", "idempotency_key", name="uq_supplier_return_shop_key"),
    )
    id: Mapped[str] = mapped_column(String(100), primary_key=True)
    shop_id: Mapped[str] = mapped_column(ForeignKey("shops.id"), index=True)
    reference: Mapped[str] = mapped_column(String(100), nullable=False)
    supplier_id: Mapped[str] = mapped_column(ForeignKey("suppliers.id"), index=True)
    purchase_id: Mapped[str] = mapped_column(ForeignKey("purchase_documents.id"), index=True)
    return_date: Mapped[datetime] = mapped_column(DateTime, nullable=False)
    total: Mapped[Decimal] = mapped_column(Numeric(18, 2), nullable=False)
    status: Mapped[str] = mapped_column(String(20), nullable=False, default="POSTED")
    notes: Mapped[str | None] = mapped_column(Text)
    created_by: Mapped[str] = mapped_column(ForeignKey("users.id"), nullable=False)
    idempotency_key: Mapped[str] = mapped_column(String(255), nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime, nullable=False)


class SupplierReturnLine(Base):
    __tablename__ = "supplier_return_lines"
    id: Mapped[str] = mapped_column(String(150), primary_key=True)
    return_id: Mapped[str] = mapped_column(
        String(100),
        ForeignKey("supplier_return_documents.id"), index=True
    )
    purchase_line_id: Mapped[str] = mapped_column(
        ForeignKey("purchase_lines.id"), index=True
    )
    product_id: Mapped[str] = mapped_column(ForeignKey("products.id"), index=True)
    quantity: Mapped[Decimal] = mapped_column(Numeric(18, 6), nullable=False)
    base_quantity: Mapped[Decimal] = mapped_column(Numeric(18, 6), nullable=False)
    unit_cost: Mapped[Decimal] = mapped_column(Numeric(18, 6), nullable=False)
    return_value: Mapped[Decimal] = mapped_column(Numeric(18, 2), nullable=False)
    unit_name: Mapped[str] = mapped_column(String(100), nullable=False)


class SaleItem(Base):
    __tablename__ = "sale_items"
    id: Mapped[str] = mapped_column(String(150), primary_key=True)
    sale_id: Mapped[str] = mapped_column(ForeignKey("sale_documents.id"), index=True)
    product_id: Mapped[str] = mapped_column(ForeignKey("products.id"), index=True)
    unit: Mapped[str] = mapped_column(String(100), nullable=False)
    quantity: Mapped[Decimal] = mapped_column(Numeric(18, 6), nullable=False)
    base_quantity: Mapped[Decimal] = mapped_column(Numeric(18, 6), nullable=False)
    unit_price: Mapped[Decimal] = mapped_column(Numeric(18, 2), nullable=False)
    line_total: Mapped[Decimal] = mapped_column(Numeric(18, 2), nullable=False)
    refunded_quantity: Mapped[Decimal] = mapped_column(
        Numeric(18, 6), nullable=False, default=0, server_default="0"
    )
    exchanged_quantity: Mapped[Decimal] = mapped_column(
        Numeric(18, 6), nullable=False, default=0, server_default="0"
    )


class RefundDocument(Base):
    __tablename__ = "refund_documents"
    __table_args__ = (UniqueConstraint("shop_id", "idempotency_key", name="uq_refund_shop_key"),)
    id: Mapped[str] = mapped_column(String(100), primary_key=True)
    shop_id: Mapped[str] = mapped_column(ForeignKey("shops.id"), index=True)
    sale_id: Mapped[str] = mapped_column(ForeignKey("sale_documents.id"), index=True)
    idempotency_key: Mapped[str] = mapped_column(String(255), nullable=False)
    amount: Mapped[Decimal] = mapped_column(Numeric(18, 2), nullable=False)
    payment_method: Mapped[str] = mapped_column(String(20), nullable=False)
    posted_by: Mapped[str] = mapped_column(String(100), nullable=False)
    posted_at: Mapped[datetime] = mapped_column(DateTime, nullable=False)


class RefundItem(Base):
    __tablename__ = "refund_items"
    id: Mapped[str] = mapped_column(String(150), primary_key=True)
    refund_id: Mapped[str] = mapped_column(ForeignKey("refund_documents.id"), index=True)
    sale_item_id: Mapped[str] = mapped_column(ForeignKey("sale_items.id"), index=True)
    quantity: Mapped[Decimal] = mapped_column(Numeric(18, 6), nullable=False)
    base_quantity: Mapped[Decimal] = mapped_column(Numeric(18, 6), nullable=False)
    amount: Mapped[Decimal] = mapped_column(Numeric(18, 2), nullable=False)


class ExchangeDocument(Base):
    __tablename__ = "exchange_documents"
    __table_args__ = (UniqueConstraint("shop_id", "idempotency_key", name="uq_exchange_shop_key"),)
    id: Mapped[str] = mapped_column(String(100), primary_key=True)
    shop_id: Mapped[str] = mapped_column(ForeignKey("shops.id"), index=True)
    sale_id: Mapped[str] = mapped_column(ForeignKey("sale_documents.id"), index=True)
    replacement_sale_id: Mapped[str | None] = mapped_column(
        ForeignKey("sale_documents.id"), index=True, nullable=True
    )
    idempotency_key: Mapped[str] = mapped_column(String(255), nullable=False)
    difference_amount: Mapped[Decimal] = mapped_column(Numeric(18, 2), nullable=False)
    payment_method: Mapped[str] = mapped_column(String(20), nullable=False)
    posted_by: Mapped[str] = mapped_column(String(100), nullable=False)
    posted_at: Mapped[datetime] = mapped_column(DateTime, nullable=False)


class ExchangeItem(Base):
    __tablename__ = "exchange_items"
    id: Mapped[str] = mapped_column(String(150), primary_key=True)
    exchange_id: Mapped[str] = mapped_column(ForeignKey("exchange_documents.id"), index=True)
    sale_item_id: Mapped[str] = mapped_column(ForeignKey("sale_items.id"), index=True)
    returned_quantity: Mapped[Decimal] = mapped_column(Numeric(18, 6), nullable=False)
    returned_base_quantity: Mapped[Decimal] = mapped_column(Numeric(18, 6), nullable=False)
    replacement_product_id: Mapped[str] = mapped_column(ForeignKey("products.id"), index=True)
    replacement_quantity: Mapped[Decimal] = mapped_column(Numeric(18, 6), nullable=False)
    replacement_base_quantity: Mapped[Decimal] = mapped_column(Numeric(18, 6), nullable=False)
    old_amount: Mapped[Decimal] = mapped_column(Numeric(18, 2), nullable=False)
    new_amount: Mapped[Decimal] = mapped_column(Numeric(18, 2), nullable=False)


class ExchangeSettlement(Base):
    __tablename__ = "exchange_settlements"
    __table_args__ = (
        UniqueConstraint("exchange_id", name="uq_exchange_settlement_exchange"),
    )
    id: Mapped[str] = mapped_column(String(150), primary_key=True)
    exchange_id: Mapped[str] = mapped_column(
        ForeignKey("exchange_documents.id"), index=True
    )
    replacement_sale_id: Mapped[str] = mapped_column(
        ForeignKey("sale_documents.id"), index=True
    )
    shop_id: Mapped[str] = mapped_column(ForeignKey("shops.id"), index=True)
    payment_id: Mapped[str] = mapped_column(ForeignKey("sale_payments.id"))
    cash_movement_id: Mapped[str | None] = mapped_column(
        ForeignKey("cash_movements.id"), nullable=True
    )
    customer_ledger_id: Mapped[str | None] = mapped_column(
        ForeignKey("customer_ledger.id"), nullable=True
    )
    returned_amount: Mapped[Decimal] = mapped_column(Numeric(18, 2), nullable=False)
    replacement_amount: Mapped[Decimal] = mapped_column(
        Numeric(18, 2), nullable=False
    )
    difference_amount: Mapped[Decimal] = mapped_column(
        Numeric(18, 2), nullable=False
    )
    payment_method: Mapped[str] = mapped_column(String(20), nullable=False)
    posted_at: Mapped[datetime] = mapped_column(DateTime, nullable=False)


class SaleDraft(Base):
    __tablename__ = "sale_drafts"
    __table_args__ = (
        UniqueConstraint("shop_id", "owner_id", "id", name="uq_sale_draft_scope_id"),
    )
    id: Mapped[str] = mapped_column(String(100), primary_key=True)
    shop_id: Mapped[str] = mapped_column(ForeignKey("shops.id"), index=True)
    owner_id: Mapped[str] = mapped_column(ForeignKey("users.id"), index=True)
    visibility: Mapped[str] = mapped_column(
        String(20), nullable=False, default="PRIVATE", server_default="PRIVATE"
    )
    sale_number: Mapped[int] = mapped_column(Integer, nullable=False)
    status: Mapped[str] = mapped_column(String(20), nullable=False, default="OPEN")
    version: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    customer_id: Mapped[str | None] = mapped_column(String(100), index=True)
    customer_name: Mapped[str | None] = mapped_column(String(255))
    payment_method: Mapped[str] = mapped_column(String(20), nullable=False, default="cash")
    discount: Mapped[Decimal] = mapped_column(Numeric(18, 2), nullable=False, default=0)
    paid_amount: Mapped[Decimal | None] = mapped_column(Numeric(18, 2))
    checkout_sale_id: Mapped[str | None] = mapped_column(
        ForeignKey("sale_documents.id"), index=True
    )
    created_at: Mapped[datetime] = mapped_column(
        DateTime, server_default=func.current_timestamp()
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime, server_default=func.current_timestamp()
    )
    owner: Mapped["User"] = relationship(foreign_keys=[owner_id])
    items: Mapped[list["SaleDraftItem"]] = relationship(
        back_populates="draft", cascade="all, delete-orphan", order_by="SaleDraftItem.created_at"
    )


class SaleDraftItem(Base):
    __tablename__ = "sale_draft_items"
    __table_args__ = (
        UniqueConstraint("draft_id", "product_id", name="uq_sale_draft_product"),
    )
    id: Mapped[str] = mapped_column(String(150), primary_key=True)
    draft_id: Mapped[str] = mapped_column(ForeignKey("sale_drafts.id"), index=True)
    product_id: Mapped[str] = mapped_column(ForeignKey("products.id"), index=True)
    unit: Mapped[str] = mapped_column(String(100), nullable=False, default="piece")
    icon_key: Mapped[str | None] = mapped_column(String(50))
    quantity: Mapped[Decimal] = mapped_column(Numeric(18, 6), nullable=False)
    unit_price: Mapped[Decimal | None] = mapped_column(Numeric(18, 2))
    created_at: Mapped[datetime] = mapped_column(
        DateTime, server_default=func.current_timestamp()
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime, server_default=func.current_timestamp()
    )
    draft: Mapped[SaleDraft] = relationship(back_populates="items")
    product: Mapped[Product] = relationship()


class Payment(Base):
    __tablename__ = "sale_payments"
    id: Mapped[str] = mapped_column(String(150), primary_key=True)
    sale_id: Mapped[str] = mapped_column(ForeignKey("sale_documents.id"), index=True)
    shop_id: Mapped[str] = mapped_column(ForeignKey("shops.id"), index=True)
    amount: Mapped[Decimal] = mapped_column(Numeric(18, 2), nullable=False)
    method: Mapped[str] = mapped_column(String(20), nullable=False)
    paid_at: Mapped[datetime] = mapped_column(DateTime, nullable=False)


class CashMovement(Base):
    __tablename__ = "cash_movements"
    id: Mapped[str] = mapped_column(String(150), primary_key=True)
    sale_id: Mapped[str] = mapped_column(ForeignKey("sale_documents.id"), index=True)
    shop_id: Mapped[str] = mapped_column(ForeignKey("shops.id"), index=True)
    amount: Mapped[Decimal] = mapped_column(Numeric(18, 2), nullable=False)
    movement_type: Mapped[str] = mapped_column(String(30), nullable=False)
    occurred_at: Mapped[datetime] = mapped_column(DateTime, nullable=False)


class CustomerLedger(Base):
    __tablename__ = "customer_ledger"
    id: Mapped[str] = mapped_column(String(150), primary_key=True)
    customer_id: Mapped[str] = mapped_column(String(100), index=True)
    sale_id: Mapped[str] = mapped_column(ForeignKey("sale_documents.id"), index=True)
    shop_id: Mapped[str] = mapped_column(ForeignKey("shops.id"), index=True)
    amount: Mapped[Decimal] = mapped_column(Numeric(18, 2), nullable=False)
    direction: Mapped[str] = mapped_column(String(20), nullable=False)
    posted_at: Mapped[datetime] = mapped_column(DateTime, nullable=False)


# Descriptive aliases retained for callers that prefer explicit persistence names.
PaymentRecord = Payment
CashMovementRecord = CashMovement
CustomerLedgerRecord = CustomerLedger
