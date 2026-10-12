from collections.abc import Generator
from concurrent.futures import ThreadPoolExecutor
from decimal import Decimal
from threading import Barrier

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, select, update
from sqlalchemy.orm import Session, sessionmaker

from app.database import Base, get_db
from app.main import app
from app.models import Product, SaleDocument, SaleDraft, StockMovement, Shop, User
from app.security import hash_password


@pytest.fixture
def draft_client(tmp_path) -> Generator[TestClient, None, None]:
    engine = create_engine(
        f"sqlite:///{tmp_path / 'drafts.db'}",
        connect_args={"check_same_thread": False},
    )
    Base.metadata.create_all(engine)
    factory = sessionmaker(bind=engine, expire_on_commit=False)

    def override() -> Generator[Session, None, None]:
        with factory() as session:
            yield session

    app.dependency_overrides[get_db] = override
    with factory() as db:
        db.add_all(
            [
                Shop(id="draft-shop", name="Draft Shop"),
                Shop(id="other-shop", name="Other Shop"),
                User(
                    id="draft-owner",
                    shop_id="draft-shop",
                    username="draft-owner",
                    display_name="Draft Owner",
                    password_hash=hash_password("pw"),
                    role="admin",
                ),
                User(
                    id="cashier-a",
                    shop_id="draft-shop",
                    username="cashier-a",
                    display_name="Cashier A",
                    password_hash=hash_password("pw"),
                    role="cashier",
                ),
                User(
                    id="cashier-b",
                    shop_id="draft-shop",
                    username="cashier-b",
                    display_name="Cashier B",
                    password_hash=hash_password("pw"),
                    role="cashier",
                ),
                User(
                    id="manager-a",
                    shop_id="draft-shop",
                    username="manager-a",
                    display_name="Manager A",
                    password_hash=hash_password("pw"),
                    role="manager",
                ),
                User(
                    id="other-owner",
                    shop_id="other-shop",
                    username="other-owner",
                    display_name="Other Owner",
                    password_hash=hash_password("pw"),
                    role="admin",
                ),
                Product(
                    id="draft-product",
                    shop_id="draft-shop",
                    name="Product",
                    base_unit="piece",
                    price=Decimal("10.00"),
                    cost=Decimal("2.00"),
                    stock=5,
                ),
                Product(
                    id="draft-product-b",
                    shop_id="draft-shop",
                    name="Product B",
                    base_unit="piece",
                    price=Decimal("10.00"),
                    cost=Decimal("2.00"),
                    stock=5,
                ),
                Product(
                    id="draft-product-c",
                    shop_id="draft-shop",
                    name="Product C",
                    base_unit="piece",
                    price=Decimal("10.00"),
                    cost=Decimal("2.00"),
                    stock=5,
                ),
                Product(
                    id="other-product",
                    shop_id="other-shop",
                    name="Other Product",
                    base_unit="piece",
                    price=Decimal("10.00"),
                    stock=5,
                ),
            ]
        )
        db.commit()
    try:
        yield TestClient(app)
    finally:
        app.dependency_overrides.pop(get_db, None)
        engine.dispose()


def auth(client: TestClient, username: str = "draft-owner") -> dict[str, str]:
    result = client.post(
        "/api/v1/auth/login", json={"username": username, "password": "pw"}
    )
    assert result.status_code == 200
    return {"Authorization": f"Bearer {result.json()['access_token']}"}


def bearer_token(client: TestClient, username: str = "draft-owner") -> str:
    return auth(client, username)["Authorization"].split(" ", 1)[1]


def test_new_draft_defaults_private_and_ignores_client_owner_override(
    draft_client: TestClient,
) -> None:
    owner = auth(draft_client)
    created = draft_client.post(
        "/api/v1/sales/drafts",
        headers=owner,
        json={"owner_id": "cashier-a", "visibility": "SHARED"},
    )
    assert created.status_code == 201
    draft = created.json()
    assert draft["owner_id"] == "draft-owner"
    assert draft["visibility"] == "PRIVATE"


def test_shared_drafts_are_visible_to_same_shop_and_not_private_others(
    draft_client: TestClient,
) -> None:
    owner = auth(draft_client)
    private_draft = draft_client.post("/api/v1/sales/drafts", headers=owner, json={})
    assert private_draft.status_code == 201

    shared_seed = draft_client.post("/api/v1/sales/drafts", headers=owner, json={})
    assert shared_seed.status_code == 201
    shared_draft = draft_client.put(
        f"/api/v1/sales/drafts/{shared_seed.json()['id']}",
        headers={**owner, "If-Match": "0"},
        json={"visibility": "SHARED", "expected_version": 0},
    )
    assert shared_draft.status_code == 200
    assert shared_draft.json()["visibility"] == "SHARED"

    cashier = auth(draft_client, "cashier-a")
    cashier_ids = {
        draft["id"]
        for draft in draft_client.get("/api/v1/sales/drafts", headers=cashier).json()["drafts"]
    }
    assert shared_draft.json()["id"] in cashier_ids
    assert private_draft.json()["id"] not in cashier_ids

    other = auth(draft_client, "other-owner")
    assert draft_client.get(
        f"/api/v1/sales/drafts/{shared_draft.json()['id']}", headers=other
    ).status_code == 404


def test_admin_sees_all_same_shop_drafts_but_not_other_shop(
    draft_client: TestClient,
) -> None:
    cashier = auth(draft_client, "cashier-a")
    private_draft = draft_client.post(
        "/api/v1/sales/drafts", headers=cashier, json={}
    ).json()
    shared_seed = draft_client.post(
        "/api/v1/sales/drafts", headers=cashier, json={}
    ).json()
    shared_draft = draft_client.put(
        f"/api/v1/sales/drafts/{shared_seed['id']}",
        headers={**cashier, "If-Match": "0"},
        json={"visibility": "SHARED", "expected_version": 0},
    )
    assert shared_draft.status_code == 200

    other_owner = auth(draft_client, "other-owner")
    other_shop_draft = draft_client.post(
        "/api/v1/sales/drafts", headers=other_owner, json={}
    ).json()

    admin = auth(draft_client)
    response = draft_client.get(
        "/api/v1/sales/drafts?include_held=true", headers=admin
    )
    assert response.status_code == 200
    ids = {draft["id"] for draft in response.json()["drafts"]}
    assert private_draft["id"] in ids
    assert shared_draft.json()["id"] in ids
    assert other_shop_draft["id"] not in ids


def test_manager_and_cashier_cannot_see_another_users_private_draft_but_can_see_shared(
    draft_client: TestClient,
) -> None:
    owner = auth(draft_client, "cashier-a")
    private_draft = draft_client.post(
        "/api/v1/sales/drafts", headers=owner, json={}
    ).json()
    shared_seed = draft_client.post(
        "/api/v1/sales/drafts", headers=owner, json={}
    ).json()
    shared_draft = draft_client.put(
        f"/api/v1/sales/drafts/{shared_seed['id']}",
        headers={**owner, "If-Match": "0"},
        json={"visibility": "SHARED", "expected_version": 0},
    )
    assert shared_draft.status_code == 200

    for username in ("cashier-b", "manager-a"):
        user = auth(draft_client, username)
        visible_ids = {
            draft["id"]
            for draft in draft_client.get(
                "/api/v1/sales/drafts", headers=user
            ).json()["drafts"]
        }
        assert private_draft["id"] not in visible_ids
        assert shared_draft.json()["id"] in visible_ids


def test_manager_and_admin_visibility_and_shared_version_conflict(
    draft_client: TestClient,
) -> None:
    owner = auth(draft_client)
    created = draft_client.post(
        "/api/v1/sales/drafts", headers=owner, json={}
    ).json()
    draft_id = created["id"]

    manager = auth(draft_client, "manager-a")
    assert draft_client.get(
        f"/api/v1/sales/drafts/{draft_id}", headers=manager
    ).status_code == 404

    shared = draft_client.put(
        f"/api/v1/sales/drafts/{draft_id}",
        headers={**owner, "If-Match": "0"},
        json={"visibility": "SHARED", "expected_version": 0},
    )
    assert shared.status_code == 200
    assert shared.json()["owner_name"] == "Draft Owner"

    manager_read = draft_client.get(
        f"/api/v1/sales/drafts/{draft_id}", headers=manager
    )
    assert manager_read.status_code == 200
    updated = draft_client.put(
        f"/api/v1/sales/drafts/{draft_id}",
        headers={**manager, "If-Match": str(shared.json()["version"])},
        json={"expected_version": shared.json()["version"]},
    )
    assert updated.status_code == 200

    conflict = draft_client.put(
        f"/api/v1/sales/drafts/{draft_id}",
        headers={**owner, "If-Match": "1"},
        json={"visibility": "PRIVATE", "expected_version": 1},
    )
    assert conflict.status_code == 409

    admin = auth(draft_client)
    admin_ids = {
        draft["id"]
        for draft in draft_client.get("/api/v1/sales/drafts", headers=admin).json()["drafts"]
    }
    assert draft_id in admin_ids


def test_visibility_changes_are_owner_or_admin_only(
    draft_client: TestClient,
) -> None:
    owner = auth(draft_client, "cashier-a")
    created = draft_client.post(
        "/api/v1/sales/drafts", headers=owner, json={}
    ).json()
    draft_id = created["id"]

    cashier = auth(draft_client, "cashier-b")
    denied_private_share = draft_client.put(
        f"/api/v1/sales/drafts/{draft_id}",
        headers={**cashier, "If-Match": "0"},
        json={"visibility": "SHARED", "expected_version": 0},
    )
    assert denied_private_share.status_code == 404

    admin = auth(draft_client)
    admin_share = draft_client.put(
        f"/api/v1/sales/drafts/{draft_id}",
        headers={**admin, "If-Match": "0"},
        json={"visibility": "SHARED", "expected_version": 0},
    )
    assert admin_share.status_code == 200

    shared_edit = draft_client.put(
        f"/api/v1/sales/drafts/{draft_id}",
        headers={**cashier, "If-Match": "1"},
        json={"expected_version": 1},
    )
    assert shared_edit.status_code == 200
    denied_private = draft_client.put(
        f"/api/v1/sales/drafts/{draft_id}",
        headers={**cashier, "If-Match": "2"},
        json={"visibility": "PRIVATE", "expected_version": 2},
    )
    assert denied_private.status_code == 403

    owner_private = draft_client.put(
        f"/api/v1/sales/drafts/{draft_id}",
        headers={**owner, "If-Match": "2"},
        json={"visibility": "PRIVATE", "expected_version": 2},
    )
    assert owner_private.status_code == 200

    conflict = draft_client.put(
        f"/api/v1/sales/drafts/{draft_id}",
        headers={**admin, "If-Match": "2"},
        json={"visibility": "SHARED", "expected_version": 2},
    )
    assert conflict.status_code == 409


def test_draft_crud_version_and_owner_isolation(draft_client: TestClient) -> None:
    owner = auth(draft_client)
    created = draft_client.post("/api/v1/sales/drafts", headers=owner, json={})
    assert created.status_code == 201
    draft = created.json()
    assert draft["version"] == 0

    added = draft_client.post(
        f"/api/v1/sales/drafts/{draft['id']}/items",
        headers=owner,
        json={
            "product_id": "draft-product",
            "quantity": "2",
            "expected_version": 0,
        },
    )
    assert added.status_code == 201
    item = added.json()["items"][0]
    assert added.json()["version"] == 1
    conflict = draft_client.post(
        f"/api/v1/sales/drafts/{draft['id']}/items",
        headers=owner,
        json={
            "product_id": "draft-product",
            "quantity": "1",
            "expected_version": 0,
        },
    )
    assert conflict.status_code == 409
    assert conflict.json()["detail"]["current_version"] == 1

    deleted = draft_client.delete(
        f"/api/v1/sales/drafts/{draft['id']}/items/{item['id']}?expected_version=1",
        headers=owner,
    )
    assert deleted.status_code == 200
    assert deleted.json()["items"] == []

    other = auth(draft_client, "other-owner")
    assert (
        draft_client.get(f"/api/v1/sales/drafts/{draft['id']}", headers=other).status_code
        == 404
    )
    assert draft_client.get("/api/v1/sales/drafts", headers=other).json()["drafts"] == []


def test_draft_hold_resume_clear_and_checkout_are_atomic(draft_client: TestClient) -> None:
    owner = auth(draft_client)
    created = draft_client.post("/api/v1/sales/drafts", headers=owner, json={}).json()
    draft_id = created["id"]
    added = draft_client.post(
        f"/api/v1/sales/drafts/{draft_id}/items",
        headers=owner,
        json={"product_id": "draft-product", "quantity": "2", "expected_version": 0},
    ).json()
    held = draft_client.post(
        f"/api/v1/sales/drafts/{draft_id}/hold",
        headers=owner,
        json={"expected_version": added["version"]},
    )
    assert held.status_code == 200 and held.json()["status"] == "HELD"
    resumed = draft_client.post(
        f"/api/v1/sales/drafts/{draft_id}/resume",
        headers=owner,
        json={"expected_version": held.json()["version"]},
    )
    assert resumed.status_code == 200 and resumed.json()["status"] == "OPEN"

    # Draft mutations never post stock.
    with next(app.dependency_overrides[get_db]()) as db:
        assert db.scalar(select(Product.stock).where(Product.id == "draft-product")) == 5

    checked_out = draft_client.post(
        f"/api/v1/sales/drafts/{draft_id}/checkout",
        headers=owner,
        json={"idempotency_key": "draft-checkout", "payment_method": "cash"},
    )
    assert checked_out.status_code == 201
    assert Decimal(checked_out.json()["items"][0]["refunded_quantity"]) == 0
    assert Decimal(checked_out.json()["items"][0]["exchanged_quantity"]) == 0
    replay = draft_client.post(
        f"/api/v1/sales/drafts/{draft_id}/checkout",
        headers=owner,
        json={"idempotency_key": "draft-checkout", "payment_method": "cash"},
    )
    assert replay.status_code == 201
    assert replay.json() == checked_out.json()

    # A checked-out draft cannot be cleared and its stock was posted exactly once.
    assert (
        draft_client.post(
            f"/api/v1/sales/drafts/{draft_id}/clear",
            headers=owner,
            json={"expected_version": resumed.json()["version"]},
        ).status_code
        == 409
    )
    with next(app.dependency_overrides[get_db]()) as db:
        assert db.scalar(select(Product.stock).where(Product.id == "draft-product")) == 3


def _cashier_draft(
    client: TestClient,
    owner: dict[str, str],
    product_id: str,
    *,
    visibility: str | None = None,
) -> dict:
    draft = client.post("/api/v1/sales/drafts", headers=owner, json={}).json()
    item = client.post(
        f"/api/v1/sales/drafts/{draft['id']}/items",
        headers=owner,
        json={"product_id": product_id, "quantity": "1", "expected_version": 0},
    )
    assert item.status_code == 201
    if visibility is None:
        return item.json()
    shared = client.put(
        f"/api/v1/sales/drafts/{draft['id']}",
        headers={**owner, "If-Match": str(item.json()["version"])},
        json={
            "items": [
                {
                    "product_id": product_id,
                    "quantity": "1",
                    "unit": "piece",
                }
            ],
            "visibility": visibility,
            "expected_version": item.json()["version"],
        },
    )
    assert shared.status_code == 200
    return shared.json()


def test_cashier_draft_checkout_authorization_and_posting(
    draft_client: TestClient,
) -> None:
    owner = auth(draft_client, "cashier-a")
    cashier_b = auth(draft_client, "cashier-b")
    manager = auth(draft_client, "manager-a")
    admin = auth(draft_client)

    private = _cashier_draft(draft_client, owner, "draft-product")
    own_private = draft_client.post(
        f"/api/v1/sales/drafts/{private['id']}/checkout",
        headers=owner,
        json={"idempotency_key": "cashier-private", "payment_method": "cash"},
    )
    assert own_private.status_code == 201

    shared_for_owner = _cashier_draft(
        draft_client, owner, "draft-product-b", visibility="SHARED"
    )
    own_shared = draft_client.post(
        f"/api/v1/sales/drafts/{shared_for_owner['id']}/checkout",
        headers=owner,
        json={"idempotency_key": "cashier-own-shared", "payment_method": "cash"},
    )
    assert own_shared.status_code == 201

    shared_for_cashier = _cashier_draft(
        draft_client, owner, "draft-product-c", visibility="SHARED"
    )
    edited = draft_client.put(
        f"/api/v1/sales/drafts/{shared_for_cashier['id']}",
        headers={**cashier_b, "If-Match": str(shared_for_cashier["version"])},
        json={
            "expected_version": shared_for_cashier["version"],
            "items": [
                {
                    "product_id": "draft-product-c",
                    "quantity": "1",
                    "unit": "piece",
                }
            ],
        },
    )
    assert edited.status_code == 200
    other_cashier_checkout = draft_client.post(
        f"/api/v1/sales/drafts/{shared_for_cashier['id']}/checkout",
        headers=cashier_b,
        json={"idempotency_key": "cashier-shared", "payment_method": "cash"},
    )
    assert other_cashier_checkout.status_code == 201

    manager_shared = _cashier_draft(
        draft_client, owner, "draft-product", visibility="SHARED"
    )
    manager_checkout = draft_client.post(
        f"/api/v1/sales/drafts/{manager_shared['id']}/checkout",
        headers=manager,
        json={"idempotency_key": "manager-shared", "payment_method": "cash"},
    )
    assert manager_checkout.status_code == 201

    admin_shared = _cashier_draft(
        draft_client, owner, "draft-product-b", visibility="SHARED"
    )
    admin_checkout = draft_client.post(
        f"/api/v1/sales/drafts/{admin_shared['id']}/checkout",
        headers=admin,
        json={"idempotency_key": "admin-shared", "payment_method": "cash"},
    )
    assert admin_checkout.status_code == 201

    denied_private = _cashier_draft(
        draft_client, owner, "draft-product-c"
    )
    denied = draft_client.post(
        f"/api/v1/sales/drafts/{denied_private['id']}/checkout",
        headers=cashier_b,
        json={"idempotency_key": "cashier-private-other", "payment_method": "cash"},
    )
    assert denied.status_code == 404

    other_owner = auth(draft_client, "other-owner")
    other_shop_draft = _cashier_draft(
        draft_client, other_owner, "other-product"
    )
    cross_shop = draft_client.post(
        f"/api/v1/sales/drafts/{other_shop_draft['id']}/checkout",
        headers=cashier_b,
        json={"idempotency_key": "cross-shop", "payment_method": "cash"},
    )
    assert cross_shop.status_code == 404

    with next(app.dependency_overrides[get_db]()) as db:
        assert db.scalar(select(Product.stock).where(Product.id == "draft-product")) == 3
        assert db.scalar(select(Product.stock).where(Product.id == "draft-product-b")) == 3
        assert db.scalar(select(Product.stock).where(Product.id == "draft-product-c")) == 4
        assert db.query(SaleDocument).count() == 5
        assert db.query(StockMovement).count() == 5
        assert db.scalar(
            select(SaleDraft.status).where(SaleDraft.id == denied_private["id"])
        ) == "OPEN"


def test_manager_can_checkout_same_shop_private_draft_without_sharing(
    draft_client: TestClient,
) -> None:
    owner = auth(draft_client, "cashier-a")
    manager = auth(draft_client, "manager-a")
    draft = _cashier_draft(draft_client, owner, "draft-product")

    checkout = draft_client.post(
        f"/api/v1/sales/drafts/{draft['id']}/checkout",
        headers=manager,
        json={"idempotency_key": "manager-private", "payment_method": "cash"},
    )

    assert checkout.status_code == 201
    assert checkout.json()["posted_by"] == "manager-a"
    assert checkout.json()["status"] == "POSTED"
    assert checkout.json()["items"][0]["product_id"] == "draft-product"

    with next(app.dependency_overrides[get_db]()) as db:
        stored_draft = db.scalar(
            select(SaleDraft).where(SaleDraft.id == draft["id"])
        )
        assert stored_draft is not None
        assert stored_draft.visibility == "PRIVATE"
        assert stored_draft.status == "CHECKED_OUT"
        assert stored_draft.checkout_sale_id == checkout.json()["sale_id"]
        assert db.query(SaleDocument).count() == 1
        assert db.query(StockMovement).count() == 1
        assert db.scalar(
            select(Product.stock).where(Product.id == "draft-product")
        ) == 4


def _run_concurrently(*operations):
    barrier = Barrier(len(operations))

    def run(operation):
        barrier.wait()
        return operation()

    with ThreadPoolExecutor(max_workers=len(operations)) as executor:
        return list(executor.map(run, operations))


def test_database_claim_allows_only_one_concurrent_draft_version_update(
    draft_client: TestClient,
) -> None:
    owner = auth(draft_client, "cashier-a")
    draft = draft_client.post(
        "/api/v1/sales/drafts", headers=owner, json={}
    ).json()

    def claim():
        with next(app.dependency_overrides[get_db]()) as db:
            result = db.execute(
                update(SaleDraft)
                .where(
                    SaleDraft.id == draft["id"],
                    SaleDraft.shop_id == "draft-shop",
                    SaleDraft.status.in_({"OPEN", "HELD"}),
                    SaleDraft.version == 0,
                )
                .values(version=SaleDraft.version + 1)
                .execution_options(synchronize_session=False)
            )
            db.commit()
            return result.rowcount

    assert sorted(_run_concurrently(claim, claim)) == [0, 1]


def test_database_guarded_stock_decrement_allows_only_one_concurrent_consumer(
    draft_client: TestClient,
) -> None:
    def decrement():
        with next(app.dependency_overrides[get_db]()) as db:
            result = db.execute(
                update(Product)
                .where(
                    Product.id == "draft-product",
                    Product.shop_id == "draft-shop",
                    Product.stock >= 1,
                )
                .values(stock=Product.stock - 1)
                .execution_options(synchronize_session=False)
            )
            db.commit()
            return result.rowcount

    with next(app.dependency_overrides[get_db]()) as db:
        db.execute(update(Product).where(Product.id == "draft-product").values(stock=1))
        db.commit()

    assert sorted(_run_concurrently(decrement, decrement)) == [0, 1]
    with next(app.dependency_overrides[get_db]()) as db:
        assert db.scalar(select(Product.stock).where(Product.id == "draft-product")) == 0


def test_concurrent_same_draft_checkout_replays_or_conflicts_without_duplicate_sale(
    draft_client: TestClient,
) -> None:
    owner = auth(draft_client, "cashier-a")
    other = auth(draft_client, "cashier-b")
    draft = _cashier_draft(
        draft_client, owner, "draft-product", visibility="SHARED"
    )

    def checkout(headers, key):
        return draft_client.post(
            f"/api/v1/sales/drafts/{draft['id']}/checkout",
            headers=headers,
            json={"idempotency_key": key, "payment_method": "cash"},
        ).status_code

    statuses = _run_concurrently(
        lambda: checkout(owner, "concurrent-key"),
        lambda: checkout(other, "concurrent-key"),
    )
    assert statuses == [201, 201]

    with next(app.dependency_overrides[get_db]()) as db:
        assert db.query(SaleDocument).count() == 1
        assert db.query(StockMovement).count() == 1


def test_concurrent_different_keys_and_shared_stock_post_once(
    draft_client: TestClient,
) -> None:
    owner = auth(draft_client, "cashier-a")
    first = _cashier_draft(draft_client, owner, "draft-product")
    second = _cashier_draft(draft_client, owner, "draft-product")
    with next(app.dependency_overrides[get_db]()) as db:
        db.execute(
            update(Product)
            .where(Product.id == "draft-product")
            .values(stock=1)
        )
        db.commit()

    def checkout(draft_id, key):
        return draft_client.post(
            f"/api/v1/sales/drafts/{draft_id}/checkout",
            headers=owner,
            json={"idempotency_key": key, "payment_method": "cash"},
        ).status_code

    statuses = _run_concurrently(
        lambda: checkout(first["id"], "different-key-a"),
        lambda: checkout(second["id"], "different-key-b"),
    )
    assert sorted(statuses) == [201, 409]
    retry = draft_client.post(
        f"/api/v1/sales/drafts/{first['id']}/checkout",
        headers=owner,
        json={"idempotency_key": "different-key-a-2", "payment_method": "cash"},
    )
    assert retry.status_code == 409
    with next(app.dependency_overrides[get_db]()) as db:
        stocks = [
            db.scalar(select(Product.stock).where(Product.id == product_id))
            for product_id in ("draft-product",)
        ]
        assert stocks == [0]
        assert db.query(SaleDocument).count() == 1
        assert db.query(StockMovement).count() == 1


def test_draft_websocket_is_authenticated_and_receives_owner_events(
    draft_client: TestClient,
) -> None:
    token = bearer_token(draft_client)
    owner = {"Authorization": f"Bearer {token}"}
    with draft_client.websocket_connect(
        f"/api/v1/sales/drafts/ws?token={token}"
    ) as socket:
        created = draft_client.post("/api/v1/sales/drafts", headers=owner, json={})
        assert created.status_code == 201
        event = socket.receive_json()
        assert event["type"] == "sale_draft.updated"
        assert event["action"] == "created"
        assert event["draft_id"] == created.json()["id"]
    with pytest.raises(Exception):
        with draft_client.websocket_connect("/api/v1/sales/drafts/ws?token=invalid"):
            pass


def test_legacy_full_draft_update_and_versioned_checkout_contract(
    draft_client: TestClient,
) -> None:
    owner = auth(draft_client)
    draft = draft_client.post("/api/v1/sales/drafts", headers=owner, json={}).json()
    updated = draft_client.put(
        f"/api/v1/sales/drafts/{draft['id']}",
        headers={**owner, "If-Match": "0"},
        json={
            "items": [
                {
                    "product_id": "draft-product",
                    "name": "ignored client label",
                    "quantity": 1,
                    "unit": "piece",
                    "unit_price": 10,
                }
            ],
            "payment_method": "cash",
            "version": 0,
        },
    )
    assert updated.status_code == 200
    assert updated.json()["version"] == 1
    checkout = draft_client.post(
        f"/api/v1/sales/drafts/{draft['id']}/checkout",
        headers={**owner, "If-Match": "1"},
        json={"payment_method": "cash", "version": 1},
    )
    assert checkout.status_code == 201
    replay = draft_client.post(
        f"/api/v1/sales/drafts/{draft['id']}/checkout",
        headers=owner,
        json={"payment_method": "cash", "version": 1},
    )
    assert replay.status_code == 201
    assert replay.json()["sale_id"] == checkout.json()["sale_id"]


def test_full_draft_replacement_updates_same_product_repeatedly(
    draft_client: TestClient,
) -> None:
    owner = auth(draft_client)
    draft = draft_client.post("/api/v1/sales/drafts", headers=owner, json={}).json()
    draft_id = draft["id"]

    for expected_version, quantity in enumerate((2, 3, 1, 3, 1, 2)):
        response = draft_client.put(
            f"/api/v1/sales/drafts/{draft_id}",
            headers={**owner, "If-Match": str(expected_version)},
            json={
                "items": [
                    {
                        "product_id": "draft-product",
                        "quantity": quantity,
                        "unit": "piece",
                    }
                ],
                "expected_version": expected_version,
            },
        )
        assert response.status_code == 200
        assert response.json()["version"] == expected_version + 1
        assert response.json()["items"][0]["quantity"] == str(quantity)


def test_full_draft_replacement_deletes_removed_and_inserts_new_items(
    draft_client: TestClient,
) -> None:
    owner = auth(draft_client)
    draft = draft_client.post("/api/v1/sales/drafts", headers=owner, json={}).json()
    draft_id = draft["id"]

    initial = draft_client.put(
        f"/api/v1/sales/drafts/{draft_id}",
        headers={**owner, "If-Match": "0"},
        json={
            "items": [
                {"product_id": "draft-product", "quantity": 2},
                {"product_id": "draft-product-b", "quantity": 1},
            ],
        },
    )
    assert initial.status_code == 200

    replaced = draft_client.put(
        f"/api/v1/sales/drafts/{draft_id}",
        headers={**owner, "If-Match": "1"},
        json={
            "items": [
                {"product_id": "draft-product", "quantity": 3},
                {"product_id": "draft-product-c", "quantity": 1},
            ],
        },
    )
    assert replaced.status_code == 200
    assert {
        (item["product_id"], item["quantity"]) for item in replaced.json()["items"]
    } == {("draft-product", "3"), ("draft-product-c", "1")}
