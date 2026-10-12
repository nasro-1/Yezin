"""Add server stock adjustment documents and lines."""

from alembic import op
import sqlalchemy as sa


revision = "0003_stock_adjustments"
down_revision = "0002_opening_stock"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "stock_adjustment_documents",
        sa.Column("id", sa.String(100), primary_key=True),
        sa.Column("shop_id", sa.String(100), sa.ForeignKey("shops.id"), nullable=False),
        sa.Column("product_id", sa.String(100), sa.ForeignKey("products.id"), nullable=False),
        sa.Column("idempotency_key", sa.String(255), nullable=False),
        sa.Column("reference_number", sa.String(100), nullable=False, unique=True),
        sa.Column("adjustment_date", sa.DateTime(), nullable=False),
        sa.Column("reason", sa.Text(), nullable=False),
        sa.Column("notes", sa.Text()),
        sa.Column("posted_by", sa.String(100), nullable=False),
        sa.Column("created_at", sa.DateTime(), nullable=False, server_default=sa.func.current_timestamp()),
        sa.UniqueConstraint("shop_id", "idempotency_key", name="uq_stock_adjustment_shop_key"),
    )
    op.create_index("ix_stock_adjustment_documents_shop_id", "stock_adjustment_documents", ["shop_id"])
    op.create_index("ix_stock_adjustment_documents_product_id", "stock_adjustment_documents", ["product_id"])
    op.create_index("ix_stock_adjustment_documents_idempotency_key", "stock_adjustment_documents", ["idempotency_key"])
    op.create_table(
        "stock_adjustment_lines",
        sa.Column("id", sa.String(150), primary_key=True),
        sa.Column("document_id", sa.String(100), sa.ForeignKey("stock_adjustment_documents.id"), nullable=False),
        sa.Column("product_id", sa.String(100), sa.ForeignKey("products.id"), nullable=False),
        sa.Column("unit", sa.String(100), nullable=False),
        sa.Column("current_quantity", sa.Float(), nullable=False),
        sa.Column("counted_quantity", sa.Float(), nullable=False),
        sa.Column("quantity_change", sa.Float(), nullable=False),
        sa.Column("unit_cost", sa.Float(), nullable=False),
        sa.Column("line_total", sa.Float(), nullable=False),
        sa.Column("created_at", sa.DateTime(), nullable=False, server_default=sa.func.current_timestamp()),
    )
    op.create_index("ix_stock_adjustment_lines_document_id", "stock_adjustment_lines", ["document_id"])
    op.create_index("ix_stock_adjustment_lines_product_id", "stock_adjustment_lines", ["product_id"])


def downgrade() -> None:
    op.drop_index("ix_stock_adjustment_lines_product_id", table_name="stock_adjustment_lines")
    op.drop_index("ix_stock_adjustment_lines_document_id", table_name="stock_adjustment_lines")
    op.drop_table("stock_adjustment_lines")
    op.drop_index("ix_stock_adjustment_documents_idempotency_key", table_name="stock_adjustment_documents")
    op.drop_index("ix_stock_adjustment_documents_product_id", table_name="stock_adjustment_documents")
    op.drop_index("ix_stock_adjustment_documents_shop_id", table_name="stock_adjustment_documents")
    op.drop_table("stock_adjustment_documents")
