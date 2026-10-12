from collections.abc import Generator
from datetime import datetime
from decimal import Decimal

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import select
from sqlalchemy.orm import Session, sessionmaker
from sqlalchemy import create_engine

from app.database import Base, get_db
from app.main import app
from app.models import IdempotencyRecord, Shop, Supplier, SupplierLedger, User
from app.security import hash_password


@pytest.fixture
def payment_client(tmp_path) -> Generator[TestClient, None, None]:
    engine = create_engine(
        f"sqlite:///{tmp_path / 'supplier-payments.db'}",
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
            Shop(id="payment-shop", name="Payment Shop"),
            Shop(id="other-payment-shop", name="Other Payment Shop"),
            User(
                id="payment-admin",
                shop_id="payment-shop",
                username="payment-admin",
                display_name="Payment Admin",
                password_hash=hash_password("pw"),
                role="admin",
            ),
            User(
                id="payment-manager",
                shop_id="payment-shop",
                username="payment-manager",
                display_name="Payment Manager",
                password_hash=hash_password("pw"),
                role="manager",
            ),
            User(
                id="payment-cashier",
                shop_id="payment-shop",
                username="payment-cashier",
                display_name="Payment Cashier",
                password_hash=hash_password("pw"),
                role="cashier",
            ),
            Supplier(
                id="server-supplier",
                shop_id="payment-shop",
                code="SUP-000001",
                name="Test Supplier",
            ),
            Supplier(
                id="other-server-supplier",
                shop_id="other-payment-shop",
                code="SUP-000001",
                name="Other Supplier",
            ),
            SupplierLedger(
                id="opening-balance",
                shop_id="payment-shop",
                supplier_id="server-supplier",
                entry_type="opening_balance",
                amount=Decimal("9000.00"),
                balance_after=Decimal("9000.00"),
                reference_type="supplier",
                reference_id="server-supplier",
                notes="Opening balance",
                created_at=datetime(2026, 9, 1),
            ),
        ])
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
        "idempotency_key": "payment-request-1",
        "amount": "9000.00",
        "payment_date": "2026-09-29T19:51:47",
        "payment_method": "cash",
        "reference": "SP-TEST-1",
        "notes": "Settled purchase balance",
    }
    payload.update(updates)
    return payload


def test_server_supplier_payment_reduces_ledger_balance_atomically(
    payment_client: TestClient,
) -> None:
    token = _token(payment_client, "payment-admin")
    response = payment_client.post(
        "/api/v1/suppliers/server-supplier/payments",
        headers=_headers(token),
        json=_payload(),
    )
    assert response.status_code == 201, response.text
    body = response.json()
    assert body["supplier_id"] == "server-supplier"
    assert body["amount"] == "9000.00"
    assert body["payment_method"] == "cash"
    assert body["reference"] == "SP-TEST-1"
    assert body["balance_after"] == "0.00"

    balance = payment_client.get(
        "/api/v1/suppliers/server-supplier/balance",
        headers=_headers(token),
    )
    assert balance.status_code == 200
    assert Decimal(balance.json()["balance"]) == Decimal("0.00")

    with payment_client.app.state.test_session_factory() as db:
        entries = db.scalars(
            select(SupplierLedger).where(
                SupplierLedger.supplier_id == "server-supplier",
                SupplierLedger.entry_type == "supplier_payment",
            )
        ).all()
        assert len(entries) == 1
        assert entries[0].amount == Decimal("-9000.00")
        assert entries[0].balance_after == Decimal("0.00")
        assert db.scalar(
            select(IdempotencyRecord).where(
                IdempotencyRecord.idempotency_key == "payment-request-1"
            )
        ) is not None


def test_supplier_payment_retry_is_idempotent_and_body_conflicts_are_rejected(
    payment_client: TestClient,
) -> None:
    token = _token(payment_client, "payment-admin")
    path = "/api/v1/suppliers/server-supplier/payments"
    headers = _headers(token)
    first = payment_client.post(path, headers=headers, json=_payload())
    retry = payment_client.post(path, headers=headers, json=_payload())
    assert first.status_code == retry.status_code == 201
    assert first.json() == retry.json()

    conflict = payment_client.post(
        path,
        headers=headers,
        json=_payload(amount="100.00"),
    )
    assert conflict.status_code == 409
    with payment_client.app.state.test_session_factory() as db:
        assert len(db.scalars(
            select(SupplierLedger).where(
                SupplierLedger.supplier_id == "server-supplier",
                SupplierLedger.entry_type == "supplier_payment",
            )
        ).all()) == 1


def test_supplier_payment_rejects_invalid_supplier_overpayment_and_cashier(
    payment_client: TestClient,
) -> None:
    admin = _headers(_token(payment_client, "payment-admin"))
    invalid_supplier = payment_client.post(
        "/api/v1/suppliers/other-server-supplier/payments",
        headers=admin,
        json=_payload(idempotency_key="invalid-supplier"),
    )
    assert invalid_supplier.status_code == 404
    overpayment = payment_client.post(
        "/api/v1/suppliers/server-supplier/payments",
        headers=admin,
        json=_payload(idempotency_key="overpayment", amount="9000.01"),
    )
    assert overpayment.status_code == 422
    cashier = _headers(_token(payment_client, "payment-cashier"))
    denied = payment_client.post(
        "/api/v1/suppliers/server-supplier/payments",
        headers=cashier,
        json=_payload(idempotency_key="cashier-payment"),
    )
    assert denied.status_code == 403

    with payment_client.app.state.test_session_factory() as db:
        assert db.scalars(
            select(SupplierLedger).where(
                SupplierLedger.entry_type == "supplier_payment"
            )
        ).all() == []
        assert db.scalars(select(IdempotencyRecord)).all() == []
