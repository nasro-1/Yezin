from importlib.util import module_from_spec, spec_from_file_location
from pathlib import Path

import pytest
from alembic.migration import MigrationContext
from alembic.operations import Operations
from sqlalchemy import create_engine, text
from sqlalchemy.exc import IntegrityError


MIGRATION_PATH = (
    Path(__file__).resolve().parents[1]
    / "migrations"
    / "versions"
    / "0021_active_product_barcode_scope.py"
)
SPEC = spec_from_file_location("active_product_barcode_scope", MIGRATION_PATH)
assert SPEC is not None and SPEC.loader is not None
MIGRATION = module_from_spec(SPEC)
SPEC.loader.exec_module(MIGRATION)


def test_product_barcode_migration_preserves_inactive_duplicates_and_shop_scope(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    engine = create_engine("sqlite:///:memory:")
    with engine.begin() as connection:
        connection.execute(
            text(
                """
                CREATE TABLE products (
                    id TEXT PRIMARY KEY,
                    shop_id TEXT NOT NULL,
                    barcode TEXT,
                    is_active BOOLEAN NOT NULL
                )
                """
            )
        )
        connection.execute(
            text(
                """
                INSERT INTO products (id, shop_id, barcode, is_active)
                VALUES
                    ('inactive-one', 'shop-one', ' 100000000001 ', 0),
                    ('inactive-two', 'shop-one', '100000000001', 0),
                    ('active-one', 'shop-one', '100000000001', 1),
                    ('active-other-shop', 'shop-two', '100000000001', 1)
                """
            )
        )

        operations = Operations(MigrationContext.configure(connection))
        monkeypatch.setattr(MIGRATION, "op", operations)
        MIGRATION.upgrade()

        with pytest.raises(IntegrityError):
            connection.execute(
                text(
                    """
                    INSERT INTO products (id, shop_id, barcode, is_active)
                    VALUES ('active-duplicate', 'shop-one', '100000000001', 1)
                    """
                )
            )

        connection.execute(
            text(
                """
                INSERT INTO products (id, shop_id, barcode, is_active)
                VALUES ('inactive-third', 'shop-one', '100000000001', 0)
                """
            )
        )

    engine.dispose()
