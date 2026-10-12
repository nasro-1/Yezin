"""Add server-authoritative sales transaction tables."""
from alembic import op
import sqlalchemy as sa

revision = "0005_sales"
down_revision = "0004_phase0_foundations"
branch_labels = None
depends_on = None


def upgrade() -> None:
    money = sa.Numeric(18, 2)
    op.create_table("sale_documents",
        sa.Column("id", sa.String(100), primary_key=True),
        sa.Column("shop_id", sa.String(100), sa.ForeignKey("shops.id"), nullable=False),
        sa.Column("idempotency_key", sa.String(255), nullable=False),
        sa.Column("status", sa.String(20), nullable=False),
        sa.Column("customer_id", sa.String(100)),
        sa.Column("payment_method", sa.String(20), nullable=False),
        sa.Column("total", money, nullable=False),
        sa.Column("posted_by", sa.String(100), nullable=False),
        sa.Column("posted_at", sa.DateTime(), nullable=False),
        sa.UniqueConstraint("shop_id", "idempotency_key", name="uq_sale_shop_key"),
    )
    op.create_index("ix_sale_documents_shop_id", "sale_documents", ["shop_id"])
    op.create_table("sale_items",
        sa.Column("id", sa.String(150), primary_key=True),
        sa.Column("sale_id", sa.String(100), sa.ForeignKey("sale_documents.id"), nullable=False),
        sa.Column("product_id", sa.String(100), sa.ForeignKey("products.id"), nullable=False),
        sa.Column("unit", sa.String(100), nullable=False),
        sa.Column("quantity", sa.Numeric(18, 6), nullable=False),
        sa.Column("base_quantity", sa.Numeric(18, 6), nullable=False),
        sa.Column("unit_price", money, nullable=False),
        sa.Column("line_total", money, nullable=False),
    )
    for name, table, cols in [
        ("ix_sale_items_sale_id", "sale_items", ["sale_id"]),
        ("ix_sale_items_product_id", "sale_items", ["product_id"]),
    ]:
        op.create_index(name, table, cols)
    for table, prefix in [("sale_payments", "payment"), ("cash_movements", "cash"), ("customer_ledger", "ledger")]:
        columns = [
            sa.Column("id", sa.String(150), primary_key=True),
            sa.Column("sale_id", sa.String(100), sa.ForeignKey("sale_documents.id"), nullable=False),
            sa.Column("shop_id", sa.String(100), sa.ForeignKey("shops.id"), nullable=False),
        ]
        if table == "customer_ledger":
            columns += [sa.Column("customer_id", sa.String(100), nullable=False)]
        columns += [sa.Column("amount", money, nullable=False)]
        if table == "sale_payments":
            columns += [sa.Column("method", sa.String(20), nullable=False), sa.Column("paid_at", sa.DateTime(), nullable=False)]
        elif table == "cash_movements":
            columns += [sa.Column("movement_type", sa.String(30), nullable=False), sa.Column("occurred_at", sa.DateTime(), nullable=False)]
        else:
            columns += [sa.Column("direction", sa.String(20), nullable=False), sa.Column("posted_at", sa.DateTime(), nullable=False)]
        op.create_table(table, *columns)
        op.create_index("ix_%s_sale_id" % table, table, ["sale_id"])
        op.create_index("ix_%s_shop_id" % table, table, ["shop_id"])


def downgrade() -> None:
    for table in ("customer_ledger", "cash_movements", "sale_payments"):
        op.drop_index("ix_%s_shop_id" % table, table_name=table)
        op.drop_index("ix_%s_sale_id" % table, table_name=table)
        op.drop_table(table)
    op.drop_index("ix_sale_items_product_id", table_name="sale_items")
    op.drop_index("ix_sale_items_sale_id", table_name="sale_items")
    op.drop_table("sale_items")
    op.drop_index("ix_sale_documents_shop_id", table_name="sale_documents")
    op.drop_table("sale_documents")
