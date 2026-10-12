"""Persist exact FIFO lot allocations and refund/exchange restorations."""

from alembic import op
import sqlalchemy as sa


revision = "0019_fifo_sale_line_allocations"
down_revision = "0018_fifo_inventory_lots"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "sale_item_fifo_allocations",
        sa.Column("id", sa.String(length=150), primary_key=True),
        sa.Column("shop_id", sa.String(length=100), sa.ForeignKey("shops.id"), nullable=False),
        sa.Column("sale_item_id", sa.String(length=150), sa.ForeignKey("sale_items.id"), nullable=False),
        sa.Column("inventory_lot_id", sa.String(length=150), sa.ForeignKey("inventory_lots.id"), nullable=False),
        sa.Column("allocated_quantity", sa.Float(), nullable=False),
        sa.Column("restored_quantity", sa.Float(), nullable=False, server_default="0"),
        sa.Column("created_at", sa.DateTime(), nullable=False, server_default=sa.func.current_timestamp()),
        sa.UniqueConstraint("sale_item_id", "inventory_lot_id", name="uq_sale_item_fifo_allocation_lot"),
    )
    op.create_index("ix_sale_item_fifo_allocations_shop_id", "sale_item_fifo_allocations", ["shop_id"])
    op.create_index("ix_sale_item_fifo_allocations_sale_item_id", "sale_item_fifo_allocations", ["sale_item_id"])
    op.create_index("ix_sale_item_fifo_allocations_inventory_lot_id", "sale_item_fifo_allocations", ["inventory_lot_id"])
    op.create_table(
        "sale_item_fifo_restorations",
        sa.Column("id", sa.String(length=150), primary_key=True),
        sa.Column("shop_id", sa.String(length=100), sa.ForeignKey("shops.id"), nullable=False),
        sa.Column("sale_item_fifo_allocation_id", sa.String(length=150), sa.ForeignKey("sale_item_fifo_allocations.id"), nullable=False),
        sa.Column("refund_item_id", sa.String(length=150), sa.ForeignKey("refund_items.id"), nullable=True),
        sa.Column("exchange_item_id", sa.String(length=150), sa.ForeignKey("exchange_items.id"), nullable=True),
        sa.Column("restored_quantity", sa.Float(), nullable=False),
        sa.Column("unit_cost", sa.Float(), nullable=False),
        sa.Column("created_at", sa.DateTime(), nullable=False, server_default=sa.func.current_timestamp()),
    )
    op.create_index("ix_sale_item_fifo_restorations_shop_id", "sale_item_fifo_restorations", ["shop_id"])
    op.create_index("ix_sale_item_fifo_restorations_allocation_id", "sale_item_fifo_restorations", ["sale_item_fifo_allocation_id"])
    op.create_index("ix_sale_item_fifo_restorations_refund_item_id", "sale_item_fifo_restorations", ["refund_item_id"])
    op.create_index("ix_sale_item_fifo_restorations_exchange_item_id", "sale_item_fifo_restorations", ["exchange_item_id"])


def downgrade() -> None:
    op.drop_index("ix_sale_item_fifo_restorations_exchange_item_id", table_name="sale_item_fifo_restorations")
    op.drop_index("ix_sale_item_fifo_restorations_refund_item_id", table_name="sale_item_fifo_restorations")
    op.drop_index("ix_sale_item_fifo_restorations_allocation_id", table_name="sale_item_fifo_restorations")
    op.drop_index("ix_sale_item_fifo_restorations_shop_id", table_name="sale_item_fifo_restorations")
    op.drop_table("sale_item_fifo_restorations")
    op.drop_index("ix_sale_item_fifo_allocations_inventory_lot_id", table_name="sale_item_fifo_allocations")
    op.drop_index("ix_sale_item_fifo_allocations_sale_item_id", table_name="sale_item_fifo_allocations")
    op.drop_index("ix_sale_item_fifo_allocations_shop_id", table_name="sale_item_fifo_allocations")
    op.drop_table("sale_item_fifo_allocations")
