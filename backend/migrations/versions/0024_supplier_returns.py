"""Add server-authoritative supplier returns."""

from alembic import op
import sqlalchemy as sa


revision = "0024_supplier_returns"
down_revision = "0023_purchases_suppliers"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "supplier_return_documents",
        sa.Column("id", sa.String(100), primary_key=True),
        sa.Column("shop_id", sa.String(100), sa.ForeignKey("shops.id"), nullable=False),
        sa.Column("reference", sa.String(100), nullable=False),
        sa.Column("supplier_id", sa.String(100), sa.ForeignKey("suppliers.id"), nullable=False),
        sa.Column("purchase_id", sa.String(100), sa.ForeignKey("purchase_documents.id"), nullable=False),
        sa.Column("return_date", sa.DateTime(), nullable=False),
        sa.Column("total", sa.Numeric(18, 2), nullable=False),
        sa.Column("status", sa.String(20), nullable=False, server_default="POSTED"),
        sa.Column("notes", sa.Text()),
        sa.Column("created_by", sa.String(100), sa.ForeignKey("users.id"), nullable=False),
        sa.Column("idempotency_key", sa.String(255), nullable=False),
        sa.Column("created_at", sa.DateTime(), nullable=False),
        sa.UniqueConstraint("shop_id", "reference", name="uq_supplier_return_shop_reference"),
        sa.UniqueConstraint("shop_id", "idempotency_key", name="uq_supplier_return_shop_key"),
    )
    op.create_index(
        "ix_supplier_return_documents_shop_id", "supplier_return_documents", ["shop_id"]
    )
    op.create_index(
        "ix_supplier_return_documents_supplier_id",
        "supplier_return_documents",
        ["supplier_id"],
    )
    op.create_index(
        "ix_supplier_return_documents_purchase_id",
        "supplier_return_documents",
        ["purchase_id"],
    )

    op.create_table(
        "supplier_return_lines",
        sa.Column("id", sa.String(150), primary_key=True),
        sa.Column(
            "return_id",
            sa.String(100),
            sa.ForeignKey("supplier_return_documents.id"),
            nullable=False,
        ),
        sa.Column(
            "purchase_line_id", sa.String(150), sa.ForeignKey("purchase_lines.id"), nullable=False
        ),
        sa.Column("product_id", sa.String(100), sa.ForeignKey("products.id"), nullable=False),
        sa.Column("quantity", sa.Numeric(18, 6), nullable=False),
        sa.Column("base_quantity", sa.Numeric(18, 6), nullable=False),
        sa.Column("unit_cost", sa.Numeric(18, 6), nullable=False),
        sa.Column("return_value", sa.Numeric(18, 2), nullable=False),
        sa.Column("unit_name", sa.String(100), nullable=False),
    )
    op.create_index("ix_supplier_return_lines_return_id", "supplier_return_lines", ["return_id"])
    op.create_index(
        "ix_supplier_return_lines_purchase_line_id",
        "supplier_return_lines",
        ["purchase_line_id"],
    )
    op.create_index(
        "ix_supplier_return_lines_product_id", "supplier_return_lines", ["product_id"]
    )


def downgrade() -> None:
    op.drop_index("ix_supplier_return_lines_product_id", table_name="supplier_return_lines")
    op.drop_index(
        "ix_supplier_return_lines_purchase_line_id", table_name="supplier_return_lines"
    )
    op.drop_index("ix_supplier_return_lines_return_id", table_name="supplier_return_lines")
    op.drop_table("supplier_return_lines")
    op.drop_index(
        "ix_supplier_return_documents_purchase_id",
        table_name="supplier_return_documents",
    )
    op.drop_index(
        "ix_supplier_return_documents_supplier_id",
        table_name="supplier_return_documents",
    )
    op.drop_index(
        "ix_supplier_return_documents_shop_id", table_name="supplier_return_documents"
    )
    op.drop_table("supplier_return_documents")
