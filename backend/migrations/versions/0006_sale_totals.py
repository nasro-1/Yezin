"""Add sale references and payment totals."""
from alembic import op
import sqlalchemy as sa

revision = "0006_sale_totals"
down_revision = "0005_sales"
branch_labels = None
depends_on = None


def upgrade() -> None:
    with op.batch_alter_table("sale_documents") as batch:
        batch.add_column(sa.Column("document_reference", sa.String(100), nullable=True))
        batch.add_column(sa.Column("subtotal", sa.Numeric(18, 2), nullable=True))
        batch.add_column(sa.Column("discount", sa.Numeric(18, 2), nullable=True))
        batch.add_column(sa.Column("payment_result", sa.Numeric(18, 2), nullable=True))
        batch.add_column(sa.Column("remaining_amount", sa.Numeric(18, 2), nullable=True))
        batch.add_column(sa.Column("stock_posting_reference", sa.String(150), nullable=True))
    bind = op.get_bind()
    bind.execute(sa.text(
        "UPDATE sale_documents SET document_reference = id, subtotal = total, "
        "discount = 0, payment_result = total, remaining_amount = 0, "
        "stock_posting_reference = 'sale:' || id"
    ))
    with op.batch_alter_table("sale_documents") as batch:
        for name, typ in [
            ("document_reference", sa.String(100)), ("subtotal", sa.Numeric(18, 2)),
            ("discount", sa.Numeric(18, 2)), ("payment_result", sa.Numeric(18, 2)),
            ("remaining_amount", sa.Numeric(18, 2)), ("stock_posting_reference", sa.String(150)),
        ]:
            batch.alter_column(name, existing_type=typ, nullable=False)
        batch.create_unique_constraint("uq_sale_document_reference", ["document_reference"])


def downgrade() -> None:
    with op.batch_alter_table("sale_documents") as batch:
        batch.drop_constraint("uq_sale_document_reference", type_="unique")
        for name in ("stock_posting_reference", "remaining_amount", "payment_result", "discount", "subtotal", "document_reference"):
            batch.drop_column(name)
