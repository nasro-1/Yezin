from collections.abc import Generator
from datetime import date, datetime, timedelta
from decimal import Decimal
from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, select
from sqlalchemy.orm import Session, sessionmaker

from app.database import Base, get_db
from app.main import app
from app.models import (
    CashMovement,
    CustomerLedger,
    ExchangeDocument,
    ExchangeItem,
    ExchangeSettlement,
    InventoryLotRecord,
    Payment,
    Product,
    SaleDocument,
    SaleItemFifoAllocation,
    SaleItem,
    Shop,
    StockMovement,
    User,
)
from app.security import hash_password
from app.sales_service import _response


@pytest.fixture
def returns_client(tmp_path) -> Generator[TestClient, None, None]:
    engine = create_engine(f"sqlite:///{tmp_path / 'returns.db'}", connect_args={"check_same_thread": False})
    Base.metadata.create_all(engine)
    factory = sessionmaker(bind=engine, expire_on_commit=False)

    def override():
        with factory() as session:
            yield session

    app.dependency_overrides[get_db] = override
    app.state.returns_session_factory = factory
    with factory() as db:
        db.add_all([
            Shop(id="shop", name="Shop"),
            User(id="admin", shop_id="shop", username="admin", display_name="Admin",
                 password_hash=hash_password("pw"), role="admin"),
            Product(id="old", shop_id="shop", name="Old", base_unit="piece",
                    price=Decimal("10"), cost=Decimal("2"), stock=10),
            Product(id="new", shop_id="shop", name="New", base_unit="piece",
                    price=Decimal("12"), cost=Decimal("3"), stock=10),
            Product(id="equal", shop_id="shop", name="Equal", base_unit="piece",
                    price=Decimal("10"), cost=Decimal("3"), stock=10),
            Product(id="cheap", shop_id="shop", name="Cheap", base_unit="piece",
                    price=Decimal("8"), cost=Decimal("3"), stock=10),
        ])
        db.commit()
    try:
        yield TestClient(app)
    finally:
        app.dependency_overrides.pop(get_db, None)
        del app.state.returns_session_factory
        engine.dispose()


def _headers(client: TestClient) -> dict[str, str]:
    token = client.post("/api/v1/auth/login", json={"username": "admin", "password": "pw"}).json()["access_token"]
    return {"Authorization": f"Bearer {token}"}


def _sale(
    client: TestClient,
    *,
    idempotency_key: str = "sale",
    payment_method: str = "cash",
    customer_id: str | None = None,
    quantity: str = "2",
) -> dict:
    response = client.post("/api/v1/sales", headers=_headers(client), json={
        "idempotency_key": idempotency_key,
        "payment_method": payment_method,
        "customer_id": customer_id,
        "items": [{"product_id": "old", "quantity": quantity}],
    })
    assert response.status_code == 201
    return response.json()


def _exchange(
    client: TestClient,
    sale: dict,
    *,
    idempotency_key: str,
    replacement_product_id: str,
    returned_quantity: str = "1",
    replacement_quantity: str = "1",
    payment_method: str | None = None,
) -> dict:
    response = client.post(
        f"/api/v1/sales/{sale['sale_id']}/exchange",
        headers=_headers(client),
        json={
            "idempotency_key": idempotency_key,
            "payment_method": payment_method,
            "items": [{
                "sale_item_id": sale["items"][0]["id"],
                "returned_quantity": returned_quantity,
                "replacement_product_id": replacement_product_id,
                "replacement_quantity": replacement_quantity,
            }],
        },
    )
    assert response.status_code == 201
    return response.json()


def _session(client: TestClient) -> Session:
    return client.app.state.returns_session_factory()


def test_partial_refund_is_idempotent_and_restores_stock(returns_client):
    sale = _sale(returns_client)
    headers = _headers(returns_client)
    payload = {"idempotency_key": "refund", "items": [{"sale_item_id": sale["items"][0]["id"], "quantity": "1"}]}
    first = returns_client.post(f"/api/v1/sales/{sale['sale_id']}/refund", headers=headers, json=payload)
    replay = returns_client.post(f"/api/v1/sales/{sale['sale_id']}/refund", headers=headers, json=payload)
    assert first.status_code == 201
    assert replay.json() == first.json()
    assert first.json()["amount"] == "10.00"


def test_sales_list_includes_refund_document_and_preserves_original_total(returns_client):
    sale = _sale(returns_client)
    headers = _headers(returns_client)
    refund = returns_client.post(
        f"/api/v1/sales/{sale['sale_id']}/refund",
        headers=headers,
        json={
            "idempotency_key": "sales-list-refund",
            "items": [{"sale_item_id": sale["items"][0]["id"], "quantity": "1"}],
        },
    )
    assert refund.status_code == 201

    listed = returns_client.get(
        "/api/v1/sales?page=1&page_size=200", headers=headers
    )
    assert listed.status_code == 200
    records = listed.json()["items"]
    original = next(record for record in records if record["sale_id"] == sale["sale_id"])
    refund_record = next(record for record in records if record["is_refund"])
    assert original["total"] == "20.00"
    assert original["refunded_total"] == "10.00"
    assert original["items"][0]["refunded_quantity"] == "1.000000"
    assert refund_record["total"] == "10.00"
    assert refund_record["document_reference"].startswith("CR-")
    assert refund_record["original_sale_id"] == sale["sale_id"]
    assert refund_record["items"][0]["id"] == sale["items"][0]["id"]
    analytics = returns_client.get("/api/v1/analytics", headers=headers)
    assert analytics.status_code == 200
    assert analytics.json()["gross_revenue"] == 20.0
    assert analytics.json()["refunded_amount"] == 10.0
    assert analytics.json()["total_revenue"] == 10.0
    assert analytics.json()["total_sales"] == 1


def test_analytics_uses_sale_time_cost_snapshot_for_refund_only_date_range(returns_client):
    with _session(returns_client) as db:
        db.add(
            InventoryLotRecord(
                id="analytics-fifo-lot",
                shop_id="shop",
                product_id="old",
                movement_id="analytics-fifo-movement",
                source_type="test",
                source_id="analytics-fifo-source",
                received_quantity=10,
                remaining_quantity=10,
                unit_cost=3,
                acquired_at=datetime(2020, 1, 1),
            )
        )
        db.commit()
    sale = _sale(returns_client, quantity="2")
    assert Decimal(sale["items"][0]["historical_cost"]) == Decimal("6")
    assert sale["items"][0]["historical_cost_available"] is True
    with _session(returns_client) as db:
        allocation = db.scalar(
            select(SaleItemFifoAllocation).where(
                SaleItemFifoAllocation.sale_item_id == sale["items"][0]["id"]
            )
        )
        assert allocation is not None
        lot = db.get(InventoryLotRecord, allocation.inventory_lot_id)
        assert lot is not None
        lot.unit_cost = Decimal("7")
        product = db.get(Product, "old")
        assert product is not None
        product.cost = Decimal("999")
        product.wholesale_price = Decimal("888")
        sale_document = db.get(SaleDocument, sale["sale_id"])
        assert sale_document is not None
        sale_document.posted_at = datetime(2020, 1, 1)
        db.commit()

    refund = returns_client.post(
        f"/api/v1/sales/{sale['sale_id']}/refund",
        headers=_headers(returns_client),
        json={
            "idempotency_key": "fifo-analytics-refund",
            "items": [{"sale_item_id": sale["items"][0]["id"], "quantity": "1"}],
        },
    )
    assert refund.status_code == 201

    today = date.today()
    analytics = returns_client.get(
        "/api/v1/analytics",
        headers=_headers(returns_client),
        params={
            "date_from": today.isoformat(),
            "date_to_exclusive": (today + timedelta(days=1)).isoformat(),
        },
    )
    assert analytics.status_code == 200
    assert analytics.json()["total_revenue"] == -10.0
    assert analytics.json()["total_cost"] == -3.0


def test_missing_sale_cost_snapshot_keeps_refund_cogs_unavailable(returns_client):
    with _session(returns_client) as db:
        db.add(
            InventoryLotRecord(
                id="missing-snapshot-lot",
                shop_id="shop",
                product_id="old",
                movement_id="missing-snapshot-movement",
                source_type="purchase",
                source_id="missing-snapshot-purchase",
                received_quantity=10,
                remaining_quantity=10,
                unit_cost=3,
                acquired_at=datetime(2026, 1, 1),
            )
        )
        db.commit()

    sale = _sale(returns_client, idempotency_key="missing-snapshot-sale")
    with _session(returns_client) as db:
        allocation = db.scalar(
            select(SaleItemFifoAllocation).where(
                SaleItemFifoAllocation.sale_item_id == sale["items"][0]["id"]
            )
        )
        assert allocation is not None
        allocation.unit_cost_at_sale = None
        lot = db.get(InventoryLotRecord, allocation.inventory_lot_id)
        assert lot is not None
        lot.unit_cost = 99
        db.commit()

    refund = returns_client.post(
        f"/api/v1/sales/{sale['sale_id']}/refund",
        headers=_headers(returns_client),
        json={
            "idempotency_key": "missing-snapshot-refund",
            "items": [{"sale_item_id": sale["items"][0]["id"], "quantity": "1"}],
        },
    )
    assert refund.status_code == 201
    listing = returns_client.get(
        "/api/v1/sales", headers=_headers(returns_client)
    ).json()
    refund_line = next(
        record["items"][0] for record in listing["items"] if record["is_refund"]
    )
    assert refund_line["historical_cost"] is None
    assert refund_line["historical_cost_available"] is False

    analytics = returns_client.get(
        "/api/v1/analytics", headers=_headers(returns_client)
    ).json()
    assert analytics["total_cost"] is None
    assert analytics["cost_data_available"] is False


def test_analytics_fifo_accounting_matches_local_refund_exchange_scenario(
    returns_client,
):
    with _session(returns_client) as db:
        old_product = db.get(Product, "old")
        replacement_product = db.get(Product, "new")
        assert old_product is not None
        assert replacement_product is not None
        old_product.stock = 20
        replacement_product.stock = 20
        db.add_all(
            [
                InventoryLotRecord(
                    id="analytics-parity-lot-1",
                    shop_id="shop",
                    product_id="old",
                    movement_id="analytics-parity-movement-1",
                    source_type="purchase",
                    source_id="analytics-parity-purchase-1",
                    received_quantity=10,
                    remaining_quantity=10,
                    unit_cost=50,
                    acquired_at=datetime(2026, 8, 1),
                ),
                InventoryLotRecord(
                    id="analytics-parity-lot-2",
                    shop_id="shop",
                    product_id="old",
                    movement_id="analytics-parity-movement-2",
                    source_type="purchase",
                    source_id="analytics-parity-purchase-2",
                    received_quantity=10,
                    remaining_quantity=10,
                    unit_cost=80,
                    acquired_at=datetime(2026, 8, 2),
                ),
                InventoryLotRecord(
                    id="analytics-parity-replacement-lot",
                    shop_id="shop",
                    product_id="new",
                    movement_id="analytics-parity-replacement-movement",
                    source_type="purchase",
                    source_id="analytics-parity-replacement-purchase",
                    received_quantity=10,
                    remaining_quantity=10,
                    unit_cost=30,
                    acquired_at=datetime(2026, 8, 3),
                ),
            ]
        )
        db.commit()

    sale = _sale(returns_client, quantity="15")
    with _session(returns_client) as db:
        sale_document = db.get(SaleDocument, sale["sale_id"])
        assert sale_document is not None
        sale_document.posted_at = datetime(2020, 1, 1)
        db.commit()
    refund = returns_client.post(
        f"/api/v1/sales/{sale['sale_id']}/refund",
        headers=_headers(returns_client),
        json={
            "idempotency_key": "analytics-parity-refund",
            "items": [{"sale_item_id": sale["items"][0]["id"], "quantity": "5"}],
        },
    )
    assert refund.status_code == 201
    exchange = _exchange(
        returns_client,
        sale,
        idempotency_key="analytics-parity-exchange",
        replacement_product_id="new",
    )
    assert exchange["difference_amount"] == "2.00"
    with _session(returns_client) as db:
        old_product = db.get(Product, "old")
        replacement_product = db.get(Product, "new")
        assert old_product is not None
        assert replacement_product is not None
        old_product.cost = Decimal("999")
        old_product.wholesale_price = Decimal("888")
        replacement_product.cost = Decimal("777")
        replacement_product.wholesale_price = Decimal("666")
        db.commit()

    analytics = returns_client.get("/api/v1/analytics", headers=_headers(returns_client))
    assert analytics.status_code == 200
    body = analytics.json()
    assert body["total_revenue"] == 102.0
    assert body["total_cost"] == 480.0
    assert body["return_rate_percent"] == pytest.approx(31.25)
    by_product = {item["product_id"]: item for item in body["top_products"]}
    assert by_product["old"]["quantity_sold"] == 9.0
    assert by_product["old"]["revenue"] == 90.0
    assert by_product["old"]["cost"] == 450.0
    assert by_product["new"]["cost"] == 30.0

    event_only = returns_client.get(
        "/api/v1/analytics",
        headers=_headers(returns_client),
        params={
            "date_from": date.today().isoformat(),
            "date_to_exclusive": (date.today() + timedelta(days=1)).isoformat(),
        },
    )
    assert event_only.status_code == 200
    assert event_only.json()["total_revenue"] == -48.0
    assert event_only.json()["total_cost"] == -420.0


def test_exchange_atomically_returns_old_and_posts_replacement(returns_client):
    sale = _sale(returns_client)
    response = returns_client.post(f"/api/v1/sales/{sale['sale_id']}/exchange", headers=_headers(returns_client), json={
        "idempotency_key": "exchange", "items": [{
            "sale_item_id": sale["items"][0]["id"], "returned_quantity": "1",
            "replacement_product_id": "new", "replacement_quantity": "1",
        }],
    })
    assert response.status_code == 201
    body = response.json()
    assert body["difference_amount"] == "2.00"
    assert body["replacement_sale_id"]
    assert body["replacement_document_reference"].startswith("SALE-")

    replacement = returns_client.get(
        "/api/v1/sales", headers=_headers(returns_client)
    )
    assert replacement.status_code == 200
    replacement_items = replacement.json()["items"]
    replacement_sale = next(
        item for item in replacement_items
        if item["sale_id"] == body["replacement_sale_id"]
    )
    assert replacement_sale["document_reference"] == body["replacement_document_reference"]
    assert replacement_sale["total"] == "12.00"
    assert replacement_sale["items"][0]["product_id"] == "new"
    assert replacement_sale["items"][0]["quantity"] == "1.000000"

    retry = returns_client.post(
        f"/api/v1/sales/{sale['sale_id']}/exchange",
        headers=_headers(returns_client),
        json={
            "idempotency_key": "exchange",
            "items": [{
                "sale_item_id": sale["items"][0]["id"],
                "returned_quantity": "1",
                "replacement_product_id": "new",
                "replacement_quantity": "1",
            }],
        },
    )
    assert retry.status_code == 201
    assert retry.json() == body

    changed_payload = returns_client.post(
        f"/api/v1/sales/{sale['sale_id']}/exchange",
        headers=_headers(returns_client),
        json={
            "idempotency_key": "exchange",
            "items": [{
                "sale_item_id": sale["items"][0]["id"],
                "returned_quantity": "1",
                "replacement_product_id": "equal",
                "replacement_quantity": "1",
            }],
        },
    )
    assert changed_payload.status_code == 409

    with _session(returns_client) as db:
        assert db.query(ExchangeDocument).count() == 1
        assert db.query(ExchangeSettlement).count() == 1
        assert db.query(SaleDocument).count() == 2
        assert db.query(Payment).filter_by(sale_id=body["replacement_sale_id"]).count() == 1


def test_equal_exchange_creates_a_settled_replacement_and_no_cash_delta(returns_client):
    sale = _sale(returns_client)
    result = _exchange(
        returns_client,
        sale,
        idempotency_key="equal-exchange",
        replacement_product_id="equal",
    )

    assert result["difference_amount"] == "0.00"
    with _session(returns_client) as db:
        original = db.get(SaleDocument, sale["sale_id"])
        replacement = db.get(SaleDocument, result["replacement_sale_id"])
        original_item = db.get(SaleItem, sale["items"][0]["id"])
        settlement = db.scalar(
            select(ExchangeSettlement).where(
                ExchangeSettlement.exchange_id == result["exchange_id"]
            )
        )
        payment = db.get(Payment, settlement.payment_id)

        assert original.total == Decimal("20.00")
        assert original.payment_result == Decimal("20.00")
        assert original_item.exchanged_quantity == Decimal("1.000000")
        assert replacement.total == Decimal("10.00")
        assert replacement.payment_result == replacement.total
        assert replacement.remaining_amount == Decimal("0.00")
        assert payment.sale_id == replacement.id
        assert payment.amount == replacement.total
        assert settlement.replacement_sale_id == replacement.id
        assert settlement.returned_amount == Decimal("10.00")
        assert settlement.replacement_amount == Decimal("10.00")
        assert settlement.difference_amount == Decimal("0.00")
        assert settlement.cash_movement_id is None
        assert settlement.customer_ledger_id is None
        assert db.query(CashMovement).filter_by(sale_id=replacement.id).count() == 0


def test_exchange_customer_pays_extra_records_cash_against_replacement_sale(returns_client):
    sale = _sale(returns_client)
    result = _exchange(
        returns_client,
        sale,
        idempotency_key="cash-extra-exchange",
        replacement_product_id="new",
    )

    assert result["difference_amount"] == "2.00"
    with _session(returns_client) as db:
        replacement = db.get(SaleDocument, result["replacement_sale_id"])
        settlement = db.scalar(
            select(ExchangeSettlement).where(
                ExchangeSettlement.exchange_id == result["exchange_id"]
            )
        )
        cash = db.get(CashMovement, settlement.cash_movement_id)
        payment = db.get(Payment, settlement.payment_id)

        assert replacement.total == Decimal("12.00")
        assert replacement.payment_result == Decimal("12.00")
        assert replacement.remaining_amount == Decimal("0.00")
        assert payment.amount == Decimal("12.00")
        assert cash.sale_id == replacement.id
        assert cash.amount == Decimal("2.00")
        assert cash.movement_type == "exchange"
        assert settlement.customer_ledger_id is None


def test_exchange_customer_receives_difference_records_cash_refund(returns_client):
    sale = _sale(returns_client)
    result = _exchange(
        returns_client,
        sale,
        idempotency_key="cash-refund-exchange",
        replacement_product_id="cheap",
    )

    assert result["difference_amount"] == "-2.00"
    with _session(returns_client) as db:
        replacement = db.get(SaleDocument, result["replacement_sale_id"])
        settlement = db.scalar(
            select(ExchangeSettlement).where(
                ExchangeSettlement.exchange_id == result["exchange_id"]
            )
        )
        cash = db.get(CashMovement, settlement.cash_movement_id)

        assert replacement.total == Decimal("8.00")
        assert replacement.payment_result == Decimal("8.00")
        assert replacement.remaining_amount == Decimal("0.00")
        assert cash.sale_id == replacement.id
        assert cash.amount == Decimal("-2.00")
        assert settlement.returned_amount == Decimal("10.00")
        assert settlement.replacement_amount == Decimal("8.00")


def test_credit_exchange_links_customer_ledger_to_replacement_settlement(returns_client):
    sale = _sale(
        returns_client,
        idempotency_key="credit-sale",
        payment_method="credit",
        customer_id="customer-1",
    )
    result = _exchange(
        returns_client,
        sale,
        idempotency_key="credit-exchange",
        replacement_product_id="new",
        payment_method="credit",
    )

    with _session(returns_client) as db:
        replacement = db.get(SaleDocument, result["replacement_sale_id"])
        settlement = db.scalar(
            select(ExchangeSettlement).where(
                ExchangeSettlement.exchange_id == result["exchange_id"]
            )
        )
        ledger = db.get(CustomerLedger, settlement.customer_ledger_id)
        payment = db.get(Payment, settlement.payment_id)

        assert replacement.customer_id == "customer-1"
        assert payment.sale_id == replacement.id
        assert payment.amount == replacement.total == Decimal("12.00")
        assert ledger.sale_id == replacement.id
        assert ledger.customer_id == "customer-1"
        assert ledger.amount == Decimal("2.00")
        assert ledger.direction == "debit"
        assert settlement.cash_movement_id is None


def test_exchange_rejects_duplicate_return_lines_atomically(returns_client):
    sale = _sale(returns_client)
    with _session(returns_client) as db:
        before_counts = {
            "sales": db.query(SaleDocument).count(),
            "exchange_documents": db.query(ExchangeDocument).count(),
            "exchange_items": db.query(ExchangeItem).count(),
            "settlements": db.query(ExchangeSettlement).count(),
            "payments": db.query(Payment).count(),
            "cash": db.query(CashMovement).count(),
            "ledger": db.query(CustomerLedger).count(),
            "movements": db.query(StockMovement).count(),
        }
        old_stock = db.get(Product, "old").stock
        new_stock = db.get(Product, "new").stock

    response = returns_client.post(
        f"/api/v1/sales/{sale['sale_id']}/exchange",
        headers=_headers(returns_client),
        json={
            "idempotency_key": "duplicate-return-lines",
            "items": [
                {
                    "sale_item_id": sale["items"][0]["id"],
                    "returned_quantity": "2",
                    "replacement_product_id": "new",
                    "replacement_quantity": "1",
                },
                {
                    "sale_item_id": sale["items"][0]["id"],
                    "returned_quantity": "2",
                    "replacement_product_id": "equal",
                    "replacement_quantity": "1",
                },
            ],
        },
    )

    assert response.status_code == 409
    with _session(returns_client) as db:
        assert db.get(SaleItem, sale["items"][0]["id"]).exchanged_quantity == Decimal("0")
        assert db.get(Product, "old").stock == old_stock
        assert db.get(Product, "new").stock == new_stock
        assert db.query(SaleDocument).count() == before_counts["sales"]
        assert db.query(ExchangeDocument).count() == before_counts["exchange_documents"]
        assert db.query(ExchangeItem).count() == before_counts["exchange_items"]
        assert db.query(ExchangeSettlement).count() == before_counts["settlements"]
        assert db.query(Payment).count() == before_counts["payments"]
        assert db.query(CashMovement).count() == before_counts["cash"]
        assert db.query(CustomerLedger).count() == before_counts["ledger"]
        assert db.query(StockMovement).count() == before_counts["movements"]


def test_exchange_allows_valid_multiple_replacement_mappings(returns_client):
    sale = _sale(returns_client)
    response = returns_client.post(
        f"/api/v1/sales/{sale['sale_id']}/exchange",
        headers=_headers(returns_client),
        json={
            "idempotency_key": "multiple-replacements",
            "items": [
                {
                    "sale_item_id": sale["items"][0]["id"],
                    "returned_quantity": "1",
                    "replacement_product_id": "new",
                    "replacement_quantity": "1",
                },
                {
                    "sale_item_id": sale["items"][0]["id"],
                    "returned_quantity": "1",
                    "replacement_product_id": "equal",
                    "replacement_quantity": "1",
                },
            ],
        },
    )

    assert response.status_code == 201
    result = response.json()
    assert result["difference_amount"] == "2.00"
    with _session(returns_client) as db:
        original_item = db.get(SaleItem, sale["items"][0]["id"])
        replacement = db.get(SaleDocument, result["replacement_sale_id"])
        settlement = db.scalar(
            select(ExchangeSettlement).where(
                ExchangeSettlement.exchange_id == result["exchange_id"]
            )
        )

        assert original_item.exchanged_quantity == Decimal("2.000000")
        assert db.query(ExchangeItem).filter_by(exchange_id=result["exchange_id"]).count() == 2
        assert db.query(SaleItem).filter_by(sale_id=replacement.id).count() == 2
        assert db.get(Product, "old").stock == Decimal("10")
        assert db.get(Product, "new").stock == Decimal("9")
        assert db.get(Product, "equal").stock == Decimal("9")
        assert settlement.returned_amount == Decimal("20.00")
        assert settlement.replacement_amount == Decimal("22.00")


def test_refund_matches_duplicate_product_lines_by_sale_item_id(returns_client):
    sale_response = returns_client.post(
        "/api/v1/sales",
        headers=_headers(returns_client),
        json={
            "idempotency_key": "duplicate-lines-sale",
            "payment_method": "cash",
            "items": [
                {"product_id": "old", "quantity": "1", "unit_price": "100"},
                {"product_id": "old", "quantity": "2", "unit_price": "80"},
            ],
        },
    )
    assert sale_response.status_code == 201
    sale = sale_response.json()
    first_id, second_id = (item["id"] for item in sale["items"])

    first = returns_client.post(
        f"/api/v1/sales/{sale['sale_id']}/refund",
        headers=_headers(returns_client),
        json={
            "idempotency_key": "duplicate-lines-refund-a",
            "items": [{"sale_item_id": first_id, "quantity": "1"}],
        },
    )
    assert first.status_code == 201
    assert first.json()["amount"] == "100.00"

    second = returns_client.post(
        f"/api/v1/sales/{sale['sale_id']}/refund",
        headers=_headers(returns_client),
        json={
            "idempotency_key": "duplicate-lines-refund-b",
            "items": [{"sale_item_id": second_id, "quantity": "1"}],
        },
    )
    assert second.status_code == 201
    assert second.json()["amount"] == "80.00"


def test_legacy_null_return_quantities_serialize_safely():
    sale = SimpleNamespace(
        id="sale-legacy",
        shop_id="shop",
        status="POSTED",
        document_reference="SALE-LEGACY",
        customer_id=None,
        payment_method="cash",
        subtotal=Decimal("10"),
        discount=Decimal("0"),
        total=Decimal("10"),
        payment_result=Decimal("10"),
        remaining_amount=Decimal("0"),
        stock_posting_reference="sale:sale-legacy",
        posted_at=datetime.utcnow(),
        posted_by="admin",
    )
    item = SimpleNamespace(
        id="sale-item-legacy",
        product_id="old",
        unit="piece",
        quantity=Decimal("1"),
        base_quantity=Decimal("1"),
        unit_price=Decimal("10"),
        line_total=Decimal("10"),
        refunded_quantity=None,
        exchanged_quantity=None,
    )

    response = _response(sale, [item])

    assert response.items[0].refunded_quantity == 0
    assert response.items[0].exchanged_quantity == 0
