"""Persist explicit remaining FIFO lots with base-quantity and lineage metadata."""

from alembic import op
import sqlalchemy as sa


revision = "0018_fifo_inventory_lots"
down_revision = "0017_selling_unit_minimum_stock"
branch_labels = None
depends_on = None


def upgrade() -> None:
    with op.batch_alter_table("stock_movements") as batch:
        batch.add_column(sa.Column("lineage_id", sa.String(length=150), nullable=True))
    op.create_table(
        "inventory_lots",
        sa.Column("id", sa.String(length=150), primary_key=True),
        sa.Column("shop_id", sa.String(length=100), sa.ForeignKey("shops.id"), nullable=False),
        sa.Column("product_id", sa.String(length=100), sa.ForeignKey("products.id"), nullable=False),
        sa.Column("movement_id", sa.String(length=150), nullable=False),
        sa.Column("source_type", sa.String(length=50), nullable=False),
        sa.Column("source_id", sa.String(length=150), nullable=False),
        sa.Column("source_reference", sa.String(length=150), nullable=True),
        sa.Column("received_quantity", sa.Float(), nullable=False),
        sa.Column("remaining_quantity", sa.Float(), nullable=False),
        sa.Column("unit_cost", sa.Float(), nullable=False),
        sa.Column("acquired_at", sa.DateTime(), nullable=False, server_default=sa.func.current_timestamp()),
        sa.Column("lineage_id", sa.String(length=150), nullable=True),
        sa.UniqueConstraint(
            "shop_id",
            "product_id",
            "movement_id",
            name="uq_inventory_lot_shop_product_movement",
        ),
    )
    op.create_index("ix_inventory_lots_shop_id", "inventory_lots", ["shop_id"])
    op.create_index("ix_inventory_lots_product_id", "inventory_lots", ["product_id"])
    op.create_index("ix_inventory_lots_movement_id", "inventory_lots", ["movement_id"])
    op.create_index("ix_inventory_lots_source_reference", "inventory_lots", ["source_reference"])
    op.create_index("ix_inventory_lots_acquired_at", "inventory_lots", ["acquired_at"])
    op.create_index("ix_inventory_lots_lineage_id", "inventory_lots", ["lineage_id"])


def downgrade() -> None:
    with op.batch_alter_table("stock_movements") as batch:
        batch.drop_column("lineage_id")
    with op.batch_alter_table("inventory_lots") as batch:
        batch.drop_constraint("uq_inventory_lot_shop_product_movement", type_="unique")
    op.drop_index("ix_inventory_lots_lineage_id", table_name="inventory_lots")
    op.drop_index("ix_inventory_lots_acquired_at", table_name="inventory_lots")
    op.drop_index("ix_inventory_lots_source_reference", table_name="inventory_lots")
    op.drop_index("ix_inventory_lots_movement_id", table_name="inventory_lots")
    op.drop_index("ix_inventory_lots_product_id", table_name="inventory_lots")
    op.drop_index("ix_inventory_lots_shop_id", table_name="inventory_lots")
    op.drop_table("inventory_lots")
