"""Add stable human-readable sale numbers and customer names to drafts."""
from alembic import op
import sqlalchemy as sa

revision = "0008_sale_draft_numbers"
down_revision = "0007_sale_drafts"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column("sale_drafts", sa.Column("sale_number", sa.Integer(), nullable=True))
    op.add_column("sale_drafts", sa.Column("customer_name", sa.String(255), nullable=True))
    bind = op.get_bind()
    rows = bind.execute(sa.text(
        "SELECT id, shop_id FROM sale_drafts ORDER BY shop_id, created_at, id"
    )).fetchall()
    counters = {}
    for row in rows:
        number = counters.get(row.shop_id, 0) + 1
        counters[row.shop_id] = number
        bind.execute(
            sa.text("UPDATE sale_drafts SET sale_number=:number WHERE id=:id"),
            {"number": number, "id": row.id},
        )
    op.create_index(
        "uq_sale_drafts_shop_sale_number",
        "sale_drafts",
        ["shop_id", "sale_number"],
        unique=True,
    )


def downgrade() -> None:
    op.drop_index("uq_sale_drafts_shop_sale_number", table_name="sale_drafts")
    op.drop_column("sale_drafts", "customer_name")
    op.drop_column("sale_drafts", "sale_number")
