from collections.abc import Generator
from datetime import datetime

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import Session, sessionmaker

from app.database import Base, configure_sqlite_foreign_keys, get_db
from app.main import app
from app.models import (
    Category,
    IdempotencyRecord,
    OpeningStockDocument,
    OpeningStockLine,
    InventoryLotRecord,
    Product,
    ProductSellingUnit,
    Shop,
    StockAdjustmentDocument,
    StockAdjustmentLine,
    StockMovement,
    FifoCostCorrection,
    SaleItemFifoAllocation,
    SaleItemFifoRestoration,
    User,
)
from app.security import hash_password
from app.fifo_inventory import FifoInventoryCostingService


@pytest.fixture
def client(tmp_path) -> Generator[TestClient, None, None]:
    engine = create_engine(f"sqlite:///{tmp_path / 'test.db'}", connect_args={"check_same_thread": False})
    configure_sqlite_foreign_keys(engine)
    Base.metadata.create_all(engine)
    factory = sessionmaker(bind=engine, autoflush=False, expire_on_commit=False)

    def override_get_db() -> Generator[Session, None, None]:
        with factory() as session:
            yield session

    app.dependency_overrides[get_db] = override_get_db
    try:
        yield TestClient(app)
    finally:
        app.dependency_overrides.pop(get_db, None)
        engine.dispose()


@pytest.fixture
def seeded(client: TestClient) -> tuple[TestClient, str]:
    factory_generator = app.dependency_overrides[get_db]()
    db = next(factory_generator)
    db.add_all([
        Shop(id="shop-one", name="Shop One"),
        Shop(id="shop-two", name="Shop Two"),
    ])
    db.flush()
    db.add_all([
        User(id="user-one", shop_id="shop-one", username="admin", display_name="Admin",
             password_hash=hash_password("secret"), role="admin"),
        User(id="cashier-one-dev", shop_id="shop-one", username="cashier-1",
             display_name="Cashier 1", password_hash=hash_password("cashier-1"),
             role="cashier"),
        User(id="manager-one", shop_id="shop-one", username="manager", display_name="Manager",
             password_hash=hash_password("secret"), role="manager"),
        User(id="cashier-one", shop_id="shop-one", username="cashier", display_name="Cashier",
             password_hash=hash_password("secret"), role="cashier"),
        User(id="user-two", shop_id="shop-two", username="other", display_name="Other",
             password_hash=hash_password("secret"), role="cashier"),
        User(id="manager-two", shop_id="shop-two", username="manager-two", display_name="Manager Two",
             password_hash=hash_password("secret"), role="manager"),
        Category(id="cat-one", shop_id="shop-one", name="Phones"),
        Category(id="cat-two", shop_id="shop-two", name="Other"),
    ])
    db.flush()
    db.add_all([
        Product(id="product-one", shop_id="shop-one", category_id="cat-one", name="Phone",
                code="P-1", barcode="111", product_type="PACKAGED", price=100,
                min_price=90, wholesale_price=80, cost=50, stock=2, min_stock=5),
        Product(id="inactive-one", shop_id="shop-one", name="Inactive", barcode="999",
                is_active=False),
        Product(id="other-product", shop_id="shop-two", name="Other Shop Product", barcode="222"),
        ProductSellingUnit(id="unit-piece", product_id="product-one", name="piece",
                           conversion_to_base=1, selling_price=100, cost_price=50,
                           is_default=True, barcode="111-piece"),
        ProductSellingUnit(id="unit-box", product_id="product-one", name="box",
                           conversion_to_base=10, selling_price=950, cost_price=500,
                           wholesale_price=900, barcode="111-box"),
    ])
    db.commit()
    login = client.post("/api/v1/auth/login", json={"username": "admin", "password": "secret"})
    factory_generator.close()
    return client, login.json()["access_token"]


def headers(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


def _record_opening_stock(
    db: Session,
    product_id: str,
    quantity: float,
    unit_cost: float,
) -> None:
    product = db.get(Product, product_id)
    assert product is not None
    document_id = f"opening-{product_id}"
    movement_id = f"{document_id}-movement"
    created_at = datetime(2024, 1, 1)
    document = OpeningStockDocument(
        id=document_id,
        shop_id=product.shop_id,
        product_id=product.id,
        idempotency_key=document_id,
        reference_number=f"OS-{product.id}",
        quantity=quantity,
        unit_cost=unit_cost,
        reason="Initial inventory",
        posted_by="user-one",
        created_at=created_at,
    )
    db.add(document)
    db.flush()
    db.add_all([
        OpeningStockLine(
            id=f"{document_id}-line",
            document_id=document_id,
            product_id=product.id,
            quantity=quantity,
            unit_cost=unit_cost,
            line_total=quantity * unit_cost,
            base_quantity=quantity,
            created_at=created_at,
        ),
    ])
    db.flush()
    db.add_all([
        StockMovement(
            id=movement_id,
            shop_id=product.shop_id,
            product_id=product.id,
            movement_type="opening_stock",
            quantity_change=quantity,
            unit_cost=unit_cost,
            running_stock=quantity,
            reference_type="opening_stock",
            reference_id=document_id,
            created_at=created_at,
        ),
    ])
    db.flush()
    db.add(
        InventoryLotRecord(
            id=f"fifo-lot-{product.shop_id}-{product.id}-{movement_id}",
            shop_id=product.shop_id,
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
    db.commit()


def test_health_and_version(client: TestClient) -> None:
    assert client.get("/api/v1/health").json() == {"status": "ok", "database": "ok"}
    assert client.get("/api/v1/version").json()["version"] == "1.0.0"


def test_login_and_invalid_login(seeded) -> None:
    client, _ = seeded
    response = client.post("/api/v1/auth/login", json={"username": "admin", "password": "secret"})
    assert response.status_code == 200
    assert response.json()["role"] == "admin"
    assert response.json()["shop_id"] == "shop-one"
    assert client.post("/api/v1/auth/login", json={"username": "admin", "password": "wrong"}).status_code == 401


def test_user_management_preserves_roles_and_deactivation_safety(seeded) -> None:
    client, admin_token = seeded
    admin = headers(admin_token)

    users = client.get("/api/v1/users", headers=admin)
    assert users.status_code == 200
    by_username = {item["username"]: item for item in users.json()}
    assert by_username["admin"]["role"] == "admin"
    assert by_username["manager"]["role"] == "manager"
    assert by_username["cashier"]["role"] == "cashier"
    assert "password_hash" not in by_username["admin"]

    created = client.post(
        "/api/v1/users",
        headers=admin,
        json={
            "username": "testmanager",
            "display_name": "Test Manager",
            "password": "testmanager",
            "role": "manager",
        },
    )
    assert created.status_code == 201
    assert created.json()["role"] == "manager"
    assert client.post(
        "/api/v1/users",
        headers=admin,
        json={
            "username": "testmanager",
            "display_name": "Duplicate",
            "password": "testmanager",
            "role": "manager",
        },
    ).status_code == 409

    updated = client.patch(
        "/api/v1/users/testmanager",
        headers=admin,
        json={"role": "cashier"},
    )
    assert updated.status_code == 200
    assert updated.json()["role"] == "cashier"

    deactivated = client.delete("/api/v1/users/cashier-one", headers=admin)
    assert deactivated.status_code == 200
    assert deactivated.json()["is_active"] is False
    assert client.post(
        "/api/v1/auth/login",
        json={"username": "cashier", "password": "secret"},
    ).status_code == 401

    assert client.delete("/api/v1/users/user-one", headers=admin).status_code == 409
    assert client.delete("/api/v1/users/user-two", headers=admin).status_code == 404
    manager = headers(login_token(client, "manager"))
    assert client.delete("/api/v1/users/cashier-one-dev", headers=manager).status_code == 403


def test_cashier_1_development_quick_login(seeded) -> None:
    client, _ = seeded
    response = client.post(
        "/api/v1/auth/login",
        json={"username": "cashier-1", "password": "cashier-1"},
    )
    assert response.status_code == 200
    assert response.json()["access_token"]
    assert response.json()["role"] == "cashier"
    assert response.json()["shop_id"] == "shop-one"


def test_authorization_is_required(client: TestClient) -> None:
    assert client.get("/api/v1/products").status_code == 401
    assert client.get("/api/v1/categories").status_code == 401


def login_token(client: TestClient, username: str) -> str:
    response = client.post(
        "/api/v1/auth/login",
        json={"username": username, "password": "secret"},
    )
    assert response.status_code == 200
    return response.json()["access_token"]


def test_role_matrix_is_enforced_for_catalog_and_stock_commands(seeded) -> None:
    client, admin_token = seeded
    manager = headers(login_token(client, "manager"))
    cashier = headers(login_token(client, "cashier"))
    admin = headers(admin_token)
    product_payload = {
        "id": "permission-product",
        "name": "Permission Product",
        "price": 1,
        "cost": 1,
    }

    assert client.get("/api/v1/products", headers=cashier).status_code == 200
    assert client.get("/api/v1/categories", headers=cashier).status_code == 200
    assert client.get("/api/v1/stock/summary", headers=cashier).status_code == 403
    assert client.post(
        "/api/v1/products", headers=cashier, json=product_payload
    ).status_code == 403
    assert client.put(
        "/api/v1/products/product-one",
        headers=cashier,
        json={**product_payload, "id": "product-one", "name": "No Update"},
    ).status_code == 403
    assert client.delete(
        "/api/v1/products/product-one", headers=cashier
    ).status_code == 403
    assert client.post(
        "/api/v1/categories", headers=cashier, json={"name": "Cashier Category"}
    ).status_code == 403
    assert client.post(
        "/api/v1/stock/adjustments",
        headers=cashier,
        json={
            "idempotency_key": "cashier-adjustment",
            "reason": "Count",
            "lines": [{"product_id": "product-one", "counted_quantity": 3}],
        },
    ).status_code == 403

    assert client.post(
        "/api/v1/products", headers=manager, json=product_payload
    ).status_code == 201
    assert client.put(
        "/api/v1/products/permission-product",
        headers=manager,
        json={**product_payload, "name": "Updated Permission Product"},
    ).status_code == 200
    assert client.post(
        "/api/v1/categories", headers=manager, json={"name": "Manager Category"}
    ).status_code == 201
    assert client.delete(
        "/api/v1/categories/cat-one", headers=manager
    ).status_code == 409
    assert client.delete(
        "/api/v1/products/permission-product", headers=manager
    ).status_code == 200
    assert client.delete(
        "/api/v1/products/missing", headers=admin
    ).status_code == 404


def test_analytics_and_stock_summary_follow_role_hierarchy(seeded) -> None:
    client, admin_token = seeded
    admin = headers(admin_token)
    manager = headers(login_token(client, "manager"))
    cashier = headers(login_token(client, "cashier"))

    for auth in (admin, manager):
        assert client.get("/api/v1/analytics", headers=auth).status_code == 200
        assert client.get("/api/v1/stock-summary", headers=auth).status_code == 200

    assert client.get("/api/v1/analytics", headers=cashier).status_code == 403
    assert client.get("/api/v1/stock-summary", headers=cashier).status_code == 403

    assert client.get("/api/v1/users", headers=admin).status_code == 200
    assert client.get("/api/v1/users", headers=manager).status_code == 200
    assert client.get("/api/v1/users", headers=cashier).status_code == 200
    assert client.post(
        "/api/v1/users",
        headers=manager,
        json={
            "username": "manager-created",
            "display_name": "Manager Created",
            "password": "secret",
            "role": "cashier",
        },
    ).status_code == 403
    assert client.post(
        "/api/v1/users",
        headers=cashier,
        json={
            "username": "cashier-created",
            "display_name": "Cashier Created",
            "password": "secret",
            "role": "cashier",
        },
    ).status_code == 403


def test_categories_are_shop_scoped(seeded) -> None:
    client, token = seeded
    response = client.get("/api/v1/categories", headers=headers(token))
    assert response.status_code == 200
    assert response.json() == [{"id": "cat-one", "name": "Phones"}]


def test_category_create_refresh_and_delete(seeded) -> None:
    client, token = seeded
    auth = headers(token)
    created = client.post(
        "/api/v1/categories",
        headers=auth,
        json={"name": "  Good Server Category  "},
    )
    assert created.status_code == 201
    category = created.json()
    assert category["name"] == "Good Server Category"
    assert category["id"].startswith("category-")
    assert any(
        item["id"] == category["id"]
        for item in client.get("/api/v1/categories", headers=auth).json()
    )
    deleted = client.delete(
        f"/api/v1/categories/{category['id']}",
        headers=auth,
    )
    assert deleted.status_code == 200
    assert all(
        item["id"] != category["id"]
        for item in client.get("/api/v1/categories", headers=auth).json()
    )


def test_category_create_delete_validation_and_isolation(seeded) -> None:
    client, token = seeded
    auth = headers(token)
    assert client.post(
        "/api/v1/categories",
        headers=auth,
        json={"name": " Phones "},
    ).status_code == 409
    assert client.post(
        "/api/v1/categories",
        headers=auth,
        json={"name": "   "},
    ).status_code == 422
    assert client.delete("/api/v1/categories/missing", headers=auth).status_code == 404
    assert client.delete("/api/v1/categories/cat-two", headers=auth).status_code == 404
    assert client.delete("/api/v1/categories/cat-one", headers=auth).status_code == 409


def test_category_name_can_be_reused_after_soft_delete_and_remains_shop_scoped(
    seeded,
) -> None:
    client, token = seeded
    auth = headers(token)
    created = client.post(
        "/api/v1/categories",
        headers=auth,
        json={"name": " Beverages "},
    )
    assert created.status_code == 201
    category_id = created.json()["id"]
    assert client.post(
        "/api/v1/categories",
        headers=auth,
        json={"name": " beverages "},
    ).status_code == 409

    other_token = client.post(
        "/api/v1/auth/login",
        json={"username": "manager-two", "password": "secret"},
    ).json()["access_token"]
    assert client.post(
        "/api/v1/categories",
        headers=headers(other_token),
        json={"name": "Beverages"},
    ).status_code == 201

    deleted = client.delete(f"/api/v1/categories/{category_id}", headers=auth)
    assert deleted.status_code == 200
    assert all(
        item["id"] != category_id
        for item in client.get("/api/v1/categories", headers=auth).json()
    )

    recreated = client.post(
        "/api/v1/categories",
        headers=auth,
        json={"name": "Beverages"},
    )
    assert recreated.status_code == 201
    assert recreated.json()["id"] != category_id
    assert client.post(
        "/api/v1/categories",
        headers=auth,
        json={"name": " beverages "},
    ).status_code == 409


def test_stock_summary_uses_corrected_fifo_value_without_rewriting_history(
    seeded,
) -> None:
    client, token = seeded
    auth = headers(token)
    category = client.post(
        "/api/v1/categories",
        headers=auth,
        json={"name": "FIFO Valuation"},
    )
    assert category.status_code == 201
    product_id = "fifo-summary-valuation"
    created = client.post(
        "/api/v1/products",
        headers=auth,
        json=_create_payload(
            product_id,
            opening_quantity=50,
            opening_unit_cost=60,
            opening_reason="Opening acquisition",
            category_id=category.json()["id"],
        ),
    )
    assert created.status_code == 201
    layer = client.get(
        f"/api/v1/products/{product_id}/fifo-layers", headers=auth
    ).json()[0]
    corrected = client.post(
        f"/api/v1/products/{product_id}/fifo-cost-corrections",
        headers={**auth, "Idempotency-Key": "fifo-summary-valuation-correction"},
        json={"layer_id": layer["layer_id"], "new_unit_cost": 50},
    )
    assert corrected.status_code == 201

    summary = client.get("/api/v1/stock-summary", headers=auth).json()
    row = next(
        item
        for item in summary["categories"]
        if item["category_id"] == category.json()["id"]
    )
    assert row["total_quantity"] == 50
    assert row["total_current_inventory_cost"] == 2500
    assert row["total_historic_value"] == 2500


def test_stock_summary_keeps_mixed_product_units_separate(seeded) -> None:
    client, token = seeded
    auth = headers(token)
    category = client.post(
        "/api/v1/categories",
        headers=auth,
        json={"name": "Mixed Units"},
    )
    assert category.status_code == 201
    category_id = category.json()["id"]
    for product_id, unit, quantity in [
        ("mixed-units-cola", "piece", 50),
        ("mixed-units-oil", "kg", 25),
    ]:
        created = client.post(
            "/api/v1/products",
            headers=auth,
            json={
                **_create_payload(
                    product_id,
                    opening_quantity=quantity,
                    opening_unit_cost=10,
                    opening_reason="Mixed-unit fixture",
                    category_id=category_id,
                    opening_unit=unit,
                ),
                "base_unit": unit,
            },
        )
        assert created.status_code == 201, created.text

    summary = client.get("/api/v1/stock-summary", headers=auth).json()
    row = next(item for item in summary["categories"] if item["category_id"] == category_id)
    assert row["quantity_by_unit"] == {"piece": 50.0, "kg": 25.0}

    second_category = client.post(
        "/api/v1/categories",
        headers=auth,
        json={"name": "Packaged Food"},
    )
    assert second_category.status_code == 201
    packaged = client.post(
        "/api/v1/products",
        headers=auth,
        json={
            **_create_payload(
                "mixed-units-packaged",
                product_type="PACKAGED",
                opening_reason="Mixed-unit packaged fixture",
                category_id=second_category.json()["id"],
                selling_units=[
                    {
                        "id": "mixed-packaged-piece",
                        "name": "Piece",
                        "conversion_to_base": 1,
                        "selling_price": 10,
                        "cost_price": 10,
                        "wholesale_price": 10,
                        "minimum_stock": 0,
                        "is_default": True,
                        "is_active": True,
                    },
                    {
                        "id": "mixed-packaged-pack",
                        "name": "Pack",
                        "conversion_to_base": 10,
                        "selling_price": 100,
                        "cost_price": 100,
                        "wholesale_price": 100,
                        "minimum_stock": 0,
                        "is_default": False,
                        "is_active": True,
                    },
                    {
                        "id": "mixed-packaged-box",
                        "name": "Box",
                        "conversion_to_base": 20,
                        "selling_price": 200,
                        "cost_price": 200,
                        "wholesale_price": 200,
                        "minimum_stock": 0,
                        "is_default": False,
                        "is_active": True,
                    },
                ],
            ),
            "base_unit": "piece",
            "opening_lines": [
                {"unit": "Pack", "quantity": 10, "unit_cost": 100},
            ],
        },
    )
    assert packaged.status_code == 201, packaged.text
    summary = client.get("/api/v1/stock-summary", headers=auth).json()
    packaged_row = next(
        item
        for item in summary["categories"]
        if item["category_id"] == second_category.json()["id"]
    )
    assert packaged_row["quantity_by_unit"] == {"piece": 100.0}


def test_stock_summary_uses_packaged_piece_price_for_expected_value(seeded) -> None:
    client, token = seeded
    category = client.post(
        "/api/v1/categories",
        headers=headers(token),
        json={"name": "Packaged Valuation"},
    )
    assert category.status_code == 201
    response = client.post(
        "/api/v1/products",
        headers=headers(token),
        json={
            **_create_payload(
                "packaged-valuation",
                "Test Biscuit",
                "PACKAGED",
                [
                    {
                        "id": "packaged-valuation-piece",
                        "name": "Piece",
                        "conversion_to_base": 1,
                        "selling_price": 100,
                        "is_default": True,
                    },
                    {
                        "id": "packaged-valuation-pack",
                        "name": "Pack",
                        "conversion_to_base": 30,
                        "selling_price": 1200,
                        "wholesale_price": 1100,
                    },
                    {
                        "id": "packaged-valuation-box",
                        "name": "Box",
                        "conversion_to_base": 360,
                        "selling_price": 13500,
                        "wholesale_price": 12500,
                    },
                ],
                category_id=category.json()["id"],
                opening_reason="Initial packaged stock",
            ),
            "opening_lines": [
                {"unit": "Pack", "quantity": 10, "unit_cost": 900},
                {"unit": "Box", "quantity": 2, "unit_cost": 8500},
            ],
        },
    )
    assert response.status_code == 201, response.text

    summary = client.get("/api/v1/stock-summary", headers=headers(token))
    assert summary.status_code == 200, summary.text
    row = next(
        item
        for item in summary.json()["categories"]
        if item["category_id"] == category.json()["id"]
    )
    assert row["total_quantity"] == 1020
    assert row["total_current_inventory_cost"] == 26000
    assert row["total_default_sell_value"] == 39000
    assert row["total_default_sell_value"] - row["total_current_inventory_cost"] == 13000
    assert row["wholesale_prices_by_unit"]["Pack"] == [1100]
    assert row["wholesale_prices_by_unit"]["Box"] == [12500]


def test_product_list_detail_and_filters(seeded) -> None:
    client, token = seeded
    response = client.get("/api/v1/products?page=1&page_size=1&search=Phone", headers=headers(token))
    assert response.json()["total"] == 1
    detail = client.get("/api/v1/products/product-one", headers=headers(token))
    assert detail.status_code == 200
    assert detail.json()["category_name"] == "Phones"


def test_delete_product_deactivates_shop_product(seeded) -> None:
    client, token = seeded
    response = client.delete("/api/v1/products/product-one", headers=headers(token))
    assert response.status_code == 200
    assert response.json()["id"] == "product-one"
    assert response.json()["is_active"] is False
    assert client.get(
        "/api/v1/products?page=1&page_size=50&active=true",
        headers=headers(token),
    ).json()["total"] == 0
    assert client.get(
        "/api/v1/products/product-one",
        headers=headers(token),
    ).status_code == 200


def test_delete_product_returns_not_found_and_enforces_shop_scope(seeded) -> None:
    client, token = seeded
    assert client.delete(
        "/api/v1/products/missing",
        headers=headers(token),
    ).status_code == 404
    assert client.delete(
        "/api/v1/products/other-product",
        headers=headers(token),
    ).status_code == 404


def test_barcode_lookup_distinguishes_states(seeded) -> None:
    client, token = seeded
    auth = headers(token)
    assert client.get("/api/v1/products/barcode/111", headers=auth).status_code == 200
    assert client.get("/api/v1/products/barcode/111-box", headers=auth).status_code == 404
    assert client.get("/api/v1/products/barcode/missing", headers=auth).status_code == 404
    assert client.get("/api/v1/products/barcode/999", headers=auth).status_code == 410
    product = client.get("/api/v1/products/product-one", headers=auth).json()
    assert {unit["barcode"] for unit in product["selling_units"]} == {None}


def test_packaged_units_and_stock_summary(seeded) -> None:
    client, token = seeded
    auth = headers(token)
    product = client.get("/api/v1/products/product-one", headers=auth).json()
    assert {unit["name"] for unit in product["selling_units"]} == {"piece", "box"}
    assert client.get("/api/v1/stock/summary", headers=auth).json() == {
        "total_products": 1,
        "low_stock_products": 1,
        "out_of_stock_products": 0,
        "total_stock_quantity": 2.0,
    }
    detail = client.get("/api/v1/stock-summary", headers=auth)
    assert detail.status_code == 200
    category = detail.json()["categories"][0]
    assert category["category_id"] == "cat-one"
    assert category["category_name"] == "Phones"
    assert category["total_quantity"] == 2.0
    assert category["total_current_inventory_cost"] == 100.0
    assert category["total_default_sell_value"] == 200.0
    assert detail.json()["total_expected_profit"] == 100.0


def test_shop_tenant_isolation(seeded) -> None:
    client, token = seeded
    auth = headers(token)
    assert client.get("/api/v1/products/other-product", headers=auth).status_code == 404
    assert client.get("/api/v1/products/barcode/222", headers=auth).status_code == 404


def test_stock_adjustment_updates_product_and_creates_history(seeded) -> None:
    client, token = seeded
    factory_generator = app.dependency_overrides[get_db]()
    db = next(factory_generator)
    _record_opening_stock(db, "product-one", 2, 50)
    factory_generator.close()

    response = client.post(
        "/api/v1/stock/adjustments",
        headers=headers(token),
        json={
            "idempotency_key": "adjustment-one",
            "reason": "Physical count",
            "notes": "Cycle count",
            "lines": [{
                "product_id": "product-one",
                "unit": "piece",
                "counted_quantity": 12,
                "unit_cost": 50,
                "operation": "add",
            }],
        },
    )
    assert response.status_code == 201
    body = response.json()
    assert body["product"]["stock"] == 12
    assert body["lines"][0]["quantity_change"] == 10
    assert body["lines"][0]["running_stock"] == 12

    factory_generator = app.dependency_overrides[get_db]()
    db = next(factory_generator)
    assert db.query(StockAdjustmentDocument).count() == 1
    assert db.query(StockAdjustmentLine).count() == 1
    movement = db.query(StockMovement).filter_by(
        movement_type="stock_adjustment"
    ).one()
    assert movement.movement_type == "stock_adjustment"
    assert movement.running_stock == 12
    detail = client.get("/api/v1/stock-summary", headers=headers(token)).json()
    category = detail["categories"][0]
    assert category["total_current_inventory_cost"] == 600.0
    assert category["total_default_sell_value"] == 1150.0
    assert detail["total_expected_profit"] == 550.0
    assert category["total_historic_value"] == 600.0
    factory_generator.close()


def test_stock_reduction_reconciles_persisted_fifo_lots(seeded) -> None:
    client, token = seeded
    auth = headers(token)
    factory_generator = app.dependency_overrides[get_db]()
    db = next(factory_generator)
    _record_opening_stock(db, "product-one", 2, 50)
    factory_generator.close()

    increased = client.post(
        "/api/v1/stock/adjustments",
        headers=auth,
        json={
            "idempotency_key": "adjustment-increase-before-reduction",
            "reason": "Physical count",
            "lines": [{
                "product_id": "product-one",
                "unit": "piece",
                "counted_quantity": 12,
                "unit_cost": 50,
                "operation": "add",
            }],
        },
    )
    assert increased.status_code == 201

    factory_generator = app.dependency_overrides[get_db]()
    db = next(factory_generator)
    opening_lot = db.query(InventoryLotRecord).filter_by(
        product_id="product-one",
        movement_id="opening-product-one-movement",
    ).one()
    opening_lot.remaining_quantity += 5
    db.commit()
    factory_generator.close()

    reduced = client.post(
        "/api/v1/stock/adjustments",
        headers=auth,
        json={
            "idempotency_key": "adjustment-reduction",
            "reason": "Physical count",
            "lines": [{
                "product_id": "product-one",
                "unit": "piece",
                "counted_quantity": 7,
                "operation": "remove",
            }],
        },
    )
    assert reduced.status_code == 201

    factory_generator = app.dependency_overrides[get_db]()
    db = next(factory_generator)
    lots = db.query(InventoryLotRecord).filter_by(product_id="product-one").all()
    product = db.get(Product, "product-one")
    assert product is not None
    assert sum(lot.remaining_quantity for lot in lots) == product.stock == 7
    assert sum(lot.remaining_quantity * lot.unit_cost for lot in lots) == 350
    assert db.query(StockMovement).filter_by(
        product_id="product-one"
    ).count() == 3
    factory_generator.close()


def test_packaged_stock_adjustment_converts_entered_unit_cost_to_base_cost(
    seeded,
) -> None:
    client, token = seeded
    auth = headers(token)
    created = client.post(
        "/api/v1/products",
        headers=auth,
        json={
            **_create_payload(
                "adjustment-packaged-cost",
                product_type="PACKAGED",
                opening_quantity=0,
                opening_reason="Adjustment cost fixture",
                selling_units=[
                    {
                        "id": "adjustment-packaged-piece",
                        "name": "Piece",
                        "conversion_to_base": 1,
                        "selling_price": 100,
                        "cost_price": 0,
                        "is_default": True,
                        "is_active": True,
                    },
                    {
                        "id": "adjustment-packaged-pack",
                        "name": "Pack",
                        "conversion_to_base": 30,
                        "selling_price": 1200,
                        "cost_price": 0,
                        "is_default": False,
                        "is_active": True,
                    },
                ],
            ),
            "base_unit": "piece",
        },
    )
    assert created.status_code == 201, created.text

    response = client.post(
        "/api/v1/stock/adjustments",
        headers=auth,
        json={
            "idempotency_key": "packaged-adjustment-cost",
            "reason": "Found goods",
            "lines": [{
                "product_id": "adjustment-packaged-cost",
                "unit": "Pack",
                "counted_quantity": 60,
                "unit_cost": 900,
                "operation": "add",
            }],
        },
    )
    assert response.status_code == 201, response.text
    line = response.json()["lines"][0]
    assert line["quantity_change"] == 60
    assert line["unit_cost"] == 30
    assert line["line_total"] == 1800

    factory_generator = app.dependency_overrides[get_db]()
    db = next(factory_generator)
    lot = db.query(InventoryLotRecord).filter_by(
        product_id="adjustment-packaged-cost"
    ).one()
    assert lot.remaining_quantity == 60
    assert lot.unit_cost == 30
    factory_generator.close()


def test_packaged_box_stock_adjustment_converts_exact_ui_payload(seeded) -> None:
    client, token = seeded
    auth = headers(token)
    created = client.post(
        "/api/v1/products",
        headers=auth,
        json={
            **_create_payload(
                "adjustment-packaged-box-cost",
                product_type="PACKAGED",
                opening_quantity=0,
                opening_reason="Box adjustment cost fixture",
                selling_units=[
                    {
                        "id": "adjustment-box-piece",
                        "name": "Piece",
                        "conversion_to_base": 1,
                        "selling_price": 100,
                        "cost_price": 0,
                        "is_default": True,
                        "is_active": True,
                    },
                    {
                        "id": "adjustment-box-box",
                        "name": "Box",
                        "conversion_to_base": 360,
                        "selling_price": 13500,
                        "cost_price": 0,
                        "is_default": False,
                        "is_active": True,
                    },
                ],
            ),
            "base_unit": "piece",
        },
    )
    assert created.status_code == 201, created.text

    response = client.post(
        "/api/v1/stock/adjustments",
        headers=auth,
        json={
            "idempotency_key": "packaged-box-adjustment-cost",
            "reason": "Found goods",
            "lines": [{
                "product_id": "adjustment-packaged-box-cost",
                "unit": "Box",
                "counted_quantity": 360,
                "unit_cost": 8500,
                "operation": "add",
            }],
        },
    )
    assert response.status_code == 201, response.text
    line = response.json()["lines"][0]
    assert line["quantity_change"] == 360
    assert line["unit_cost"] == pytest.approx(8500 / 360)
    assert line["line_total"] == pytest.approx(8500)

    factory_generator = app.dependency_overrides[get_db]()
    db = next(factory_generator)
    lot = db.query(InventoryLotRecord).filter_by(
        product_id="adjustment-packaged-box-cost"
    ).one()
    assert lot.remaining_quantity == 360
    assert lot.unit_cost == pytest.approx(8500 / 360)
    factory_generator.close()


def test_packaged_remove_adjustment_uses_fifo_cost_without_input_cost(seeded) -> None:
    client, token = seeded
    auth = headers(token)
    created = client.post(
        "/api/v1/products",
        headers=auth,
        json={
            **_create_payload(
                "adjustment-packaged-remove",
                product_type="PACKAGED",
                opening_reason="Remove adjustment fixture",
                selling_units=[
                    {
                        "id": "remove-piece",
                        "name": "Piece",
                        "conversion_to_base": 1,
                        "selling_price": 100,
                        "cost_price": 30,
                        "is_default": True,
                        "is_active": True,
                    },
                    {
                        "id": "remove-pack",
                        "name": "Pack",
                        "conversion_to_base": 30,
                        "selling_price": 1250,
                        "cost_price": 900,
                        "is_default": False,
                        "is_active": True,
                    },
                    {
                        "id": "remove-box",
                        "name": "Box",
                        "conversion_to_base": 360,
                        "selling_price": 14000,
                        "cost_price": 8500,
                        "is_default": False,
                        "is_active": True,
                    },
                ],
            ),
            "base_unit": "piece",
            "opening_lines": [
                {"unit": "pack", "quantity": 10, "unit_cost": 900},
                {"unit": "box", "quantity": 2, "unit_cost": 8500},
            ],
        },
    )
    assert created.status_code == 201, created.text

    for idempotency_key, counted_quantity, unit_cost, layer_quantity, corrected_cost in [
        ("packaged-remove-layer-3", 1080, 900, 60, 30),
        ("packaged-remove-layer-4", 1440, 8500, 360, 8500 / 360),
    ]:
        added = client.post(
            "/api/v1/stock/adjustments",
            headers=auth,
            json={
                "idempotency_key": idempotency_key,
                "reason": "FIFO layer fixture",
                "lines": [{
                    "product_id": "adjustment-packaged-remove",
                    "unit": "Piece",
                    "counted_quantity": counted_quantity,
                    "unit_cost": unit_cost,
                    "operation": "add",
                }],
            },
        )
        assert added.status_code == 201, added.text
        layers_response = client.get(
            "/api/v1/products/adjustment-packaged-remove/fifo-layers",
            headers=auth,
        )
        assert layers_response.status_code == 200, layers_response.text
        layer = next(
            layer
            for layer in layers_response.json()
            if layer["current_unit_cost"] == pytest.approx(unit_cost)
            and layer["remaining_quantity"] == pytest.approx(layer_quantity)
        )
        corrected = client.post(
            "/api/v1/products/adjustment-packaged-remove/fifo-cost-corrections",
            headers={
                **auth,
                "Idempotency-Key": f"{idempotency_key}-cost-correction",
            },
            json={
                "layer_id": layer["layer_id"],
                "new_unit_cost": corrected_cost,
            },
        )
        assert corrected.status_code == 201, corrected.text

    response = client.post(
        "/api/v1/stock/adjustments",
        headers=auth,
        json={
            "idempotency_key": "packaged-remove-no-cost",
            "reason": "Damaged goods",
            "lines": [{
                "product_id": "adjustment-packaged-remove",
                "unit": "Pack",
                "counted_quantity": 1410,
                "unit_cost": 0,
                "operation": "remove",
            }],
        },
    )
    assert response.status_code == 201, response.text
    line = response.json()["lines"][0]
    assert line["quantity_change"] == -30
    assert line["unit_cost"] == pytest.approx(30)
    assert line["line_total"] == pytest.approx(900)

    factory_generator = app.dependency_overrides[get_db]()
    db = next(factory_generator)
    removal_record = db.query(StockMovement).filter(
        StockMovement.product_id == "adjustment-packaged-remove",
        StockMovement.quantity_change == -30,
    ).one()
    removal_record.unit_cost = 0
    for lot in db.query(InventoryLotRecord).filter_by(
        product_id="adjustment-packaged-remove"
    ).all():
        lot.remaining_quantity = lot.received_quantity
    db.commit()
    lots = db.query(InventoryLotRecord).filter_by(
        product_id="adjustment-packaged-remove"
    ).order_by(InventoryLotRecord.acquired_at).all()
    history = client.get(
        "/api/v1/products/adjustment-packaged-remove/stock-movements",
        headers=auth,
    )
    assert history.status_code == 200, history.text
    removal = next(
        movement
        for movement in history.json()
        if movement["quantity_change"] == -30
    )
    assert removal["unit_cost"] == pytest.approx(30)
    assert removal["line_total"] == pytest.approx(900)
    summary = client.get("/api/v1/stock-summary", headers=auth).json()
    category = next(
        item
        for item in summary["categories"]
        if item["quantity_by_unit"].get("piece") == pytest.approx(1410)
    )
    assert category["total_current_inventory_cost"] == pytest.approx(35400)
    assert category["total_default_sell_value"] == pytest.approx(55750)
    gross_profit = (
        category["total_default_sell_value"]
        - category["total_current_inventory_cost"]
    )
    assert gross_profit == pytest.approx(20350)
    reconstructed = FifoInventoryCostingService.rebuild_lots_from_history(
        db,
        "adjustment-packaged-remove",
        shop_id="shop-one",
    )
    assert [lot.remaining_quantity for lot in reconstructed] == pytest.approx(
        [270, 720, 60, 360]
    )
    factory_generator.close()


def test_product_stock_movements_returns_packaged_history_and_preserves_fields(seeded) -> None:
    client, token = seeded
    response = client.post(
        "/api/v1/stock/adjustments",
        headers=headers(token),
        json={
            "idempotency_key": "history-read-one",
            "reason": "History read",
            "lines": [{
                "product_id": "product-one",
                "unit": "box",
                "counted_quantity": 8,
                "unit_cost": 50,
            }],
        },
    )
    assert response.status_code == 201

    history = client.get(
        "/api/v1/products/product-one/stock-movements",
        headers=headers(token),
    )
    assert history.status_code == 200
    body = history.json()
    assert len(body) == 1
    assert body[0]["product_id"] == "product-one"
    assert body[0]["product_name"] == "Phone"
    assert body[0]["movement_type"] == "stock_adjustment"
    assert body[0]["quantity_change"] == 6
    assert body[0]["running_stock"] == 8
    assert body[0]["reference_type"] == "stock_adjustment"
    assert body[0]["reference_id"].startswith("adjustment-")
    assert body[0]["source_description"].startswith("Adjustment ADJ-")


def test_product_stock_movements_is_empty_and_shop_scoped(seeded) -> None:
    client, token = seeded
    assert client.get(
        "/api/v1/products/product-one/stock-movements",
        headers=headers(token),
    ).json() == []
    assert client.get(
        "/api/v1/products/other-product/stock-movements",
        headers=headers(token),
    ).status_code == 404


def test_stock_adjustment_idempotency_replays_atomically_and_persists_device(seeded) -> None:
    client, token = seeded
    auth = {**headers(token), "X-Device-ID": "device-a"}
    payload = {
        "idempotency_key": "atomic-adjustment",
        "reason": "Physical count",
        "lines": [{
            "product_id": "product-one",
            "unit": "piece",
            "counted_quantity": 7,
            "unit_cost": 50,
        }],
    }
    first = client.post("/api/v1/stock/adjustments", headers=auth, json=payload)
    retry = client.post("/api/v1/stock/adjustments", headers=auth, json=payload)
    assert first.status_code == 201
    assert retry.status_code == 201
    assert retry.json() == first.json()

    factory_generator = app.dependency_overrides[get_db]()
    db = next(factory_generator)
    assert db.query(StockAdjustmentDocument).count() == 1
    assert db.query(StockAdjustmentLine).count() == 1
    assert db.query(StockMovement).count() == 1
    assert db.query(IdempotencyRecord).count() == 1
    assert db.query(StockMovement).one().device_id == "device-a"
    factory_generator.close()


def test_stock_adjustment_idempotency_rejects_payload_reuse_and_allows_other_shop(seeded) -> None:
    client, token = seeded
    auth = headers(token)
    payload = {
        "idempotency_key": "shared-adjustment-key",
        "reason": "Physical count",
        "lines": [{"product_id": "product-one", "counted_quantity": 8}],
    }
    assert client.post("/api/v1/stock/adjustments", headers=auth, json=payload).status_code == 201
    changed = {**payload, "reason": "Different count"}
    assert client.post("/api/v1/stock/adjustments", headers=auth, json=changed).status_code == 409

    other_token = login_token(client, "manager-two")
    other_payload = {
        "idempotency_key": "shared-adjustment-key",
        "reason": "Other shop count",
        "lines": [{"product_id": "other-product", "counted_quantity": 1}],
    }
    assert client.post(
        "/api/v1/stock/adjustments",
        headers=headers(other_token),
        json=other_payload,
    ).status_code == 201


def test_logout_revokes_jwt_end_to_end(seeded) -> None:
    client, token = seeded
    auth = headers(token)
    assert client.get("/api/v1/products", headers=auth).status_code == 200
    assert client.post("/api/v1/auth/logout", headers=auth).status_code == 204
    assert client.get("/api/v1/products", headers=auth).status_code == 401


def test_stock_adjustment_validates_reason_quantity_and_tenant(seeded) -> None:
    client, token = seeded
    auth = headers(token)
    base = {
        "idempotency_key": "adjustment-invalid",
        "reason": "",
        "lines": [{
            "product_id": "product-one",
            "unit": "piece",
            "counted_quantity": 3,
        }],
    }
    assert client.post("/api/v1/stock/adjustments", headers=auth, json=base).status_code == 422
    base["idempotency_key"] = "adjustment-invalid-quantity"
    base["reason"] = "Correction"
    base["lines"][0]["counted_quantity"] = -1
    assert client.post("/api/v1/stock/adjustments", headers=auth, json=base).status_code == 422
    base["idempotency_key"] = "adjustment-wrong-shop"
    base["lines"][0]["counted_quantity"] = 3
    base["lines"][0]["product_id"] = "other-product"
    assert client.post("/api/v1/stock/adjustments", headers=auth, json=base).status_code == 404


def test_stock_adjustment_is_idempotent_and_atomic(seeded) -> None:
    client, token = seeded
    auth = headers(token)
    payload = {
        "idempotency_key": "adjustment-atomic",
        "reason": "Correction",
        "lines": [{
            "product_id": "product-one",
            "unit": "piece",
            "counted_quantity": 4,
        }],
    }
    assert client.post("/api/v1/stock/adjustments", headers=auth, json=payload).status_code == 201
    replay = client.post("/api/v1/stock/adjustments", headers=auth, json=payload)
    assert replay.status_code == 201
    assert replay.json() == client.post(
        "/api/v1/stock/adjustments", headers=auth, json=payload
    ).json()
    factory_generator = app.dependency_overrides[get_db]()
    db = next(factory_generator)
    assert db.query(StockAdjustmentDocument).count() == 1
    assert db.query(StockMovement).count() == 1
    factory_generator.close()


def _create_payload(
    product_id: str,
    barcode: str | None = None,
    product_type: str = "STANDARD",
    selling_units: list[dict] | None = None,
    opening_quantity: float = 0,
    opening_unit_cost: float = 0,
    opening_unit: str | None = None,
    opening_reason: str | None = None,
    opening_notes: str | None = None,
    category_id: str | None = None,
) -> dict:
    return {
        "id": product_id,
        "name": "Created Product",
        "code": f"CODE-{product_id}",
        "barcode": barcode,
        "product_type": product_type,
        "category_id": category_id,
        "price": 100,
        "cost": 50,
        "min_stock": 2,
        "opening_quantity": opening_quantity,
        "opening_unit_cost": opening_unit_cost,
        "opening_unit": opening_unit,
        "opening_reason": opening_reason,
        "opening_notes": opening_notes,
        "selling_units": selling_units or [],
    }


def test_authenticated_standard_product_creation_starts_with_zero_stock(seeded) -> None:
    client, token = seeded
    response = client.post(
        "/api/v1/products",
        json=_create_payload("created-standard", "333"),
        headers=headers(token),
    )
    assert response.status_code == 201
    assert response.json()["id"] == "created-standard"
    assert response.json()["stock"] == 0
    assert response.json()["selling_units"] == []


def test_product_creation_with_opening_stock_creates_atomic_ledger(seeded) -> None:
    client, token = seeded
    response = client.post(
        "/api/v1/products",
        json=_create_payload(
            "created-opening",
            "334",
            opening_quantity=15,
            opening_unit_cost=12.5,
            opening_reason="initial inventory",
            opening_notes="Windows setup",
        ),
        headers=headers(token),
    )
    assert response.status_code == 201
    assert response.json()["stock"] == 15
    generator = app.dependency_overrides[get_db]()
    db = next(generator)
    try:
        document = db.query(OpeningStockDocument).filter_by(id="opening-created-opening").one()
        line = db.query(OpeningStockLine).filter_by(document_id=document.id).one()
        movement = db.query(StockMovement).filter_by(id="opening-created-opening-movement").one()
        assert document.quantity == 15
        assert line.unit_cost == 12.5
        assert movement.quantity_change == 15
        assert movement.unit_cost == 12.5
        assert movement.running_stock == 15
        assert movement.reference_type == "opening_stock"
    finally:
        generator.close()


def test_opening_stock_contributes_historical_cost_without_changing_cost_valuation(
    seeded,
) -> None:
    client, token = seeded
    response = client.post(
        "/api/v1/products",
        json=_create_payload(
            "summary-opening",
            "336",
            opening_quantity=8,
            opening_unit_cost=50,
            opening_reason="initial inventory",
            category_id="cat-one",
        ),
        headers=headers(token),
    )
    assert response.status_code == 201

    detail = client.get("/api/v1/stock-summary", headers=headers(token)).json()
    category = next(item for item in detail["categories"] if item["category_id"] == "cat-one")
    assert category["total_quantity"] == 10.0
    assert category["total_current_inventory_cost"] == 500.0
    assert category["total_historic_value"] == 400.0


def test_product_creation_with_zero_opening_stock_creates_no_movement(seeded) -> None:
    client, token = seeded
    response = client.post(
        "/api/v1/products",
        json=_create_payload("created-no-opening", "335"),
        headers=headers(token),
    )
    assert response.status_code == 201
    generator = app.dependency_overrides[get_db]()
    db = next(generator)
    try:
        assert db.query(OpeningStockDocument).filter_by(product_id="created-no-opening").count() == 0
        assert db.query(StockMovement).filter_by(product_id="created-no-opening").count() == 0
    finally:
        generator.close()


def test_negative_opening_quantity_is_rejected(seeded) -> None:
    client, token = seeded
    response = client.post(
        "/api/v1/products",
        json=_create_payload("negative-opening", "336", opening_quantity=-1),
        headers=headers(token),
    )
    assert response.status_code == 422


def test_product_creation_is_shop_scoped(seeded) -> None:
    client, token = seeded
    other_token = client.post(
        "/api/v1/auth/login",
        json={"username": "other", "password": "secret"},
    ).json()["access_token"]
    response = client.post(
        "/api/v1/products",
        json=_create_payload("other-created", "111"),
        headers=headers(other_token),
    )
    assert response.status_code == 403
    assert client.get(
        "/api/v1/products/other-created", headers=headers(token)
    ).status_code == 404


def test_packaged_product_creation_persists_active_units(seeded) -> None:
    client, token = seeded
    response = client.post(
        "/api/v1/products",
        json=_create_payload(
            "created-packaged",
            "444",
            "PACKAGED",
            [
                {
                    "id": "created-piece",
                    "name": "piece",
                    "conversion_to_base": 1,
                    "selling_price": 100,
                    "cost_price": 50,
                    "is_default": True,
                },
                {
                    "id": "created-box",
                    "name": "box",
                    "conversion_to_base": 10,
                    "selling_price": 950,
                    "cost_price": 500,
                },
            ],
        ),
        headers=headers(token),
    )
    assert response.status_code == 201
    assert response.json()["stock"] == 0
    assert {unit["name"] for unit in response.json()["selling_units"]} == {
        "piece",
        "box",
    }
    assert response.json()["selling_units"][1]["conversion_to_base"] == 10


def test_packaged_opening_cost_is_derived_per_base_unit(seeded) -> None:
    client, token = seeded
    response = client.post(
        "/api/v1/products",
        json=_create_payload(
            "created-pack-cost",
            "445",
            "PACKAGED",
            [
                {
                    "id": "created-pack-cost-piece",
                    "name": "piece",
                    "conversion_to_base": 1,
                    "selling_price": 10,
                    "is_default": True,
                },
                {
                    "id": "created-pack-cost-pack",
                    "name": "pack",
                    "conversion_to_base": 30,
                    "selling_price": 250,
                },
            ],
            opening_quantity=10,
            opening_unit_cost=200,
            opening_unit="pack",
            opening_reason="initial inventory",
        ),
        headers=headers(token),
    )
    assert response.status_code == 201
    assert response.json()["stock"] == 300
    assert response.json()["cost"] == pytest.approx(200 / 30)

    generator = app.dependency_overrides[get_db]()
    db = next(generator)
    try:
        movement = db.query(StockMovement).filter_by(
            id="opening-created-pack-cost-movement"
        ).one()
        assert movement.quantity_change == 300
        assert movement.unit_cost == pytest.approx(200 / 30)
    finally:
        generator.close()


def test_packaged_opening_lines_create_independent_fifo_layers(seeded) -> None:
    client, token = seeded
    response = client.post(
        "/api/v1/products",
        json={
            **_create_payload(
                "multi-opening-packaged",
                "multi-opening-packaged",
                "PACKAGED",
                [
                    {
                        "id": "multi-opening-piece",
                        "name": "piece",
                        "conversion_to_base": 1,
                        "selling_price": 10,
                        "is_default": True,
                    },
                    {
                        "id": "multi-opening-pack",
                        "name": "pack",
                        "conversion_to_base": 30,
                        "selling_price": 250,
                    },
                    {
                        "id": "multi-opening-box",
                        "name": "box",
                        "conversion_to_base": 360,
                        "selling_price": 2500,
                    },
                ],
                opening_reason="initial inventory",
            ),
            "opening_lines": [
                {"unit": "pack", "quantity": 10, "unit_cost": 900},
                {"unit": "box", "quantity": 2, "unit_cost": 8500},
            ],
        },
        headers=headers(token),
    )
    assert response.status_code == 201, response.text
    assert response.json()["stock"] == 1020

    generator = app.dependency_overrides[get_db]()
    db = next(generator)
    try:
        lots = (
            db.query(InventoryLotRecord)
            .filter_by(product_id="multi-opening-packaged")
            .order_by(InventoryLotRecord.movement_id)
            .all()
        )
        assert len(lots) == 2
        assert [lot.received_quantity for lot in lots] == [300, 720]
        assert [lot.unit_cost for lot in lots] == pytest.approx([30, 8500 / 360])
    finally:
        generator.close()


def test_packaged_opening_lines_reject_piece_acquisition(seeded) -> None:
    client, token = seeded
    response = client.post(
        "/api/v1/products",
        json={
            **_create_payload(
                "piece-opening-rejected",
                "piece-opening-rejected",
                "PACKAGED",
                [
                    {
                        "id": "piece-opening-piece",
                        "name": "piece",
                        "conversion_to_base": 1,
                        "selling_price": 10,
                        "is_default": True,
                    },
                    {
                        "id": "piece-opening-pack",
                        "name": "pack",
                        "conversion_to_base": 30,
                        "selling_price": 250,
                    },
                ],
                opening_reason="initial inventory",
            ),
            "opening_lines": [
                {"unit": "piece", "quantity": 10, "unit_cost": 5},
            ],
        },
        headers=headers(token),
    )
    assert response.status_code == 422
    assert response.json()["detail"] == "Packaged initial stock must use Pack or Box"


@pytest.mark.parametrize(
    ("suffix", "lines", "expected_detail"),
    [
        (
            "duplicate-pack",
            [
                {"unit": "pack", "quantity": 1, "unit_cost": 10},
                {"unit": "pack", "quantity": 2, "unit_cost": 20},
            ],
            "Packaged initial stock allows at most one Pack line",
        ),
        (
            "duplicate-box",
            [
                {"unit": "box", "quantity": 1, "unit_cost": 10},
                {"unit": "box", "quantity": 2, "unit_cost": 20},
            ],
            "Packaged initial stock allows at most one Box line",
        ),
        (
            "three-lines-pack",
            [
                {"unit": "pack", "quantity": 1, "unit_cost": 10},
                {"unit": "box", "quantity": 2, "unit_cost": 20},
                {"unit": "pack", "quantity": 3, "unit_cost": 30},
            ],
            "Packaged initial stock allows at most one Pack line",
        ),
        (
            "three-lines-box",
            [
                {"unit": "pack", "quantity": 1, "unit_cost": 10},
                {"unit": "box", "quantity": 2, "unit_cost": 20},
                {"unit": "box", "quantity": 3, "unit_cost": 30},
            ],
            "Packaged initial stock allows at most one Box line",
        ),
    ],
)
def test_packaged_opening_lines_reject_duplicate_units(
    seeded, suffix, lines, expected_detail
) -> None:
    client, token = seeded
    response = client.post(
        "/api/v1/products",
        json={
            **_create_payload(
                f"invalid-{suffix}",
                f"invalid-{suffix}",
                "PACKAGED",
                [
                    {
                        "id": f"{suffix}-piece",
                        "name": "piece",
                        "conversion_to_base": 1,
                        "selling_price": 10,
                        "is_default": True,
                    },
                    {
                        "id": f"{suffix}-pack",
                        "name": "pack",
                        "conversion_to_base": 30,
                        "selling_price": 250,
                    },
                    {
                        "id": f"{suffix}-box",
                        "name": "box",
                        "conversion_to_base": 360,
                        "selling_price": 2500,
                    },
                ],
                opening_reason="initial inventory",
            ),
            "opening_lines": lines,
        },
        headers=headers(token),
    )
    assert response.status_code == 422
    assert response.json()["detail"] == expected_detail


def test_box_opening_cost_is_derived_per_base_unit(seeded) -> None:
    client, token = seeded
    response = client.post(
        "/api/v1/products",
        json=_create_payload(
            "created-box-cost",
            "446",
            "PACKAGED",
            [
                {
                    "id": "created-box-cost-piece",
                    "name": "piece",
                    "conversion_to_base": 1,
                    "selling_price": 10,
                    "is_default": True,
                },
                {
                    "id": "created-box-cost-box",
                    "name": "box",
                    "conversion_to_base": 100,
                    "selling_price": 1200,
                },
            ],
            opening_quantity=1,
            opening_unit_cost=1000,
            opening_unit="box",
            opening_reason="initial inventory",
        ),
        headers=headers(token),
    )
    assert response.status_code == 201
    assert response.json()["stock"] == 100
    assert response.json()["cost"] == pytest.approx(10)


def test_product_creation_rolls_back_on_duplicate_selling_unit_id(seeded) -> None:
    client, token = seeded
    response = client.post(
        "/api/v1/products",
        json=_create_payload(
            "created-rollback",
            product_type="PACKAGED",
            opening_quantity=15,
            opening_unit_cost=9,
            opening_unit="box",
            opening_reason="rollback test",
            selling_units=[
                {
                    "id": "duplicate-unit",
                    "name": "piece",
                    "conversion_to_base": 1,
                    "selling_price": 100,
                },
                {
                    "id": "duplicate-unit",
                    "name": "box",
                    "conversion_to_base": 10,
                    "selling_price": 950,
                },
            ],
        ),
        headers=headers(token),
    )
    assert response.status_code == 409
    assert client.get(
        "/api/v1/products/created-rollback", headers=headers(token)
    ).status_code == 404
    generator = app.dependency_overrides[get_db]()
    db = next(generator)
    try:
        assert db.query(OpeningStockDocument).filter_by(product_id="created-rollback").count() == 0
        assert db.query(StockMovement).filter_by(product_id="created-rollback").count() == 0
    finally:
        generator.close()


def test_fifo_http_flow_persists_multi_lot_sale_refunds_and_exchange(seeded) -> None:
    client, token = seeded
    auth = headers(token)
    product_id = "fifo-http-product"
    replacement_id = "fifo-http-replacement"
    packaged = client.post(
        "/api/v1/products",
        headers=auth,
        json=_create_payload(
            product_id,
            "fifo-http-barcode",
            "PACKAGED",
            [
                {"id": "fifo-http-piece", "name": "piece", "conversion_to_base": 1, "selling_price": 10, "is_default": True},
                {"id": "fifo-http-pack", "name": "pack", "conversion_to_base": 30, "selling_price": 300},
            ],
            opening_quantity=10,
            opening_unit_cost=200,
            opening_unit="pack",
            opening_reason="FIFO integration",
        ),
    )
    assert packaged.status_code == 201
    assert packaged.json()["stock"] == 300
    adjustment = client.post(
        "/api/v1/stock/adjustments",
        headers=auth,
        json={
            "idempotency_key": "fifo-http-adjustment",
            "reason": "Second FIFO lot",
            "lines": [{
                "product_id": product_id,
                "unit": "pack",
                "counted_quantity": 450,
                "unit_cost": 10,
                "operation": "add",
            }],
        },
    )
    assert adjustment.status_code == 201
    first = client.post(
        "/api/v1/sales",
        headers=auth,
        json={
            "idempotency_key": "fifo-http-sale-one",
            "payment_method": "cash",
            "items": [{"product_id": product_id, "quantity": 2, "unit": "pack"}],
        },
    )
    assert first.status_code == 201
    second = client.post(
        "/api/v1/sales",
        headers=auth,
        json={
            "idempotency_key": "fifo-http-sale-two",
            "payment_method": "cash",
            "items": [{"product_id": product_id, "quantity": 300, "unit": "piece"}],
        },
    )
    assert second.status_code == 201
    second_item_id = second.json()["items"][0]["id"]
    retry = client.post(
        "/api/v1/sales",
        headers=auth,
        json={
            "idempotency_key": "fifo-http-sale-two",
            "payment_method": "cash",
            "items": [{"product_id": product_id, "quantity": 300, "unit": "piece"}],
        },
    )
    assert retry.status_code == 201
    refund_one = client.post(
        f"/api/v1/sales/{second.json()['sale_id']}/refund",
        headers=auth,
        json={"idempotency_key": "fifo-http-refund-one", "items": [{"sale_item_id": second_item_id, "quantity": 20}]},
    )
    assert refund_one.status_code == 201
    refund_two = client.post(
        f"/api/v1/sales/{second.json()['sale_id']}/refund",
        headers=auth,
        json={"idempotency_key": "fifo-http-refund-two", "items": [{"sale_item_id": second_item_id, "quantity": 50}]},
    )
    assert refund_two.status_code == 201
    replacement = client.post(
        "/api/v1/products",
        headers=auth,
        json=_create_payload(
            replacement_id,
            "fifo-http-replacement-barcode",
            opening_quantity=100,
            opening_unit_cost=4,
            opening_reason="Replacement FIFO",
        ),
    )
    assert replacement.status_code == 201
    replacement_adjustment = client.post(
        "/api/v1/stock/adjustments",
        headers=auth,
        json={
            "idempotency_key": "fifo-http-replacement-adjustment",
            "reason": "Replacement second lot",
            "lines": [{
                "product_id": replacement_id,
                "unit": "piece",
                "counted_quantity": 200,
                "unit_cost": 7,
                "operation": "add",
            }],
        },
    )
    assert replacement_adjustment.status_code == 201
    exchange = client.post(
        f"/api/v1/sales/{second.json()['sale_id']}/exchange",
        headers=auth,
        json={
            "idempotency_key": "fifo-http-exchange",
            "payment_method": "cash",
            "items": [{
                "sale_item_id": second_item_id,
                "returned_quantity": 20,
                "replacement_product_id": replacement_id,
                "replacement_quantity": 150,
            }],
        },
    )
    assert exchange.status_code == 201
    exchange_retry = client.post(
        f"/api/v1/sales/{second.json()['sale_id']}/exchange",
        headers=auth,
        json={
            "idempotency_key": "fifo-http-exchange",
            "payment_method": "cash",
            "items": [{
                "sale_item_id": second_item_id,
                "returned_quantity": 20,
                "replacement_product_id": replacement_id,
                "replacement_quantity": 150,
            }],
        },
    )
    assert exchange_retry.status_code == 201
    generator = app.dependency_overrides[get_db]()
    db = next(generator)
    try:
        lots = db.query(InventoryLotRecord).filter_by(product_id=product_id).order_by(InventoryLotRecord.acquired_at).all()
        allocations = db.query(SaleItemFifoAllocation).filter_by(sale_item_id=second_item_id).all()
        restorations = db.query(SaleItemFifoRestoration).join(
            SaleItemFifoAllocation,
            SaleItemFifoRestoration.sale_item_fifo_allocation_id == SaleItemFifoAllocation.id,
        ).filter(SaleItemFifoAllocation.sale_item_id == second_item_id).all()
        assert [lot.remaining_quantity for lot in lots] == pytest.approx([30, 150])
        assert sorted(round(row.allocated_quantity, 6) for row in allocations) == [60, 240]
        assert sum(row.restored_quantity for row in restorations) == pytest.approx(90)
        assert db.query(Product).filter_by(id=product_id).one().stock == pytest.approx(180)
        replacement_lots = db.query(InventoryLotRecord).filter_by(product_id=replacement_id).order_by(InventoryLotRecord.acquired_at).all()
        assert [lot.remaining_quantity for lot in replacement_lots] == pytest.approx([0, 50])
    finally:
        generator.close()


def test_product_creation_rejects_duplicate_barcode(seeded) -> None:
    client, token = seeded
    response = client.post(
        "/api/v1/products",
        json=_create_payload("duplicate-barcode", "111"),
        headers=headers(token),
    )
    assert response.status_code == 409


def test_product_barcode_can_be_reused_after_deactivation_within_shop_scope(seeded) -> None:
    client, token = seeded
    auth = headers(token)
    barcode = "100000000001"

    original = client.post(
        "/api/v1/products",
        json=_create_payload("barcode-reuse-original", barcode),
        headers=auth,
    )
    assert original.status_code == 201
    assert client.post(
        "/api/v1/products",
        json=_create_payload("barcode-reuse-active-duplicate", barcode),
        headers=auth,
    ).status_code == 409

    deleted = client.delete(
        "/api/v1/products/barcode-reuse-original",
        headers=auth,
    )
    assert deleted.status_code == 200
    assert deleted.json()["is_active"] is False
    active_products = client.get(
        "/api/v1/products?page=1&page_size=50&active=true",
        headers=auth,
    ).json()["items"]
    assert "barcode-reuse-original" not in {
        product["id"] for product in active_products
    }

    replacement = client.post(
        "/api/v1/products",
        json=_create_payload("barcode-reuse-replacement", barcode),
        headers=auth,
    )
    assert replacement.status_code == 201
    assert replacement.json()["barcode"] == barcode
    assert client.post(
        "/api/v1/products",
        json=_create_payload("barcode-reuse-third-active", barcode),
        headers=auth,
    ).status_code == 409
    lookup = client.get(
        f"/api/v1/products/barcode/{barcode}",
        headers=auth,
    )
    assert lookup.status_code == 200
    assert lookup.json()["id"] == "barcode-reuse-replacement"

    other_shop_token = client.post(
        "/api/v1/auth/login",
        json={"username": "manager-two", "password": "secret"},
    ).json()["access_token"]
    other_shop_product = client.post(
        "/api/v1/products",
        json=_create_payload("barcode-reuse-other-shop", barcode),
        headers=headers(other_shop_token),
    )
    assert other_shop_product.status_code == 201


def test_inactive_product_can_only_reactivate_when_barcode_is_available(seeded) -> None:
    client, token = seeded
    auth = headers(token)
    barcode = "100000000002"
    original = client.post(
        "/api/v1/products",
        json=_create_payload("barcode-reactivation-original", barcode),
        headers=auth,
    )
    assert original.status_code == 201

    deactivated = client.put(
        "/api/v1/products/barcode-reactivation-original",
        json=_create_payload("barcode-reactivation-original", barcode)
        | {"is_active": False},
        headers=auth,
    )
    assert deactivated.status_code == 200
    assert deactivated.json()["is_active"] is False
    assert client.post(
        "/api/v1/products",
        json=_create_payload("barcode-reactivation-replacement", barcode),
        headers=auth,
    ).status_code == 201

    reactivated = client.put(
        "/api/v1/products/barcode-reactivation-original",
        json=_create_payload("barcode-reactivation-original", barcode)
        | {"is_active": True},
        headers=auth,
    )
    assert reactivated.status_code == 409


def test_product_barcode_trims_whitespace_and_rejects_selling_unit_barcodes(seeded) -> None:
    client, token = seeded
    auth = headers(token)
    packaged = _create_payload(
        "barcode-normalization",
        " 100000000003 ",
        product_type="PACKAGED",
        selling_units=[
            {
                "id": "barcode-normalization-box",
                "name": "box",
                "conversion_to_base": 10,
                "selling_price": 950,
            }
        ],
    )
    created = client.post("/api/v1/products", json=packaged, headers=auth)
    assert created.status_code == 201
    assert created.json()["barcode"] == "100000000003"
    assert created.json()["selling_units"][0]["barcode"] is None
    assert client.post(
        "/api/v1/products",
        json=_create_payload("barcode-normalization-duplicate", "100000000003"),
        headers=auth,
    ).status_code == 409
    invalid_unit_barcode = client.post(
        "/api/v1/products",
        json=_create_payload(
            "barcode-normalization-unit-barcode",
            product_type="PACKAGED",
            selling_units=[
                {
                    "id": "barcode-normalization-invalid-box",
                    "name": "box",
                    "conversion_to_base": 10,
                    "selling_price": 950,
                    "barcode": "100000000004",
                }
            ],
        ),
        headers=auth,
    )
    assert invalid_unit_barcode.status_code == 422
    assert client.get(
        "/api/v1/products/barcode/100000000004",
        headers=auth,
    ).status_code == 404


def test_authenticated_product_update_does_not_create_duplicate(seeded) -> None:
    client, token = seeded
    response = client.put(
        "/api/v1/products/product-one",
        json={
            "id": "product-one",
            "name": "Updated Phone",
            "code": "P-1",
            "barcode": "111",
            "product_type": "PACKAGED",
            "category_id": "cat-one",
            "price": 125,
            "cost": 50,
            "selling_units": [],
        },
        headers=headers(token),
    )
    assert response.status_code == 200
    assert response.json()["name"] == "Updated Phone"
    assert client.post(
        "/api/v1/products",
        json=_create_payload("product-one", "111"),
        headers=headers(token),
    ).status_code == 409


def test_product_creation_allows_no_category(seeded) -> None:
    client, token = seeded
    response = client.post(
        "/api/v1/products",
        json=_create_payload("no-category", "337"),
        headers=headers(token),
    )
    assert response.status_code == 201
    assert response.json()["category_id"] is None


def test_product_creation_rejects_category_from_another_shop(seeded) -> None:
    client, token = seeded
    response = client.post(
        "/api/v1/products",
        json={**_create_payload("wrong-category", "338"), "category_id": "cat-two"},
        headers=headers(token),
    )
    assert response.status_code == 400
    assert response.json()["detail"] == "Category not found"


def test_fifo_cost_correction_reprices_entire_remaining_layer_and_preserves_history(
    seeded,
) -> None:
    client, token = seeded
    auth = headers(token)
    product_id = "fifo-cost-correction-full"
    created = client.post(
        "/api/v1/products",
        headers=auth,
        json=_create_payload(
            product_id,
            opening_quantity=50,
            opening_unit_cost=60,
            opening_reason="Opening acquisition",
            category_id="cat-one",
        ),
    )
    assert created.status_code == 201
    layer_response = client.get(
        f"/api/v1/products/{product_id}/fifo-layers", headers=auth
    )
    assert layer_response.status_code == 200
    original_layer = layer_response.json()[0]
    assert original_layer["remaining_quantity"] == 50
    assert original_layer["original_unit_cost"] == 60
    assert original_layer["source_movement_id"] == f"opening-{product_id}-movement"

    payload = {
        "layer_id": original_layer["layer_id"],
        "new_unit_cost": 50,
    }
    first = client.post(
        f"/api/v1/products/{product_id}/fifo-cost-corrections",
        headers={**auth, "Idempotency-Key": "fifo-cost-correction-full"},
        json=payload,
    )
    replay = client.post(
        f"/api/v1/products/{product_id}/fifo-cost-corrections",
        headers={**auth, "Idempotency-Key": "fifo-cost-correction-full"},
        json=payload,
    )
    assert first.status_code == 201
    assert replay.json() == first.json()
    assert first.json()["quantity"] == 50
    assert first.json()["value_difference"] == -500
    changed_request = {**payload, "new_unit_cost": 55}
    assert client.post(
        f"/api/v1/products/{product_id}/fifo-cost-corrections",
        headers={**auth, "Idempotency-Key": "fifo-cost-correction-full"},
        json=changed_request,
    ).status_code == 409
    partial_request = {
        **payload,
        "quantity": 20,
    }
    assert client.post(
        f"/api/v1/products/{product_id}/fifo-cost-corrections",
        headers={**auth, "Idempotency-Key": "fifo-cost-correction-reject-partial"},
        json=partial_request,
    ).status_code == 422
    assert client.post(
        f"/api/v1/products/{product_id}/fifo-cost-corrections",
        headers=auth,
        json=payload,
    ).status_code == 422

    current_product = client.get(f"/api/v1/products/{product_id}", headers=auth)
    assert current_product.json()["stock"] == 50
    assert current_product.json()["cost"] == 60
    layers = client.get(
        f"/api/v1/products/{product_id}/fifo-layers", headers=auth
    ).json()
    assert [
        (row["remaining_quantity"], row["current_unit_cost"])
        for row in layers
    ] == [(50, 50)]
    assert layers[0]["original_unit_cost"] == 60
    assert layers[0]["correction_old_unit_cost"] == 60
    assert layers[0]["correction_new_unit_cost"] == 50
    assert layers[0]["correction_created_at"] is not None

    summary = client.get("/api/v1/stock-summary", headers=auth).json()
    category = next(row for row in summary["categories"] if row["category_id"] == "cat-one")
    assert category["total_quantity"] == 52
    assert category["total_current_inventory_cost"] == 2600
    assert category["total_historic_value"] == 2500

    history = client.get(
        f"/api/v1/products/{product_id}/stock-movements", headers=auth
    )
    correction_event = next(
        row for row in history.json() if row["movement_type"] == "cost_correction"
    )
    assert correction_event["quantity_change"] == 0
    assert correction_event["correction_quantity"] == 50
    assert correction_event["old_unit_cost"] == 60
    assert correction_event["new_unit_cost"] == 50
    assert correction_event["value_difference"] == -500
    assert correction_event["notes"] == "FIFO remaining inventory cost correction"
    assert correction_event["correction_user"] == "Admin"

    generator = app.dependency_overrides[get_db]()
    db = next(generator)
    try:
        acquisition = db.query(StockMovement).filter_by(
            id=f"opening-{product_id}-movement"
        ).one()
        assert acquisition.quantity_change == 50
        assert acquisition.unit_cost == 60
        assert db.query(FifoCostCorrection).filter_by(product_id=product_id).count() == 1
    finally:
        generator.close()


def test_fifo_cost_correction_preserves_sales_returns_and_reconstruction(seeded) -> None:
    client, token = seeded
    auth = headers(token)
    product_id = "fifo-cost-correction-sold"
    created = client.post(
        "/api/v1/products",
        headers=auth,
        json=_create_payload(
            product_id,
            opening_quantity=50,
            opening_unit_cost=60,
            opening_reason="Opening acquisition",
        ),
    )
    assert created.status_code == 201
    sale_response = client.post(
        "/api/v1/sales",
        headers=auth,
        json={
            "idempotency_key": "fifo-cost-correction-sale",
            "payment_method": "cash",
            "items": [{"product_id": product_id, "quantity": 20}],
        },
    )
    assert sale_response.status_code == 201
    sale = sale_response.json()
    sale_item_id = sale["items"][0]["id"]
    layers = client.get(
        f"/api/v1/products/{product_id}/fifo-layers", headers=auth
    ).json()
    assert len(layers) == 1
    assert layers[0]["remaining_quantity"] == 30
    partial = client.post(
        f"/api/v1/products/{product_id}/fifo-cost-corrections",
        headers={**auth, "Idempotency-Key": "fifo-cost-correction-partial-rejected"},
        json={
            "layer_id": layers[0]["layer_id"],
            "quantity": 10,
            "new_unit_cost": 50,
        },
    )
    assert partial.status_code == 422
    assert client.get(
        "/api/v1/analytics", headers=auth
    ).json()["total_cost"] == 1200

    corrected = client.post(
        f"/api/v1/products/{product_id}/fifo-cost-corrections",
        headers={**auth, "Idempotency-Key": "fifo-cost-correction-sold-full"},
        json={
            "layer_id": layers[0]["layer_id"],
            "new_unit_cost": 50,
        },
    )
    assert corrected.status_code == 201
    assert client.get(
        "/api/v1/analytics", headers=auth
    ).json()["total_cost"] == 1200

    replacement_id = "fifo-cost-correction-replacement"
    replacement = client.post(
        "/api/v1/products",
        headers=auth,
        json=_create_payload(
            replacement_id,
            opening_quantity=5,
            opening_unit_cost=5,
            opening_reason="Replacement stock",
        ),
    )
    assert replacement.status_code == 201
    refund = client.post(
        f"/api/v1/sales/{sale['sale_id']}/refund",
        headers=auth,
        json={
            "idempotency_key": "fifo-cost-correction-refund",
            "items": [{"sale_item_id": sale_item_id, "quantity": 1}],
        },
    )
    exchange = client.post(
        f"/api/v1/sales/{sale['sale_id']}/exchange",
        headers=auth,
        json={
            "idempotency_key": "fifo-cost-correction-exchange",
            "payment_method": "cash",
            "items": [{
                "sale_item_id": sale_item_id,
                "returned_quantity": 1,
                "replacement_product_id": replacement_id,
                "replacement_quantity": 1,
            }],
        },
    )
    assert refund.status_code == 201
    assert exchange.status_code == 201

    next_sale = client.post(
        "/api/v1/sales",
        headers=auth,
        json={
            "idempotency_key": "fifo-cost-correction-future-sale",
            "payment_method": "cash",
            "items": [{"product_id": product_id, "quantity": 25}],
        },
    )
    assert next_sale.status_code == 201
    generator = app.dependency_overrides[get_db]()
    db = next(generator)
    try:
        first_allocations = db.query(SaleItemFifoAllocation).filter_by(
            sale_item_id=sale_item_id
        ).all()
        assert sum(row.allocated_quantity * row.unit_cost_at_sale for row in first_allocations) == 1200
        restored_costs = db.query(SaleItemFifoRestoration).join(
            SaleItemFifoAllocation,
            SaleItemFifoRestoration.sale_item_fifo_allocation_id
            == SaleItemFifoAllocation.id,
        ).filter(SaleItemFifoAllocation.sale_item_id == sale_item_id).all()
        assert [row.unit_cost for row in restored_costs] == [60, 60]

        future_item_id = next_sale.json()["items"][0]["id"]
        future_allocations = db.query(SaleItemFifoAllocation).filter_by(
            sale_item_id=future_item_id
        ).all()
        assert sum(
            row.allocated_quantity * row.unit_cost_at_sale
            for row in future_allocations
        ) == 1270
        reconstructed = FifoInventoryCostingService.rebuild_lots_from_history(
            db, product_id, shop_id="shop-one"
        )
        assert sum(row.remaining_quantity for row in reconstructed) == 7
        assert sum(row.total_value for row in reconstructed) == 350
        FifoInventoryCostingService.sync_persisted_lots(
            db, product_id, shop_id="shop-one", lots=reconstructed
        )
        persisted = FifoInventoryCostingService.lots_for_product(
            db, product_id, shop_id="shop-one"
        )
        assert sum(row.remaining_quantity for row in persisted) == 7
        assert sum(row.total_value for row in persisted) == 350
    finally:
        generator.close()


def test_fifo_cost_correction_keeps_multiple_layers_ordered_and_scoped(seeded) -> None:
    client, token = seeded
    auth = headers(token)
    product_id = "fifo-cost-correction-multiple"
    created = client.post(
        "/api/v1/products",
        headers=auth,
        json=_create_payload(
            product_id,
            opening_quantity=20,
            opening_unit_cost=50,
            opening_reason="First acquisition",
            category_id="cat-one",
        ),
    )
    assert created.status_code == 201
    for key, quantity, cost in [
        ("fifo-correction-lot-two", 50, 60),
        ("fifo-correction-lot-three", 90, 70),
    ]:
        adjusted = client.post(
            "/api/v1/stock/adjustments",
            headers=auth,
            json={
                "idempotency_key": key,
                "reason": "Additional acquisition",
                "lines": [{
                    "product_id": product_id,
                    "unit": "piece",
                    "counted_quantity": quantity,
                    "unit_cost": cost,
                    "operation": "add",
                }],
            },
        )
        assert adjusted.status_code == 201

    layers = client.get(
        f"/api/v1/products/{product_id}/fifo-layers", headers=auth
    ).json()
    assert [row["current_unit_cost"] for row in layers] == [50, 60, 70]
    second_layer_id = layers[1]["layer_id"]
    assert client.post(
        f"/api/v1/products/{product_id}/fifo-cost-corrections",
        headers={**auth, "Idempotency-Key": "fifo-correction-middle-layer"},
        json={
            "layer_id": second_layer_id,
            "new_unit_cost": 55,
        },
    ).status_code == 201

    ordered = client.get(
        f"/api/v1/products/{product_id}/fifo-layers", headers=auth
    ).json()
    assert [
        (row["remaining_quantity"], row["current_unit_cost"])
        for row in ordered
    ] == [(20, 50), (30, 55), (40, 70)]
    cashier = headers(login_token(client, "cashier"))
    assert client.get(
        f"/api/v1/products/{product_id}/fifo-layers", headers=cashier
    ).status_code == 403
    assert client.post(
        f"/api/v1/products/{product_id}/fifo-cost-corrections",
        headers={**cashier, "Idempotency-Key": "fifo-correction-cashier"},
        json={
            "layer_id": ordered[0]["layer_id"],
            "new_unit_cost": 1,
        },
    ).status_code == 403

    other_shop_manager = headers(login_token(client, "manager-two"))
    assert client.post(
        "/api/v1/products/other-product/fifo-cost-corrections",
        headers={**other_shop_manager, "Idempotency-Key": "fifo-correction-cross-tenant"},
        json={
            "layer_id": ordered[0]["layer_id"],
            "new_unit_cost": 1,
        },
    ).status_code == 404

    future_sale = client.post(
        "/api/v1/sales",
        headers=auth,
        json={
            "idempotency_key": "fifo-correction-multi-layer-sale",
            "payment_method": "cash",
            "items": [{"product_id": product_id, "quantity": 45}],
        },
    )
    assert future_sale.status_code == 201
    generator = app.dependency_overrides[get_db]()
    db = next(generator)
    try:
        allocations = db.query(SaleItemFifoAllocation).filter_by(
            sale_item_id=future_sale.json()["items"][0]["id"]
        ).all()
        assert sum(
            row.allocated_quantity * row.unit_cost_at_sale for row in allocations
        ) == 2375
        rebuilt = FifoInventoryCostingService.rebuild_lots_from_history(
            db, product_id, shop_id="shop-one"
        )
        assert [row.unit_cost for row in rebuilt] == [55, 70]
        assert [row.remaining_quantity for row in rebuilt] == [5, 40]
    finally:
        generator.close()
