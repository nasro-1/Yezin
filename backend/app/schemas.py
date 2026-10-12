from datetime import datetime
from decimal import Decimal

from typing import Literal

from pydantic import AliasChoices, BaseModel, ConfigDict, Field, field_validator


class HealthResponse(BaseModel):
    status: str
    database: str


class VersionResponse(BaseModel):
    version: str


class LoginRequest(BaseModel):
    username: str
    password: str


class LoginResponse(BaseModel):
    access_token: str
    token_type: str = "bearer"
    user_id: str
    shop_id: str
    role: str


class UserResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    shop_id: str
    username: str
    display_name: str
    phone: str | None = None
    role: str
    is_active: bool = True
    image_path: str | None = None


class UserCreate(BaseModel):
    username: str
    display_name: str | None = None
    phone: str | None = None
    password: str
    role: str = "cashier"
    is_active: bool = True


class UserUpdate(BaseModel):
    display_name: str | None = None
    phone: str | None = None
    password: str | None = None
    role: str | None = None
    is_active: bool | None = None


class CategoryCreate(BaseModel):
    name: str
    color: str | None = None
    sort_order: int = 0


class SupplierCreate(BaseModel):
    id: str
    code: str = ""
    name: str = Field(min_length=1, max_length=255)
    registration_name: str = ""
    activity: str = "Retail"
    address: str = ""
    phone: str = ""
    mobile: str = ""
    email: str | None = None
    tax_number: str | None = None
    registration_number: str | None = None
    supplier_reference: str | None = None
    contact_person: str | None = None
    commercial_register: str | None = None
    tax_id: str | None = None
    nis: str | None = None
    ai: str | None = None
    bank_name: str | None = None
    bank_account: str | None = None
    currency: str = "DZD"
    credit_limit: Decimal = Field(default=Decimal("0"), ge=0)
    opening_balance: Decimal = Field(default=Decimal("0"), ge=0)
    notes: str | None = None
    is_active: bool = True


class SupplierUpdate(BaseModel):
    name: str = Field(min_length=1, max_length=255)
    registration_name: str = ""
    activity: str = "Retail"
    address: str = ""
    phone: str = ""
    mobile: str = ""
    email: str | None = None
    tax_number: str | None = None
    registration_number: str | None = None
    supplier_reference: str | None = None
    contact_person: str | None = None
    commercial_register: str | None = None
    tax_id: str | None = None
    nis: str | None = None
    ai: str | None = None
    bank_name: str | None = None
    bank_account: str | None = None
    currency: str = "DZD"
    credit_limit: Decimal = Field(default=Decimal("0"), ge=0)
    notes: str | None = None
    is_active: bool = True


class SupplierResponse(BaseModel):
    id: str
    shop_id: str
    code: str
    name: str
    registration_name: str
    activity: str
    address: str
    phone: str
    mobile: str
    email: str | None
    tax_number: str | None
    registration_number: str | None
    supplier_reference: str | None
    contact_person: str | None
    commercial_register: str | None
    tax_id: str | None
    nis: str | None
    ai: str | None
    bank_name: str | None
    bank_account: str | None
    currency: str
    credit_limit: Decimal
    opening_balance: Decimal = Decimal("0")
    current_balance: Decimal
    notes: str | None
    is_active: bool
    created_at: datetime
    updated_at: datetime


class SupplierListResponse(BaseModel):
    items: list[SupplierResponse]
    total: int


class SupplierLedgerResponse(BaseModel):
    id: str
    supplier_id: str
    entry_type: str
    amount: Decimal
    balance_after: Decimal
    reference_type: str
    reference_id: str
    notes: str | None
    created_at: datetime


class SupplierPaymentCreate(BaseModel):
    idempotency_key: str = Field(min_length=1, max_length=100)
    amount: Decimal = Field(gt=0, allow_inf_nan=False)
    payment_date: datetime
    payment_method: Literal["cash"] = "cash"
    reference: str = Field(default="", max_length=100)
    notes: str | None = None


class SupplierPaymentResponse(BaseModel):
    payment_id: str
    supplier_id: str
    amount: Decimal
    payment_date: datetime
    payment_method: str
    reference: str
    notes: str | None
    balance_after: Decimal
    created_at: datetime


class SupplierReturnLineCreate(BaseModel):
    purchase_item_id: str = Field(min_length=1, max_length=150)
    product_id: str = Field(min_length=1, max_length=100)
    quantity: Decimal = Field(gt=0, allow_inf_nan=False)


class SupplierReturnCreate(BaseModel):
    idempotency_key: str = Field(min_length=1, max_length=100)
    reference: str = Field(min_length=1, max_length=100)
    purchase_id: str = Field(min_length=1, max_length=100)
    return_date: datetime
    lines: list[SupplierReturnLineCreate] = Field(min_length=1)
    notes: str | None = None


class SupplierReturnLineResponse(BaseModel):
    purchase_item_id: str
    product_id: str
    quantity: Decimal
    base_quantity: Decimal
    unit_cost: Decimal
    return_value: Decimal
    unit_name: str


class SupplierReturnResponse(BaseModel):
    return_id: str
    reference: str
    supplier_id: str
    source_purchase_id: str
    source_purchase_reference: str
    return_date: datetime
    status: str
    total: Decimal
    balance_after: Decimal
    lines: list[SupplierReturnLineResponse]
    created_at: datetime


class SellingUnitCreate(BaseModel):
    id: str
    name: str
    icon_key: str | None = None
    conversion_to_base: float
    selling_price: float
    cost_price: float = 0
    wholesale_price: float | None = None
    minimum_stock: float = Field(default=0, ge=0)
    barcode: str | None = Field(default=None, deprecated=True)
    is_default: bool = False
    is_active: bool = True

    @field_validator("barcode")
    @classmethod
    def reject_selling_unit_barcode(cls, value: str | None) -> str | None:
        if value is not None and value.strip():
            raise ValueError("Barcode belongs to the product, not a selling unit")
        return value


class OpeningStockLineCreate(BaseModel):
    unit: str
    quantity: float = Field(gt=0)
    unit_cost: float = Field(ge=0)


class ProductCreate(BaseModel):
    id: str
    name: str
    code: str | None = None
    barcode: str | None = None
    internal_reference: str | None = None
    product_type: str = "STANDARD"
    base_unit: str = "piece"
    quantity_precision: int = 3
    allow_partial_package_sale: bool = False
    price: float = 0
    min_price: float = 0
    wholesale_price: float = 0
    cost: float = 0
    min_stock: float = 0
    category_id: str | None = None
    image_path: str | None = None
    is_active: bool = True
    opening_quantity: float = Field(default=0, ge=0)
    opening_unit: str | None = None
    opening_unit_cost: float = Field(default=0, ge=0)
    opening_reason: str | None = None
    opening_notes: str | None = None
    opening_lines: list[OpeningStockLineCreate] = Field(default_factory=list)
    selling_units: list[SellingUnitCreate] = Field(default_factory=list)


class ProductUpdate(ProductCreate):
    opening_quantity: float = Field(default=0, ge=0)
    opening_unit_cost: float = Field(default=0, ge=0)
    opening_reason: str | None = None
    opening_notes: str | None = None


class CategoryResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    name: str


class SellingUnitResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    name: str
    icon_key: str | None
    conversion_to_base: float
    selling_price: float
    cost_price: float
    wholesale_price: float | None
    minimum_stock: float
    barcode: str | None
    is_default: bool
    is_active: bool


class ProductResponse(BaseModel):
    id: str
    name: str
    code: str | None
    barcode: str | None
    internal_reference: str | None
    product_type: str
    base_unit: str
    quantity_precision: int
    allow_partial_package_sale: bool
    price: float
    min_price: float
    wholesale_price: float
    cost: float
    stock: float
    min_stock: float
    category_id: str | None
    category_name: str | None = None
    image_path: str | None
    is_active: bool
    matched_selling_unit_id: str | None = None
    matched_selling_unit_name: str | None = None
    selling_units: list[SellingUnitResponse] = Field(default_factory=list)


class ProductListResponse(BaseModel):
    items: list[ProductResponse]
    total: int
    page: int
    page_size: int


class StockSummaryResponse(BaseModel):
    total_products: int
    low_stock_products: int
    out_of_stock_products: int
    total_stock_quantity: float


class StockSummaryCategoryResponse(BaseModel):
    category_id: str
    category_name: str
    product_count: int
    total_quantity: float
    total_sold_quantity: float
    total_historic_value: float | None
    total_current_inventory_cost: float
    total_min_sell_value: float
    total_default_sell_value: float
    quantity_by_unit: dict[str, float] = Field(default_factory=dict)
    wholesale_prices_by_unit: dict[str, list[float]] = Field(default_factory=dict)
    is_deleted_category: bool = False


class StockSummaryDetailResponse(BaseModel):
    categories: list[StockSummaryCategoryResponse]
    total_store_historic_value: float | None
    total_store_current_inventory_cost: float
    total_expected_profit: float


class StockMovementResponse(BaseModel):
    id: str
    product_id: str
    product_barcode: str | None = None
    product_name: str
    movement_type: str
    quantity_change: float
    unit_cost: float
    line_total: float
    running_stock: float
    reference_type: str | None
    reference_id: str | None
    reference_line_id: str | None = None
    notes: str | None
    user_id: str | None
    created_at: datetime
    source_description: str | None = None
    correction_quantity: float | None = None
    old_unit_cost: float | None = None
    new_unit_cost: float | None = None
    value_difference: float | None = None
    correction_user: str | None = None


class FifoCostCorrectionCreate(BaseModel):
    model_config = ConfigDict(extra="forbid")

    layer_id: str
    new_unit_cost: float = Field(ge=0, allow_inf_nan=False)


class FifoInventoryLayerResponse(BaseModel):
    layer_id: str
    source_movement_id: str
    acquisition_date: datetime
    acquisition_reference: str
    original_unit_cost: float
    current_unit_cost: float
    remaining_quantity: float
    correction_old_unit_cost: float | None = None
    correction_new_unit_cost: float | None = None
    correction_created_at: datetime | None = None


class FifoCostCorrectionResponse(BaseModel):
    correction_id: str
    product_id: str
    source_layer_id: str
    resulting_layer_id: str
    source_reference: str
    quantity: float
    old_unit_cost: float
    new_unit_cost: float
    value_difference: float
    reason: str
    posted_by: str
    created_at: datetime


class StockAdjustmentLineCreate(BaseModel):
    product_id: str
    unit: str = "piece"
    counted_quantity: float = Field(ge=0)
    unit_cost: float = Field(default=0, ge=0)
    operation: str | None = None


class StockAdjustmentCreate(BaseModel):
    idempotency_key: str
    adjustment_date: datetime | None = None
    reason: str
    notes: str | None = None
    lines: list[StockAdjustmentLineCreate] = Field(min_length=1)


class StockAdjustmentLineResponse(BaseModel):
    id: str
    document_id: str
    product_id: str
    product_name: str
    product_barcode: str | None = None
    unit: str
    current_quantity: float
    counted_quantity: float
    quantity_change: float
    unit_cost: float
    line_total: float
    running_stock: float
    created_at: datetime


class StockAdjustmentResponse(BaseModel):
    document_id: str
    reference_number: str
    idempotency_key: str
    adjustment_date: datetime
    reason: str
    notes: str | None
    posted_at: datetime
    posted_by: str
    lines: list[StockAdjustmentLineResponse]
    product: ProductResponse


class SaleItemCreate(BaseModel):
    product_id: str
    quantity: Decimal = Field(gt=0)
    unit: str = "piece"
    unit_price: Decimal | None = Field(default=None, ge=0)


class SaleCreate(BaseModel):
    idempotency_key: str
    payment_method: str
    customer_id: str | None = None
    discount: Decimal = Field(default=Decimal("0"), ge=0)
    paid_amount: Decimal | None = Field(default=None, ge=0)
    items: list[SaleItemCreate] = Field(min_length=1)


class PurchaseLineCreate(BaseModel):
    product_id: str
    quantity: Decimal = Field(gt=0, allow_inf_nan=False)
    unit_cost: Decimal = Field(ge=0, allow_inf_nan=False)
    selling_unit_id: str | None = None


class PurchaseCreate(BaseModel):
    idempotency_key: str = Field(min_length=1, max_length=255)
    reference: str = Field(min_length=1, max_length=100)
    supplier_id: str
    purchase_date: datetime
    notes: str | None = None
    lines: list[PurchaseLineCreate] = Field(min_length=1)


class PurchaseLineResponse(BaseModel):
    id: str
    product_id: str
    quantity: Decimal
    unit_cost: Decimal
    line_total: Decimal
    selling_unit_id: str | None
    selling_quantity: Decimal | None
    conversion_factor: Decimal
    selling_unit_name: str
    base_unit: str


class PurchaseResponse(BaseModel):
    id: str
    shop_id: str
    reference: str
    supplier_id: str
    purchase_date: datetime
    notes: str | None
    subtotal: Decimal
    total: Decimal
    status: str
    created_by: str
    created_at: datetime
    items: list[PurchaseLineResponse]


class PurchaseListResponse(BaseModel):
    items: list[PurchaseResponse]
    total: int


class SaleItemResponse(BaseModel):
    id: str
    product_id: str
    unit: str
    quantity: Decimal
    base_quantity: Decimal
    unit_price: Decimal
    line_total: Decimal
    historical_cost: Decimal | None = None
    historical_cost_available: bool = False
    refunded_quantity: Decimal = Decimal("0")
    exchanged_quantity: Decimal = Decimal("0")


class SaleResponse(BaseModel):
    sale_id: str
    shop_id: str
    status: str
    document_reference: str
    customer_id: str | None
    payment_method: str
    subtotal: Decimal
    discount: Decimal
    total: Decimal
    payment_result: Decimal
    remaining_amount: Decimal
    stock_posting_reference: str
    posted_at: datetime
    posted_by: str
    posted_by_name: str | None = None
    items: list[SaleItemResponse]
    is_refund: bool = False
    original_sale_id: str | None = None
    refunded_total: Decimal = Decimal("0")


class SaleListResponse(BaseModel):
    items: list[SaleResponse]
    total: int
    page: int
    page_size: int


class RefundLineCreate(BaseModel):
    sale_item_id: str | None = None
    product_id: str | None = None
    quantity: Decimal = Field(gt=0)


class RefundCreate(BaseModel):
    idempotency_key: str
    items: list[RefundLineCreate] = Field(min_length=1, validation_alias=AliasChoices("items", "lines"))
    payment_method: str | None = None


class RefundResponse(BaseModel):
    refund_id: str
    sale_id: str
    amount: Decimal
    payment_method: str
    posted_at: datetime


class ExchangeLineCreate(BaseModel):
    sale_item_id: str | None = None
    original_sale_item_id: str | None = None
    product_id: str | None = None
    replacement_product_id: str
    returned_quantity: Decimal = Field(gt=0)
    replacement_quantity: Decimal = Field(gt=0)
    replacement_unit: str | None = None


class ExchangeCreate(BaseModel):
    idempotency_key: str
    items: list[ExchangeLineCreate] = Field(min_length=1, validation_alias=AliasChoices("items", "lines"))
    payment_method: str | None = None
    customer_id: str | None = None


class ExchangeResponse(BaseModel):
    exchange_id: str
    sale_id: str
    replacement_sale_id: str = ""
    replacement_document_reference: str = ""
    difference_amount: Decimal
    payment_method: str
    posted_at: datetime


class SaleDraftCreate(BaseModel):
    id: str | None = None
    customer_id: str | None = None
    customer_name: str | None = None
    visibility: Literal["PRIVATE", "SHARED"] = "PRIVATE"
    payment_method: str = "cash"
    discount: Decimal = Field(default=Decimal("0"), ge=0)
    paid_amount: Decimal | None = Field(default=None, ge=0)


class SaleDraftItemCreate(BaseModel):
    product_id: str
    quantity: Decimal = Field(gt=0)
    unit: str = "piece"
    icon_key: str | None = None
    unit_price: Decimal | None = Field(default=None, ge=0)
    expected_version: int | None = Field(default=None, ge=0)
    version: int | None = Field(default=None, ge=0)


class SaleDraftItemUpdate(BaseModel):
    quantity: Decimal | None = Field(default=None, gt=0)
    unit: str | None = None
    unit_price: Decimal | None = Field(default=None, ge=0)
    expected_version: int | None = Field(default=None, ge=0)
    version: int | None = Field(default=None, ge=0)


class SaleDraftMutation(BaseModel):
    expected_version: int | None = Field(default=None, ge=0)
    version: int | None = Field(default=None, ge=0)


class SaleDraftUpdate(BaseModel):
    items: list[SaleDraftItemCreate] = Field(default_factory=list)
    customer_id: str | None = None
    customer_name: str | None = None
    visibility: Literal["PRIVATE", "SHARED"] | None = None
    payment_method: str | None = None
    discount: Decimal | None = Field(default=None, ge=0)
    paid_amount: Decimal | None = Field(default=None, ge=0)
    expected_version: int | None = Field(default=None, ge=0)
    version: int | None = Field(default=None, ge=0)


class SaleDraftCheckout(BaseModel):
    idempotency_key: str | None = None
    version: int | None = Field(default=None, ge=0)
    expected_version: int | None = Field(default=None, ge=0)
    payment_method: str | None = None
    customer_id: str | None = None
    discount: Decimal | None = Field(default=None, ge=0)
    paid_amount: Decimal | None = Field(default=None, ge=0)


class SaleDraftItemResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    product_id: str
    code: str | None = None
    barcode: str | None = None
    unit: str
    icon_key: str | None
    selling_unit_id: str | None = None
    quantity: Decimal
    base_quantity: Decimal | None = None
    conversion_factor: Decimal | None = None
    unit_price: Decimal | None
    stock: Decimal | None = None
    name: str | None = None


class SaleDraftResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    sale_number: int
    shop_id: str
    owner_id: str
    owner_name: str | None = None
    visibility: str
    status: str
    version: int
    customer_id: str | None
    customer_name: str | None
    payment_method: str
    discount: Decimal
    paid_amount: Decimal | None
    checkout_sale_id: str | None
    created_at: datetime
    updated_at: datetime
    items: list[SaleDraftItemResponse]


class SaleDraftListResponse(BaseModel):
    drafts: list[SaleDraftResponse]
