"""Scope product barcode uniqueness to active products within each shop."""

import sqlalchemy as sa
from alembic import op


revision = "0021_active_product_barcode_scope"
down_revision = "0020_active_category_name_scope"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_index(
        "uq_products_shop_active_normalized_barcode",
        "products",
        ["shop_id", sa.text("trim(barcode)")],
        unique=True,
        sqlite_where=sa.text(
            "is_active = 1 AND barcode IS NOT NULL AND trim(barcode) <> ''"
        ),
        postgresql_where=sa.text(
            "is_active AND barcode IS NOT NULL AND trim(barcode) <> ''"
        ),
    )


def downgrade() -> None:
    op.drop_index(
        "uq_products_shop_active_normalized_barcode",
        table_name="products",
    )
