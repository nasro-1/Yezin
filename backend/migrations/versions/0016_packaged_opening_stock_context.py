"""preserve packaged opening stock unit context

Revision ID: 0016
Revises: 0015
"""

from alembic import op
import sqlalchemy as sa


revision = "0016_packaged_opening_stock_context"
down_revision = "0015_exchange_settlements"
branch_labels = None
depends_on = None


def upgrade() -> None:
    with op.batch_alter_table("opening_stock_documents") as batch:
        batch.add_column(sa.Column("entered_unit", sa.String(100), nullable=False, server_default="piece"))
        batch.add_column(sa.Column("conversion_to_base", sa.Float(), nullable=False, server_default="1"))
        batch.add_column(sa.Column("base_quantity", sa.Float(), nullable=False, server_default="0"))
    with op.batch_alter_table("opening_stock_lines") as batch:
        batch.add_column(sa.Column("entered_unit", sa.String(100), nullable=False, server_default="piece"))
        batch.add_column(sa.Column("conversion_to_base", sa.Float(), nullable=False, server_default="1"))
        batch.add_column(sa.Column("base_quantity", sa.Float(), nullable=False, server_default="0"))
    op.execute(
        "UPDATE opening_stock_documents SET base_quantity = quantity "
        "WHERE base_quantity = 0 AND quantity <> 0"
    )
    op.execute(
        "UPDATE opening_stock_lines SET base_quantity = quantity "
        "WHERE base_quantity = 0 AND quantity <> 0"
    )


def downgrade() -> None:
    with op.batch_alter_table("opening_stock_lines") as batch:
        batch.drop_column("base_quantity")
        batch.drop_column("conversion_to_base")
        batch.drop_column("entered_unit")
    with op.batch_alter_table("opening_stock_documents") as batch:
        batch.drop_column("base_quantity")
        batch.drop_column("conversion_to_base")
        batch.drop_column("entered_unit")
