"""Add server-authoritative open and held sale drafts."""
from alembic import op
import sqlalchemy as sa


revision = "0007_sale_drafts"
down_revision = "0006_sale_totals"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "sale_drafts",
        sa.Column("id", sa.String(100), primary_key=True),
        sa.Column("shop_id", sa.String(100), sa.ForeignKey("shops.id"), nullable=False),
        sa.Column("owner_id", sa.String(100), sa.ForeignKey("users.id"), nullable=False),
        sa.Column("status", sa.String(20), nullable=False, server_default="OPEN"),
        sa.Column("version", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("customer_id", sa.String(100)),
        sa.Column("payment_method", sa.String(20), nullable=False, server_default="cash"),
        sa.Column("discount", sa.Numeric(18, 2), nullable=False, server_default="0"),
        sa.Column("paid_amount", sa.Numeric(18, 2)),
        sa.Column("checkout_sale_id", sa.String(100), sa.ForeignKey("sale_documents.id")),
        sa.Column("created_at", sa.DateTime(), server_default=sa.func.current_timestamp()),
        sa.Column("updated_at", sa.DateTime(), server_default=sa.func.current_timestamp()),
    )
    op.create_index("ix_sale_drafts_shop_id", "sale_drafts", ["shop_id"])
    op.create_index("ix_sale_drafts_owner_id", "sale_drafts", ["owner_id"])
    op.create_index("ix_sale_drafts_checkout_sale_id", "sale_drafts", ["checkout_sale_id"])
    op.create_table(
        "sale_draft_items",
        sa.Column("id", sa.String(150), primary_key=True),
        sa.Column("draft_id", sa.String(100), sa.ForeignKey("sale_drafts.id"), nullable=False),
        sa.Column("product_id", sa.String(100), sa.ForeignKey("products.id"), nullable=False),
        sa.Column("unit", sa.String(100), nullable=False, server_default="piece"),
        sa.Column("quantity", sa.Numeric(18, 6), nullable=False),
        sa.Column("unit_price", sa.Numeric(18, 2)),
        sa.Column("created_at", sa.DateTime(), server_default=sa.func.current_timestamp()),
        sa.Column("updated_at", sa.DateTime(), server_default=sa.func.current_timestamp()),
        sa.UniqueConstraint("draft_id", "product_id", name="uq_sale_draft_product"),
    )
    op.create_index("ix_sale_draft_items_draft_id", "sale_draft_items", ["draft_id"])
    op.create_index("ix_sale_draft_items_product_id", "sale_draft_items", ["product_id"])


def downgrade() -> None:
    op.drop_index("ix_sale_draft_items_product_id", table_name="sale_draft_items")
    op.drop_index("ix_sale_draft_items_draft_id", table_name="sale_draft_items")
    op.drop_table("sale_draft_items")
    op.drop_index("ix_sale_drafts_checkout_sale_id", table_name="sale_drafts")
    op.drop_index("ix_sale_drafts_owner_id", table_name="sale_drafts")
    op.drop_index("ix_sale_drafts_shop_id", table_name="sale_drafts")
    op.drop_table("sale_drafts")
