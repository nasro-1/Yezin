"""Add base-convertible minimum stock thresholds to selling units."""

from alembic import op
import sqlalchemy as sa


revision = "0017_selling_unit_minimum_stock"
down_revision = "0016_packaged_opening_stock_context"
branch_labels = None
depends_on = None


def upgrade() -> None:
    with op.batch_alter_table("product_selling_units") as batch:
        batch.add_column(
            sa.Column("minimum_stock", sa.Float(), nullable=False, server_default="0")
        )


def downgrade() -> None:
    with op.batch_alter_table("product_selling_units") as batch:
        batch.drop_column("minimum_stock")
