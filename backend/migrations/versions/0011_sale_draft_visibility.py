"""Add visibility metadata to sale drafts.

Revision ID: 0011_sale_draft_visibility
Revises: 0010_sale_draft_item_icons
"""

from alembic import op
import sqlalchemy as sa


revision = "0011_sale_draft_visibility"
down_revision = "0010_sale_draft_item_icons"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column(
        "sale_drafts",
        sa.Column(
            "visibility",
            sa.String(length=20),
            nullable=False,
            server_default="PRIVATE",
        ),
    )
    op.execute(
        sa.text("UPDATE sale_drafts SET visibility = 'PRIVATE' WHERE visibility IS NULL")
    )


def downgrade() -> None:
    op.drop_column("sale_drafts", "visibility")
