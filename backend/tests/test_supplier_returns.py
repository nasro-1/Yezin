from collections.abc import Generator
from datetime import datetime
from decimal import Decimal

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, select
from sqlalchemy.orm import Session, sessionmaker

from app.database import Base, get_db
from app.main import app
from app.models import (
    IdempotencyRecord,
    InventoryLotRecord,
    Product,
    PurchaseDocument,
    PurchaseLine,
    Shop,
    StockMovement,
    Supplier,
    SupplierLedger,
    SupplierReturnDocument,
    SupplierReturnLine,
    User,
)
from app.security import hash_password


@pytest.fixture
def return_client(tmp_path) -> Generator[TestClient, None, None]:
    engine = create_engine(
        f"sqlite:///{tmp_path / 'supplier-returns.db'}",
        connect_args={"check_same_thread": False},
    )
    Base.metadata.create_all(engine)
    factory = sessionmaker(bind=engine, autoflush=False, expire_on_commit=False)
    previous_factory = getattr(app.state, "test_session_factory", None)
    app.state.test_session_factory = factory

    def override() -> Generator[Session, None, None]:
        with factory() as session:
            yield session

    app.dependency_overrides[get_db] = override
    with factory() as db:
        db.add_all(
            [
                Shop(id="return-shop", name="Return Shop"),
                Shop(id="other-return-shop", name="Other Return Shop"),
                User(
                    id="return-admin",
                    shop_id="return-shop",
                    username="return-admin",
                    display_name="Return Admin",
                    password_hash=hash_password("pw"),
                    role="admin",
                ),
                User(
                    id="return-cashier",
                    shop_id="return-shop",
                    username="return-cashier",
                    display_name="Return Cashier",
                    password_hash=hash_password("pw"),
                    role="cashier",
                ),
                Supplier(
                    id="return-supplier",
                    shop_id="return-shop",
                    code="SUP-000001",
                    name="Test Supplier",
                ),
                Supplier(
                    id="another-return-supplier",
                    shop_id="return-shop",
                    code="SUP-000002",
                    name="Another Supplier",
                ),
                Supplier(
                    id="foreign-return-supplier",
                    shop_id="other-return-shop",
                    code="SUP-000001",
                    name="Foreign Supplier",
                ),
                Product(
                    id="return-product",
                    shop_id="return-shop",
                    name="Olive Oil Premium",
                    product_type="WEIGHTED",
                    base_unit="kg",
                    stock=10,
                    cost=900,
                    is_active=True,
                ),
                PurchaseDocument(
                    id="return-purchase",
                    shop_id="return-shop",
                    reference="PUR-1790707886631140-1",
                    supplier_id="return-supplier",
                    purchase_date=datetime(2026, 9, 29),
                    subtotal=Decimal("9000.00"),
                    total=Decimal("9000.00"),
                    status="POSTED",
                    created_by="return-admin",
                    idempotency_key="purchase-key",
                    created_at=datetime(2026, 9, 29),
                ),
                PurchaseLine(
                    id="return-purchase-line",
                    purchase_id="return-purchase",
                    product_id="return-product",
                    quantity=Decimal("10"),
                    unit_cost=Decimal("900"),
                    line_total=Decimal("9000.00"),
                    selling_quantity=None,
                    conversion_factor_snapshot=Decimal("1"),
                    selling_unit_name_snapshot="kg",
                    base_unit_snapshot="kg",
                ),
                StockMovement(
                    id="return-purchase-movement",
                    shop_id="return-shop",
                    product_id="return-product",
                    movement_type="purchase",
                    quantity_change=10,
                    unit_cost=900,
                    running_stock=10,
                    reference_type="purchase",
                    reference_id="return-purchase",
                    created_at=datetime(2026, 9, 29),
                ),
                InventoryLotRecord(
                    id="return-purchase-lot",
                    shop_id="return-shop",
                    product_id="return-product",
                    movement_id="return-purchase-movement",
                    source_type="purchase",
                    source_id="return-purchase",
                    source_reference="PUR-1790707886631140-1",
                    received_quantity=10,
                    remaining_quantity=10,
                    unit_cost=900,
                    acquired_at=datetime(2026, 9, 29),
                ),
                SupplierLedger(
                    id="return-purchase-ledger",
                    shop_id="return-shop",
                    supplier_id="return-supplier",
                    entry_type="purchase",
                    amount=Decimal("9000.00"),
                    balance_after=Decimal("9000.00"),
                    reference_type="purchase",
                    reference_id="return-purchase",
                    notes="Purchase",
                    created_at=datetime(2026, 9, 29),
                ),
            ]
        )
        db.commit()
    try:
        yield TestClient(app)
    finally:
        app.dependency_overrides.pop(get_db, None)
        if previous_factory is None:
            del app.state.test_session_factory
        else:
            app.state.test_session_factory = previous_factory
        engine.dispose()


def _token(client: TestClient, username: str = "return-admin") -> str:
    response = client.post(
        "/api/v1/auth/login", json={"username": username, "password": "pw"}
    )
    assert response.status_code == 200
    return response.json()["access_token"]


def _headers(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


def _payload(**updates) -> dict:
    payload = {
        "idempotency_key": "return-request-1",
        "reference": "SR-TEST-1",
        "purchase_id": "return-purchase",
        "return_date": "2026-09-30T10:00:00",
        "lines": [
            {
                "purchase_item_id": "return-purchase-line",
                "product_id": "return-product",
                "quantity": "5",
            }
        ],
    }
    payload.update(updates)
    return payload


def test_server_supplier_return_updates_stock_fifo_and_supplier_ledger_atomically(
    return_client: TestClient,
) -> None:
    token = _token(return_client)
    response = return_client.post(
        "/api/v1/suppliers/return-supplier/returns",
        headers=_headers(token),
        json=_payload(),
    )
    assert response.status_code == 201, response.text
    body = response.json()
    assert body["reference"] == "SR-TEST-1"
    assert body["source_purchase_reference"] == "PUR-1790707886631140-1"
    assert Decimal(body["total"]) == Decimal("4500.00")
    assert Decimal(body["lines"][0]["quantity"]) == Decimal("5")
    assert Decimal(body["lines"][0]["base_quantity"]) == Decimal("5")
    assert Decimal(body["lines"][0]["unit_cost"]) == Decimal("900")
    assert body["status"] == "POSTED"

    balance = return_client.get(
        "/api/v1/suppliers/return-supplier/balance",
        headers=_headers(token),
    )
    assert Decimal(balance.json()["balance"]) == Decimal("4500.00")

    with return_client.app.state.test_session_factory() as db:
        product = db.get(Product, "return-product")
        lot = db.get(InventoryLotRecord, "return-purchase-lot")
        movement = db.scalar(
            select(StockMovement).where(
                StockMovement.reference_id == body["return_id"],
                StockMovement.movement_type == "supplier_return",
            )
        )
        ledger = db.scalar(
            select(SupplierLedger).where(
                SupplierLedger.reference_id == body["return_id"],
                SupplierLedger.entry_type == "supplier_return",
            )
        )
        assert Decimal(str(product.stock)) == Decimal("5")
        assert Decimal(str(lot.remaining_quantity)) == Decimal("5")
        assert movement is not None
        assert Decimal(str(movement.quantity_change)) == Decimal("-5")
        assert Decimal(str(movement.unit_cost)) == Decimal("900")
        assert ledger is not None
        assert ledger.amount == Decimal("-4500.00")
        assert ledger.balance_after == Decimal("4500.00")
        assert len(db.scalars(select(SupplierReturnDocument)).all()) == 1
        assert len(db.scalars(select(SupplierReturnLine)).all()) == 1
        assert db.scalar(
            select(IdempotencyRecord).where(
                IdempotencyRecord.idempotency_key == "return-request-1"
            )
        ) is not None


def test_supplier_return_retry_is_idempotent_and_payload_conflicts_are_rejected(
    return_client: TestClient,
) -> None:
    headers = _headers(_token(return_client))
    path = "/api/v1/suppliers/return-supplier/returns"
    first = return_client.post(path, headers=headers, json=_payload())
    retry = return_client.post(path, headers=headers, json=_payload())
    assert first.status_code == retry.status_code == 201
    assert first.json() == retry.json()
    conflict = return_client.post(
        path,
        headers=headers,
        json=_payload(lines=[
            {
                "purchase_item_id": "return-purchase-line",
                "product_id": "return-product",
                "quantity": "4",
            }
        ]),
    )
    assert conflict.status_code == 409
    with return_client.app.state.test_session_factory() as db:
        assert len(db.scalars(select(SupplierReturnDocument)).all()) == 1


def test_supplier_return_rejects_over_return_and_rolls_back_all_effects(
    return_client: TestClient,
) -> None:
    response = return_client.post(
        "/api/v1/suppliers/return-supplier/returns",
        headers=_headers(_token(return_client)),
        json=_payload(
            idempotency_key="too-much",
            reference="SR-TOO-MUCH",
            lines=[
                {
                    "purchase_item_id": "return-purchase-line",
                    "product_id": "return-product",
                    "quantity": "11",
                }
            ],
        ),
    )
    assert response.status_code == 422
    with return_client.app.state.test_session_factory() as db:
        assert Decimal(str(db.get(Product, "return-product").stock)) == Decimal("10")
        assert len(db.scalars(select(SupplierReturnDocument)).all()) == 0
        assert len(db.scalars(
            select(SupplierLedger).where(SupplierLedger.entry_type == "supplier_return")
        ).all()) == 0
        assert len(db.scalars(
            select(StockMovement).where(StockMovement.movement_type == "supplier_return")
        ).all()) == 0


def test_supplier_return_caps_subsequent_returns_to_the_remaining_quantity(
    return_client: TestClient,
) -> None:
    headers = _headers(_token(return_client))
    path = "/api/v1/suppliers/return-supplier/returns"
    first = return_client.post(
        path,
        headers=headers,
        json=_payload(
            idempotency_key="partial-return-1",
            reference="SR-PARTIAL-1",
            lines=[
                {
                    "purchase_item_id": "return-purchase-line",
                    "product_id": "return-product",
                    "quantity": "6",
                }
            ],
        ),
    )
    assert first.status_code == 201, first.text

    exceeds_remaining = return_client.post(
        path,
        headers=headers,
        json=_payload(
            idempotency_key="partial-return-2",
            reference="SR-PARTIAL-2",
            lines=[
                {
                    "purchase_item_id": "return-purchase-line",
                    "product_id": "return-product",
                    "quantity": "5",
                }
            ],
        ),
    )
    assert exceeds_remaining.status_code == 422
    with return_client.app.state.test_session_factory() as db:
        assert Decimal(str(db.get(Product, "return-product").stock)) == Decimal("4")
        assert len(db.scalars(select(SupplierReturnDocument)).all()) == 1
        assert len(db.scalars(
            select(SupplierReturnLine).where(
                SupplierReturnLine.purchase_line_id == "return-purchase-line"
            )
        ).all()) == 1


def test_supplier_return_rejects_wrong_supplier_and_non_posted_purchase(
    return_client: TestClient,
) -> None:
    token = _token(return_client)
    wrong_supplier = return_client.post(
        "/api/v1/suppliers/another-return-supplier/returns",
        headers=_headers(token),
        json=_payload(idempotency_key="wrong-supplier"),
    )
    assert wrong_supplier.status_code == 404

    with return_client.app.state.test_session_factory() as db:
        db.get(PurchaseDocument, "return-purchase").status = "CANCELLED"
        db.commit()
    not_posted = return_client.post(
        "/api/v1/suppliers/return-supplier/returns",
        headers=_headers(token),
        json=_payload(idempotency_key="not-posted"),
    )
    assert not_posted.status_code == 422
    with return_client.app.state.test_session_factory() as db:
        assert len(db.scalars(select(SupplierReturnDocument)).all()) == 0


def test_supplier_return_rejects_cross_shop_supplier_and_cashier(
    return_client: TestClient,
) -> None:
    admin = _headers(_token(return_client))
    foreign = return_client.post(
        "/api/v1/suppliers/foreign-return-supplier/returns",
        headers=admin,
        json=_payload(idempotency_key="foreign-supplier"),
    )
    assert foreign.status_code == 404
    cashier = return_client.post(
        "/api/v1/suppliers/return-supplier/returns",
        headers=_headers(_token(return_client, "return-cashier")),
        json=_payload(idempotency_key="cashier-return"),
    )
    assert cashier.status_code == 403
