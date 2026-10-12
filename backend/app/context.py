from dataclasses import dataclass
from enum import StrEnum

from app.models import User


@dataclass(frozen=True)
class ServerContext:
    """Authenticated request context shared by application services."""

    user_id: str
    shop_id: str
    role: str
    device_id: str | None = None

    @classmethod
    def from_user(cls, user: User, device_id: str | None = None) -> "ServerContext":
        return cls(
            user_id=user.id,
            shop_id=user.shop_id,
            role=user.role,
            device_id=device_id,
        )


def require_shop_match(context: ServerContext, shop_id: str) -> None:
    if context.shop_id != shop_id:
        raise ValueError("Cross-shop access is not permitted")


class Role(StrEnum):
    ADMIN = "admin"
    MANAGER = "manager"
    CASHIER = "cashier"


class Permission(StrEnum):
    READ_CATALOG = "read_catalog"
    READ_SUPPLIERS = "read_suppliers"
    MANAGE_CATALOG = "manage_catalog"
    MANAGE_SUPPLIERS = "manage_suppliers"
    POST_STOCK_ADJUSTMENT = "post_stock_adjustment"
    POST_SALE = "post_sale"
    POST_PURCHASE = "post_purchase"
    POST_SUPPLIER_PAYMENT = "post_supplier_payment"
    POST_SUPPLIER_RETURN = "post_supplier_return"
    POST_REFUND = "post_refund"
    POST_EXCHANGE = "post_exchange"
    VIEW_ANALYTICS = "view_analytics"
    VIEW_STOCK_SUMMARY = "view_stock_summary"


_ROLE_PERMISSIONS = {
    Role.ADMIN: frozenset(Permission),
    Role.MANAGER: frozenset(
        {Permission.READ_CATALOG, Permission.READ_SUPPLIERS, Permission.MANAGE_SUPPLIERS,
         Permission.MANAGE_CATALOG, Permission.POST_STOCK_ADJUSTMENT,
         Permission.POST_SALE, Permission.POST_PURCHASE, Permission.POST_REFUND, Permission.POST_EXCHANGE,
         Permission.POST_SUPPLIER_PAYMENT, Permission.POST_SUPPLIER_RETURN,
         Permission.VIEW_ANALYTICS, Permission.VIEW_STOCK_SUMMARY}
    ),
    Role.CASHIER: frozenset({Permission.READ_CATALOG}),
}


def require_permission(context: ServerContext, permission: Permission) -> None:
    try:
        role = Role(context.role)
    except ValueError as error:
        raise PermissionError("Unknown role") from error
    if permission not in _ROLE_PERMISSIONS[role]:
        raise PermissionError(f"Role {role.value} cannot perform {permission.value}")
