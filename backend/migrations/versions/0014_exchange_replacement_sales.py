"""Link exchanges to replacement sale documents."""

from alembic import op
import sqlalchemy as sa


revision = "0014_exchange_replacement_sales"
down_revision = "0013_normalize_sale_item_return_quantities"
branch_labels = None
depends_on = None


def upgrade() -> None:
    with op.batch_alter_table("exchange_documents") as batch_op:
        batch_op.add_column(
            sa.Column("replacement_sale_id", sa.String(length=100), nullable=True)
        )
        batch_op.create_foreign_key(
            "fk_exchange_documents_replacement_sale_id",
            "sale_documents",
            ["replacement_sale_id"],
            ["id"],
        )
    op.create_index(
        "ix_exchange_documents_replacement_sale_id",
        "exchange_documents",
        ["replacement_sale_id"],
    )


def downgrade() -> None:
    op.drop_index(
        "ix_exchange_documents_replacement_sale_id",
        table_name="exchange_documents",
    )
    with op.batch_alter_table("exchange_documents") as batch_op:
        batch_op.drop_constraint(
            "fk_exchange_documents_replacement_sale_id",
            type_="foreignkey",
        )
        batch_op.drop_column("replacement_sale_id")
