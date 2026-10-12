"""Persist append-only FIFO cost corrections and sale-time allocation costs."""

from alembic import op
import sqlalchemy as sa


revision = "0022_fifo_cost_corrections"
down_revision = "0021_active_product_barcode_scope"
branch_labels = None
depends_on = None


def upgrade() -> None:
    with op.batch_alter_table("inventory_lots") as batch:
        batch.add_column(sa.Column("fifo_order", sa.String(length=500), nullable=True))
        batch.add_column(sa.Column("parent_layer_id", sa.String(length=150), nullable=True))
        batch.create_foreign_key(
            "fk_inventory_lots_parent_layer_id_inventory_lots",
            "inventory_lots",
            ["parent_layer_id"],
            ["id"],
        )
        batch.create_index("ix_inventory_lots_fifo_order", ["fifo_order"])
        batch.create_index("ix_inventory_lots_parent_layer_id", ["parent_layer_id"])

    with op.batch_alter_table("sale_item_fifo_allocations") as batch:
        batch.add_column(
            sa.Column("unit_cost_at_sale", sa.Float(), nullable=True)
        )

    with op.batch_alter_table("stock_movements") as batch:
        batch.add_column(
            sa.Column("reference_line_id", sa.String(length=150), nullable=True)
        )
        batch.create_index(
            "ix_stock_movements_reference_line_id", ["reference_line_id"]
        )

    op.create_table(
        "fifo_cost_corrections",
        sa.Column("id", sa.String(length=150), primary_key=True),
        sa.Column("shop_id", sa.String(length=100), sa.ForeignKey("shops.id"), nullable=False),
        sa.Column("product_id", sa.String(length=100), sa.ForeignKey("products.id"), nullable=False),
        sa.Column("source_layer_id", sa.String(length=150), sa.ForeignKey("inventory_lots.id"), nullable=False),
        sa.Column("resulting_layer_id", sa.String(length=150), sa.ForeignKey("inventory_lots.id"), nullable=False),
        sa.Column("source_movement_id", sa.String(length=150), nullable=False),
        sa.Column("correction_movement_id", sa.String(length=150), nullable=False, unique=True),
        sa.Column("source_reference", sa.String(length=150), nullable=False),
        sa.Column("quantity", sa.Float(), nullable=False),
        sa.Column("old_unit_cost", sa.Float(), nullable=False),
        sa.Column("new_unit_cost", sa.Float(), nullable=False),
        sa.Column("value_difference", sa.Float(), nullable=False),
        sa.Column("reason", sa.Text(), nullable=False),
        sa.Column("posted_by", sa.String(length=100), sa.ForeignKey("users.id"), nullable=False),
        sa.Column("idempotency_key", sa.String(length=255), nullable=False),
        sa.Column("request_hash", sa.String(length=64), nullable=False),
        sa.Column("created_at", sa.DateTime(), nullable=False, server_default=sa.func.current_timestamp()),
        sa.UniqueConstraint("shop_id", "idempotency_key", name="uq_fifo_cost_correction_shop_key"),
    )
    op.create_index("ix_fifo_cost_corrections_shop_id", "fifo_cost_corrections", ["shop_id"])
    op.create_index("ix_fifo_cost_corrections_product_id", "fifo_cost_corrections", ["product_id"])
    op.create_index("ix_fifo_cost_corrections_source_layer_id", "fifo_cost_corrections", ["source_layer_id"])
    op.create_index("ix_fifo_cost_corrections_resulting_layer_id", "fifo_cost_corrections", ["resulting_layer_id"])

    dialect = op.get_bind().dialect.name
    if dialect == "sqlite":
        op.execute(
            """
            CREATE TRIGGER fifo_cost_corrections_no_update
            BEFORE UPDATE ON fifo_cost_corrections
            BEGIN
                SELECT RAISE(ABORT, 'FIFO cost corrections are immutable');
            END
            """
        )
        op.execute(
            """
            CREATE TRIGGER fifo_cost_corrections_no_delete
            BEFORE DELETE ON fifo_cost_corrections
            BEGIN
                SELECT RAISE(ABORT, 'FIFO cost corrections cannot be deleted');
            END
            """
        )
    elif dialect == "postgresql":
        op.execute(
            """
            CREATE FUNCTION prevent_fifo_cost_correction_mutation()
            RETURNS trigger AS $$
            BEGIN
                RAISE EXCEPTION 'FIFO cost corrections are immutable';
            END;
            $$ LANGUAGE plpgsql
            """
        )
        op.execute(
            """
            CREATE TRIGGER fifo_cost_corrections_immutable
            BEFORE UPDATE OR DELETE ON fifo_cost_corrections
            FOR EACH ROW EXECUTE FUNCTION prevent_fifo_cost_correction_mutation()
            """
        )


def downgrade() -> None:
    dialect = op.get_bind().dialect.name
    if dialect == "sqlite":
        op.execute("DROP TRIGGER fifo_cost_corrections_no_delete")
        op.execute("DROP TRIGGER fifo_cost_corrections_no_update")
    elif dialect == "postgresql":
        op.execute("DROP TRIGGER fifo_cost_corrections_immutable ON fifo_cost_corrections")
        op.execute("DROP FUNCTION prevent_fifo_cost_correction_mutation()")
    op.drop_index("ix_fifo_cost_corrections_resulting_layer_id", table_name="fifo_cost_corrections")
    op.drop_index("ix_fifo_cost_corrections_source_layer_id", table_name="fifo_cost_corrections")
    op.drop_index("ix_fifo_cost_corrections_product_id", table_name="fifo_cost_corrections")
    op.drop_index("ix_fifo_cost_corrections_shop_id", table_name="fifo_cost_corrections")
    op.drop_table("fifo_cost_corrections")
    with op.batch_alter_table("sale_item_fifo_allocations") as batch:
        batch.drop_column("unit_cost_at_sale")
    with op.batch_alter_table("stock_movements") as batch:
        batch.drop_index("ix_stock_movements_reference_line_id")
        batch.drop_column("reference_line_id")
    with op.batch_alter_table("inventory_lots") as batch:
        batch.drop_index("ix_inventory_lots_parent_layer_id")
        batch.drop_index("ix_inventory_lots_fifo_order")
        batch.drop_constraint(
            "fk_inventory_lots_parent_layer_id_inventory_lots",
            type_="foreignkey",
        )
        batch.drop_column("parent_layer_id")
        batch.drop_column("fifo_order")
