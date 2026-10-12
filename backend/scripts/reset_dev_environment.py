"""Reset the server development tenant without recreating its schema.

This is intentionally narrower than ``seed_dev_data.py``: it removes only
records owned by ``dev-shop`` and recreates the three development users.
"""

from __future__ import annotations

import os
import shutil
import sys
from datetime import datetime
from pathlib import Path

from sqlalchemy import bindparam, inspect, text

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app.config import settings
from app.database import SessionLocal, engine
from app.development_safety import require_development_data_reset
from app.models import Shop, User
from app.security import hash_password


DEV_SHOP_ID = "dev-shop"
DEVELOPMENT_USERS = {
    "admin": ("System Administrator", "admin", "admin"),
    "manager": ("Development Manager", "manager", "manager"),
    "cashier": ("Development Cashier", "cashier", "cashier"),
}

# Children must be removed before their parent documents. These tables are
# optional so the script remains compatible with older development databases.
CHILD_TABLES = (
    "exchange_settlements",
    "exchange_items",
    "refund_items",
    "sale_draft_items",
    "purchase_items",
    "supplier_return_items",
    "stock_adjustment_lines",
    "opening_stock_lines",
    "sale_items",
    "sale_payments",
    "cash_movements",
    "customer_ledger",
    "supplier_ledger",
)
PARENT_TABLES = (
    "exchange_documents",
    "refund_documents",
    "supplier_returns",
    "purchases",
    "sale_drafts",
    "stock_adjustment_documents",
    "opening_stock_documents",
    "sale_documents",
    "stock_movements",
    "payments",
    "expenses",
    "notifications",
    "activity_logs",
    "idempotency_records",
    "product_selling_units",
    "products",
    "categories",
    "customers",
    "suppliers",
    "devices",
)
PROTECTED_TABLES = {"shops", "users", "revoked_tokens"}


def _database_path() -> Path:
    prefix = "sqlite:///"
    if not settings.database_url.startswith(prefix):
        raise RuntimeError(
            "reset_dev_environment.py only supports the configured SQLite development database."
        )
    return Path(settings.database_url.removeprefix(prefix)).resolve()


def _backup_database(database_path: Path) -> Path:
    if not database_path.exists():
        raise FileNotFoundError(f"Configured database does not exist: {database_path}")
    timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    candidate = database_path.with_name(f"{database_path.name}.backup-{timestamp}")
    suffix = 1
    while candidate.exists():
        candidate = database_path.with_name(
            f"{database_path.name}.backup-{timestamp}-{suffix}"
        )
        suffix += 1
    shutil.copy2(database_path, candidate)
    return candidate


def _table_columns(table: str) -> set[str]:
    return {column["name"] for column in inspect(engine).get_columns(table)}


def _table_names() -> set[str]:
    return set(inspect(engine).get_table_names())


def _ids(connection, table: str, column: str = "id") -> list[str]:
    if table not in _table_names() or "shop_id" not in _table_columns(table):
        return []
    rows = connection.execute(
        text(f'SELECT "{column}" FROM "{table}" WHERE shop_id = :shop_id'),
        {"shop_id": DEV_SHOP_ID},
    )
    return [row[0] for row in rows]


def _delete_ids(
    connection, table: str, column: str, values: list[str], counts: dict[str, int]
) -> None:
    if not values or table not in _table_names() or column not in _table_columns(table):
        return
    result = connection.execute(
        text(f'DELETE FROM "{table}" WHERE "{column}" IN :values').bindparams(
            bindparam("values", expanding=True)
        ),
        {"values": values},
    )
    counts[f"{table} (by {column})"] = result.rowcount


def _delete_shop_rows(connection, table: str, counts: dict[str, int]) -> None:
    if table not in _table_names():
        return
    columns = _table_columns(table)
    if "shop_id" not in columns:
        return
    result = connection.execute(
        text(f'DELETE FROM "{table}" WHERE shop_id = :shop_id'),
        {"shop_id": DEV_SHOP_ID},
    )
    counts[table] = result.rowcount


def _ensure_users(connection) -> None:
    rows = connection.execute(
        text("SELECT id, username FROM users WHERE shop_id = :shop_id"),
        {"shop_id": DEV_SHOP_ID},
    ).mappings()
    keep_ids = {username for username in DEVELOPMENT_USERS}
    for row in rows:
        if row["id"] not in keep_ids and row["username"] not in keep_ids:
            connection.execute(text("DELETE FROM users WHERE id = :id"), {"id": row["id"]})

    for username, (display_name, role, password) in DEVELOPMENT_USERS.items():
        existing = connection.execute(
            text(
                "SELECT id FROM users "
                "WHERE shop_id = :shop_id AND username = :username"
            ),
            {"shop_id": DEV_SHOP_ID, "username": username},
        ).first()
        values = {
            "id": username,
            "shop_id": DEV_SHOP_ID,
            "username": username,
            "display_name": display_name,
            "password_hash": hash_password(password),
            "role": role,
        }
        if existing is None:
            connection.execute(
                text(
                    "INSERT INTO users "
                    "(id, shop_id, username, display_name, password_hash, role, is_active) "
                    "VALUES (:id, :shop_id, :username, :display_name, "
                    ":password_hash, :role, 1)"
                ),
                values,
            )
        else:
            connection.execute(
                text(
                    "UPDATE users SET id = :id, display_name = :display_name, "
                    "password_hash = :password_hash, role = :role, is_active = 1 "
                    "WHERE shop_id = :shop_id AND username = :username"
                ),
                values,
            )


def _verify(connection) -> dict[str, int]:
    counts: dict[str, int] = {}
    tables = set(inspect(engine).get_table_names())
    for table in (*CHILD_TABLES, *PARENT_TABLES):
        if table in tables:
            columns = _table_columns(table)
            if "shop_id" in columns:
                counts[table] = connection.execute(
                    text(f'SELECT COUNT(*) FROM "{table}" WHERE shop_id = :shop_id'),
                    {"shop_id": DEV_SHOP_ID},
                ).scalar_one()
    counts["users"] = connection.execute(
        text("SELECT COUNT(*) FROM users WHERE shop_id = :shop_id"),
        {"shop_id": DEV_SHOP_ID},
    ).scalar_one()
    return counts


def reset() -> None:
    require_development_data_reset(
        settings.environment, os.environ.get("BAYAA_ALLOW_DEV_DATA_RESET")
    )
    database_path = _database_path()
    backup_path = _backup_database(database_path)
    print(f"BACKUP: {backup_path}")
    print(f"DATABASE: {database_path}")
    print(f"SHOP: {DEV_SHOP_ID}")

    with engine.begin() as connection:
        shop = connection.execute(
            text("SELECT id FROM shops WHERE id = :shop_id"),
            {"shop_id": DEV_SHOP_ID},
        ).first()
        if shop is None:
            raise RuntimeError(f"Required shop {DEV_SHOP_ID!r} does not exist.")

        counts: dict[str, int] = {}
        sale_ids = _ids(connection, "sale_documents")
        exchange_ids = _ids(connection, "exchange_documents")
        refund_ids = _ids(connection, "refund_documents")
        draft_ids = _ids(connection, "sale_drafts")
        adjustment_ids = _ids(connection, "stock_adjustment_documents")
        opening_ids = _ids(connection, "opening_stock_documents")
        purchase_ids = _ids(connection, "purchases")
        supplier_return_ids = _ids(connection, "supplier_returns")
        product_ids = _ids(connection, "products")

        _delete_ids(connection, "exchange_settlements", "exchange_id", exchange_ids, counts)
        _delete_ids(connection, "exchange_items", "exchange_id", exchange_ids, counts)
        _delete_ids(connection, "refund_items", "refund_id", refund_ids, counts)
        _delete_ids(connection, "sale_draft_items", "draft_id", draft_ids, counts)
        _delete_ids(connection, "purchase_items", "purchase_id", purchase_ids, counts)
        _delete_ids(
            connection,
            "supplier_return_items",
            "return_id",
            supplier_return_ids,
            counts,
        )
        _delete_ids(
            connection, "stock_adjustment_lines", "document_id", adjustment_ids, counts
        )
        _delete_ids(
            connection, "opening_stock_lines", "document_id", opening_ids, counts
        )
        _delete_ids(connection, "sale_items", "sale_id", sale_ids, counts)
        _delete_ids(connection, "sale_payments", "sale_id", sale_ids, counts)
        _delete_ids(connection, "cash_movements", "sale_id", sale_ids, counts)
        _delete_ids(connection, "customer_ledger", "sale_id", sale_ids, counts)
        _delete_ids(connection, "product_selling_units", "product_id", product_ids, counts)

        for table in (*CHILD_TABLES, *PARENT_TABLES):
            _delete_shop_rows(connection, table, counts)
        _ensure_users(connection)
        remaining = _verify(connection)

    print("\nDEV ENVIRONMENT RESET")
    print(f"Shop: {DEV_SHOP_ID}")
    print("Users:")
    for username in DEVELOPMENT_USERS:
        print(f"  {username} active")
    for table, count in sorted(remaining.items()):
        if table != "users":
            print(f"{table}: {count}")
    print(f"users: {remaining['users']}")
    print("Schema: preserved (no migrations or tables recreated)")
    print("Currency: server has no print-settings table; local defaults remain DZD / DA")
    print("Document counters: server uses UUID document references; no server counter reset required")
    print("Unsupported in current server schema: customers, suppliers, purchases, expenses, print settings")


if __name__ == "__main__":
    reset()
