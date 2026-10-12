"""Allow category names to be reused after soft deletion."""

from alembic import op


revision = "0020_active_category_name_scope"
down_revision = "0019_fifo_sale_line_allocations"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute(
        """
        CREATE UNIQUE INDEX uq_categories_shop_active_normalized_name
        ON categories (shop_id, lower(trim(name)))
        WHERE is_active = 1
        """
    )


def downgrade() -> None:
    op.drop_index(
        "uq_categories_shop_active_normalized_name",
        table_name="categories",
    )