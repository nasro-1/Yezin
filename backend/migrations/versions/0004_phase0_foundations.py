"""Add Phase 0 idempotency, token revocation, and device audit foundations."""

from alembic import op
import sqlalchemy as sa


revision = "0004_phase0_foundations"
down_revision = "0003_stock_adjustments"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "idempotency_records",
        sa.Column("id", sa.String(100), primary_key=True),
        sa.Column("shop_id", sa.String(100), sa.ForeignKey("shops.id"), nullable=False),
        sa.Column("idempotency_key", sa.String(255), nullable=False),
        sa.Column("request_hash", sa.String(64), nullable=False),
        sa.Column("response_json", sa.Text(), nullable=False),
        sa.Column("status_code", sa.Integer(), nullable=False),
        sa.Column("device_id", sa.String(100)),
        sa.Column("created_at", sa.DateTime(), nullable=False, server_default=sa.func.current_timestamp()),
        sa.UniqueConstraint("shop_id", "idempotency_key", name="uq_idempotency_shop_key"),
    )
    op.create_index("ix_idempotency_records_shop_id", "idempotency_records", ["shop_id"])
    op.create_table(
        "revoked_tokens",
        sa.Column("jti", sa.String(100), primary_key=True),
        sa.Column("revoked_at", sa.DateTime(), nullable=False, server_default=sa.func.current_timestamp()),
        sa.Column("expires_at", sa.DateTime(), nullable=False),
    )
    op.add_column("stock_movements", sa.Column("device_id", sa.String(100)))


def downgrade() -> None:
    op.drop_column("stock_movements", "device_id")
    op.drop_table("revoked_tokens")
    op.drop_index("ix_idempotency_records_shop_id", table_name="idempotency_records")
    op.drop_table("idempotency_records")
