"""Add tenant-scoped suppliers and server-authoritative purchases."""

from alembic import op
import sqlalchemy as sa


revision = "0023_purchases_suppliers"
down_revision = "0022_fifo_cost_corrections"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "suppliers",
        sa.Column("id", sa.String(100), primary_key=True),
        sa.Column("shop_id", sa.String(100), sa.ForeignKey("shops.id"), nullable=False),
        sa.Column("code", sa.String(100), nullable=False),
        sa.Column("name", sa.String(255), nullable=False),
        sa.Column("registration_name", sa.String(255), nullable=False, server_default=""),
        sa.Column("activity", sa.String(255), nullable=False, server_default="Retail"),
        sa.Column("address", sa.Text(), nullable=False, server_default=""),
        sa.Column("phone", sa.String(50), nullable=False, server_default=""),
        sa.Column("mobile", sa.String(50), nullable=False, server_default=""),
        sa.Column("email", sa.String(255)),
        sa.Column("tax_number", sa.String(100)),
        sa.Column("registration_number", sa.String(100)),
        sa.Column("supplier_reference", sa.String(100)),
        sa.Column("contact_person", sa.String(255)),
        sa.Column("commercial_register", sa.String(100)),
        sa.Column("tax_id", sa.String(100)),
        sa.Column("nis", sa.String(100)),
        sa.Column("ai", sa.String(100)),
        sa.Column("bank_name", sa.String(255)),
        sa.Column("bank_account", sa.String(100)),
        sa.Column("currency", sa.String(10), nullable=False, server_default="DZD"),
        sa.Column("credit_limit", sa.Numeric(18, 2), nullable=False, server_default="0"),
        sa.Column("notes", sa.Text()),
        sa.Column("is_active", sa.Boolean(), nullable=False, server_default=sa.true()),
        sa.Column("created_at", sa.DateTime(), nullable=False, server_default=sa.func.current_timestamp()),
        sa.Column("updated_at", sa.DateTime(), nullable=False, server_default=sa.func.current_timestamp()),
        sa.UniqueConstraint("shop_id", "code", name="uq_supplier_shop_code"),
    )
    op.create_index("ix_suppliers_shop_id", "suppliers", ["shop_id"])

    op.create_table(
        "purchase_documents",
        sa.Column("id", sa.String(100), primary_key=True),
        sa.Column("shop_id", sa.String(100), sa.ForeignKey("shops.id"), nullable=False),
        sa.Column("reference", sa.String(100), nullable=False),
        sa.Column("supplier_id", sa.String(100), sa.ForeignKey("suppliers.id"), nullable=False),
        sa.Column("purchase_date", sa.DateTime(), nullable=False),
        sa.Column("notes", sa.Text()),
        sa.Column("subtotal", sa.Numeric(18, 2), nullable=False),
        sa.Column("total", sa.Numeric(18, 2), nullable=False),
        sa.Column("status", sa.String(20), nullable=False, server_default="POSTED"),
        sa.Column("created_by", sa.String(100), sa.ForeignKey("users.id"), nullable=False),
        sa.Column("idempotency_key", sa.String(255), nullable=False),
        sa.Column("created_at", sa.DateTime(), nullable=False),
        sa.UniqueConstraint("shop_id", "reference", name="uq_purchase_shop_reference"),
        sa.UniqueConstraint("shop_id", "idempotency_key", name="uq_purchase_shop_key"),
    )
    op.create_index("ix_purchase_documents_shop_id", "purchase_documents", ["shop_id"])
    op.create_index("ix_purchase_documents_supplier_id", "purchase_documents", ["supplier_id"])
    op.create_index("ix_purchase_documents_purchase_date", "purchase_documents", ["purchase_date"])

    op.create_table(
        "purchase_lines",
        sa.Column("id", sa.String(150), primary_key=True),
        sa.Column("purchase_id", sa.String(100), sa.ForeignKey("purchase_documents.id"), nullable=False),
        sa.Column("product_id", sa.String(100), sa.ForeignKey("products.id"), nullable=False),
        sa.Column("quantity", sa.Numeric(18, 6), nullable=False),
        sa.Column("unit_cost", sa.Numeric(18, 6), nullable=False),
        sa.Column("line_total", sa.Numeric(18, 2), nullable=False),
        sa.Column("selling_unit_id", sa.String(100)),
        sa.Column("selling_quantity", sa.Numeric(18, 6)),
        sa.Column("conversion_factor_snapshot", sa.Numeric(18, 6), nullable=False, server_default="1"),
        sa.Column("selling_unit_name_snapshot", sa.String(100), nullable=False),
        sa.Column("base_unit_snapshot", sa.String(50), nullable=False),
    )
    op.create_index("ix_purchase_lines_purchase_id", "purchase_lines", ["purchase_id"])
    op.create_index("ix_purchase_lines_product_id", "purchase_lines", ["product_id"])

    op.create_table(
        "supplier_ledger",
        sa.Column("id", sa.String(150), primary_key=True),
        sa.Column("shop_id", sa.String(100), sa.ForeignKey("shops.id"), nullable=False),
        sa.Column("supplier_id", sa.String(100), sa.ForeignKey("suppliers.id"), nullable=False),
        sa.Column("entry_type", sa.String(30), nullable=False),
        sa.Column("amount", sa.Numeric(18, 2), nullable=False),
        sa.Column("balance_after", sa.Numeric(18, 2), nullable=False),
        sa.Column("reference_type", sa.String(50), nullable=False),
        sa.Column("reference_id", sa.String(150), nullable=False),
        sa.Column("notes", sa.Text()),
        sa.Column("created_at", sa.DateTime(), nullable=False),
    )
    op.create_index("ix_supplier_ledger_shop_id", "supplier_ledger", ["shop_id"])
    op.create_index("ix_supplier_ledger_supplier_id", "supplier_ledger", ["supplier_id"])
    op.create_index("ix_supplier_ledger_created_at", "supplier_ledger", ["created_at"])


def downgrade() -> None:
    op.drop_index("ix_supplier_ledger_created_at", table_name="supplier_ledger")
    op.drop_index("ix_supplier_ledger_supplier_id", table_name="supplier_ledger")
    op.drop_index("ix_supplier_ledger_shop_id", table_name="supplier_ledger")
    op.drop_table("supplier_ledger")
    op.drop_index("ix_purchase_lines_product_id", table_name="purchase_lines")
    op.drop_index("ix_purchase_lines_purchase_id", table_name="purchase_lines")
    op.drop_table("purchase_lines")
    op.drop_index("ix_purchase_documents_purchase_date", table_name="purchase_documents")
    op.drop_index("ix_purchase_documents_supplier_id", table_name="purchase_documents")
    op.drop_index("ix_purchase_documents_shop_id", table_name="purchase_documents")
    op.drop_table("purchase_documents")
    op.drop_index("ix_suppliers_shop_id", table_name="suppliers")
    op.drop_table("suppliers")
