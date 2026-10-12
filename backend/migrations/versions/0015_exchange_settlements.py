"""Persist exchange settlement details."""

from alembic import op
import sqlalchemy as sa


revision = "0015_exchange_settlements"
down_revision = "0014_exchange_replacement_sales"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "exchange_settlements",
        sa.Column("id", sa.String(length=150), primary_key=True),
        sa.Column(
            "exchange_id",
            sa.String(length=100),
            sa.ForeignKey("exchange_documents.id"),
            nullable=False,
        ),
        sa.Column(
            "replacement_sale_id",
            sa.String(length=100),
            sa.ForeignKey("sale_documents.id"),
            nullable=False,
        ),
        sa.Column(
            "shop_id",
            sa.String(length=100),
            sa.ForeignKey("shops.id"),
            nullable=False,
        ),
        sa.Column(
            "payment_id",
            sa.String(length=150),
            sa.ForeignKey("sale_payments.id"),
            nullable=False,
        ),
        sa.Column(
            "cash_movement_id",
            sa.String(length=150),
            sa.ForeignKey("cash_movements.id"),
            nullable=True,
        ),
        sa.Column(
            "customer_ledger_id",
            sa.String(length=150),
            sa.ForeignKey("customer_ledger.id"),
            nullable=True,
        ),
        sa.Column("returned_amount", sa.Numeric(18, 2), nullable=False),
        sa.Column("replacement_amount", sa.Numeric(18, 2), nullable=False),
        sa.Column("difference_amount", sa.Numeric(18, 2), nullable=False),
        sa.Column("payment_method", sa.String(length=20), nullable=False),
        sa.Column("posted_at", sa.DateTime(), nullable=False),
        sa.UniqueConstraint("exchange_id", name="uq_exchange_settlement_exchange"),
    )
    op.create_index(
        "ix_exchange_settlements_exchange_id",
        "exchange_settlements",
        ["exchange_id"],
    )
    op.create_index(
        "ix_exchange_settlements_replacement_sale_id",
        "exchange_settlements",
        ["replacement_sale_id"],
    )
    op.create_index(
        "ix_exchange_settlements_shop_id",
        "exchange_settlements",
        ["shop_id"],
    )


def downgrade() -> None:
    op.drop_index("ix_exchange_settlements_shop_id", table_name="exchange_settlements")
    op.drop_index(
        "ix_exchange_settlements_replacement_sale_id",
        table_name="exchange_settlements",
    )
    op.drop_index(
        "ix_exchange_settlements_exchange_id", table_name="exchange_settlements"
    )
    op.drop_table("exchange_settlements")
