from decimal import Decimal


def decimal_amount(value: object) -> Decimal:
    """Convert API numeric values without introducing binary float rounding."""

    return Decimal(str(value))


def multiply_amount(quantity: object, unit_cost: object) -> Decimal:
    return decimal_amount(quantity) * decimal_amount(unit_cost)
