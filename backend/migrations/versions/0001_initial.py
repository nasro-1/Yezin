"""Create Phase 1 server foundation tables.

Revision ID: 0001_initial
Revises:
"""

from alembic import op
import sqlalchemy as sa


revision = "0001_initial"
down_revision = None
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "shops",
        sa.Column("id", sa.String(100), primary_key=True),
        sa.Column("name", sa.String(255), nullable=False),
        sa.Column("is_active", sa.Boolean(), nullable=False, server_default=sa.true()),
        sa.Column("created_at", sa.DateTime(), nullable=False, server_default=sa.func.current_timestamp()),
    )
    op.create_table(
        "users",
        sa.Column("id", sa.String(100), primary_key=True),
        sa.Column("shop_id", sa.String(100), sa.ForeignKey("shops.id"), nullable=False),
        sa.Column("username", sa.String(100), nullable=False),
        sa.Column("display_name", sa.String(255), nullable=False),
        sa.Column("phone", sa.String(50)),
        sa.Column("password_hash", sa.String(255), nullable=False),
        sa.Column("role", sa.String(20), nullable=False, server_default="cashier"),
        sa.Column("is_active", sa.Boolean(), nullable=False, server_default=sa.true()),
    )
    op.create_index("ix_users_shop_id", "users", ["shop_id"])
    op.create_index("ix_users_username", "users", ["username"])
    op.create_table(
        "devices",
        sa.Column("id", sa.String(100), primary_key=True),
        sa.Column("shop_id", sa.String(100), sa.ForeignKey("shops.id"), nullable=False),
        sa.Column("name", sa.String(255), nullable=False),
        sa.Column("device_type", sa.String(50), nullable=False, server_default="android"),
        sa.Column("is_active", sa.Boolean(), nullable=False, server_default=sa.true()),
        sa.Column("last_seen_at", sa.DateTime()),
    )
    op.create_index("ix_devices_shop_id", "devices", ["shop_id"])
    op.create_table(
        "categories",
        sa.Column("id", sa.String(100), primary_key=True),
        sa.Column("shop_id", sa.String(100), sa.ForeignKey("shops.id"), nullable=False),
        sa.Column("name", sa.String(255), nullable=False),
        sa.Column("color", sa.String(30)),
        sa.Column("sort_order", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("is_active", sa.Boolean(), nullable=False, server_default=sa.true()),
    )
    op.create_index("ix_categories_shop_id", "categories", ["shop_id"])
    op.create_table(
        "products",
        sa.Column("id", sa.String(100), primary_key=True),
        sa.Column("shop_id", sa.String(100), sa.ForeignKey("shops.id"), nullable=False),
        sa.Column("category_id", sa.String(100), sa.ForeignKey("categories.id")),
        sa.Column("name", sa.String(255), nullable=False),
        sa.Column("code", sa.String(100)),
        sa.Column("barcode", sa.String(100)),
        sa.Column("internal_reference", sa.String(100)),
        sa.Column("product_type", sa.String(20), nullable=False, server_default="STANDARD"),
        sa.Column("base_unit", sa.String(50), nullable=False, server_default="piece"),
        sa.Column("quantity_precision", sa.Integer(), nullable=False, server_default="3"),
        sa.Column("allow_partial_package_sale", sa.Boolean(), nullable=False, server_default=sa.false()),
        sa.Column("price", sa.Float(), nullable=False, server_default="0"),
        sa.Column("min_price", sa.Float(), nullable=False, server_default="0"),
        sa.Column("wholesale_price", sa.Float(), nullable=False, server_default="0"),
        sa.Column("cost", sa.Float(), nullable=False, server_default="0"),
        sa.Column("stock", sa.Float(), nullable=False, server_default="0"),
        sa.Column("min_stock", sa.Float(), nullable=False, server_default="0"),
        sa.Column("image_path", sa.Text()),
        sa.Column("is_active", sa.Boolean(), nullable=False, server_default=sa.true()),
        sa.Column("created_at", sa.DateTime(), nullable=False, server_default=sa.func.current_timestamp()),
        sa.Column("updated_at", sa.DateTime(), nullable=False, server_default=sa.func.current_timestamp()),
    )
    for name, column in (
        ("ix_products_shop_id", "shop_id"),
        ("ix_products_category_id", "category_id"),
        ("ix_products_code", "code"),
        ("ix_products_barcode", "barcode"),
    ):
        op.create_index(name, "products", [column])
    op.create_table(
        "product_selling_units",
        sa.Column("id", sa.String(100), primary_key=True),
        sa.Column("product_id", sa.String(100), sa.ForeignKey("products.id"), nullable=False),
        sa.Column("name", sa.String(100), nullable=False),
        sa.Column("conversion_to_base", sa.Float(), nullable=False),
        sa.Column("selling_price", sa.Float(), nullable=False),
        sa.Column("cost_price", sa.Float(), nullable=False, server_default="0"),
        sa.Column("wholesale_price", sa.Float()),
        sa.Column("barcode", sa.String(100)),
        sa.Column("is_default", sa.Boolean(), nullable=False, server_default=sa.false()),
        sa.Column("is_active", sa.Boolean(), nullable=False, server_default=sa.true()),
        sa.Column("created_at", sa.DateTime(), nullable=False, server_default=sa.func.current_timestamp()),
        sa.Column("updated_at", sa.DateTime(), nullable=False, server_default=sa.func.current_timestamp()),
    )
    op.create_index("ix_product_selling_units_product_id", "product_selling_units", ["product_id"])
    op.create_index("ix_product_selling_units_barcode", "product_selling_units", ["barcode"])


def downgrade() -> None:
    op.drop_index("ix_product_selling_units_barcode", table_name="product_selling_units")
    op.drop_index("ix_product_selling_units_product_id", table_name="product_selling_units")
    op.drop_table("product_selling_units")
    for name in ("ix_products_barcode", "ix_products_code", "ix_products_category_id", "ix_products_shop_id"):
        op.drop_index(name, table_name="products")
    op.drop_table("products")
    op.drop_index("ix_categories_shop_id", table_name="categories")
    op.drop_table("categories")
    op.drop_index("ix_devices_shop_id", table_name="devices")
    op.drop_table("devices")
    op.drop_index("ix_users_username", table_name="users")
    op.drop_index("ix_users_shop_id", table_name="users")
    op.drop_table("users")
    op.drop_table("shops")
