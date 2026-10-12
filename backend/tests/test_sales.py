from collections.abc import Generator
from datetime import datetime, timedelta
from decimal import Decimal

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, select
from sqlalchemy.orm import Session, sessionmaker

from app.database import Base, get_db
from app.main import app
from app.models import Product, ProductSellingUnit, Shop, User
from app.security import hash_password


@pytest.fixture
def sales_client(tmp_path) -> Generator[TestClient, None, None]:
    engine = create_engine(f"sqlite:///{tmp_path / 'sales.db'}", connect_args={"check_same_thread": False})
    Base.metadata.create_all(engine)
    factory = sessionmaker(bind=engine, expire_on_commit=False)

    def override() -> Generator[Session, None, None]:
        with factory() as session:
            yield session

    app.dependency_overrides[get_db] = override
    with factory() as db:
        db.add_all([
            Shop(id="s1", name="One"), Shop(id="s2", name="Two"),
            User(id="admin", shop_id="s1", username="admin", display_name="Admin", password_hash=hash_password("pw"), role="admin"),
            User(id="cashier", shop_id="s1", username="cashier", display_name="Cashier", password_hash=hash_password("pw"), role="cashier"),
            User(id="other", shop_id="s2", username="other", display_name="Other", password_hash=hash_password("pw"), role="admin"),
            Product(id="p1", shop_id="s1", name="Phone", base_unit="piece", price=Decimal("10.00"), cost=Decimal("2.00"), stock=20),
            Product(id="p2", shop_id="s1", name="Cable", base_unit="piece", price=Decimal("3.00"), cost=Decimal("1.00"), stock=10),
            Product(id="packaged", shop_id="s1", name="Drinks", base_unit="piece",
                    product_type="PACKAGED", allow_partial_package_sale=False,
                    price=Decimal("120.00"), cost=Decimal("50.00"), stock=25),
            Product(id="partial-packaged", shop_id="s1", name="Partial Drinks", base_unit="piece",
                    product_type="PACKAGED", allow_partial_package_sale=True,
                    price=Decimal("120.00"), cost=Decimal("50.00"), stock=3),
            Product(id="p-other", shop_id="s2", name="Other", base_unit="piece", price=5, stock=10),
            ProductSellingUnit(id="box", product_id="p1", name="box", conversion_to_base=10, selling_price=Decimal("95.00"), cost_price=2),
            ProductSellingUnit(id="pack", product_id="packaged", name="Pack",
                               conversion_to_base=6, selling_price=Decimal("650.00"),
                               cost_price=500, barcode="PACK123"),
            ProductSellingUnit(id="packaged-piece", product_id="packaged", name="Piece",
                               conversion_to_base=1, selling_price=Decimal("120.00"),
                               cost_price=50, barcode="PIECE123", is_default=True),
            ProductSellingUnit(id="partial-pack", product_id="partial-packaged", name="Pack",
                               conversion_to_base=6, selling_price=Decimal("650.00"),
                               cost_price=500, barcode="PARTIAL123"),
        ])
        db.commit()
    try:
        yield TestClient(app)
    finally:
        app.dependency_overrides.pop(get_db, None)
        engine.dispose()


def token(client: TestClient, username: str) -> str:
    response = client.post("/api/v1/auth/login", json={"username": username, "password": "pw"})
    assert response.status_code == 200
    return response.json()["access_token"]


def post(client: TestClient, payload: dict, username="admin"):
    return client.post("/api/v1/sales", headers={"Authorization": f"Bearer {token(client, username)}"}, json=payload)


def test_cash_multi_item_package_decimal_totals_and_stock(sales_client):
    response = post(sales_client, {"idempotency_key": "cash-1", "payment_method": "cash", "discount": "0.05", "items": [
        {"product_id": "p1", "unit": "box", "quantity": "1.5"},
        {"product_id": "p2", "quantity": "2", "unit_price": "3.25"},
    ]})
    assert response.status_code == 201
    body = response.json()
    assert body["document_reference"].startswith("SALE-")
    assert body["subtotal"] == "149.00"
    assert body["discount"] == "0.05"
    assert body["total"] == "148.95"
    assert body["payment_result"] == "148.95"
    assert body["remaining_amount"] == "0.00"
    assert body["stock_posting_reference"].startswith("sale:")
    assert all(
        Decimal(item["refunded_quantity"]) == 0
        and Decimal(item["exchanged_quantity"]) == 0
        for item in body["items"]
    )
    get_response = sales_client.get(f"/api/v1/sales/{body['sale_id']}", headers={"Authorization": f"Bearer {token(sales_client, 'admin')}"})
    fetched = get_response.json()
    assert fetched["sale_id"] == body["sale_id"]
    assert fetched["total"] == body["total"]
    assert [i["line_total"] for i in fetched["items"]] == [i["line_total"] for i in body["items"]]


def test_credit_requires_customer_and_records_remaining_amount(sales_client):
    response = post(sales_client, {"idempotency_key": "credit-1", "payment_method": "credit", "customer_id": "customer-1", "items": [{"product_id": "p1", "quantity": "2"}]})
    assert response.status_code == 201
    assert Decimal(response.json()["payment_result"]) == Decimal("0.00")
    assert response.json()["remaining_amount"] == "20.00"
    assert post(sales_client, {"idempotency_key": "credit-2", "payment_method": "credit", "items": [{"product_id": "p1", "quantity": "1"}]}).status_code == 422


def test_rollback_on_insufficient_stock_and_validation(sales_client):
    response = post(sales_client, {"idempotency_key": "bad-stock", "payment_method": "cash", "items": [{"product_id": "p1", "quantity": "21"}]})
    assert response.status_code == 409
    response = post(sales_client, {"idempotency_key": "bad-unit", "payment_method": "cash", "items": [{"product_id": "p1", "unit": "crate", "quantity": "1"}]})
    assert response.status_code == 422
    assert post(sales_client, {"idempotency_key": "bad-payment", "payment_method": "cash", "paid_amount": "999", "items": [{"product_id": "p1", "quantity": "1"}]}).status_code == 422


def test_packaged_sales_use_base_stock_and_partial_package_policy(sales_client):
    assert post(
        sales_client,
        {"idempotency_key": "pack-four", "payment_method": "cash",
         "items": [{"product_id": "packaged", "unit": "Pack", "quantity": "4"}]},
    ).status_code == 201
    rejected = post(
        sales_client,
        {"idempotency_key": "pack-five", "payment_method": "cash",
         "items": [{"product_id": "packaged", "unit": "Pack", "quantity": "1"}]},
    )
    assert rejected.status_code == 409
    fractional = post(
        sales_client,
        {"idempotency_key": "pack-half", "payment_method": "cash",
         "items": [{"product_id": "packaged", "unit": "Pack", "quantity": "0.5"}]},
    )
    assert fractional.status_code == 422
    partial = post(
        sales_client,
        {"idempotency_key": "partial-allowed", "payment_method": "cash",
         "items": [{"product_id": "partial-packaged", "unit": "Pack", "quantity": "0.5"}]},
    )
    assert partial.status_code == 201
    assert partial.json()["items"][0]["quantity"] == "0.5"


def test_idempotency_exact_mismatch_and_cross_shop(sales_client):
    payload = {"idempotency_key": "same", "payment_method": "cash", "items": [{"product_id": "p1", "quantity": "1"}]}
    first = post(sales_client, payload)
    replay = post(sales_client, payload)
    assert replay.status_code == 201 and replay.json() == first.json()
    changed = dict(payload, items=[{"product_id": "p1", "quantity": "2"}])
    assert post(sales_client, changed).status_code == 409
    other = sales_client.post("/api/v1/sales", headers={"Authorization": f"Bearer {token(sales_client, 'other')}"}, json=dict(payload, items=[{"product_id": "p-other", "quantity": "1"}]))
    assert other.status_code == 201


def test_permissions_cross_shop_and_posted_immutable(sales_client):
    payload = {"idempotency_key": "cashier", "payment_method": "cash", "items": [{"product_id": "p1", "quantity": "1"}]}
    assert post(sales_client, payload, "cashier").status_code == 403
    cross = sales_client.get("/api/v1/sales/not-here", headers={"Authorization": f"Bearer {token(sales_client, 'other')}"})
    assert cross.status_code == 404
    created = post(sales_client, {"idempotency_key": "immutable", "payment_method": "cash", "items": [{"product_id": "p1", "quantity": "1"}]})
    assert created.json()["status"] == "POSTED"
    assert sales_client.put("/api/v1/sales/" + created.json()["sale_id"], headers={"Authorization": f"Bearer {token(sales_client, 'admin')}"}, json={}).status_code == 405
def test_list_sales_isolated_paginated_newest_first_filtered_with_items_and_user_name(sales_client):
    admin_headers = {"Authorization": f"Bearer {token(sales_client, 'admin')}"}
    other_headers = {"Authorization": f"Bearer {token(sales_client, 'other')}"}
    for key in ("list-1", "list-2", "list-3"):
        response = sales_client.post(
            "/api/v1/sales",
            headers=admin_headers,
            json={"idempotency_key": key, "payment_method": "cash",
                  "items": [{"product_id": "p1", "quantity": "1"}]},
        )
        assert response.status_code == 201
    other = sales_client.post(
        "/api/v1/sales", headers=other_headers,
        json={"idempotency_key": "other-list", "payment_method": "cash",
              "items": [{"product_id": "p-other", "quantity": "1"}]},
    )
    assert other.status_code == 201
    response = sales_client.get(
        "/api/v1/sales?page=1&page_size=2&status=posted"
        f"&date_from={(datetime.utcnow() - timedelta(days=1)).date().isoformat()}",
        headers=admin_headers,
    )
    assert response.status_code == 200
    body = response.json()
    assert body["total"] == 3
    assert len(body["items"]) == 2
    assert body["items"][0]["posted_at"] >= body["items"][1]["posted_at"]
    assert {sale["shop_id"] for sale in body["items"]} == {"s1"}
    assert body["items"][0]["posted_by"] == "admin"
    assert body["items"][0]["posted_by_name"] == "Admin"
    assert body["items"][0]["items"][0]["product_id"] == "p1"
    response = sales_client.get(
        "/api/v1/sales?page=2&page_size=2&status=POSTED",
        headers=admin_headers,
    )
    assert response.status_code == 200
    assert len(response.json()["items"]) == 1
    assert sales_client.get(
        "/api/v1/sales?status=VOID", headers=admin_headers
    ).json()["items"] == []


def test_analytics_requires_authentication_and_respects_date_range(sales_client):
    assert sales_client.get("/api/v1/analytics").status_code == 401
    admin_headers = {"Authorization": f"Bearer {token(sales_client, 'admin')}"}
    response = sales_client.post(
        "/api/v1/sales",
        headers=admin_headers,
        json={
            "idempotency_key": "analytics-range",
            "payment_method": "cash",
            "items": [{"product_id": "p1", "quantity": "1"}],
        },
    )
    assert response.status_code == 201
    assert sales_client.get(
        "/api/v1/analytics?date_from=2000-01-01&date_to=2000-01-02",
        headers=admin_headers,
    ).json()["total_sales"] == 0
    body = sales_client.get("/api/v1/analytics", headers=admin_headers).json()
    assert body["total_sales"] == 1
    assert body["cost_data_available"] is False
    assert body["total_cost"] is None
    top_product = body["top_products"][0]
    assert top_product["cost_data_available"] is False
    assert top_product["cost"] is None
    assert top_product["profit"] is None
    assert body["expenses_data_available"] is False
