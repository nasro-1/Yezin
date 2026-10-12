"""Persist selected selling-unit icons in sale drafts.

Revision ID: 0010_sale_draft_item_icons
Revises: 0009_selling_unit_icons
"""

from alembic import op
import sqlalchemy as sa


revision = "0010_sale_draft_item_icons"
down_revision = "0009_selling_unit_icons"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column(
        "sale_draft_items",
        sa.Column("icon_key", sa.String(length=50), nullable=True),
    )


def downgrade() -> None:
    op.drop_column("sale_draft_items", "icon_key")
