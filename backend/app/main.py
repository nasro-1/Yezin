import asyncio
import logging
from datetime import date, datetime, time, timedelta, timezone
from decimal import Decimal
import json
import jwt
from uuid import uuid4

from fastapi import (
    Depends,
    FastAPI,
    Header,
    HTTPException,
    Query,
    WebSocket,
    WebSocketDisconnect,
    status,
)
from fastapi.middleware.cors import CORSMiddleware
from sqlalchemy import and_, func, or_, select, update
from sqlalchemy.exc import IntegrityError, SQLAlchemyError
from sqlalchemy.orm import Session, joinedload, selectinload

from app.config import settings
from app.database import get_db
from app.fifo_inventory import FifoInventoryCostingService, InventoryMovement
from app.models import (
    Category,
    FifoCostCorrection,
    OpeningStockDocument,
    OpeningStockLine,
    InventoryLotRecord,
    Product,
    ProductSellingUnit,
    StockMovement,
    StockAdjustmentDocument,
    StockAdjustmentLine,
    User,
    IdempotencyRecord,
    RevokedToken,
    RefundDocument, RefundItem, ExchangeDocument, ExchangeItem, SaleDocument, SaleItem,
    SaleItemFifoAllocation, SaleItemFifoRestoration, SaleDraft, SaleDraftItem,
    Supplier, SupplierLedger, PurchaseDocument, PurchaseLine,
)
from app.schemas import (
    HealthResponse,
    LoginRequest,
    LoginResponse,
    ProductCreate,
    ProductListResponse,
    ProductResponse,
    ProductUpdate,
    OpeningStockLineCreate,
    CategoryResponse,
    CategoryCreate,
    StockSummaryResponse,
    StockSummaryDetailResponse, StockSummaryCategoryResponse,
    StockMovementResponse,
    StockAdjustmentCreate,
    StockAdjustmentLineResponse,
    StockAdjustmentResponse,
    UserCreate,
    UserResponse,
    UserUpdate,
    VersionResponse,
    SaleCreate, SaleResponse, SaleItemResponse, SaleListResponse, SaleDraftCreate, SaleDraftItemCreate,
    SaleDraftItemUpdate, SaleDraftMutation, SaleDraftCheckout, SaleDraftResponse,
    SaleDraftUpdate, SaleDraftListResponse,
    SellingUnitResponse,
    RefundCreate, RefundResponse, ExchangeCreate, ExchangeResponse,
    FifoCostCorrectionCreate, FifoCostCorrectionResponse,
    FifoInventoryLayerResponse,
    SupplierCreate, SupplierUpdate, SupplierResponse, SupplierListResponse,
    SupplierLedgerResponse, PurchaseCreate, PurchaseResponse,
    PurchaseListResponse, SupplierPaymentCreate, SupplierPaymentResponse,
    SupplierReturnCreate, SupplierReturnResponse,
)
from app.security import create_access_token, get_current_user, hash_password, verify_password
from app.security import get_server_context, oauth2_scheme
from app.context import Permission, ServerContext, require_permission
from app.transactions import request_hash
from app.finance import multiply_amount
from app.transactions import atomic_command
from app.sales_service import post_sale, sqlite_write_lock
from app.returns_service import post_refund, post_exchange
from app.purchase_service import (
    create_supplier,
    post_purchase,
    purchase_response,
    supplier_balance,
    supplier_response,
    update_supplier,
)
from app.supplier_payment_service import post_supplier_payment
from app.supplier_return_service import post_supplier_return


app = FastAPI(title="Yezin Backend", version=settings.api_version)
logger = logging.getLogger(__name__)


def _selling_unit_icon_key(name: str, icon_key: str | None = None) -> str:
    if icon_key and icon_key.strip():
        return icon_key.strip().lower()
    return {
        "piece": "package",
        "box": "box",
        "bottle": "bottle",
        "can": "can",
        "pack": "pack",
        "carton": "carton",
    }.get(name.strip().lower(), "package")
app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.cors_origin_list,
    allow_credentials=settings.cors_origins != "*",
    allow_methods=["GET", "POST", "DELETE", "OPTIONS"],
    allow_headers=["Authorization", "Content-Type", "Idempotency-Key"],
)


class DraftConnectionManager:
    """Keep draft event sockets tenant and owner scoped."""

    def __init__(self) -> None:
        self._connections: dict[tuple[str, str], set[WebSocket]] = {}
        self._loops: dict[WebSocket, asyncio.AbstractEventLoop] = {}

    async def connect(self, websocket: WebSocket, shop_id: str, owner_id: str) -> None:
        await websocket.accept()
        key = (shop_id, owner_id)
        self._connections.setdefault(key, set()).add(websocket)
        self._loops[websocket] = asyncio.get_running_loop()

    def disconnect(self, websocket: WebSocket, shop_id: str, owner_id: str) -> None:
        key = (shop_id, owner_id)
        sockets = self._connections.get(key)
        if sockets:
            sockets.discard(websocket)
            if not sockets:
                self._connections.pop(key, None)
        self._loops.pop(websocket, None)

    async def _broadcast(
        self, shop_id: str, owner_id: str, event: dict[str, object]
    ) -> None:
        sockets = list(self._connections.get((shop_id, owner_id), set()))
        for websocket in sockets:
            try:
                await websocket.send_json(event)
            except Exception:
                self.disconnect(websocket, shop_id, owner_id)

    def publish(self, shop_id: str, owner_id: str, event: dict[str, object]) -> None:
        for websocket in list(self._connections.get((shop_id, owner_id), set())):
            loop = self._loops.get(websocket)
            if loop is not None and not loop.is_closed():
                asyncio.run_coroutine_threadsafe(
                    self._broadcast(shop_id, owner_id, event), loop
                )

    def publish_to_users(
        self, shop_id: str, user_ids: set[str], event: dict[str, object]
    ) -> None:
        for owner_id in user_ids:
            self.publish(shop_id, owner_id, event)


draft_events = DraftConnectionManager()


def product_query(shop_id: str):
    return (
        select(Product)
        .options(joinedload(Product.selling_units), joinedload(Product.category))
        .where(Product.shop_id == shop_id)
    )


def product_response(
    product: Product,
) -> ProductResponse:
    return ProductResponse(
        id=product.id,
        name=product.name,
        code=product.code,
        barcode=product.barcode,
        internal_reference=product.internal_reference,
        product_type=product.product_type,
        base_unit=product.base_unit,
        quantity_precision=product.quantity_precision,
        allow_partial_package_sale=product.allow_partial_package_sale,
        price=product.price,
        min_price=product.min_price,
        wholesale_price=product.wholesale_price,
        cost=product.cost,
        stock=product.stock,
        min_stock=product.min_stock,
        category_id=product.category_id,
        category_name=product.category.name if product.category else None,
        image_path=product.image_path,
        is_active=product.is_active,
        matched_selling_unit_id=None,
        matched_selling_unit_name=None,
        selling_units=[
            SellingUnitResponse(
                id=unit.id,
                name=unit.name,
                icon_key=_selling_unit_icon_key(unit.name, unit.icon_key),
                conversion_to_base=unit.conversion_to_base,
                selling_price=unit.selling_price,
                cost_price=unit.cost_price,
                wholesale_price=unit.wholesale_price,
                minimum_stock=unit.minimum_stock,
                barcode=None,
                is_default=unit.is_default,
                is_active=unit.is_active,
            )
            for unit in product.selling_units
            if unit.is_active
        ],
    )


def _normalize_barcode(value: str | None) -> str | None:
    normalized = value.strip() if value is not None else ""
    return normalized or None


def _barcode_exists(
    db: Session,
    shop_id: str,
    barcode: str,
    *,
    exclude_product_id: str | None = None,
) -> bool:
    query = select(Product.id).where(
        Product.shop_id == shop_id,
        Product.is_active.is_(True),
        func.trim(Product.barcode) == barcode,
    )
    if exclude_product_id is not None:
        query = query.where(Product.id != exclude_product_id)
    return db.scalar(query.limit(1)) is not None


def _product_has_history(db: Session, product_id: str) -> bool:
    for model, column in (
        (SaleItem, SaleItem.product_id),
        (StockMovement, StockMovement.product_id),
        (OpeningStockLine, OpeningStockLine.product_id),
        (StockAdjustmentLine, StockAdjustmentLine.product_id),
        (RefundItem, RefundItem.sale_item_id),
        (ExchangeItem, ExchangeItem.replacement_product_id),
    ):
        if model is RefundItem:
            exists = db.scalar(
                select(RefundItem.id)
                .join(SaleItem, SaleItem.id == RefundItem.sale_item_id)
                .where(SaleItem.product_id == product_id)
                .limit(1)
            )
        elif model is ExchangeItem:
            exists = db.scalar(
                select(ExchangeItem.id)
                .where(ExchangeItem.replacement_product_id == product_id)
                .limit(1)
            )
        else:
            exists = db.scalar(select(model.id).where(column == product_id).limit(1))
        if exists is not None:
            return True
    return False


def _unit_conversion(
    db: Session,
    product: Product,
    unit_name: str | None,
) -> tuple[str, float]:
    name = (unit_name or product.base_unit).strip()
    if name == product.base_unit:
        return name, 1.0
    pending_unit = next(
        (
            unit
            for unit in product.selling_units
            if unit.is_active and unit.name == name
        ),
        None,
    )
    if pending_unit is not None:
        return pending_unit.name, pending_unit.conversion_to_base
    if product.product_type.upper() == "PACKAGED":
        preset_conversions = {"pack": 30.0, "box": 360.0}
        preset_conversion = preset_conversions.get(name.lower())
        if preset_conversion is not None:
            return name, preset_conversion
    unit = db.scalar(
        select(ProductSellingUnit).where(
            ProductSellingUnit.product_id == product.id,
            ProductSellingUnit.name == name,
            ProductSellingUnit.is_active.is_(True),
        )
    )
    if unit is None:
        raise HTTPException(status_code=422, detail=f"Unit {name} is not valid for product {product.id}")
    return unit.name, unit.conversion_to_base


def _require_catalog_manager(user: User) -> None:
    try:
        require_permission(ServerContext.from_user(user), Permission.MANAGE_CATALOG)
    except PermissionError as error:
        raise HTTPException(status_code=403, detail=str(error)) from error


def _require_permission(context: ServerContext, permission: Permission) -> None:
    try:
        require_permission(context, permission)
    except PermissionError as error:
        raise HTTPException(status_code=403, detail=str(error)) from error


def _sale_response(
    db: Session, sale: SaleDocument, items: list[SaleItem]
) -> SaleResponse:
    from app.sales_service import _response
    return _response(sale, items, db)


@app.post("/api/v1/sales", response_model=SaleResponse, status_code=201)
def create_sale(
    payload: SaleCreate,
    db: Session = Depends(get_db),
    context: ServerContext = Depends(get_server_context),
) -> SaleResponse:
    try:
        require_permission(context, Permission.POST_SALE)
    except PermissionError as error:
        raise HTTPException(status_code=403, detail=str(error)) from error
    key = payload.idempotency_key.strip()
    if not key:
        raise HTTPException(status_code=422, detail="Idempotency key is required")
    payload_hash = request_hash(payload.model_dump(mode="json"))
    with sqlite_write_lock:
        existing = db.scalar(select(IdempotencyRecord).where(
            IdempotencyRecord.shop_id == context.shop_id,
            IdempotencyRecord.idempotency_key == key,
        ))
        if existing:
            if existing.request_hash != payload_hash:
                raise HTTPException(status_code=409, detail="Idempotency key was already used with a different request")
            return SaleResponse.model_validate(json.loads(existing.response_json))
        try:
            with atomic_command(db):
                response = post_sale(db, payload, context.shop_id, context.user_id, context.device_id)
                db.add(IdempotencyRecord(
                    id=f"idempotency-{uuid4().hex}", shop_id=context.shop_id,
                    idempotency_key=key, request_hash=payload_hash,
                    response_json=response.model_dump_json(), status_code=201,
                    device_id=context.device_id,
                ))
            return response
        except ValueError as error:
            code = 409 if "Insufficient stock" in str(error) else 422
            raise HTTPException(status_code=code, detail=str(error)) from error


@app.post("/api/v1/sales/{sale_id}/refund", response_model=RefundResponse, status_code=201)
def refund_sale(
    sale_id: str, payload: RefundCreate, db: Session = Depends(get_db),
    context: ServerContext = Depends(get_server_context),
) -> RefundResponse:
    try:
        require_permission(context, Permission.POST_REFUND)
    except PermissionError as error:
        raise HTTPException(status_code=403, detail=str(error)) from error
    key = payload.idempotency_key.strip()
    if not key:
        raise HTTPException(status_code=422, detail="Idempotency key is required")
    payload_hash = request_hash({"sale_id": sale_id, **payload.model_dump(mode="json")})
    with sqlite_write_lock:
        existing = db.scalar(select(IdempotencyRecord).where(
            IdempotencyRecord.shop_id == context.shop_id, IdempotencyRecord.idempotency_key == key))
        if existing:
            if existing.request_hash != payload_hash:
                raise HTTPException(status_code=409, detail="Idempotency key was already used with a different request")
            return RefundResponse.model_validate(json.loads(existing.response_json))
        try:
            with atomic_command(db):
                first = payload.items[0]
                sale_item = db.scalar(select(SaleItem).where(SaleItem.id == first.sale_item_id))
                if sale_item is None or db.scalar(select(SaleDocument).where(
                        SaleDocument.id == sale_item.sale_id, SaleDocument.id == sale_id,
                        SaleDocument.shop_id == context.shop_id)) is None:
                    raise ValueError("Sale not found")
                response = post_refund(db, payload, context.shop_id, context.user_id)
                db.add(IdempotencyRecord(id=f"idempotency-{uuid4().hex}", shop_id=context.shop_id,
                    idempotency_key=key, request_hash=payload_hash, response_json=response.model_dump_json(),
                    status_code=201, device_id=context.device_id))
            return response
        except ValueError as error:
            code = 404 if str(error) == "Sale not found" else 409
            raise HTTPException(status_code=code, detail=str(error)) from error


@app.post("/api/v1/sales/{sale_id}/exchange", response_model=ExchangeResponse, status_code=201)
def exchange_sale(
    sale_id: str, payload: ExchangeCreate, db: Session = Depends(get_db),
    context: ServerContext = Depends(get_server_context),
) -> ExchangeResponse:
    try:
        require_permission(context, Permission.POST_EXCHANGE)
    except PermissionError as error:
        raise HTTPException(status_code=403, detail=str(error)) from error
    key = payload.idempotency_key.strip()
    if not key:
        raise HTTPException(status_code=422, detail="Idempotency key is required")
    payload_hash = request_hash({"sale_id": sale_id, **payload.model_dump(mode="json")})
    with sqlite_write_lock:
        existing = db.scalar(select(IdempotencyRecord).where(
            IdempotencyRecord.shop_id == context.shop_id, IdempotencyRecord.idempotency_key == key))
        if existing:
            if existing.request_hash != payload_hash:
                raise HTTPException(status_code=409, detail="Idempotency key was already used with a different request")
            return ExchangeResponse.model_validate(json.loads(existing.response_json))
        try:
            with atomic_command(db):
                response = post_exchange(db, payload, sale_id, context.shop_id, context.user_id)
                db.add(IdempotencyRecord(id=f"idempotency-{uuid4().hex}", shop_id=context.shop_id,
                    idempotency_key=key, request_hash=payload_hash, response_json=response.model_dump_json(),
                    status_code=201, device_id=context.device_id))
            return response
        except ValueError as error:
            code = 404 if str(error) == "Sale not found" else (409 if "stock" in str(error).lower() or "exceeds" in str(error).lower() else 422)
            raise HTTPException(status_code=code, detail=str(error)) from error


def _draft_access_filter(context: ServerContext):
    if context.role == "admin":
        return SaleDraft.shop_id == context.shop_id
    return and_(
        SaleDraft.shop_id == context.shop_id,
        or_(
            SaleDraft.owner_id == context.user_id,
            SaleDraft.visibility == "SHARED",
        ),
    )


def _draft_query(db: Session, draft_id: str, context: ServerContext):
    return db.scalar(
        select(SaleDraft)
        .options(
            selectinload(SaleDraft.owner),
            selectinload(SaleDraft.items).selectinload(SaleDraftItem.product),
        )
        .where(SaleDraft.id == draft_id)
        .where(_draft_access_filter(context))
    )


def _draft_response(draft: SaleDraft) -> SaleDraftResponse:
    return SaleDraftResponse(
        id=draft.id,
        sale_number=draft.sale_number,
        shop_id=draft.shop_id,
        owner_id=draft.owner_id,
        owner_name=draft.owner.display_name if draft.owner is not None else None,
        visibility=draft.visibility,
        status=draft.status,
        version=draft.version,
        customer_id=draft.customer_id,
        customer_name=draft.customer_name,
        payment_method=draft.payment_method,
        discount=Decimal(str(draft.discount)),
        paid_amount=Decimal(str(draft.paid_amount)) if draft.paid_amount is not None else None,
        checkout_sale_id=draft.checkout_sale_id,
        created_at=draft.created_at,
        updated_at=draft.updated_at,
        items=[
            {
                "id": item.id,
                "product_id": item.product_id,
                "code": item.product.code if item.product is not None else None,
                "barcode": item.product.barcode if item.product is not None else None,
                "unit": item.unit,
                "selling_unit_id": next(
                    (
                        unit.id
                        for unit in (item.product.selling_units if item.product else [])
                        if unit.is_active and unit.name.strip().lower() == item.unit.strip().lower()
                    ),
                    None,
                ),
                "icon_key": item.icon_key,
                "quantity": Decimal(str(item.quantity)),
                "base_quantity": Decimal(str(item.quantity))
                * Decimal(
                    str(
                        next(
                            (
                                unit.conversion_to_base
                                for unit in (item.product.selling_units if item.product else [])
                                if unit.is_active
                                and unit.name.strip().lower() == item.unit.strip().lower()
                            ),
                            1,
                        )
                    )
                ),
                "conversion_factor": next(
                    (
                        Decimal(str(unit.conversion_to_base))
                        for unit in (item.product.selling_units if item.product else [])
                        if unit.is_active
                        and unit.name.strip().lower() == item.unit.strip().lower()
                    ),
                    Decimal("1"),
                ),
                "unit_price": (
                    Decimal(str(item.unit_price))
                    if item.unit_price is not None
                    else None
                ),
                "stock": (
                    Decimal(str(item.product.stock))
                    if item.product is not None
                    else None
                ),
                "name": item.product.name if item.product is not None else None,
            }
            for item in draft.items
        ],
    )


def _draft_or_404(db: Session, draft_id: str, context: ServerContext) -> SaleDraft:
    draft = _draft_query(db, draft_id, context)
    if draft is None:
        raise HTTPException(status_code=404, detail="Sale draft not found")
    return draft


def _checkout_draft_or_404(
    db: Session, draft_id: str, context: ServerContext
) -> SaleDraft:
    if context.role == "manager":
        draft = db.scalar(
            select(SaleDraft)
            .options(
                selectinload(SaleDraft.owner),
                selectinload(SaleDraft.items).selectinload(SaleDraftItem.product),
            )
            .where(
                SaleDraft.id == draft_id,
                SaleDraft.shop_id == context.shop_id,
            )
        )
        if draft is None:
            raise HTTPException(status_code=404, detail="Sale draft not found")
        return draft
    return _draft_or_404(db, draft_id, context)


def _check_draft_version(draft: SaleDraft, expected_version: int | None) -> None:
    if expected_version is not None and expected_version != draft.version:
        raise HTTPException(
            status_code=409,
            detail={
                "message": "Sale draft version conflict",
                "current_version": draft.version,
            },
        )


def _require_draft_checkout_access(
    draft: SaleDraft, context: ServerContext
) -> None:
    if draft.shop_id != context.shop_id:
        raise HTTPException(status_code=404, detail="Sale draft not found")
    if context.role == "admin":
        return
    if context.role == "manager":
        return
    if draft.visibility == "PRIVATE" and (
        draft.owner_id == context.user_id and context.role == "cashier"
    ):
        return
    if draft.visibility == "SHARED" and context.role in {"cashier", "manager"}:
        return
    raise HTTPException(status_code=403, detail="You cannot checkout this sale draft")


def _draft_item_product(
    db: Session, draft: SaleDraft, product_id: str, unit: str
) -> Product:
    product = db.scalar(
        select(Product).where(
            Product.id == product_id,
            Product.shop_id == draft.shop_id,
            Product.is_active.is_(True),
        )
    )
    if product is None:
        raise ValueError("Product not found")
    unit_name = unit.strip()
    if not unit_name:
        raise ValueError("Unit is required")
    if unit_name != product.base_unit:
        unit_row = db.scalar(
            select(ProductSellingUnit).where(
                ProductSellingUnit.product_id == product.id,
                ProductSellingUnit.name == unit_name,
                ProductSellingUnit.is_active.is_(True),
            )
        )
        if unit_row is None:
            raise ValueError(f"Unit {unit_name} is not valid for product {product.id}")
    return product


def _draft_unit_price(
    db: Session, product: Product, unit: str, requested: Decimal | None
) -> Decimal:
    if requested is not None:
        return requested
    if unit.strip() == product.base_unit:
        return Decimal(str(product.price))
    unit_row = db.scalar(
        select(ProductSellingUnit).where(
            ProductSellingUnit.product_id == product.id,
            ProductSellingUnit.name == unit.strip(),
            ProductSellingUnit.is_active.is_(True),
        )
    )
    return Decimal(str(unit_row.selling_price if unit_row is not None else product.price))


def _draft_event(draft: SaleDraft, action: str) -> dict[str, object]:
    return {
        "type": "sale_draft.updated",
        "action": action,
        "draft_id": draft.id,
        "status": draft.status,
        "version": draft.version,
        "visibility": draft.visibility,
        "owner_id": draft.owner_id,
    }


def _draft_event_recipients(db: Session, draft: SaleDraft, context: ServerContext) -> set[str]:
    role_filter = User.shop_id == draft.shop_id
    if draft.visibility == "SHARED":
        recipients = db.scalars(
            select(User.id).where(
                role_filter,
                User.is_active.is_(True),
                or_(
                    User.id == draft.owner_id,
                    User.role == "admin",
                    User.role.in_({"cashier", "manager"}),
                ),
            )
        ).all()
        return set(recipients)

    recipients = db.scalars(
        select(User.id).where(
            role_filter,
            User.is_active.is_(True),
            or_(User.id == draft.owner_id, User.role == "admin"),
        )
    ).all()
    return set(recipients)


@app.get("/api/v1/sales/drafts", response_model=SaleDraftListResponse)
def list_sale_drafts(
    draft_status: str | None = Query(default=None, alias="status"),
    include_held: bool = Query(default=True),
    db: Session = Depends(get_db),
    context: ServerContext = Depends(get_server_context),
) -> list[SaleDraftResponse]:
    query = (
        select(SaleDraft)
        .options(
            selectinload(SaleDraft.owner),
            selectinload(SaleDraft.items).selectinload(SaleDraftItem.product),
        )
        .where(_draft_access_filter(context))
        .order_by(SaleDraft.updated_at.desc(), SaleDraft.created_at.desc())
    )
    if draft_status:
        query = query.where(SaleDraft.status == draft_status.strip().upper())
    elif include_held:
        query = query.where(SaleDraft.status.in_({"OPEN", "HELD"}))
    else:
        query = query.where(SaleDraft.status == "OPEN")
    return SaleDraftListResponse(
        drafts=[_draft_response(draft) for draft in db.scalars(query).all()]
    )


@app.post("/api/v1/sales/drafts", response_model=SaleDraftResponse, status_code=201)
def create_sale_draft(
    payload: SaleDraftCreate,
    db: Session = Depends(get_db),
    context: ServerContext = Depends(get_server_context),
) -> SaleDraftResponse:
    payment_method = payload.payment_method.strip().lower()
    if payment_method not in {"cash", "credit"}:
        raise HTTPException(status_code=422, detail="Payment method must be cash or credit")
    if payload.discount < 0:
        raise HTTPException(status_code=422, detail="Discount cannot be negative")
    visibility = "PRIVATE"
    with sqlite_write_lock:
        try:
            with atomic_command(db):
                draft = SaleDraft(
                    id=payload.id or f"draft-{uuid4().hex}",
                    shop_id=context.shop_id,
                    owner_id=context.user_id,
                    visibility=visibility,
                    sale_number=(db.scalar(
                        select(func.max(SaleDraft.sale_number)).where(
                            SaleDraft.shop_id == context.shop_id
                        )
                    ) or 0) + 1,
                    status="OPEN",
                    version=0,
                    customer_id=payload.customer_id,
                    customer_name=payload.customer_name,
                    payment_method=payment_method,
                    discount=payload.discount.quantize(Decimal("0.01")),
                    paid_amount=payload.paid_amount,
                )
                db.add(draft)
                db.flush()
                db.refresh(draft)
            response = _draft_response(draft)
        except IntegrityError as error:
            raise HTTPException(status_code=409, detail="Sale draft already exists") from error
    draft_events.publish_to_users(
        context.shop_id,
        _draft_event_recipients(db, draft, context),
        _draft_event(draft, "created"),
    )
    return response


@app.get("/api/v1/sales/drafts/{draft_id}", response_model=SaleDraftResponse)
def get_sale_draft(
    draft_id: str,
    db: Session = Depends(get_db),
    context: ServerContext = Depends(get_server_context),
) -> SaleDraftResponse:
    return _draft_response(_draft_or_404(db, draft_id, context))


@app.put("/api/v1/sales/drafts/{draft_id}", response_model=SaleDraftResponse)
def replace_sale_draft(
    draft_id: str,
    payload: SaleDraftUpdate,
    if_match: str | None = Header(default=None, alias="If-Match"),
    db: Session = Depends(get_db),
    context: ServerContext = Depends(get_server_context),
) -> SaleDraftResponse:
    expected = payload.expected_version
    if expected is None:
        expected = payload.version
    if expected is None and if_match:
        try:
            expected = int(if_match.strip().strip('"'))
        except ValueError:
            raise HTTPException(status_code=400, detail="Invalid If-Match version")
    payment_method = (payload.payment_method or "cash").strip().lower()
    if payment_method not in {"cash", "credit"}:
        raise HTTPException(status_code=422, detail="Payment method must be cash or credit")
    if payload.visibility is not None:
        visibility = payload.visibility.upper()
        if visibility not in {"PRIVATE", "SHARED"}:
            raise HTTPException(status_code=422, detail="Visibility must be PRIVATE or SHARED")
    with sqlite_write_lock:
        draft = _draft_or_404(db, draft_id, context)
        print(
            f"[API_DRAFT_TRACE] draft_id={draft_id} "
            f"incoming_item_count={len(payload.items)} "
            f"incoming_item_ids={[item.product_id for item in payload.items]} "
            f"version={expected}"
        )
        _check_draft_version(draft, expected)
        if payload.visibility is not None and payload.visibility.upper() != draft.visibility:
            if context.role != "admin" and context.user_id != draft.owner_id:
                raise HTTPException(
                    status_code=403,
                    detail="Only the draft owner or a shop admin can change visibility",
                )
        if draft.status not in {"OPEN", "HELD", "CLEARED"}:
            raise HTTPException(status_code=409, detail="Sale draft is no longer editable")
        product_ids: set[str] = set()
        try:
            replacement: list[SaleDraftItem] = []
            for request in payload.items:
                product = _draft_item_product(db, draft, request.product_id, request.unit)
                if request.product_id in product_ids:
                    raise ValueError("A product can only appear once in a sale draft")
                product_ids.add(request.product_id)
                replacement.append(
                    SaleDraftItem(
                        id=f"draft-item-{uuid4().hex}",
                        draft_id=draft.id,
                        product_id=request.product_id,
                        unit=request.unit.strip(),
                        icon_key=_selling_unit_icon_key(request.unit, request.icon_key),
                        quantity=request.quantity,
                        unit_price=_draft_unit_price(
                            db, product, request.unit, request.unit_price
                        ),
                    )
                )
            draft.status = "OPEN"
            if payload.customer_id is not None:
                draft.customer_id = payload.customer_id
                draft.customer_name = payload.customer_name
            if payload.visibility is not None:
                draft.visibility = visibility
            draft.payment_method = payment_method
            if payload.discount is not None:
                draft.discount = payload.discount.quantize(Decimal("0.01"))
            if payload.paid_amount is not None:
                draft.paid_amount = payload.paid_amount
            draft.version += 1
            draft.updated_at = datetime.utcnow()
            with atomic_command(db):
                # Flush orphan deletions before inserting replacement rows so
                # the draft's unique (draft_id, product_id) constraint holds.
                draft.items.clear()
                db.flush()
                draft.items.extend(replacement)
                db.flush()
            response = _draft_response(draft)
            print(
                f"[API_DRAFT_TRACE] draft_id={draft.id} stored_item_count="
                f"{len(draft.items)} stored_item_ids="
                f"{[item.product_id for item in draft.items]} version={draft.version}"
            )
        except ValueError as error:
            raise HTTPException(status_code=422, detail=str(error)) from error
    draft_events.publish_to_users(
        context.shop_id,
        _draft_event_recipients(db, draft, context),
        _draft_event(draft, "updated"),
    )
    return response


@app.post(
    "/api/v1/sales/drafts/{draft_id}/items",
    response_model=SaleDraftResponse,
    status_code=201,
)
def add_sale_draft_item(
    draft_id: str,
    payload: SaleDraftItemCreate,
    expected_version: int | None = Query(default=None),
    db: Session = Depends(get_db),
    context: ServerContext = Depends(get_server_context),
) -> SaleDraftResponse:
    with sqlite_write_lock:
        draft = _draft_or_404(db, draft_id, context)
        _check_draft_version(
            draft,
            (
                payload.expected_version
                if payload.expected_version is not None
                else payload.version
                if payload.version is not None
                else expected_version
            ),
        )
        if draft.status not in {"OPEN", "HELD", "CLEARED"}:
            raise HTTPException(status_code=409, detail="Sale draft is no longer editable")
        try:
            product = _draft_item_product(db, draft, payload.product_id, payload.unit)
            if any(item.product_id == payload.product_id for item in draft.items):
                raise ValueError("A product can only appear once in a sale draft")
            item = SaleDraftItem(
                id=f"draft-item-{uuid4().hex}",
                draft_id=draft.id,
                product_id=payload.product_id,
                unit=payload.unit.strip(),
                icon_key=_selling_unit_icon_key(payload.unit, payload.icon_key),
                quantity=payload.quantity,
                unit_price=_draft_unit_price(db, product, payload.unit, payload.unit_price),
            )
            draft.items.append(item)
            draft.status = "OPEN"
            draft.version += 1
            draft.updated_at = datetime.utcnow()
            with atomic_command(db):
                db.flush()
            response = _draft_response(draft)
        except ValueError as error:
            raise HTTPException(status_code=422, detail=str(error)) from error
        except IntegrityError as error:
            db.rollback()
            raise HTTPException(status_code=409, detail="Sale draft item already exists") from error
    draft_events.publish_to_users(
        context.shop_id,
        _draft_event_recipients(db, draft, context),
        _draft_event(draft, "item_added"),
    )
    return response


@app.patch(
    "/api/v1/sales/drafts/{draft_id}/items/{item_id}",
    response_model=SaleDraftResponse,
)
@app.put(
    "/api/v1/sales/drafts/{draft_id}/items/{item_id}",
    response_model=SaleDraftResponse,
)
def update_sale_draft_item(
    draft_id: str,
    item_id: str,
    payload: SaleDraftItemUpdate,
    expected_version: int | None = Query(default=None),
    db: Session = Depends(get_db),
    context: ServerContext = Depends(get_server_context),
) -> SaleDraftResponse:
    with sqlite_write_lock:
        draft = _draft_or_404(db, draft_id, context)
        _check_draft_version(
            draft,
            (
                payload.expected_version
                if payload.expected_version is not None
                else payload.version
                if payload.version is not None
                else expected_version
            ),
        )
        if draft.status not in {"OPEN", "HELD", "CLEARED"}:
            raise HTTPException(status_code=409, detail="Sale draft is no longer editable")
        item = next((value for value in draft.items if value.id == item_id), None)
        if item is None:
            raise HTTPException(status_code=404, detail="Sale draft item not found")
        try:
            if payload.unit is not None:
                product = _draft_item_product(db, draft, item.product_id, payload.unit)
                item.unit = payload.unit.strip()
                if payload.unit_price is None:
                    item.unit_price = _draft_unit_price(db, product, item.unit, None)
            if payload.quantity is not None:
                item.quantity = payload.quantity
            if payload.unit_price is not None:
                item.unit_price = payload.unit_price
            draft.status = "OPEN"
            draft.version += 1
            draft.updated_at = datetime.utcnow()
            with atomic_command(db):
                db.flush()
            response = _draft_response(draft)
        except ValueError as error:
            raise HTTPException(status_code=422, detail=str(error)) from error
    draft_events.publish_to_users(
        context.shop_id,
        _draft_event_recipients(db, draft, context),
        _draft_event(draft, "item_updated"),
    )
    return response


@app.delete(
    "/api/v1/sales/drafts/{draft_id}/items/{item_id}",
    response_model=SaleDraftResponse,
)
def delete_sale_draft_item(
    draft_id: str,
    item_id: str,
    expected_version: int | None = Query(default=None),
    if_match: str | None = Header(default=None, alias="If-Match"),
    db: Session = Depends(get_db),
    context: ServerContext = Depends(get_server_context),
) -> SaleDraftResponse:
    with sqlite_write_lock:
        draft = _draft_or_404(db, draft_id, context)
        if expected_version is None and if_match:
            try:
                expected_version = int(if_match.strip().strip('"'))
            except ValueError:
                raise HTTPException(status_code=400, detail="Invalid If-Match version")
        _check_draft_version(draft, expected_version)
        if draft.status not in {"OPEN", "HELD", "CLEARED"}:
            raise HTTPException(status_code=409, detail="Sale draft is no longer editable")
        item = next((value for value in draft.items if value.id == item_id), None)
        if item is None:
            raise HTTPException(status_code=404, detail="Sale draft item not found")
        draft.items.remove(item)
        draft.version += 1
        draft.updated_at = datetime.utcnow()
        with atomic_command(db):
            db.flush()
        response = _draft_response(draft)
    draft_events.publish_to_users(
        context.shop_id,
        _draft_event_recipients(db, draft, context),
        _draft_event(draft, "item_deleted"),
    )
    return response


@app.post("/api/v1/sales/drafts/{draft_id}/hold", response_model=SaleDraftResponse)
def hold_sale_draft(
    draft_id: str,
    payload: SaleDraftMutation | None = None,
    expected_version: int | None = Query(default=None),
    db: Session = Depends(get_db),
    context: ServerContext = Depends(get_server_context),
) -> SaleDraftResponse:
    with sqlite_write_lock:
        draft = _draft_or_404(db, draft_id, context)
        _check_draft_version(
            draft,
            (
                payload.expected_version
                if payload and payload.expected_version is not None
                else payload.version
                if payload and payload.version is not None
                else expected_version
            ),
        )
        if draft.status not in {"OPEN", "CLEARED"}:
            raise HTTPException(status_code=409, detail="Sale draft is not open")
        draft.status = "HELD"
        draft.version += 1
        draft.updated_at = datetime.utcnow()
        with atomic_command(db):
            db.flush()
        response = _draft_response(draft)
    draft_events.publish_to_users(
        context.shop_id,
        _draft_event_recipients(db, draft, context),
        _draft_event(draft, "held"),
    )
    return response


@app.post("/api/v1/sales/drafts/{draft_id}/resume", response_model=SaleDraftResponse)
def resume_sale_draft(
    draft_id: str,
    payload: SaleDraftMutation | None = None,
    expected_version: int | None = Query(default=None),
    db: Session = Depends(get_db),
    context: ServerContext = Depends(get_server_context),
) -> SaleDraftResponse:
    with sqlite_write_lock:
        draft = _draft_or_404(db, draft_id, context)
        _check_draft_version(
            draft,
            (
                payload.expected_version
                if payload and payload.expected_version is not None
                else payload.version
                if payload and payload.version is not None
                else expected_version
            ),
        )
        if draft.status not in {"HELD", "CLEARED"}:
            raise HTTPException(status_code=409, detail="Sale draft is not held")
        draft.status = "OPEN"
        draft.version += 1
        draft.updated_at = datetime.utcnow()
        with atomic_command(db):
            db.flush()
        response = _draft_response(draft)
    draft_events.publish_to_users(
        context.shop_id,
        _draft_event_recipients(db, draft, context),
        _draft_event(draft, "resumed"),
    )
    return response


@app.post("/api/v1/sales/drafts/{draft_id}/clear", response_model=SaleDraftResponse)
@app.delete("/api/v1/sales/drafts/{draft_id}", response_model=SaleDraftResponse)
def clear_sale_draft(
    draft_id: str,
    payload: SaleDraftMutation | None = None,
    expected_version: int | None = Query(default=None),
    if_match: str | None = Header(default=None, alias="If-Match"),
    db: Session = Depends(get_db),
    context: ServerContext = Depends(get_server_context),
) -> SaleDraftResponse:
    with sqlite_write_lock:
        draft = _draft_or_404(db, draft_id, context)
        if expected_version is None and if_match:
            try:
                expected_version = int(if_match.strip().strip('"'))
            except ValueError:
                raise HTTPException(status_code=400, detail="Invalid If-Match version")
        _check_draft_version(
            draft,
            (
                payload.expected_version
                if payload and payload.expected_version is not None
                else payload.version
                if payload and payload.version is not None
                else expected_version
            ),
        )
        if draft.status in {"CHECKED_OUT", "CLEARED"}:
            raise HTTPException(status_code=409, detail="Sale draft cannot be cleared")
        draft.items.clear()
        draft.status = "CLEARED"
        draft.version += 1
        draft.updated_at = datetime.utcnow()
        with atomic_command(db):
            db.flush()
        response = _draft_response(draft)
    draft_events.publish_to_users(
        context.shop_id,
        _draft_event_recipients(db, draft, context),
        _draft_event(draft, "cleared"),
    )
    return response


@app.post(
    "/api/v1/sales/drafts/{draft_id}/checkout",
    response_model=SaleResponse,
    status_code=201,
)
def checkout_sale_draft(
    draft_id: str,
    payload: SaleDraftCheckout,
    if_match: str | None = Header(default=None, alias="If-Match"),
    idempotency_header: str | None = Header(default=None, alias="Idempotency-Key"),
    db: Session = Depends(get_db),
    context: ServerContext = Depends(get_server_context),
) -> SaleResponse:
    key = (payload.idempotency_key or idempotency_header or "").strip()
    with sqlite_write_lock:
        draft = _checkout_draft_or_404(db, draft_id, context)
        _require_draft_checkout_access(draft, context)
        expected = payload.expected_version if payload.expected_version is not None else payload.version
        if expected is None and if_match:
            try:
                expected = int(if_match.strip().strip('"'))
            except ValueError:
                raise HTTPException(status_code=400, detail="Invalid If-Match version")
        if not key:
            # A version-scoped fallback keeps older clients idempotent while
            # callers that supply a key retain full retry control.
            key = f"draft:{draft.id}:version:{expected if expected is not None else draft.version}"
        request_hash_value = request_hash(payload.model_dump(mode="json"))
        existing = db.scalar(
            select(IdempotencyRecord).where(
                IdempotencyRecord.shop_id == context.shop_id,
                IdempotencyRecord.idempotency_key == key,
            )
        )
        if existing:
            if existing.request_hash != request_hash_value:
                raise HTTPException(
                    status_code=409,
                    detail="Idempotency key was already used with a different request",
                )
            return SaleResponse.model_validate(json.loads(existing.response_json))
        if draft.status not in {"OPEN", "HELD"}:
            raise HTTPException(status_code=409, detail="Sale draft is not ready for checkout")
        if not draft.items:
            raise HTTPException(status_code=422, detail="Sale draft has no items")
        if expected is None:
            expected = draft.version
        claim = db.execute(
            update(SaleDraft)
            .where(
                SaleDraft.id == draft.id,
                SaleDraft.shop_id == context.shop_id,
                SaleDraft.status.in_({"OPEN", "HELD"}),
                SaleDraft.version == expected,
            )
            .values(version=SaleDraft.version + 1)
        )
        if claim.rowcount != 1:
            db.rollback()
            existing = db.scalar(
                select(IdempotencyRecord).where(
                    IdempotencyRecord.shop_id == context.shop_id,
                    IdempotencyRecord.idempotency_key == key,
                )
            )
            if existing:
                if existing.request_hash != request_hash_value:
                    raise HTTPException(
                        status_code=409,
                        detail="Idempotency key was already used with a different request",
                    )
                return SaleResponse.model_validate(json.loads(existing.response_json))
            current_version = db.scalar(
                select(SaleDraft.version).where(
                    SaleDraft.id == draft.id,
                    SaleDraft.shop_id == context.shop_id,
                )
            )
            raise HTTPException(
                status_code=409,
                detail={
                    "message": "Sale draft version conflict",
                    "current_version": current_version,
                },
            )
        draft.version = expected + 1
        sale_payload = SaleCreate(
            idempotency_key=key,
            payment_method=(payload.payment_method or draft.payment_method),
            customer_id=(
                payload.customer_id if payload.customer_id is not None else draft.customer_id
            ),
            discount=payload.discount if payload.discount is not None else draft.discount,
            paid_amount=(
                payload.paid_amount
                if payload.paid_amount is not None
                else draft.paid_amount
            ),
            items=[
                {
                    "product_id": item.product_id,
                    "quantity": item.quantity,
                    "unit": item.unit,
                    "unit_price": item.unit_price,
                }
                for item in draft.items
            ],
        )
        payload_hash = request_hash_value
        try:
            with atomic_command(db):
                sale_response = post_sale(
                    db, sale_payload, context.shop_id, context.user_id, context.device_id
                )
                draft.status = "CHECKED_OUT"
                draft.checkout_sale_id = sale_response.sale_id
                draft.updated_at = datetime.utcnow()
                db.add(
                    IdempotencyRecord(
                        id=f"idempotency-{uuid4().hex}",
                        shop_id=context.shop_id,
                        idempotency_key=key,
                        request_hash=payload_hash,
                        response_json=sale_response.model_dump_json(),
                        status_code=201,
                        device_id=context.device_id,
                    )
                )
            draft_event = _draft_event(draft, "checked_out")
        except ValueError as error:
            code = 409 if "Insufficient stock" in str(error) else 422
            raise HTTPException(status_code=code, detail=str(error)) from error
        except IntegrityError as error:
            raise HTTPException(status_code=409, detail="Idempotency key was already used") from error
    draft_events.publish_to_users(
        context.shop_id,
        _draft_event_recipients(db, draft, context),
        draft_event,
    )
    return sale_response


def _websocket_user(websocket: WebSocket, db: Session) -> User | None:
    token = websocket.query_params.get("token")
    if not token:
        authorization = websocket.headers.get("authorization", "")
        if authorization.lower().startswith("bearer "):
            token = authorization[7:].strip()
    if not token:
        return None
    try:
        payload = jwt.decode(token, settings.jwt_secret, algorithms=[settings.jwt_algorithm])
        user_id = payload.get("sub")
        jti = payload.get("jti")
        if not isinstance(user_id, str) or not isinstance(jti, str):
            return None
        if db.get(RevokedToken, jti) is not None:
            return None
    except (jwt.InvalidTokenError, TypeError):
        return None
    return db.scalar(select(User).where(User.id == user_id, User.is_active.is_(True)))


@app.websocket("/api/v1/sales/drafts/ws")
@app.websocket("/api/v1/sales/drafts/events")
async def sale_draft_events(
    websocket: WebSocket, db: Session = Depends(get_db)
) -> None:
    user = _websocket_user(websocket, db)
    if user is None:
        await websocket.close(code=1008)
        return
    await draft_events.connect(websocket, user.shop_id, user.id)
    try:
        while True:
            await websocket.receive_text()
    except WebSocketDisconnect:
        draft_events.disconnect(websocket, user.shop_id, user.id)


@app.get("/api/v1/sales/{sale_id}", response_model=SaleResponse)
def get_sale(
    sale_id: str,
    db: Session = Depends(get_db),
    context: ServerContext = Depends(get_server_context),
) -> SaleResponse:
    sale = db.scalar(select(SaleDocument).where(SaleDocument.id == sale_id, SaleDocument.shop_id == context.shop_id))
    if sale is None:
        raise HTTPException(status_code=404, detail="Sale not found")
    items = db.scalars(select(SaleItem).where(SaleItem.sale_id == sale.id)).all()
    response = _sale_response(db, sale, list(items))
    posted_by_name = db.scalar(select(User.display_name).where(User.id == sale.posted_by))
    refunded_total = db.scalar(
        select(func.sum(RefundDocument.amount)).where(
            RefundDocument.sale_id == sale.id,
            RefundDocument.shop_id == context.shop_id,
        )
    ) or Decimal("0")
    return response.model_copy(
        update={"posted_by_name": posted_by_name, "refunded_total": refunded_total}
    )


@app.get("/api/v1/sales", response_model=SaleListResponse)
def list_sales(
    db: Session = Depends(get_db),
    context: ServerContext = Depends(get_server_context),
    page: int = Query(1, ge=1),
    page_size: int = Query(50, ge=1, le=200),
    sale_status: str | None = Query(default=None, alias="status"),
    date_from: date | None = Query(default=None),
    date_to: date | None = Query(default=None),
) -> SaleListResponse:
    filters = [SaleDocument.shop_id == context.shop_id]
    if sale_status:
        filters.append(SaleDocument.status == sale_status.strip().upper())
    if date_from is not None:
        filters.append(SaleDocument.posted_at >= datetime.combine(date_from, time.min))
    if date_to is not None:
        filters.append(SaleDocument.posted_at < datetime.combine(date_to, time.max))

    refund_filters = [RefundDocument.shop_id == context.shop_id]
    if sale_status and sale_status.strip().upper() != "POSTED":
        refund_filters.append(False)
    if date_from is not None:
        refund_filters.append(RefundDocument.posted_at >= datetime.combine(date_from, time.min))
    if date_to is not None:
        refund_filters.append(RefundDocument.posted_at < datetime.combine(date_to, time.max))

    sales = db.scalars(select(SaleDocument).where(*filters)).all()
    refunds = db.scalars(select(RefundDocument).where(*refund_filters)).all()
    entries = sorted(
        [("sale", sale) for sale in sales] + [("refund", refund) for refund in refunds],
        key=lambda entry: (entry[1].posted_at, entry[1].id),
        reverse=True,
    )
    total = len(entries)
    page_entries = entries[(page - 1) * page_size:page * page_size]
    page_sales = [entry[1] for entry in page_entries if entry[0] == "sale"]
    page_refunds = [entry[1] for entry in page_entries if entry[0] == "refund"]
    sale_ids = [sale.id for sale in page_sales]
    item_groups: dict[str, list[SaleItem]] = {sale_id: [] for sale_id in sale_ids}
    if sale_ids:
        for item in db.scalars(
            select(SaleItem).where(SaleItem.sale_id.in_(sale_ids))
        ).all():
            item_groups[item.sale_id].append(item)
    users = {
        user.id: user.display_name
        for user in db.scalars(select(User).where(User.id.in_(
            {sale.posted_by for sale in page_sales}
            | {refund.posted_by for refund in page_refunds}
        ))).all()
    } if page_sales or page_refunds else {}
    refund_totals = dict(db.execute(
        select(RefundDocument.sale_id, func.sum(RefundDocument.amount))
        .where(RefundDocument.shop_id == context.shop_id)
        .group_by(RefundDocument.sale_id)
    ).all())
    sale_responses = [
        _sale_response(db, sale, item_groups[sale.id]).model_copy(
            update={
                "posted_by_name": users.get(sale.posted_by),
                "refunded_total": refund_totals.get(sale.id, Decimal("0")),
            }
        )
        for sale in page_sales
    ]
    refund_ids = [refund.id for refund in page_refunds]
    refund_item_groups: dict[str, list[SaleItemResponse]] = {
        refund_id: [] for refund_id in refund_ids
    }
    if refund_ids:
        for refund_item, sale_item in db.execute(
            select(RefundItem, SaleItem)
            .join(SaleItem, SaleItem.id == RefundItem.sale_item_id)
            .where(RefundItem.refund_id.in_(refund_ids))
        ).all():
            restoration_rows = db.execute(
                select(SaleItemFifoRestoration).where(
                    SaleItemFifoRestoration.refund_item_id == refund_item.id
                )
            ).scalars().all()
            restored_quantity = sum(
                Decimal(str(row.restored_quantity)) for row in restoration_rows
            )
            expected_quantity = Decimal(str(refund_item.base_quantity))
            restoration_complete = (
                bool(restoration_rows)
                and abs(restored_quantity - expected_quantity)
                <= Decimal("0.000001")
            )
            historical_cost = (
                sum(
                    Decimal(str(row.restored_quantity))
                    * Decimal(str(row.unit_cost))
                    for row in restoration_rows
                )
                if restoration_complete
                else None
            )
            refund_item_groups[refund_item.refund_id].append(SaleItemResponse(
                id=sale_item.id,
                product_id=sale_item.product_id,
                unit=sale_item.unit,
                quantity=Decimal(refund_item.quantity),
                base_quantity=Decimal(refund_item.base_quantity),
                unit_price=(
                    Decimal(refund_item.amount) / Decimal(refund_item.quantity)
                ),
                line_total=Decimal(refund_item.amount),
                historical_cost=historical_cost,
                historical_cost_available=restoration_complete,
            ))
    refund_responses = [
        SaleResponse(
            sale_id=refund.id,
            shop_id=refund.shop_id,
            status="POSTED",
            document_reference=f"CR-{refund.id.removeprefix('refund-')[:12].upper()}",
            customer_id=None,
            payment_method=refund.payment_method,
            subtotal=Decimal(refund.amount),
            discount=Decimal("0"),
            total=Decimal(refund.amount),
            payment_result=-Decimal(refund.amount),
            remaining_amount=Decimal("0"),
            stock_posting_reference=f"refund:{refund.id}",
            posted_at=refund.posted_at,
            posted_by=refund.posted_by,
            posted_by_name=users.get(refund.posted_by),
            items=refund_item_groups[refund.id],
            is_refund=True,
            original_sale_id=refund.sale_id,
        )
        for refund in page_refunds
    ]
    response_by_id = {
        response.sale_id: response
        for response in sale_responses + refund_responses
    }
    responses = [response_by_id[record.id] for _, record in page_entries]
    for response in responses:
        logger.warning(
            "[REFUND_LIST_TRACE] saleId=%s reference=%s isRefund=%s "
            "originalSaleId=%s total=%s itemCount=%s",
            response.sale_id,
            response.document_reference,
            response.is_refund,
            response.original_sale_id,
            response.total,
            len(response.items),
        )
        for item in response.items:
            logger.warning(
                "[REFUND_LIST_TRACE] saleItemId=%s productId=%s quantity=%s "
                "refundedQuantity=%s exchangedQuantity=%s",
                item.id,
                item.product_id,
                item.quantity,
                item.refunded_quantity,
                item.exchanged_quantity,
            )
    return SaleListResponse(items=responses, total=total, page=page, page_size=page_size)


@app.get("/api/v1/analytics")
def analytics(
    db: Session = Depends(get_db),
    context: ServerContext = Depends(get_server_context),
    date_from: date | None = Query(default=None),
    date_to_exclusive: date | None = Query(default=None),
    date_to: date | None = Query(default=None),
) -> dict:
    _require_permission(context, Permission.VIEW_ANALYTICS)
    if date_to_exclusive is not None and date_to is not None:
        raise HTTPException(
            status_code=422,
            detail="Use either date_to_exclusive or legacy date_to, not both",
        )
    end_exclusive = date_to_exclusive
    if end_exclusive is None and date_to is not None:
        end_exclusive = date_to + timedelta(days=1)

    filters = [
        SaleDocument.shop_id == context.shop_id,
        SaleDocument.status == "POSTED",
    ]
    if date_from is not None:
        filters.append(SaleDocument.posted_at >= datetime.combine(date_from, time.min))
    if end_exclusive is not None:
        filters.append(
            SaleDocument.posted_at < datetime.combine(end_exclusive, time.min)
        )
    sales = db.scalars(select(SaleDocument).where(*filters)).all()
    refund_filters = [
        RefundDocument.shop_id == context.shop_id,
    ]
    if date_from is not None:
        refund_filters.append(
            RefundDocument.posted_at >= datetime.combine(date_from, time.min)
        )
    if end_exclusive is not None:
        refund_filters.append(
            RefundDocument.posted_at < datetime.combine(end_exclusive, time.min)
        )
    refunds = db.scalars(select(RefundDocument).where(*refund_filters)).all()

    exchange_filters = [ExchangeDocument.shop_id == context.shop_id]
    if date_from is not None:
        exchange_filters.append(
            ExchangeDocument.posted_at >= datetime.combine(date_from, time.min)
        )
    if end_exclusive is not None:
        exchange_filters.append(
            ExchangeDocument.posted_at < datetime.combine(end_exclusive, time.min)
        )
    exchange_events = db.execute(
        select(ExchangeDocument, ExchangeItem, SaleItem, Product)
        .join(ExchangeItem, ExchangeItem.exchange_id == ExchangeDocument.id)
        .join(SaleItem, SaleItem.id == ExchangeItem.sale_item_id)
        .join(Product, Product.id == SaleItem.product_id)
        .where(*exchange_filters)
        .where(Product.shop_id == context.shop_id)
    ).all()

    gross_revenue = sum(float(sale.total) for sale in sales)
    refunded_amount = sum(float(refund.amount) for refund in refunds)
    exchanged_amount = sum(
        float(item.old_amount) for _, item, _, _ in exchange_events
    )
    revenue = gross_revenue - refunded_amount - exchanged_amount
    daily: dict[str, float] = {}
    hourly: dict[str, float] = {str(hour): 0.0 for hour in range(24)}
    monthly: dict[str, float] = {}
    yearly: dict[str, float] = {}
    category_sales: dict[str, float] = {}
    products: dict[str, dict[str, float | str]] = {}

    if date_from is not None and end_exclusive is not None:
        day = date_from
        while day < end_exclusive:
            daily[day.isoformat()] = 0.0
            day += timedelta(days=1)

    for sale in sales:
        sale_total = float(sale.total)
        day = sale.posted_at.date().isoformat()
        hour = str(sale.posted_at.hour)
        month = sale.posted_at.strftime("%Y-%m")
        year = sale.posted_at.strftime("%Y")
        daily[day] = daily.get(day, 0.0) + sale_total
        hourly[hour] = hourly.get(hour, 0.0) + sale_total
        monthly[month] = monthly.get(month, 0.0) + sale_total
        yearly[year] = yearly.get(year, 0.0) + sale_total
    for refund in refunds:
        day = refund.posted_at.date().isoformat()
        hour = str(refund.posted_at.hour)
        month = refund.posted_at.strftime("%Y-%m")
        year = refund.posted_at.strftime("%Y")
        amount = float(refund.amount)
        daily[day] = daily.get(day, 0.0) - amount
        hourly[hour] = hourly.get(hour, 0.0) - amount
        monthly[month] = monthly.get(month, 0.0) - amount
        yearly[year] = yearly.get(year, 0.0) - amount

    for exchange, item, _, _ in exchange_events:
        amount = float(item.old_amount)
        day = exchange.posted_at.date().isoformat()
        hour = str(exchange.posted_at.hour)
        month = exchange.posted_at.strftime("%Y-%m")
        year = exchange.posted_at.strftime("%Y")
        daily[day] = daily.get(day, 0.0) - amount
        hourly[hour] = hourly.get(hour, 0.0) - amount
        monthly[month] = monthly.get(month, 0.0) - amount
        yearly[year] = yearly.get(year, 0.0) - amount

    sale_items: list[tuple[SaleItem, Product]] = []
    if sales:
        sale_items = db.execute(
            select(SaleItem, Product)
            .join(Product, Product.id == SaleItem.product_id)
            .options(joinedload(Product.category))
            .where(
                SaleItem.sale_id.in_([sale.id for sale in sales]),
                Product.shop_id == context.shop_id,
            )
        ).all()

    sale_item_ids = [item.id for item, _ in sale_items]
    sale_item_products = {item.id: product for item, product in sale_items}
    fifo_cost_by_item: dict[str, float] = {}
    fifo_quantity_by_item: dict[str, float] = {}
    fifo_cost_complete_by_item: dict[str, bool] = {}
    if sale_item_ids:
        allocation_rows = db.execute(
            select(SaleItemFifoAllocation, InventoryLotRecord)
            .join(
                InventoryLotRecord,
                InventoryLotRecord.id == SaleItemFifoAllocation.inventory_lot_id,
            )
            .where(
                SaleItemFifoAllocation.shop_id == context.shop_id,
                SaleItemFifoAllocation.sale_item_id.in_(sale_item_ids),
                InventoryLotRecord.shop_id == context.shop_id,
            )
        ).all()
        for allocation, lot in allocation_rows:
            fifo_quantity_by_item[allocation.sale_item_id] = (
                fifo_quantity_by_item.get(allocation.sale_item_id, 0.0)
                + float(allocation.allocated_quantity)
            )
            if allocation.unit_cost_at_sale is None:
                fifo_cost_complete_by_item[allocation.sale_item_id] = False
            else:
                fifo_cost_by_item[allocation.sale_item_id] = (
                    fifo_cost_by_item.get(allocation.sale_item_id, 0.0)
                    + float(allocation.allocated_quantity)
                    * float(allocation.unit_cost_at_sale)
                )
                fifo_cost_complete_by_item.setdefault(
                    allocation.sale_item_id, True
                )

    historical_cost_complete = True

    def line_cost(item: SaleItem, quantity: float | None = None) -> float | None:
        base_quantity = float(item.base_quantity) if quantity is None else quantity
        allocated_quantity = fifo_quantity_by_item.get(item.id, 0.0)
        if (
            not fifo_cost_complete_by_item.get(item.id, False)
            or abs(allocated_quantity - base_quantity) > 0.000001
        ):
            return None
        return fifo_cost_by_item[item.id]

    total_cost = 0.0
    for item, product in sale_items:
        category_name = product.category.name if product.category else "General"
        current = products.setdefault(
            item.product_id,
            {
                "product_name": product.name,
                "category_name": category_name,
                "quantity": 0.0,
                "revenue": 0.0,
                "cost": 0.0,
                "cost_data_available": True,
            },
        )
        quantity = float(item.base_quantity)
        item_revenue = float(item.line_total)
        item_cost = line_cost(item)
        current["quantity"] = float(current["quantity"]) + quantity
        current["revenue"] = float(current["revenue"]) + item_revenue
        if item_cost is None:
            historical_cost_complete = False
            current["cost_data_available"] = False
        else:
            current["cost"] = float(current["cost"]) + item_cost
            total_cost += item_cost
        category_sales[category_name] = (
            category_sales.get(category_name, 0.0) + item_revenue
        )

    refund_item_rows = []
    if refunds:
        refund_item_rows = db.execute(
            select(RefundDocument, RefundItem, SaleItem, Product)
            .join(RefundItem, RefundItem.refund_id == RefundDocument.id)
            .join(SaleItem, SaleItem.id == RefundItem.sale_item_id)
            .join(Product, Product.id == SaleItem.product_id)
            .options(joinedload(Product.category))
            .where(
                RefundDocument.id.in_([refund.id for refund in refunds]),
                Product.shop_id == context.shop_id,
            )
        ).all()

    refund_restoration_costs: dict[str, tuple[float, float]] = {}
    if refunds:
        restoration_rows = db.execute(
            select(SaleItemFifoRestoration, RefundItem)
            .join(RefundItem, RefundItem.id == SaleItemFifoRestoration.refund_item_id)
            .join(RefundDocument, RefundDocument.id == RefundItem.refund_id)
            .where(
                SaleItemFifoRestoration.shop_id == context.shop_id,
                RefundDocument.shop_id == context.shop_id,
                RefundDocument.id.in_([refund.id for refund in refunds]),
            )
        ).all()
        for restoration, refund_item in restoration_rows:
            quantity, cost = refund_restoration_costs.get(
                refund_item.id, (0.0, 0.0)
            )
            refund_restoration_costs[refund_item.id] = (
                quantity + float(restoration.restored_quantity),
                cost
                + float(restoration.restored_quantity)
                * float(restoration.unit_cost),
            )

    exchange_item_ids = [item.id for _, item, _, _ in exchange_events]
    exchange_restoration_costs: dict[str, tuple[float, float]] = {}
    if exchange_item_ids:
        restoration_rows = db.execute(
            select(SaleItemFifoRestoration, ExchangeItem)
            .join(ExchangeItem, ExchangeItem.id == SaleItemFifoRestoration.exchange_item_id)
            .join(ExchangeDocument, ExchangeDocument.id == ExchangeItem.exchange_id)
            .where(
                SaleItemFifoRestoration.shop_id == context.shop_id,
                ExchangeDocument.shop_id == context.shop_id,
                ExchangeItem.id.in_(exchange_item_ids),
            )
        ).all()
        for restoration, exchange_item in restoration_rows:
            quantity, cost = exchange_restoration_costs.get(
                exchange_item.id, (0.0, 0.0)
            )
            exchange_restoration_costs[exchange_item.id] = (
                quantity + float(restoration.restored_quantity),
                cost
                + float(restoration.restored_quantity)
                * float(restoration.unit_cost),
            )

    for refund, refund_item, sale_item, product in refund_item_rows:
        amount = float(refund_item.amount)
        quantity = float(refund_item.base_quantity)
        current = products.setdefault(
            sale_item.product_id,
            {
                "product_name": product.name,
                "category_name": product.category.name if product.category else "General",
                "quantity": 0.0,
                "revenue": 0.0,
                "cost": 0.0,
                "cost_data_available": True,
            },
        )
        current["quantity"] = float(current["quantity"]) - quantity
        current["revenue"] = float(current["revenue"]) - amount
        restored_quantity, restored_cost = refund_restoration_costs.get(
            refund_item.id, (0.0, 0.0)
        )
        if abs(restored_quantity - quantity) > 0.000001:
            historical_cost_complete = False
            current["cost_data_available"] = False
        else:
            current["cost"] = float(current["cost"]) - restored_cost
            total_cost -= restored_cost
        category = product.category.name if product.category else "General"
        category_sales[category] = category_sales.get(category, 0.0) - amount

    for exchange, exchange_item, original_item, product in exchange_events:
        amount = float(exchange_item.old_amount)
        quantity = float(exchange_item.returned_base_quantity)
        current = products.setdefault(
            original_item.product_id,
            {
                "product_name": product.name,
                "category_name": product.category.name if product.category else "General",
                "quantity": 0.0,
                "revenue": 0.0,
                "cost": 0.0,
                "cost_data_available": True,
            },
        )
        current["quantity"] = float(current["quantity"]) - quantity
        current["revenue"] = float(current["revenue"]) - amount
        restored_quantity, restored_cost = exchange_restoration_costs.get(
            exchange_item.id, (0.0, 0.0)
        )
        if abs(restored_quantity - quantity) > 0.000001:
            historical_cost_complete = False
            current["cost_data_available"] = False
        else:
            current["cost"] = float(current["cost"]) - restored_cost
            total_cost -= restored_cost
        category = product.category.name if product.category else "General"
        category_sales[category] = category_sales.get(category, 0.0) - amount

    top_products = []
    for product_id, values in products.items():
        quantity = float(values["quantity"])
        item_revenue = float(values["revenue"])
        if quantity <= 0 or item_revenue <= 0:
            continue
        item_cost = (
            float(values["cost"])
            if values["cost_data_available"]
            else None
        )
        profit = item_revenue - item_cost if item_cost is not None else None
        top_products.append(
            {
                "product_id": product_id,
                "product_name": values["product_name"],
                "category_name": values["category_name"],
                "quantity_sold": quantity,
                "revenue": item_revenue,
                "cost": item_cost,
                "profit": profit,
                "profit_margin": (
                    profit / item_revenue * 100
                    if profit is not None
                    else None
                ),
                "cost_data_available": values["cost_data_available"],
            }
        )
    top_products.sort(key=lambda item: float(item["revenue"]), reverse=True)
    top_products = top_products[:10]
    category_sales = {
        category: amount
        for category, amount in category_sales.items()
        if amount > 0
    }

    sold_quantity = sum(float(item.base_quantity) for item, _ in sale_items)
    refunded_quantity = sum(
        float(refund_item.base_quantity)
        for _, refund_item, _, _ in refund_item_rows
    )
    return {
        "total_revenue": revenue,
        "total_sales": len(sales),
        "gross_revenue": gross_revenue,
        "refunded_amount": refunded_amount,
        "exchanged_amount": exchanged_amount,
        "total_cost": total_cost if historical_cost_complete else None,
        "total_expenses": None,
        "total_profit": None,
        "profit_margin": None,
        "cost_data_available": historical_cost_complete,
        "profit_data_available": False,
        "expense_data_available": False,
        "expenses_data_available": False,
        "sold_quantity": sold_quantity,
        "refunded_quantity": refunded_quantity,
        "return_rate_percent": (
            refunded_quantity / sold_quantity * 100 if sold_quantity > 0 else 0.0
        ),
        "daily_time_series": daily,
        "hourly_sales": hourly,
        "category_sales": category_sales,
        "monthly_sales": monthly,
        "yearly_sales": yearly,
        "top_products": top_products,
    }


@app.get("/api/v1/health", response_model=HealthResponse)
def health(db: Session = Depends(get_db)) -> HealthResponse:
    try:
        db.execute(select(1))
    except SQLAlchemyError as error:
        raise HTTPException(status_code=503, detail="Server database is unavailable") from error
    return HealthResponse(status="ok", database="ok")


@app.get("/api/v1/version", response_model=VersionResponse)
def version() -> VersionResponse:
    return VersionResponse(version=settings.api_version)


@app.post("/api/v1/stock/adjustments", response_model=StockAdjustmentResponse, status_code=201)
def post_stock_adjustment(
    payload: StockAdjustmentCreate,
    db: Session = Depends(get_db),
    context: ServerContext = Depends(get_server_context),
) -> StockAdjustmentResponse:
    try:
        require_permission(context, Permission.POST_STOCK_ADJUSTMENT)
    except PermissionError as error:
        raise HTTPException(status_code=403, detail=str(error)) from error
    current_user = db.get(User, context.user_id)
    assert current_user is not None
    idempotency_key = payload.idempotency_key.strip()
    reason = payload.reason.strip()
    if not idempotency_key:
        raise HTTPException(status_code=422, detail="Stock adjustment idempotency key is required")
    if not reason:
        raise HTTPException(status_code=422, detail="Stock adjustment reason is required")
    payload_hash = request_hash(payload.model_dump(mode="json"))
    existing = db.scalar(select(IdempotencyRecord).where(
        IdempotencyRecord.shop_id == context.shop_id,
        IdempotencyRecord.idempotency_key == idempotency_key,
    ))
    if existing is not None:
        if existing.request_hash != payload_hash:
            raise HTTPException(status_code=409, detail="Idempotency key was already used with a different request")
        return StockAdjustmentResponse.model_validate(json.loads(existing.response_json))

    if len({line.product_id for line in payload.lines}) != len(payload.lines):
        raise HTTPException(status_code=422, detail="A product can only appear once in a stock adjustment")

    product_ids = {line.product_id for line in payload.lines}
    products = {
        product.id: product
        for product in db.scalars(
            select(Product).where(
                Product.id.in_(product_ids),
                Product.shop_id == current_user.shop_id,
                Product.is_active.is_(True),
            )
        ).all()
    }
    if len(products) != len(product_ids):
        raise HTTPException(status_code=404, detail="Product not found")

    now = datetime.utcnow()
    document_id = f"adjustment-{uuid4().hex}"
    reference_number = f"ADJ-{uuid4().hex[:12].upper()}"
    document = StockAdjustmentDocument(
        id=document_id,
        shop_id=current_user.shop_id,
        product_id=payload.lines[0].product_id,
        idempotency_key=idempotency_key,
        reference_number=reference_number,
        adjustment_date=payload.adjustment_date or now,
        reason=reason,
        notes=payload.notes.strip() if payload.notes and payload.notes.strip() else None,
        posted_by=current_user.id,
    )
    db.add(document)
    response_lines: list[StockAdjustmentLineResponse] = []
    for input_line in payload.lines:
        product = products[input_line.product_id]
        unit = input_line.unit.strip()
        valid_units = {product.base_unit}
        valid_units.update(
            unit_row.name
            for unit_row in product.selling_units
            if unit_row.is_active
        )
        if unit not in valid_units:
            raise HTTPException(status_code=422, detail=f"Unit {unit} is not valid for product {product.id}")
        selected_unit = next(
            (
                unit_row
                for unit_row in product.selling_units
                if unit_row.is_active and unit_row.name.strip().lower() == unit.lower()
            ),
            None,
        )
        conversion_to_base = (
            Decimal(str(selected_unit.conversion_to_base))
            if selected_unit is not None
            else Decimal("1")
        )
        if conversion_to_base <= 0:
            raise HTTPException(
                status_code=422,
                detail=f"Unit {unit} has an invalid conversion for product {product.id}",
            )
        base_unit_cost = (
            Decimal(str(input_line.unit_cost)) / conversion_to_base
            if input_line.operation != "remove"
            else Decimal("0")
        )

        current_quantity = product.stock
        quantity_change = input_line.counted_quantity - current_quantity
        if quantity_change == 0:
            raise HTTPException(
                status_code=422,
                detail=f"Counted quantity must differ from current stock for {product.name}",
            )
        if input_line.operation is not None and input_line.operation not in {"add", "remove"}:
            raise HTTPException(status_code=422, detail="Operation must be add or remove")
        if input_line.operation == "add" and quantity_change < 0:
            raise HTTPException(status_code=422, detail="Add operation cannot reduce stock")
        if input_line.operation == "remove" and quantity_change > 0:
            raise HTTPException(status_code=422, detail="Remove operation cannot increase stock")

        consumed_cost = Decimal("0")
        if quantity_change < 0:
            try:
                fifo_result = FifoInventoryCostingService.consume_and_persist(
                    db,
                    product.id,
                    abs(Decimal(str(quantity_change))),
                    shop_id=current_user.shop_id,
                )
            except ValueError as error:
                raise HTTPException(status_code=422, detail=str(error)) from error
            consumed_cost = fifo_result.consumed_cost
            if fifo_result.consumed_quantity > 0:
                base_unit_cost = consumed_cost / fifo_result.consumed_quantity

        product.stock = input_line.counted_quantity
        product.updated_at = now
        line_id = f"{document_id}-{product.id}"
        db.add(
            StockAdjustmentLine(
                id=line_id,
                document_id=document_id,
                product_id=product.id,
                unit=unit,
                current_quantity=current_quantity,
                counted_quantity=input_line.counted_quantity,
                quantity_change=quantity_change,
                unit_cost=float(base_unit_cost),
                line_total=float(
                    consumed_cost
                    if quantity_change < 0
                    else multiply_amount(abs(quantity_change), base_unit_cost)
                ),
            )
        )
        db.add(
            StockMovement(
                id=f"{line_id}-movement",
                shop_id=current_user.shop_id,
                product_id=product.id,
                movement_type="stock_adjustment",
                quantity_change=quantity_change,
                unit_cost=float(base_unit_cost),
                running_stock=input_line.counted_quantity,
                reference_type="stock_adjustment",
                reference_id=document_id,
                notes=reason if not document.notes else f"{reason} - {document.notes}",
                user_id=current_user.id,
                device_id=context.device_id,
                created_at=now,
            )
        )
        if quantity_change > 0:
            movement_id = f"{line_id}-movement"
            db.add(
                InventoryLotRecord(
                    id=f"fifo-lot-{current_user.shop_id}-{product.id}-{movement_id}",
                    shop_id=current_user.shop_id,
                    product_id=product.id,
                    movement_id=movement_id,
                    source_type="purchase",
                    source_id=document_id,
                    source_reference=document_id,
                    received_quantity=float(quantity_change),
                    remaining_quantity=float(quantity_change),
                    unit_cost=float(base_unit_cost),
                    acquired_at=now,
                )
            )
        response_lines.append(
            StockAdjustmentLineResponse(
                id=line_id,
                document_id=document_id,
                product_id=product.id,
                product_name=product.name,
                product_barcode=product.barcode,
                unit=unit,
                current_quantity=current_quantity,
                counted_quantity=input_line.counted_quantity,
                quantity_change=quantity_change,
                unit_cost=float(base_unit_cost),
                line_total=float(
                    consumed_cost
                    if quantity_change < 0
                    else multiply_amount(abs(quantity_change), base_unit_cost)
                ),
                running_stock=input_line.counted_quantity,
                created_at=now,
            )
        )

    db.flush()
    db.refresh(document)
    result = StockAdjustmentResponse(
        document_id=document.id,
        reference_number=document.reference_number,
        idempotency_key=document.idempotency_key,
        adjustment_date=document.adjustment_date,
        reason=document.reason,
        notes=document.notes,
        posted_at=now,
        posted_by=document.posted_by,
        lines=response_lines,
        product=product_response(products[payload.lines[0].product_id]),
    )
    db.add(IdempotencyRecord(
        id=f"idempotency-{uuid4().hex}", shop_id=context.shop_id,
        idempotency_key=idempotency_key, request_hash=payload_hash,
        response_json=result.model_dump_json(), status_code=201, device_id=context.device_id,
    ))
    try:
        db.commit()
    except IntegrityError as error:
        db.rollback()
        existing = db.scalar(select(IdempotencyRecord).where(
            IdempotencyRecord.shop_id == context.shop_id,
            IdempotencyRecord.idempotency_key == idempotency_key,
        ))
        if existing is not None and existing.request_hash == payload_hash:
            return StockAdjustmentResponse.model_validate(json.loads(existing.response_json))
        raise HTTPException(status_code=409, detail="Stock adjustment request has already been posted") from error
    return result


@app.post("/api/v1/auth/login", response_model=LoginResponse)
def login(payload: LoginRequest, db: Session = Depends(get_db)) -> LoginResponse:
    user = db.scalar(select(User).where(User.username == payload.username))
    if user is None or not user.is_active or not verify_password(payload.password, user.password_hash):
        raise HTTPException(status_code=401, detail="Invalid username or password")
    return LoginResponse(
        access_token=create_access_token(user),
        user_id=user.id,
        shop_id=user.shop_id,
        role=user.role,
    )


@app.post("/api/v1/auth/logout", status_code=204)
def logout(
    token: str = Depends(oauth2_scheme),
    db: Session = Depends(get_db),
) -> None:
    try:
        payload = jwt.decode(token, settings.jwt_secret, algorithms=[settings.jwt_algorithm],
                             options={"verify_exp": False})
        jti = payload.get("jti")
        expires = datetime.fromtimestamp(payload["exp"], tz=timezone.utc).replace(tzinfo=None)
    except (jwt.InvalidTokenError, KeyError, TypeError, ValueError) as error:
        raise HTTPException(status_code=401, detail="Invalid access token") from error
    if not isinstance(jti, str):
        raise HTTPException(status_code=401, detail="Invalid access token")
    db.merge(RevokedToken(jti=jti, expires_at=expires))
    db.commit()


@app.get("/api/v1/users", response_model=list[UserResponse])
def list_users(
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> list[UserResponse]:
    users = db.scalars(
        select(User)
        .where(
            User.shop_id == current_user.shop_id,
            User.is_active.is_(True),
        )
        .order_by(User.role, User.username)
    ).all()
    return [UserResponse.model_validate(user) for user in users]


@app.post("/api/v1/users", response_model=UserResponse, status_code=201)
def create_user(
    payload: UserCreate,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> UserResponse:
    if current_user.role != "admin":
        raise HTTPException(status_code=403, detail="Only admin can manage users")

    username = payload.username.strip()
    if not username:
        raise HTTPException(status_code=400, detail="Username is required")
    role = payload.role.strip().lower()
    if role not in {"admin", "manager", "cashier"}:
        raise HTTPException(status_code=400, detail="Invalid role")

    existing = db.scalar(
        select(User).where(
            User.shop_id == current_user.shop_id,
            User.username == username,
        )
    )
    if existing is not None:
        raise HTTPException(status_code=409, detail="Username already exists in this shop")

    user = User(
        id=username,
        shop_id=current_user.shop_id,
        username=username,
        display_name=payload.display_name.strip() if payload.display_name else username,
        phone=payload.phone.strip() if payload.phone and payload.phone.strip() else None,
        password_hash=hash_password(payload.password),
        role=role,
        is_active=payload.is_active,
    )
    db.add(user)
    db.commit()
    db.refresh(user)
    return UserResponse.model_validate(user)


@app.patch("/api/v1/users/{user_id}", response_model=UserResponse)
def update_user(
    user_id: str,
    payload: UserUpdate,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> UserResponse:
    if current_user.role != "admin":
        raise HTTPException(status_code=403, detail="Only admin can manage users")

    user = db.scalar(
        select(User).where(
            User.id == user_id,
            User.shop_id == current_user.shop_id,
        )
    )
    if user is None:
        raise HTTPException(status_code=404, detail="User not found")

    if payload.display_name is not None:
        user.display_name = payload.display_name.strip() or user.display_name
    if payload.phone is not None:
        user.phone = payload.phone.strip() or None
    if payload.role is not None:
        normalized_role = payload.role.strip().lower()
        if normalized_role not in {"admin", "manager", "cashier"}:
            raise HTTPException(status_code=400, detail="Invalid role")
        user.role = normalized_role
    if payload.password is not None:
        user.password_hash = hash_password(payload.password)
    if payload.is_active is not None:
        user.is_active = payload.is_active

    db.commit()
    db.refresh(user)
    return UserResponse.model_validate(user)


@app.delete("/api/v1/users/{user_id}", response_model=UserResponse)
def delete_user(
    user_id: str,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> UserResponse:
    if current_user.role != "admin":
        raise HTTPException(status_code=403, detail="Only admin can manage users")

    user = db.scalar(
        select(User).where(
            User.id == user_id,
            User.shop_id == current_user.shop_id,
        )
    )
    if user is None:
        raise HTTPException(status_code=404, detail="User not found")

    if user.id == current_user.id:
        raise HTTPException(
            status_code=409,
            detail="The currently authenticated user cannot be deactivated",
        )

    if user.role == "admin":
        active_admins = db.scalar(
            select(func.count(User.id)).where(
                User.shop_id == current_user.shop_id,
                User.role == "admin",
                User.is_active.is_(True),
            )
        ) or 0
        if active_admins <= 1:
            raise HTTPException(
                status_code=409,
                detail="The last active admin cannot be deactivated",
            )

    user.is_active = False
    db.commit()
    db.refresh(user)
    return UserResponse.model_validate(user)


@app.get("/api/v1/suppliers", response_model=SupplierListResponse)
def list_suppliers(
    db: Session = Depends(get_db),
    context: ServerContext = Depends(get_server_context),
    search: str | None = None,
) -> SupplierListResponse:
    _require_permission(context, Permission.READ_SUPPLIERS)
    query = select(Supplier).where(
        Supplier.shop_id == context.shop_id,
        Supplier.is_active.is_(True),
    )
    if search and search.strip():
        pattern = f"%{search.strip()}%"
        query = query.where(
            or_(
                Supplier.name.ilike(pattern),
                Supplier.code.ilike(pattern),
                Supplier.phone.ilike(pattern),
                Supplier.mobile.ilike(pattern),
                Supplier.supplier_reference.ilike(pattern),
            )
        )
    suppliers = db.scalars(query.order_by(Supplier.name, Supplier.id)).all()
    return SupplierListResponse(
        items=[supplier_response(db, supplier) for supplier in suppliers],
        total=len(suppliers),
    )


@app.post("/api/v1/suppliers", response_model=SupplierResponse, status_code=201)
def post_supplier(
    payload: SupplierCreate,
    db: Session = Depends(get_db),
    context: ServerContext = Depends(get_server_context),
) -> SupplierResponse:
    _require_permission(context, Permission.MANAGE_SUPPLIERS)
    try:
        with atomic_command(db):
            response = create_supplier(db, payload, context.shop_id)
        return response
    except ValueError as error:
        raise HTTPException(status_code=409, detail=str(error)) from error
    except IntegrityError as error:
        raise HTTPException(status_code=409, detail="Supplier already exists") from error


@app.get("/api/v1/suppliers/{supplier_id}", response_model=SupplierResponse)
def get_supplier(
    supplier_id: str,
    db: Session = Depends(get_db),
    context: ServerContext = Depends(get_server_context),
) -> SupplierResponse:
    _require_permission(context, Permission.READ_SUPPLIERS)
    supplier = db.scalar(select(Supplier).where(
        Supplier.id == supplier_id,
        Supplier.shop_id == context.shop_id,
    ))
    if supplier is None:
        raise HTTPException(status_code=404, detail="Supplier not found")
    return supplier_response(db, supplier)


@app.put("/api/v1/suppliers/{supplier_id}", response_model=SupplierResponse)
def put_supplier(
    supplier_id: str,
    payload: SupplierUpdate,
    db: Session = Depends(get_db),
    context: ServerContext = Depends(get_server_context),
) -> SupplierResponse:
    _require_permission(context, Permission.MANAGE_SUPPLIERS)
    supplier = db.scalar(select(Supplier).where(
        Supplier.id == supplier_id,
        Supplier.shop_id == context.shop_id,
    ))
    if supplier is None:
        raise HTTPException(status_code=404, detail="Supplier not found")
    try:
        with atomic_command(db):
            response = update_supplier(db, supplier, payload)
        return response
    except IntegrityError as error:
        raise HTTPException(status_code=409, detail="Unable to update supplier") from error


@app.delete("/api/v1/suppliers/{supplier_id}", response_model=SupplierResponse)
def deactivate_supplier(
    supplier_id: str,
    db: Session = Depends(get_db),
    context: ServerContext = Depends(get_server_context),
) -> SupplierResponse:
    _require_permission(context, Permission.MANAGE_SUPPLIERS)
    supplier = db.scalar(select(Supplier).where(
        Supplier.id == supplier_id,
        Supplier.shop_id == context.shop_id,
    ))
    if supplier is None:
        raise HTTPException(status_code=404, detail="Supplier not found")
    supplier.is_active = False
    supplier.updated_at = datetime.utcnow()
    db.commit()
    db.refresh(supplier)
    return supplier_response(db, supplier)


@app.get(
    "/api/v1/suppliers/{supplier_id}/ledger",
    response_model=list[SupplierLedgerResponse],
)
def get_supplier_ledger(
    supplier_id: str,
    db: Session = Depends(get_db),
    context: ServerContext = Depends(get_server_context),
) -> list[SupplierLedgerResponse]:
    _require_permission(context, Permission.READ_SUPPLIERS)
    supplier = db.scalar(select(Supplier.id).where(
        Supplier.id == supplier_id,
        Supplier.shop_id == context.shop_id,
    ))
    if supplier is None:
        raise HTTPException(status_code=404, detail="Supplier not found")
    entries = db.scalars(
        select(SupplierLedger)
        .where(
            SupplierLedger.supplier_id == supplier_id,
            SupplierLedger.shop_id == context.shop_id,
        )
        .order_by(SupplierLedger.created_at.desc(), SupplierLedger.id.desc())
    ).all()
    return [
        SupplierLedgerResponse(
            id=entry.id,
            supplier_id=entry.supplier_id,
            entry_type=entry.entry_type,
            amount=Decimal(entry.amount),
            balance_after=Decimal(entry.balance_after),
            reference_type=entry.reference_type,
            reference_id=entry.reference_id,
            notes=entry.notes,
            created_at=entry.created_at,
        )
        for entry in entries
    ]


@app.get("/api/v1/suppliers/{supplier_id}/balance")
def get_supplier_balance(
    supplier_id: str,
    db: Session = Depends(get_db),
    context: ServerContext = Depends(get_server_context),
) -> dict[str, Decimal]:
    _require_permission(context, Permission.READ_SUPPLIERS)
    if db.scalar(select(Supplier.id).where(
        Supplier.id == supplier_id,
        Supplier.shop_id == context.shop_id,
    )) is None:
        raise HTTPException(status_code=404, detail="Supplier not found")
    return {"balance": supplier_balance(db, supplier_id, context.shop_id)}


@app.post(
    "/api/v1/suppliers/{supplier_id}/payments",
    response_model=SupplierPaymentResponse,
    status_code=201,
)
def create_supplier_payment(
    supplier_id: str,
    payload: SupplierPaymentCreate,
    db: Session = Depends(get_db),
    context: ServerContext = Depends(get_server_context),
) -> SupplierPaymentResponse:
    _require_permission(context, Permission.POST_SUPPLIER_PAYMENT)
    key = payload.idempotency_key.strip()
    if not key:
        raise HTTPException(status_code=422, detail="Idempotency key is required")
    payload_hash = request_hash({"supplier_id": supplier_id, **payload.model_dump(mode="json")})
    with sqlite_write_lock:
        existing = db.scalar(select(IdempotencyRecord).where(
            IdempotencyRecord.shop_id == context.shop_id,
            IdempotencyRecord.idempotency_key == key,
        ))
        if existing is not None:
            if existing.request_hash != payload_hash:
                raise HTTPException(
                    status_code=409,
                    detail="Idempotency key was already used with a different request",
                )
            return SupplierPaymentResponse.model_validate(
                json.loads(existing.response_json)
            )
        try:
            with atomic_command(db):
                response = post_supplier_payment(
                    db, supplier_id, payload, context.shop_id
                )
                db.add(IdempotencyRecord(
                    id=f"idempotency-{uuid4().hex}",
                    shop_id=context.shop_id,
                    idempotency_key=key,
                    request_hash=payload_hash,
                    response_json=response.model_dump_json(),
                    status_code=201,
                    device_id=context.device_id,
                ))
            return response
        except LookupError as error:
            raise HTTPException(status_code=404, detail=str(error)) from error
        except ValueError as error:
            raise HTTPException(status_code=422, detail=str(error)) from error
        except IntegrityError as error:
            raise HTTPException(
                status_code=409, detail="Supplier payment has already been posted"
            ) from error


@app.post(
    "/api/v1/suppliers/{supplier_id}/returns",
    response_model=SupplierReturnResponse,
    status_code=201,
)
def create_supplier_return(
    supplier_id: str,
    payload: SupplierReturnCreate,
    db: Session = Depends(get_db),
    context: ServerContext = Depends(get_server_context),
) -> SupplierReturnResponse:
    _require_permission(context, Permission.POST_SUPPLIER_RETURN)
    key = payload.idempotency_key.strip()
    if not key:
        raise HTTPException(status_code=422, detail="Idempotency key is required")
    payload_hash = request_hash(
        {"supplier_id": supplier_id, **payload.model_dump(mode="json")}
    )
    with sqlite_write_lock:
        existing = db.scalar(
            select(IdempotencyRecord).where(
                IdempotencyRecord.shop_id == context.shop_id,
                IdempotencyRecord.idempotency_key == key,
            )
        )
        if existing is not None:
            if existing.request_hash != payload_hash:
                raise HTTPException(
                    status_code=409,
                    detail="Idempotency key was already used with a different request",
                )
            return SupplierReturnResponse.model_validate(
                json.loads(existing.response_json)
            )
        try:
            with atomic_command(db):
                response = post_supplier_return(
                    db,
                    supplier_id,
                    payload,
                    context.shop_id,
                    context.user_id,
                    context.device_id,
                )
                db.add(
                    IdempotencyRecord(
                        id=f"idempotency-{uuid4().hex}",
                        shop_id=context.shop_id,
                        idempotency_key=key,
                        request_hash=payload_hash,
                        response_json=response.model_dump_json(),
                        status_code=201,
                        device_id=context.device_id,
                    )
                )
            return response
        except LookupError as error:
            raise HTTPException(status_code=404, detail=str(error)) from error
        except ValueError as error:
            raise HTTPException(status_code=422, detail=str(error)) from error
        except IntegrityError as error:
            raise HTTPException(
                status_code=409, detail="Supplier return has already been posted"
            ) from error


@app.post("/api/v1/purchases", response_model=PurchaseResponse, status_code=201)
def create_purchase(
    payload: PurchaseCreate,
    db: Session = Depends(get_db),
    context: ServerContext = Depends(get_server_context),
) -> PurchaseResponse:
    _require_permission(context, Permission.POST_PURCHASE)
    key = payload.idempotency_key.strip()
    if not key:
        raise HTTPException(status_code=422, detail="Idempotency key is required")
    payload_hash = request_hash(payload.model_dump(mode="json"))
    with sqlite_write_lock:
        existing = db.scalar(select(IdempotencyRecord).where(
            IdempotencyRecord.shop_id == context.shop_id,
            IdempotencyRecord.idempotency_key == key,
        ))
        if existing is not None:
            if existing.request_hash != payload_hash:
                raise HTTPException(
                    status_code=409,
                    detail="Idempotency key was already used with a different request",
                )
            return PurchaseResponse.model_validate(json.loads(existing.response_json))
        try:
            with atomic_command(db):
                response = post_purchase(
                    db, payload, context.shop_id, context.user_id, context.device_id
                )
                db.add(IdempotencyRecord(
                    id=f"idempotency-{uuid4().hex}",
                    shop_id=context.shop_id,
                    idempotency_key=key,
                    request_hash=payload_hash,
                    response_json=response.model_dump_json(),
                    status_code=201,
                    device_id=context.device_id,
                ))
            return response
        except LookupError as error:
            raise HTTPException(status_code=404, detail=str(error)) from error
        except ValueError as error:
            raise HTTPException(status_code=422, detail=str(error)) from error
        except IntegrityError as error:
            raise HTTPException(
                status_code=409,
                detail="Purchase reference or request has already been posted",
            ) from error


@app.get("/api/v1/purchases", response_model=PurchaseListResponse)
def list_purchases(
    db: Session = Depends(get_db),
    context: ServerContext = Depends(get_server_context),
    page: int = Query(1, ge=1),
    page_size: int = Query(50, ge=1, le=200),
) -> PurchaseListResponse:
    _require_permission(context, Permission.READ_SUPPLIERS)
    base = select(PurchaseDocument).where(PurchaseDocument.shop_id == context.shop_id)
    total = db.scalar(select(func.count()).select_from(base.subquery())) or 0
    purchases = db.scalars(
        base.order_by(PurchaseDocument.purchase_date.desc(), PurchaseDocument.id.desc())
        .offset((page - 1) * page_size)
        .limit(page_size)
    ).all()
    responses = []
    for purchase in purchases:
        lines = db.scalars(select(PurchaseLine).where(
            PurchaseLine.purchase_id == purchase.id
        ).order_by(PurchaseLine.id)).all()
        responses.append(purchase_response(purchase, lines))
    return PurchaseListResponse(items=responses, total=total)


@app.get("/api/v1/purchases/{purchase_id}", response_model=PurchaseResponse)
def get_purchase(
    purchase_id: str,
    db: Session = Depends(get_db),
    context: ServerContext = Depends(get_server_context),
) -> PurchaseResponse:
    _require_permission(context, Permission.READ_SUPPLIERS)
    purchase = db.scalar(select(PurchaseDocument).where(
        PurchaseDocument.id == purchase_id,
        PurchaseDocument.shop_id == context.shop_id,
    ))
    if purchase is None:
        raise HTTPException(status_code=404, detail="Purchase not found")
    lines = db.scalars(select(PurchaseLine).where(
        PurchaseLine.purchase_id == purchase.id
    ).order_by(PurchaseLine.id)).all()
    return purchase_response(purchase, lines)


@app.get("/api/v1/products/{product_id}/purchase-history")
def get_product_purchase_history(
    product_id: str,
    db: Session = Depends(get_db),
    context: ServerContext = Depends(get_server_context),
) -> list[dict[str, object]]:
    _require_permission(context, Permission.READ_SUPPLIERS)
    if db.scalar(select(Product.id).where(
        Product.id == product_id, Product.shop_id == context.shop_id
    )) is None:
        raise HTTPException(status_code=404, detail="Product not found")
    rows = db.execute(
        select(PurchaseDocument, PurchaseLine, Supplier.name)
        .join(PurchaseLine, PurchaseLine.purchase_id == PurchaseDocument.id)
        .join(Supplier, Supplier.id == PurchaseDocument.supplier_id)
        .where(
            PurchaseDocument.shop_id == context.shop_id,
            PurchaseLine.product_id == product_id,
        )
        .order_by(PurchaseDocument.purchase_date.desc(), PurchaseDocument.id.desc())
    ).all()
    return [
        {
            "purchase_id": purchase.id,
            "reference_number": purchase.reference,
            "purchase_date": purchase.purchase_date,
            "status": purchase.status,
            "supplier_id": purchase.supplier_id,
            "supplier_name": supplier_name,
            "quantity": line.selling_quantity or line.quantity,
            "unit_cost": (
                line.line_total / line.selling_quantity
                if line.selling_quantity
                else line.unit_cost
            ),
            "line_total": line.line_total,
            "selling_unit_id": line.selling_unit_id,
            "selling_quantity": line.selling_quantity,
            "base_quantity": line.quantity,
            "conversion_factor_snapshot": line.conversion_factor_snapshot,
            "selling_unit_name_snapshot": line.selling_unit_name_snapshot,
            "base_unit_snapshot": line.base_unit_snapshot,
        }
        for purchase, line, supplier_name in rows
    ]


@app.get("/api/v1/products", response_model=ProductListResponse)
def list_products(
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
    page: int = Query(1, ge=1),
    page_size: int = Query(50, ge=1, le=200),
    search: str | None = None,
    active: bool | None = True,
    category_id: str | None = None,
) -> ProductListResponse:
    filters = [Product.shop_id == current_user.shop_id]
    if active is not None:
        filters.append(Product.is_active == active)
    if category_id:
        filters.append(Product.category_id == category_id)
    if search and search.strip():
        term = f"%{search.strip()}%"
        filters.append(or_(
            Product.name.ilike(term),
            Product.code.ilike(term),
            Product.barcode.ilike(term),
            Product.internal_reference.ilike(term),
        ))
    total = db.scalar(select(func.count(Product.id)).where(*filters)) or 0
    products = db.scalars(
        product_query(current_user.shop_id)
        .where(*filters)
        .order_by(Product.name, Product.id)
        .offset((page - 1) * page_size)
        .limit(page_size)
    ).unique().all()
    return ProductListResponse(
        items=[product_response(product) for product in products],
        total=total,
        page=page,
        page_size=page_size,
    )


@app.get("/api/v1/categories", response_model=list[CategoryResponse])
def list_categories(
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> list[CategoryResponse]:
    categories = db.scalars(
        select(Category)
        .where(
            Category.shop_id == current_user.shop_id,
            Category.is_active.is_(True),
        )
        .order_by(Category.sort_order, Category.name)
    ).all()
    return [CategoryResponse.model_validate(category) for category in categories]


@app.post("/api/v1/categories", response_model=CategoryResponse, status_code=201)
def create_category(
    payload: CategoryCreate,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> CategoryResponse:
    _require_catalog_manager(current_user)
    name = payload.name.strip()
    if not name:
        raise HTTPException(status_code=422, detail="Category name is required")
    duplicate = db.scalar(
        select(Category.id).where(
            Category.shop_id == current_user.shop_id,
            Category.is_active.is_(True),
            func.lower(Category.name) == name.lower(),
        )
    )
    if duplicate is not None:
        raise HTTPException(status_code=409, detail="Category already exists")
    category = Category(
        id=f"category-{uuid4().hex}",
        shop_id=current_user.shop_id,
        name=name,
        color=payload.color,
        sort_order=payload.sort_order,
        is_active=True,
    )
    db.add(category)
    try:
        db.commit()
    except IntegrityError as error:
        db.rollback()
        raise HTTPException(status_code=409, detail="Category already exists") from error
    db.refresh(category)
    return CategoryResponse.model_validate(category)


@app.delete("/api/v1/categories/{category_id}", response_model=CategoryResponse)
def delete_category(
    category_id: str,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> CategoryResponse:
    _require_catalog_manager(current_user)
    category = db.scalar(
        select(Category).where(
            Category.id == category_id,
            Category.shop_id == current_user.shop_id,
        )
    )
    if category is None:
        raise HTTPException(status_code=404, detail="Category not found")
    in_use = db.scalar(
        select(Product.id).where(
            Product.category_id == category_id,
            Product.shop_id == current_user.shop_id,
            Product.is_active.is_(True),
        ).limit(1)
    )
    if in_use is not None:
        raise HTTPException(
            status_code=409,
            detail="Cannot delete category because it contains products",
        )
    category.is_active = False
    db.commit()
    db.refresh(category)
    return CategoryResponse.model_validate(category)


@app.post("/api/v1/products", response_model=ProductResponse, status_code=201)
def create_product(
    payload: ProductCreate,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> ProductResponse:
    _require_catalog_manager(current_user)
    opening_lines = list(payload.opening_lines)
    if opening_lines and payload.opening_quantity > 0:
        raise HTTPException(status_code=422, detail="Use opening_lines instead of legacy opening stock fields")
    if not opening_lines and payload.opening_quantity > 0:
        opening_lines = [
            OpeningStockLineCreate(
                unit=payload.opening_unit or payload.base_unit,
                quantity=payload.opening_quantity,
                unit_cost=payload.opening_unit_cost,
            )
        ]
    if opening_lines and not payload.opening_reason:
        raise HTTPException(status_code=422, detail="Opening stock reason is required")
    if opening_lines and not payload.opening_reason.strip():
        raise HTTPException(status_code=422, detail="Opening stock reason is required")
    if payload.product_type.upper() == "PACKAGED":
        packaged_units = [line.unit.strip().lower() for line in opening_lines]
        if any(unit not in {"pack", "box"} for unit in packaged_units):
            raise HTTPException(
                status_code=422,
                detail="Packaged initial stock must use Pack or Box",
            )
        if packaged_units.count("pack") > 1:
            raise HTTPException(
                status_code=422,
                detail="Packaged initial stock allows at most one Pack line",
            )
        if packaged_units.count("box") > 1:
            raise HTTPException(
                status_code=422,
                detail="Packaged initial stock allows at most one Box line",
            )
        if len(packaged_units) > 2:
            raise HTTPException(
                status_code=422,
                detail="Packaged initial stock allows at most one Pack and one Box line",
            )

    if db.scalar(select(Product.id).where(Product.id == payload.id)) is not None:
        raise HTTPException(status_code=409, detail="Product already exists")

    barcode = _normalize_barcode(payload.barcode)
    if (
        payload.is_active
        and barcode is not None
        and _barcode_exists(db, current_user.shop_id, barcode)
    ):
        raise HTTPException(status_code=409, detail="Barcode already exists")

    if payload.category_id is not None and db.scalar(
        select(Category.id).where(
            Category.id == payload.category_id,
            Category.shop_id == current_user.shop_id,
        )
    ) is None:
        raise HTTPException(status_code=400, detail="Category not found")

    product = Product(
        id=payload.id,
        shop_id=current_user.shop_id,
        category_id=payload.category_id,
        name=payload.name,
        code=payload.code,
        barcode=barcode,
        internal_reference=payload.internal_reference,
        product_type=payload.product_type,
        base_unit=payload.base_unit,
        quantity_precision=payload.quantity_precision,
        allow_partial_package_sale=payload.allow_partial_package_sale,
        price=payload.price,
        min_price=payload.min_price,
        wholesale_price=payload.wholesale_price,
        cost=payload.cost,
        stock=0,
        min_stock=payload.min_stock,
        image_path=payload.image_path,
        is_active=payload.is_active,
    )
    db.add(product)

    def flush_product_creation() -> None:
        try:
            db.flush()
        except IntegrityError as error:
            db.rollback()
            raise HTTPException(
                status_code=409,
                detail="Product or barcode already exists",
            ) from error

    if payload.product_type.upper() == "PACKAGED":
        for unit in payload.selling_units:
            if unit.is_active:
                if unit.name.strip().lower() not in {"piece", "pack", "box"}:
                    raise HTTPException(
                        status_code=422,
                        detail="Selling unit must be Piece, Pack, or Box",
                    )
                product.selling_units.append(
                    ProductSellingUnit(
                        id=unit.id,
                        name=unit.name,
                        icon_key=_selling_unit_icon_key(unit.name, unit.icon_key),
                        conversion_to_base=unit.conversion_to_base,
                        selling_price=unit.selling_price,
                        cost_price=unit.cost_price,
                        wholesale_price=unit.wholesale_price,
                        minimum_stock=unit.minimum_stock,
                        is_default=unit.is_default,
                        is_active=True,
                    )
                )
    flush_product_creation()
    normalized_opening_lines = []
    for line in opening_lines:
        entered_unit, conversion = _unit_conversion(db, product, line.unit)
        base_quantity = line.quantity * conversion
        base_unit_cost = line.unit_cost / conversion
        normalized_opening_lines.append(
            (line, entered_unit, conversion, base_quantity, base_unit_cost)
        )
    opening_base_quantity = sum(item[3] for item in normalized_opening_lines)
    if normalized_opening_lines:
        product.cost = sum(item[3] * item[4] for item in normalized_opening_lines) / opening_base_quantity
        product.stock = opening_base_quantity
        document_id = f"opening-{payload.id}"
        reason = payload.opening_reason.strip()
        notes = payload.opening_notes.strip() if payload.opening_notes else None
        document = OpeningStockDocument(
            id=document_id,
            shop_id=current_user.shop_id,
            product_id=payload.id,
            idempotency_key=document_id,
            reference_number=f"OS-{payload.id}",
            quantity=opening_base_quantity,
            entered_unit=product.base_unit,
            conversion_to_base=1,
            base_quantity=opening_base_quantity,
            unit_cost=product.cost,
            reason=reason,
            notes=notes or None,
            posted_by=current_user.id,
        )
        db.add(document)
        flush_product_creation()
        acquired_at = datetime.utcnow()
        running_stock = 0.0
        for index, (line, entered_unit, conversion, base_quantity, base_unit_cost) in enumerate(
            normalized_opening_lines
        ):
            movement_id = (
                f"{document_id}-movement"
                if len(normalized_opening_lines) == 1
                else f"{document_id}-movement-{index + 1}"
            )
            line_id = (
                f"{document_id}-line"
                if len(normalized_opening_lines) == 1
                else f"{document_id}-line-{index + 1}"
            )
            running_stock += base_quantity
            db.add(OpeningStockLine(
                id=line_id,
                document_id=document_id,
                product_id=payload.id,
                quantity=line.quantity,
                entered_unit=entered_unit,
                conversion_to_base=conversion,
                base_quantity=base_quantity,
                unit_cost=line.unit_cost,
                line_total=base_quantity * base_unit_cost,
            ))
            db.add(StockMovement(
                id=movement_id,
                shop_id=current_user.shop_id,
                product_id=payload.id,
                movement_type="opening_stock",
                quantity_change=base_quantity,
                unit_cost=base_unit_cost,
                running_stock=running_stock,
                reference_type="opening_stock",
                reference_id=document_id,
                notes=f"{reason} - {notes}" if notes else reason,
                user_id=current_user.id,
                created_at=acquired_at + timedelta(microseconds=index),
            ))
        flush_product_creation()
        for index, (_, _, _, base_quantity, base_unit_cost) in enumerate(
            normalized_opening_lines
        ):
            movement_id = (
                f"{document_id}-movement"
                if len(normalized_opening_lines) == 1
                else f"{document_id}-movement-{index + 1}"
            )
            db.add(InventoryLotRecord(
                id=f"fifo-lot-{current_user.shop_id}-{payload.id}-{movement_id}",
                shop_id=current_user.shop_id,
                product_id=payload.id,
                movement_id=movement_id,
                source_type="opening_stock",
                source_id=document_id,
                source_reference=document_id,
                received_quantity=float(base_quantity),
                remaining_quantity=float(base_quantity),
                unit_cost=float(base_unit_cost),
                acquired_at=acquired_at + timedelta(microseconds=index),
            ))
    try:
        db.commit()
    except IntegrityError as error:
        db.rollback()
        raise HTTPException(status_code=409, detail="Product or barcode already exists") from error
    db.refresh(product)
    return product_response(product)


@app.put("/api/v1/products/{product_id}", response_model=ProductResponse)
def update_product(
    product_id: str,
    payload: ProductUpdate,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> ProductResponse:
    _require_catalog_manager(current_user)
    product = db.scalar(
        select(Product).where(
            Product.id == product_id,
            Product.shop_id == current_user.shop_id,
        )
    )
    if product is None:
        raise HTTPException(status_code=404, detail="Product not found")
    has_history = _product_has_history(db, product.id)
    if has_history and (
        payload.base_unit != product.base_unit
        or payload.product_type.upper() != product.product_type.upper()
    ):
        raise HTTPException(
            status_code=409,
            detail="Base unit and product type cannot change after historical stock activity",
        )
    if has_history and payload.product_type.upper() == "PACKAGED":
        existing_units = {
            unit.id: unit
            for unit in product.selling_units
            if unit.is_active
        }
        for requested_unit in payload.selling_units:
            existing_unit = existing_units.get(requested_unit.id)
            if (
                existing_unit is not None
                and existing_unit.conversion_to_base != requested_unit.conversion_to_base
            ):
                raise HTTPException(
                    status_code=409,
                    detail=f"Selling unit conversion cannot change after historical stock activity: {requested_unit.name}",
                )
    if payload.category_id is not None and db.scalar(
        select(Category.id).where(
            Category.id == payload.category_id,
            Category.shop_id == current_user.shop_id,
        )
    ) is None:
        raise HTTPException(status_code=400, detail="Category not found")
    barcode = _normalize_barcode(payload.barcode)
    if (
        payload.is_active
        and barcode is not None
        and (barcode != product.barcode or not product.is_active)
        and _barcode_exists(
            db,
            current_user.shop_id,
            barcode,
            exclude_product_id=product.id,
        )
    ):
        raise HTTPException(status_code=409, detail="Barcode already exists")
    for field in (
        "name", "code", "internal_reference", "product_type", "base_unit",
        "quantity_precision", "allow_partial_package_sale", "price",
        "min_price", "wholesale_price", "cost", "min_stock", "image_path",
        "is_active",
    ):
        setattr(product, field, getattr(payload, field))
    product.category_id = payload.category_id
    product.barcode = barcode
    if payload.product_type.upper() == "PACKAGED":
        product.selling_units.clear()
        for unit in payload.selling_units:
            if unit.is_active:
                if unit.name.strip().lower() not in {"piece", "pack", "box"}:
                    raise HTTPException(
                        status_code=422,
                        detail="Selling unit must be Piece, Pack, or Box",
                    )
                product.selling_units.append(
                    ProductSellingUnit(
                        id=unit.id,
                        name=unit.name,
                        icon_key=_selling_unit_icon_key(unit.name, unit.icon_key),
                        conversion_to_base=unit.conversion_to_base,
                        selling_price=unit.selling_price,
                        cost_price=unit.cost_price,
                        wholesale_price=unit.wholesale_price,
                        is_default=unit.is_default,
                        is_active=True,
                    )
                )
    else:
        product.selling_units.clear()
    try:
        db.commit()
    except IntegrityError as error:
        db.rollback()
        raise HTTPException(status_code=409, detail="Product or barcode already exists") from error
    db.refresh(product)
    return product_response(product)


@app.delete("/api/v1/products/{product_id}", response_model=ProductResponse)
def delete_product(
    product_id: str,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> ProductResponse:
    _require_catalog_manager(current_user)
    product = db.scalar(
        product_query(current_user.shop_id).where(Product.id == product_id)
    )
    if product is None:
        raise HTTPException(status_code=404, detail="Product not found")
    product.is_active = False
    product.updated_at = datetime.utcnow()
    db.commit()
    db.refresh(product)
    return product_response(product)


def _original_fifo_layer(db: Session, layer: InventoryLotRecord) -> InventoryLotRecord:
    current = layer
    while current.parent_layer_id:
        parent = db.get(InventoryLotRecord, current.parent_layer_id)
        if parent is None:
            break
        current = parent
    return current


@app.get(
    "/api/v1/products/{product_id}/fifo-layers",
    response_model=list[FifoInventoryLayerResponse],
)
def get_product_fifo_layers(
    product_id: str,
    db: Session = Depends(get_db),
    context: ServerContext = Depends(get_server_context),
) -> list[FifoInventoryLayerResponse]:
    _require_permission(context, Permission.VIEW_STOCK_SUMMARY)
    product = db.scalar(
        select(Product).where(
            Product.id == product_id,
            Product.shop_id == context.shop_id,
        )
    )
    if product is None:
        raise HTTPException(status_code=404, detail="Product not found")

    try:
        FifoInventoryCostingService.lots_for_product(
            db, product.id, shop_id=context.shop_id
        )
    except ValueError as error:
        raise HTTPException(status_code=409, detail=str(error)) from error

    layers = db.scalars(
        select(InventoryLotRecord)
        .where(
            InventoryLotRecord.product_id == product.id,
            InventoryLotRecord.shop_id == context.shop_id,
            InventoryLotRecord.remaining_quantity > 0,
        )
        .order_by(
            InventoryLotRecord.fifo_order.asc(),
            InventoryLotRecord.acquired_at.asc(),
            InventoryLotRecord.movement_id.asc(),
        )
    ).all()
    result = []
    for layer in layers:
        root = _original_fifo_layer(db, layer)
        original_movement = db.scalar(
            select(StockMovement).where(
                StockMovement.id == root.movement_id,
                StockMovement.shop_id == context.shop_id,
            )
        )
        correction = db.scalar(
            select(FifoCostCorrection)
            .where(
                FifoCostCorrection.resulting_layer_id == layer.id,
                FifoCostCorrection.shop_id == context.shop_id,
            )
            .order_by(FifoCostCorrection.created_at.desc())
        )
        result.append(
            FifoInventoryLayerResponse(
                layer_id=layer.id,
                source_movement_id=root.movement_id,
                acquisition_date=layer.acquired_at,
                acquisition_reference=layer.source_reference or layer.source_id,
                original_unit_cost=(
                    original_movement.unit_cost
                    if original_movement is not None
                    else root.unit_cost
                ),
                current_unit_cost=layer.unit_cost,
                remaining_quantity=layer.remaining_quantity,
                correction_old_unit_cost=(
                    correction.old_unit_cost if correction is not None else None
                ),
                correction_new_unit_cost=(
                    correction.new_unit_cost if correction is not None else None
                ),
                correction_created_at=(
                    correction.created_at if correction is not None else None
                ),
            )
        )
    return result


@app.post(
    "/api/v1/products/{product_id}/fifo-cost-corrections",
    response_model=FifoCostCorrectionResponse,
    status_code=201,
)
def correct_product_fifo_layer_cost(
    product_id: str,
    payload: FifoCostCorrectionCreate,
    idempotency_header: str | None = Header(default=None, alias="Idempotency-Key"),
    db: Session = Depends(get_db),
    context: ServerContext = Depends(get_server_context),
) -> FifoCostCorrectionResponse:
    _require_permission(context, Permission.POST_STOCK_ADJUSTMENT)
    key = (idempotency_header or "").strip()
    reason = "FIFO remaining inventory cost correction"
    if not key:
        raise HTTPException(status_code=422, detail="Idempotency-Key header is required")

    payload_hash = request_hash(
        {
            "command": "fifo_cost_correction",
            "product_id": product_id,
            **payload.model_dump(mode="json"),
        }
    )
    with sqlite_write_lock:
        existing = db.scalar(
            select(IdempotencyRecord).where(
                IdempotencyRecord.shop_id == context.shop_id,
                IdempotencyRecord.idempotency_key == key,
            )
        )
        if existing is not None:
            if existing.request_hash != payload_hash:
                raise HTTPException(
                    status_code=409,
                    detail="Idempotency key was already used with a different request",
                )
            return FifoCostCorrectionResponse.model_validate(
                json.loads(existing.response_json)
            )

        try:
            with atomic_command(db):
                product = db.scalar(
                    select(Product).where(
                        Product.id == product_id,
                        Product.shop_id == context.shop_id,
                    )
                )
                if product is None:
                    raise HTTPException(status_code=404, detail="Product not found")
                FifoInventoryCostingService.lots_for_product(
                    db, product_id, shop_id=context.shop_id
                )
                layer = db.scalar(
                    select(InventoryLotRecord).where(
                        InventoryLotRecord.id == payload.layer_id,
                        InventoryLotRecord.product_id == product_id,
                        InventoryLotRecord.shop_id == context.shop_id,
                    )
                )
                if layer is None:
                    raise HTTPException(status_code=404, detail="FIFO layer not found")

                new_unit_cost = Decimal(str(payload.new_unit_cost))
                remaining = Decimal(str(layer.remaining_quantity))
                quantity = remaining

                old_unit_cost = Decimal(str(layer.unit_cost))
                value_difference = (
                    quantity * (new_unit_cost - old_unit_cost)
                ).quantize(Decimal("0.01"))
                now = datetime.utcnow()
                correction_id = f"fifo-cost-correction-{uuid4().hex}"
                movement_id = f"cost-correction-movement-{uuid4().hex}"
                corrected_layer_id = (
                    f"fifo-lot-{context.shop_id}-{product_id}-{movement_id}"
                )
                fifo_order = layer.fifo_order or (
                    f"{layer.acquired_at.isoformat(timespec='microseconds')}"
                    f"|{layer.movement_id}"
                )
                layer.fifo_order = fifo_order

                allocations = db.scalars(
                    select(SaleItemFifoAllocation).where(
                        SaleItemFifoAllocation.inventory_lot_id == layer.id,
                        SaleItemFifoAllocation.shop_id == context.shop_id,
                        SaleItemFifoAllocation.unit_cost_at_sale.is_(None),
                    )
                ).all()
                for allocation in allocations:
                    allocation.unit_cost_at_sale = layer.unit_cost

                layer.remaining_quantity = float(remaining - quantity)
                corrected_layer = InventoryLotRecord(
                    id=corrected_layer_id,
                    shop_id=context.shop_id,
                    product_id=product_id,
                    movement_id=movement_id,
                    source_type="cost_correction",
                    source_id=correction_id,
                    source_reference=layer.source_reference or layer.source_id,
                    received_quantity=float(quantity),
                    remaining_quantity=float(quantity),
                    unit_cost=float(new_unit_cost),
                    acquired_at=layer.acquired_at,
                    lineage_id=layer.movement_id,
                    fifo_order=f"{fifo_order}/{now.isoformat()}|{movement_id}",
                    parent_layer_id=layer.id,
                )
                db.add(corrected_layer)
                db.flush()

                correction = FifoCostCorrection(
                    id=correction_id,
                    shop_id=context.shop_id,
                    product_id=product_id,
                    source_layer_id=layer.id,
                    resulting_layer_id=corrected_layer_id,
                    source_movement_id=layer.movement_id,
                    correction_movement_id=movement_id,
                    source_reference=layer.source_reference or layer.source_id,
                    quantity=float(quantity),
                    old_unit_cost=float(old_unit_cost),
                    new_unit_cost=float(new_unit_cost),
                    value_difference=float(value_difference),
                    reason=reason,
                    posted_by=context.user_id,
                    idempotency_key=key,
                    request_hash=payload_hash,
                    created_at=now,
                )
                db.add(correction)
                db.add(
                    StockMovement(
                        id=movement_id,
                        shop_id=context.shop_id,
                        product_id=product_id,
                        movement_type="cost_correction",
                        quantity_change=0,
                        unit_cost=float(new_unit_cost),
                        running_stock=float(product.stock),
                        reference_type="cost_correction",
                        reference_id=correction_id,
                        lineage_id=layer.movement_id,
                        notes=reason,
                        user_id=context.user_id,
                        device_id=context.device_id,
                        created_at=now,
                    )
                )
                response = FifoCostCorrectionResponse(
                    correction_id=correction_id,
                    product_id=product_id,
                    source_layer_id=layer.id,
                    resulting_layer_id=corrected_layer_id,
                    source_reference=correction.source_reference,
                    quantity=float(quantity),
                    old_unit_cost=float(old_unit_cost),
                    new_unit_cost=float(new_unit_cost),
                    value_difference=float(value_difference),
                    reason=reason,
                    posted_by=context.user_id,
                    created_at=now,
                )
                db.add(
                    IdempotencyRecord(
                        id=f"idempotency-{uuid4().hex}",
                        shop_id=context.shop_id,
                        idempotency_key=key,
                        request_hash=payload_hash,
                        response_json=response.model_dump_json(),
                        status_code=201,
                        device_id=context.device_id,
                    )
                )
            return response
        except HTTPException:
            raise
        except IntegrityError as error:
            db.rollback()
            raise HTTPException(
                status_code=409,
                detail="FIFO cost correction conflicted with another request",
            ) from error
        except ValueError as error:
            raise HTTPException(status_code=422, detail=str(error)) from error


@app.get(
    "/api/v1/products/{product_id}/stock-movements",
    response_model=list[StockMovementResponse],
)
def get_product_stock_movements(
    product_id: str,
    db: Session = Depends(get_db),
    context: ServerContext = Depends(get_server_context),
) -> list[StockMovementResponse]:
    product = db.scalar(
        select(Product).where(
            Product.id == product_id,
            Product.shop_id == context.shop_id,
        )
    )
    if product is None:
        raise HTTPException(status_code=404, detail="Product not found")

    movements = db.scalars(
        select(StockMovement)
        .where(
            StockMovement.product_id == product_id,
            StockMovement.shop_id == context.shop_id,
        )
        .order_by(StockMovement.created_at.desc(), StockMovement.id.desc())
    ).all()
    product_corrections = db.scalars(
        select(FifoCostCorrection).where(
            FifoCostCorrection.shop_id == context.shop_id,
            FifoCostCorrection.product_id == product_id,
        )
    ).all()
    corrections_by_movement = {
        correction.correction_movement_id: correction
        for correction in product_corrections
    }
    removal_costs: dict[str, Decimal] = {}
    chronological_movements = sorted(
        movements,
        key=lambda movement: (movement.created_at, movement.id),
    )
    prior_movements: list[InventoryMovement] = []
    for movement in chronological_movements:
        if movement.quantity_change < 0:
            try:
                prior_lots = FifoInventoryCostingService.build_lots_from_movements(
                    prior_movements
                )
                costing = FifoInventoryCostingService.apply_reduction(
                    prior_lots,
                    abs(Decimal(str(movement.quantity_change))),
                )
                removal_costs[movement.id] = costing.average_cost
            except ValueError:
                # Keep legacy movement data visible if its historical FIFO
                # chain cannot be reconstructed.
                pass
        prior_movements.append(
            InventoryMovement.from_orm(
                movement,
                correction=corrections_by_movement.get(movement.id),
            )
        )
    adjustment_ids = {
        movement.reference_id
        for movement in movements
        if movement.reference_type == "stock_adjustment" and movement.reference_id
    }
    opening_ids = {
        movement.reference_id
        for movement in movements
        if movement.reference_type == "opening_stock" and movement.reference_id
    }
    adjustment_references = {
        document.id: document.reference_number
        for document in db.scalars(
            select(StockAdjustmentDocument).where(
                StockAdjustmentDocument.shop_id == context.shop_id,
                StockAdjustmentDocument.id.in_(adjustment_ids),
            )
        ).all()
    } if adjustment_ids else {}
    opening_references = {
        document.id: document.reference_number
        for document in db.scalars(
            select(OpeningStockDocument).where(
                OpeningStockDocument.shop_id == context.shop_id,
                OpeningStockDocument.id.in_(opening_ids),
            )
        ).all()
    } if opening_ids else {}
    correction_ids = {
        movement.reference_id
        for movement in movements
        if movement.reference_type == "cost_correction" and movement.reference_id
    }
    corrections = {
        correction.id: correction
        for correction in product_corrections
        if correction.id in correction_ids
    }
    correction_users = {
        user.id: user.display_name
        for user in db.scalars(
            select(User).where(
                User.id.in_(
                    {correction.posted_by for correction in corrections.values()}
                )
            )
        ).all()
    } if corrections else {}
    return [
        StockMovementResponse(
            id=movement.id,
            product_id=movement.product_id,
            product_barcode=product.barcode,
            product_name=product.name,
            movement_type=movement.movement_type,
            quantity_change=movement.quantity_change,
            unit_cost=float(
                removal_costs.get(
                    movement.id,
                    Decimal(str(movement.unit_cost or 0)),
                )
                if movement.quantity_change < 0
                else movement.unit_cost
            ),
            line_total=float(
                Decimal(str(abs(movement.quantity_change)))
                * (
                    removal_costs.get(
                        movement.id,
                        Decimal(str(movement.unit_cost or 0)),
                    )
                    if movement.quantity_change < 0
                    else Decimal(str(movement.unit_cost or 0))
                )
            ),
            running_stock=movement.running_stock,
            reference_type=movement.reference_type,
            reference_id=movement.reference_id,
            reference_line_id=movement.reference_line_id,
            notes=movement.notes,
            user_id=movement.user_id,
            created_at=movement.created_at,
            correction_quantity=(
                corrections[movement.reference_id].quantity
                if movement.reference_id in corrections
                else None
            ),
            old_unit_cost=(
                corrections[movement.reference_id].old_unit_cost
                if movement.reference_id in corrections
                else None
            ),
            new_unit_cost=(
                corrections[movement.reference_id].new_unit_cost
                if movement.reference_id in corrections
                else None
            ),
            value_difference=(
                corrections[movement.reference_id].value_difference
                if movement.reference_id in corrections
                else None
            ),
            correction_user=(
                correction_users.get(
                    corrections[movement.reference_id].posted_by
                )
                if movement.reference_id in corrections
                else None
            ),
            source_description=(
                ("Cost Correction")
                if movement.reference_type == "cost_correction"
                else (
                    "Adjustment "
                    f"{adjustment_references[movement.reference_id]}"
                )
                if movement.reference_type == "stock_adjustment"
                and movement.reference_id in adjustment_references
                else (
                    (
                        "Opening Stock "
                        f"{opening_references[movement.reference_id]}"
                    )
                    if movement.reference_type == "opening_stock"
                    and movement.reference_id in opening_references
                    else (
                        f"{movement.reference_type}: {movement.reference_id}"
                        if movement.reference_type and movement.reference_id
                        else movement.reference_id
                    )
                )
            ),
        )
        for movement in movements
    ]


@app.get("/api/v1/products/barcode/{barcode}", response_model=ProductResponse)
def product_by_barcode(
    barcode: str,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> ProductResponse:
    normalized = barcode.strip()
    if not normalized:
        raise HTTPException(status_code=422, detail="Barcode is required")
    product = db.scalar(
        product_query(current_user.shop_id).where(
            func.trim(Product.barcode) == normalized,
            Product.is_active.is_(True),
        )
    )
    if product is None and db.scalar(
        select(Product.id).where(
            Product.shop_id == current_user.shop_id,
            func.trim(Product.barcode) == normalized,
            Product.is_active.is_(False),
        )
    ) is not None:
        raise HTTPException(status_code=410, detail="Product is inactive")
    if product is None:
        raise HTTPException(status_code=404, detail="Product not found for barcode")
    return product_response(product)


@app.get("/api/v1/products/{product_id}", response_model=ProductResponse)
def product_detail(
    product_id: str,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> ProductResponse:
    product = db.scalar(product_query(current_user.shop_id).where(Product.id == product_id))
    if product is None:
        raise HTTPException(status_code=404, detail="Product not found")
    return product_response(product)


@app.get("/api/v1/stock/summary", response_model=StockSummaryResponse)
def stock_summary(
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> StockSummaryResponse:
    _require_permission(ServerContext.from_user(current_user), Permission.VIEW_STOCK_SUMMARY)
    filters = (Product.shop_id == current_user.shop_id, Product.is_active.is_(True))
    total = db.scalar(select(func.count(Product.id)).where(*filters)) or 0
    products = db.scalars(
        select(Product).where(*filters)
    ).all()
    low = 0
    for product in products:
        threshold = float(product.min_stock)
        for unit in product.selling_units:
            if unit.is_active and float(unit.minimum_stock) > 0:
                threshold = max(
                    threshold,
                    float(unit.minimum_stock) * float(unit.conversion_to_base),
                )
        if float(product.stock) > 0 and float(product.stock) <= threshold:
            low += 1
    out = db.scalar(select(func.count(Product.id)).where(*filters, Product.stock <= 0)) or 0
    quantity = db.scalar(select(func.coalesce(func.sum(Product.stock), 0)).where(*filters)) or 0
    return StockSummaryResponse(
        total_products=total,
        low_stock_products=low,
        out_of_stock_products=out,
        total_stock_quantity=quantity,
    )


@app.get("/api/v1/stock-summary", response_model=StockSummaryDetailResponse)
def stock_summary_detail(
    db: Session = Depends(get_db),
    context: ServerContext = Depends(get_server_context),
) -> StockSummaryDetailResponse:
    _require_permission(context, Permission.VIEW_STOCK_SUMMARY)
    products = db.scalars(
        select(Product).where(
            Product.shop_id == context.shop_id,
            Product.is_active.is_(True),
        )
    ).all()
    sold_rows = db.execute(
        select(
            Product.category_id,
            SaleItem.product_id,
            func.coalesce(func.sum(SaleItem.base_quantity), 0),
        )
        .join(SaleDocument, SaleItem.sale_id == SaleDocument.id)
        .join(Product, Product.id == SaleItem.product_id)
        .where(
            SaleDocument.shop_id == context.shop_id,
            SaleDocument.status == "POSTED",
        )
        .group_by(Product.category_id, SaleItem.product_id)
    ).all()
    historic_rows = db.execute(
        select(
            Product.category_id,
            func.coalesce(
                func.sum(StockMovement.quantity_change * StockMovement.unit_cost),
                0,
            ),
        )
        .join(Product, Product.id == StockMovement.product_id)
        .where(
            StockMovement.shop_id == context.shop_id,
            StockMovement.quantity_change > 0,
            StockMovement.movement_type.in_(
                ("opening_stock", "purchase", "stock_adjustment")
            ),
        )
        .group_by(Product.category_id)
    ).all()
    historic_by_category = {
        category_id or "General": float(value or 0)
        for category_id, value in historic_rows
    }
    correction_rows = db.execute(
        select(
            Product.category_id,
            func.coalesce(func.sum(FifoCostCorrection.value_difference), 0),
        )
        .join(Product, Product.id == FifoCostCorrection.product_id)
        .where(FifoCostCorrection.shop_id == context.shop_id)
        .group_by(Product.category_id)
    ).all()
    for category_id, value in correction_rows:
        key = category_id or "General"
        historic_by_category[key] = historic_by_category.get(key, 0.0) + float(
            value or 0
        )
    sold_by_category: dict[str, float] = {}
    for category_id, _, quantity in sold_rows:
        key = category_id or "General"
        sold_by_category[key] = sold_by_category.get(key, 0.0) + float(quantity or 0)

    grouped: dict[str, list[Product]] = {}
    for product in products:
        grouped.setdefault(product.category_id or "General", []).append(product)

    categories = []
    category_names = {
        category.id: category.name
        for category in db.scalars(
            select(Category).where(Category.shop_id == context.shop_id)
        ).all()
    }
    for category, category_products in grouped.items():
        current = 0.0
        quantity_by_unit: dict[str, float] = {}
        wholesale_prices_by_unit: dict[str, list[float]] = {}
        for product in category_products:
            quantity_by_unit[product.base_unit] = (
                quantity_by_unit.get(product.base_unit, 0.0)
                + float(product.stock)
            )
            if product.product_type.upper() == "PACKAGED":
                for unit in product.selling_units:
                    if unit.is_active and unit.wholesale_price is not None:
                        wholesale_prices_by_unit.setdefault(
                            unit.name, []
                        ).append(float(unit.wholesale_price))
            try:
                lots = FifoInventoryCostingService.rebuild_lots_from_history(
                    db, product.id, shop_id=context.shop_id
                )
            except ValueError:
                lots = FifoInventoryCostingService.lots_for_product(
                    db, product.id, shop_id=context.shop_id
                )
            if lots:
                current += sum(float(lot.total_value) for lot in lots)
            else:
                current += float(product.stock) * float(product.cost)
        minimum = sum(float(p.stock) * float(p.min_price) for p in category_products)
        expected = 0.0
        for product in category_products:
            if product.product_type.upper() != "PACKAGED":
                expected += float(product.stock) * float(product.price)
                continue
            remaining = float(product.stock)
            units = sorted(
                (
                    unit
                    for unit in product.selling_units
                    if unit.is_active and unit.conversion_to_base > 0
                ),
                key=lambda unit: float(unit.conversion_to_base),
                reverse=True,
            )
            for unit in units:
                conversion = float(unit.conversion_to_base)
                count = int(remaining // conversion)
                expected += count * float(unit.selling_price)
                remaining -= count * conversion
        sold_value = sold_by_category.get(category, 0.0)
        categories.append(
            StockSummaryCategoryResponse(
                category_id=category,
                category_name=category_names.get(category, category),
                product_count=len(category_products),
                total_quantity=sum(float(p.stock) for p in category_products),
                total_sold_quantity=sold_value,
                total_historic_value=historic_by_category.get(category, 0.0),
                total_current_inventory_cost=current,
                total_min_sell_value=minimum,
                total_default_sell_value=expected,
                quantity_by_unit=quantity_by_unit,
                wholesale_prices_by_unit=wholesale_prices_by_unit,
            )
        )
    categories.sort(key=lambda item: item.category_name)
    current_total = sum(item.total_current_inventory_cost for item in categories)
    expected_profit = sum(
        item.total_default_sell_value - item.total_current_inventory_cost
        for item in categories
    )
    return StockSummaryDetailResponse(
        categories=categories,
        total_store_historic_value=sum(
            item.total_historic_value or 0 for item in categories
        ),
        total_store_current_inventory_cost=current_total,
        total_expected_profit=expected_profit,
    )
