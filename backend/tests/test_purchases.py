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
    User,
)
from app.security import hash_password


@pytest.fixture
def purchase_client(tmp_path) -> Generator[TestClient, None, None]:
    engine = create_engine(
        f"sqlite:///{tmp_path / 'purchases.db'}",
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
        db.add_all([
            Shop(id="purchase-shop", name="Purchase Shop"),
            Shop(id="other-shop", name="Other Shop"),
            User(
                id="purchase-admin",
                shop_id="purchase-shop",
                username="purchase-admin",
                display_name="Purchase Admin",
                password_hash=hash_password("pw"),
                role="admin",
            ),
            User(
                id="purchase-cashier",
                shop_id="purchase-shop",
                username="purchase-cashier",
                display_name="Purchase Cashier",
                password_hash=hash_password("pw"),
                role="cashier",
            ),
            User(
                id="other-admin",
                shop_id="other-shop",
                username="other-admin",
                display_name="Other Admin",
                password_hash=hash_password("pw"),
                role="admin",
            ),
            Supplier(
                id="supplier-one",
                shop_id="purchase-shop",
                code="SUP-000001",
                name="Test Supplier",
            ),
            Supplier(
                id="supplier-other",
                shop_id="other-shop",
                code="SUP-000001",
                name="Other Supplier",
            ),
            Product(
                id="olive-oil",
                shop_id="purchase-shop",
                name="Olive Oil Premium",
                product_type="WEIGHTED",
                base_unit="kg",
                stock=25,
                cost=500,
                is_active=True,
            ),
            Product(
                id="other-product",
                shop_id="other-shop",
                name="Other Product",
                base_unit="piece",
                stock=0,
            ),
        ])
        db.flush()
        for index, (quantity, cost, acquired_at) in enumerate([
            (15.0, 500.0, datetime(2026, 1, 1)),
            (10.0, 800.0, datetime(2026, 1, 2)),
        ]):
            movement_id = f"existing-movement-{index}"
            db.add(StockMovement(
                id=movement_id,
                shop_id="purchase-shop",
                product_id="olive-oil",
                movement_type="opening_stock" if index == 0 else "purchase",
                quantity_change=quantity,
                unit_cost=cost,
                running_stock=quantity if index == 0 else 25.0,
                reference_type="opening_stock" if index == 0 else "purchase",
                reference_id=f"existing-reference-{index}",
                created_at=acquired_at,
            ))
            db.add(InventoryLotRecord(
                id=f"existing-lot-{index}",
                shop_id="purchase-shop",
                product_id="olive-oil",
                movement_id=movement_id,
                source_type="purchase",
                source_id=f"existing-reference-{index}",
                source_reference=f"existing-reference-{index}",
                received_quantity=quantity,
                remaining_quantity=quantity,
                unit_cost=cost,
                acquired_at=acquired_at,
            ))
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


def _token(client: TestClient, username: str) -> str:
    response = client.post(
        "/api/v1/auth/login", json={"username": username, "password": "pw"}
    )
    assert response.status_code == 200
    return response.json()["access_token"]


def _headers(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


def _payload(**updates) -> dict:
    payload = {
        "idempotency_key": "purchase-idempotency-1",
        "reference": "PUR-TEST-1",
        "supplier_id": "supplier-one",
        "purchase_date": "2026-09-29T10:00:00",
        "notes": "Olive oil restock",
        "lines": [
            {
                "product_id": "olive-oil",
                "quantity": "10",
                "unit_cost": "900",
            }
        ],
    }
    payload.update(updates)
    return payload


def test_weighted_purchase_persists_header_stock_fifo_and_supplier_ledger(
    purchase_client: TestClient,
) -> None:
    token = _token(purchase_client, "purchase-admin")
    response = purchase_client.post(
        "/api/v1/purchases",
        headers=_headers(token),
        json=_payload(),
    )
    assert response.status_code == 201, response.text
    body = response.json()
    assert body["subtotal"] == "9000.00"
    assert body["total"] == "9000.00"
    assert Decimal(body["items"][0]["quantity"]) == Decimal("10")
    assert Decimal(body["items"][0]["unit_cost"]) == Decimal("900")
    assert Decimal(body["items"][0]["line_total"]) == Decimal("9000.00")

    with purchase_client.app.state.test_session_factory() as db:
        product = db.get(Product, "olive-oil")
        assert product.stock == 35
        assert product.cost == 500
        lots = db.scalars(
            select(InventoryLotRecord)
            .where(InventoryLotRecord.product_id == "olive-oil")
            .order_by(InventoryLotRecord.acquired_at, InventoryLotRecord.id)
        ).all()
        assert [(lot.remaining_quantity, lot.unit_cost) for lot in lots] == [
            (15, 500),
            (10, 800),
            (10, 900),
        ]
        movements = db.scalars(
            select(StockMovement).where(
                StockMovement.reference_id == body["id"]
            )
        ).all()
        assert len(movements) == 1
        assert movements[0].quantity_change == 10
        assert movements[0].unit_cost == 900
        purchase = db.get(PurchaseDocument, body["id"])
        assert purchase is not None
        assert purchase.reference == "PUR-TEST-1"
        assert purchase.supplier_id == "supplier-one"
        assert db.scalar(
            select(PurchaseLine).where(PurchaseLine.purchase_id == body["id"])
        ).line_total == Decimal("9000.00")
        ledger = db.scalar(
            select(SupplierLedger).where(
                SupplierLedger.reference_id == body["id"]
            )
        )
        assert ledger.amount == Decimal("9000.00")
        assert ledger.balance_after == Decimal("9000.00")
        assert db.scalar(
            select(IdempotencyRecord).where(
                IdempotencyRecord.idempotency_key == "purchase-idempotency-1"
            )
        ) is not None


def test_purchase_ignores_client_current_stock(purchase_client: TestClient) -> None:
    token = _token(purchase_client, "purchase-admin")
    payload = _payload()
    payload["lines"][0]["currentStock"] = 900000
    response = purchase_client.post(
        "/api/v1/purchases", headers=_headers(token), json=payload
    )
    assert response.status_code == 201, response.text
    with purchase_client.app.state.test_session_factory() as db:
        assert db.get(Product, "olive-oil").stock == 35


def test_purchase_is_idempotent_and_rejects_reused_key_with_different_body(
    purchase_client: TestClient,
) -> None:
    token = _token(purchase_client, "purchase-admin")
    headers = _headers(token)
    first = purchase_client.post(
        "/api/v1/purchases", headers=headers, json=_payload()
    )
    retry = purchase_client.post(
        "/api/v1/purchases", headers=headers, json=_payload()
    )
    assert first.status_code == retry.status_code == 201
    assert retry.json() == first.json()
    conflict = purchase_client.post(
        "/api/v1/purchases",
        headers=headers,
        json=_payload(notes="different request"),
    )
    assert conflict.status_code == 409
    with purchase_client.app.state.test_session_factory() as db:
        assert db.scalar(select(PurchaseDocument.id)) is not None
        assert len(db.scalars(select(PurchaseDocument)).all()) == 1
        assert db.get(Product, "olive-oil").stock == 35
        assert len(db.scalars(select(InventoryLotRecord)).all()) == 3
        assert len(db.scalars(select(SupplierLedger)).all()) == 1


@pytest.mark.parametrize(
    ("line_updates", "status"),
    [
        ({"quantity": "0"}, 422),
        ({"quantity": "-1"}, 422),
        ({"unit_cost": "-1"}, 422),
        ({"product_id": "missing-product"}, 404),
    ],
)
def test_invalid_purchase_line_is_rejected_without_partial_writes(
    purchase_client: TestClient, line_updates: dict, status: int
) -> None:
    token = _token(purchase_client, "purchase-admin")
    payload = _payload()
    payload["lines"][0].update(line_updates)
    response = purchase_client.post(
        "/api/v1/purchases", headers=_headers(token), json=payload
    )
    assert response.status_code == status, response.text
    with purchase_client.app.state.test_session_factory() as db:
        assert db.get(Product, "olive-oil").stock == 25
        assert db.scalars(select(PurchaseDocument)).all() == []
        assert db.scalars(select(PurchaseLine)).all() == []
        assert len(db.scalars(select(InventoryLotRecord)).all()) == 2
        assert db.scalars(select(SupplierLedger)).all() == []


def test_invalid_supplier_and_cross_shop_product_are_rejected(
    purchase_client: TestClient,
) -> None:
    token = _token(purchase_client, "purchase-admin")
    bad_supplier = purchase_client.post(
        "/api/v1/purchases",
        headers=_headers(token),
        json=_payload(supplier_id="supplier-other"),
    )
    assert bad_supplier.status_code == 404
    bad_product_payload = _payload()
    bad_product_payload["lines"][0]["product_id"] = "other-product"
    bad_product = purchase_client.post(
        "/api/v1/purchases", headers=_headers(token), json=bad_product_payload
    )
    assert bad_product.status_code == 404

    suppliers = purchase_client.get("/api/v1/suppliers", headers=_headers(token))
    assert suppliers.status_code == 200
    assert [item["id"] for item in suppliers.json()["items"]] == ["supplier-one"]
    other_supplier = purchase_client.get(
        "/api/v1/suppliers/supplier-other", headers=_headers(token)
    )
    assert other_supplier.status_code == 404


def test_purchase_rolls_back_header_and_first_line_if_later_line_fails(
    purchase_client: TestClient,
) -> None:
    token = _token(purchase_client, "purchase-admin")
    payload = _payload()
    payload["lines"].append({
        "product_id": "missing-after-valid",
        "quantity": "1",
        "unit_cost": "50",
    })
    response = purchase_client.post(
        "/api/v1/purchases", headers=_headers(token), json=payload
    )
    assert response.status_code == 404
    with purchase_client.app.state.test_session_factory() as db:
        assert db.get(Product, "olive-oil").stock == 25
        assert db.scalars(select(PurchaseDocument)).all() == []
        assert db.scalars(select(PurchaseLine)).all() == []
        assert len(db.scalars(select(InventoryLotRecord)).all()) == 2
        assert db.scalars(select(SupplierLedger)).all() == []
        assert db.scalars(select(IdempotencyRecord)).all() == []


def test_purchase_permission_and_supplier_crud_are_server_scoped(
    purchase_client: TestClient,
) -> None:
    admin = _headers(_token(purchase_client, "purchase-admin"))
    cashier = _headers(_token(purchase_client, "purchase-cashier"))
    denied = purchase_client.post(
        "/api/v1/purchases", headers=cashier, json=_payload()
    )
    assert denied.status_code == 403

    created = purchase_client.post(
        "/api/v1/suppliers",
        headers=admin,
        json={
            "id": "new-server-supplier",
            "name": "New Server Supplier",
            "opening_balance": "125.00",
            "phone": "555-0100",
        },
    )
    assert created.status_code == 201, created.text
    assert created.json()["code"] == "SUP-000002"
    assert created.json()["opening_balance"] == "125.00"
    assert created.json()["current_balance"] == "125.00"
    ledger = purchase_client.get(
        "/api/v1/suppliers/new-server-supplier/ledger", headers=admin
    )
    assert ledger.status_code == 200
    assert ledger.json()[0]["amount"] == "125.00"
    updated = purchase_client.put(
        "/api/v1/suppliers/new-server-supplier",
        headers=admin,
        json={"name": "Updated Server Supplier"},
    )
    assert updated.status_code == 200
    assert updated.json()["name"] == "Updated Server Supplier"
    deleted = purchase_client.delete(
        "/api/v1/suppliers/new-server-supplier", headers=admin
    )
    assert deleted.status_code == 200
    assert deleted.json()["is_active"] is False
