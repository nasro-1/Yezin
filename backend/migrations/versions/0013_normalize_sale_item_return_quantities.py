"""Normalize nullable sale item return-tracking quantities."""
from alembic import op
import sqlalchemy as sa


revision = "0013_normalize_sale_item_return_quantities"
down_revision = "0012_refunds_exchanges"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute(
        sa.text(
            "UPDATE sale_items "
            "SET refunded_quantity = 0 "
            "WHERE refunded_quantity IS NULL"
        )
    )
    op.execute(
        sa.text(
            "UPDATE sale_items "
            "SET exchanged_quantity = 0 "
            "WHERE exchanged_quantity IS NULL"
        )
    )
    with op.batch_alter_table("sale_items") as batch_op:
        batch_op.alter_column(
            "refunded_quantity",
            existing_type=sa.Numeric(18, 6),
            nullable=False,
            server_default=sa.text("0"),
        )
        batch_op.alter_column(
            "exchanged_quantity",
            existing_type=sa.Numeric(18, 6),
            nullable=False,
            server_default=sa.text("0"),
        )


def downgrade() -> None:
    with op.batch_alter_table("sale_items") as batch_op:
        batch_op.alter_column(
            "refunded_quantity",
            existing_type=sa.Numeric(18, 6),
            nullable=True,
            server_default=None,
        )
        batch_op.alter_column(
            "exchanged_quantity",
            existing_type=sa.Numeric(18, 6),
            nullable=True,
            server_default=None,
        )
