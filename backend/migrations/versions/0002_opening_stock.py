"""Add server opening-stock documents and movements."""

from alembic import op
import sqlalchemy as sa


revision = "0002_opening_stock"
down_revision = "0001_initial"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "opening_stock_documents",
        sa.Column("id", sa.String(100), primary_key=True),
        sa.Column("shop_id", sa.String(100), sa.ForeignKey("shops.id"), nullable=False),
        sa.Column("product_id", sa.String(100), sa.ForeignKey("products.id"), nullable=False),
        sa.Column("idempotency_key", sa.String(255), nullable=False, unique=True),
        sa.Column("reference_number", sa.String(100), nullable=False, unique=True),
        sa.Column("quantity", sa.Float(), nullable=False),
        sa.Column("unit_cost", sa.Float(), nullable=False),
        sa.Column("reason", sa.Text(), nullable=False),
        sa.Column("notes", sa.Text()),
        sa.Column("posted_by", sa.String(100), nullable=False),
        sa.Column("created_at", sa.DateTime(), nullable=False, server_default=sa.func.current_timestamp()),
    )
    op.create_index("ix_opening_stock_documents_shop_id", "opening_stock_documents", ["shop_id"])
    op.create_index("ix_opening_stock_documents_product_id", "opening_stock_documents", ["product_id"])
    op.create_table(
        "opening_stock_lines",
        sa.Column("id", sa.String(100), primary_key=True),
        sa.Column("document_id", sa.String(100), sa.ForeignKey("opening_stock_documents.id"), nullable=False),
        sa.Column("product_id", sa.String(100), sa.ForeignKey("products.id"), nullable=False),
        sa.Column("quantity", sa.Float(), nullable=False),
        sa.Column("unit_cost", sa.Float(), nullable=False),
        sa.Column("line_total", sa.Float(), nullable=False),
        sa.Column("created_at", sa.DateTime(), nullable=False, server_default=sa.func.current_timestamp()),
    )
    op.create_index("ix_opening_stock_lines_document_id", "opening_stock_lines", ["document_id"])
    op.create_index("ix_opening_stock_lines_product_id", "opening_stock_lines", ["product_id"])
    op.create_table(
        "stock_movements",
        sa.Column("id", sa.String(150), primary_key=True),
        sa.Column("shop_id", sa.String(100), sa.ForeignKey("shops.id"), nullable=False),
        sa.Column("product_id", sa.String(100), sa.ForeignKey("products.id"), nullable=False),
        sa.Column("movement_type", sa.String(50), nullable=False),
        sa.Column("quantity_change", sa.Float(), nullable=False),
        sa.Column("unit_cost", sa.Float(), nullable=False),
        sa.Column("running_stock", sa.Float(), nullable=False),
        sa.Column("reference_type", sa.String(50), nullable=False),
        sa.Column("reference_id", sa.String(100), nullable=False),
        sa.Column("notes", sa.Text()),
        sa.Column("user_id", sa.String(100)),
        sa.Column("created_at", sa.DateTime(), nullable=False, server_default=sa.func.current_timestamp()),
    )
    op.create_index("ix_stock_movements_shop_id", "stock_movements", ["shop_id"])
    op.create_index("ix_stock_movements_product_id", "stock_movements", ["product_id"])


def downgrade() -> None:
    op.drop_index("ix_stock_movements_product_id", table_name="stock_movements")
    op.drop_index("ix_stock_movements_shop_id", table_name="stock_movements")
    op.drop_table("stock_movements")
    op.drop_index("ix_opening_stock_lines_product_id", table_name="opening_stock_lines")
    op.drop_index("ix_opening_stock_lines_document_id", table_name="opening_stock_lines")
    op.drop_table("opening_stock_lines")
    op.drop_index("ix_opening_stock_documents_product_id", table_name="opening_stock_documents")
    op.drop_index("ix_opening_stock_documents_shop_id", table_name="opening_stock_documents")
    op.drop_table("opening_stock_documents")
