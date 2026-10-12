"""Persist selling-unit icon keys.

Revision ID: 0009_selling_unit_icons
Revises: 0008_sale_draft_numbers
"""

from alembic import op
import sqlalchemy as sa


revision = "0009_selling_unit_icons"
down_revision = "0008_sale_draft_numbers"
branch_labels = None
depends_on = None


def _default_icon(name: str) -> str:
    return {
        "piece": "package",
        "box": "box",
        "bottle": "bottle",
        "can": "can",
        "pack": "pack",
        "carton": "carton",
    }.get(name.strip().lower(), "package")


def upgrade() -> None:
    op.add_column(
        "product_selling_units",
        sa.Column("icon_key", sa.String(length=50), nullable=True),
    )
    connection = op.get_bind()
    rows = connection.execute(
        sa.text("SELECT id, name FROM product_selling_units WHERE icon_key IS NULL")
    ).fetchall()
    for row in rows:
        connection.execute(
            sa.text(
                "UPDATE product_selling_units SET icon_key = :icon_key WHERE id = :id"
            ),
            {"icon_key": _default_icon(row.name), "id": row.id},
        )


def downgrade() -> None:
    op.drop_column("product_selling_units", "icon_key")
