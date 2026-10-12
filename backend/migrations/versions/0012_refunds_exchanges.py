"""Add server-side refund and exchange documents."""
from alembic import op
import sqlalchemy as sa

revision = "0012_refunds_exchanges"
down_revision = "0011_sale_draft_visibility"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column("sale_items", sa.Column("refunded_quantity", sa.Numeric(18, 6), nullable=False, server_default="0"))
    op.add_column("sale_items", sa.Column("exchanged_quantity", sa.Numeric(18, 6), nullable=False, server_default="0"))
    money = sa.Numeric(18, 2)
    for name, sale_fk in (("refund", "refund"), ("exchange", "exchange")):
        op.create_table(f"{name}_documents",
            sa.Column("id", sa.String(100), primary_key=True),
            sa.Column("shop_id", sa.String(100), sa.ForeignKey("shops.id"), nullable=False),
            sa.Column("sale_id", sa.String(100), sa.ForeignKey("sale_documents.id"), nullable=False),
            sa.Column("idempotency_key", sa.String(255), nullable=False),
            sa.Column("amount" if name == "refund" else "difference_amount", money, nullable=False),
            sa.Column("payment_method", sa.String(20), nullable=False),
            sa.Column("posted_by", sa.String(100), nullable=False),
            sa.Column("posted_at", sa.DateTime(), nullable=False),
            sa.UniqueConstraint("shop_id", "idempotency_key", name=f"uq_{name}_shop_key"))
        op.create_index(f"ix_{name}_documents_shop_id", f"{name}_documents", ["shop_id"])
        op.create_index(f"ix_{name}_documents_sale_id", f"{name}_documents", ["sale_id"])
    op.create_table("refund_items",
        sa.Column("id", sa.String(150), primary_key=True),
        sa.Column("refund_id", sa.String(100), sa.ForeignKey("refund_documents.id"), nullable=False),
        sa.Column("sale_item_id", sa.String(150), sa.ForeignKey("sale_items.id"), nullable=False),
        sa.Column("quantity", sa.Numeric(18, 6), nullable=False),
        sa.Column("base_quantity", sa.Numeric(18, 6), nullable=False),
        sa.Column("amount", money, nullable=False))
    op.create_table("exchange_items",
        sa.Column("id", sa.String(150), primary_key=True),
        sa.Column("exchange_id", sa.String(100), sa.ForeignKey("exchange_documents.id"), nullable=False),
        sa.Column("sale_item_id", sa.String(150), sa.ForeignKey("sale_items.id"), nullable=False),
        sa.Column("returned_quantity", sa.Numeric(18, 6), nullable=False),
        sa.Column("returned_base_quantity", sa.Numeric(18, 6), nullable=False),
        sa.Column("replacement_product_id", sa.String(100), sa.ForeignKey("products.id"), nullable=False),
        sa.Column("replacement_quantity", sa.Numeric(18, 6), nullable=False),
        sa.Column("replacement_base_quantity", sa.Numeric(18, 6), nullable=False),
        sa.Column("old_amount", money, nullable=False), sa.Column("new_amount", money, nullable=False))


def downgrade() -> None:
    op.drop_table("exchange_items"); op.drop_table("refund_items")
    op.drop_index("ix_exchange_documents_sale_id", table_name="exchange_documents")
    op.drop_index("ix_exchange_documents_shop_id", table_name="exchange_documents")
    op.drop_table("exchange_documents")
    op.drop_index("ix_refund_documents_sale_id", table_name="refund_documents")
    op.drop_index("ix_refund_documents_shop_id", table_name="refund_documents")
    op.drop_table("refund_documents")
    op.drop_column("sale_items", "exchanged_quantity"); op.drop_column("sale_items", "refunded_quantity")
