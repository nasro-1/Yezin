from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from decimal import Decimal, InvalidOperation
from typing import Any, Iterable, Mapping
from uuid import uuid4

from sqlalchemy import delete, or_, select
from sqlalchemy.orm import Session

from app.models import (
    FifoCostCorrection,
    InventoryLotRecord,
    SaleItemFifoAllocation,
    SaleItemFifoRestoration,
    StockMovement,
)


def _as_decimal(value: Any, default: Decimal = Decimal("0")) -> Decimal:
    if value is None:
        return default
    if isinstance(value, Decimal):
        return value
    try:
        return Decimal(str(value))
    except (InvalidOperation, ValueError, TypeError):
        return default


def _as_datetime(value: Any) -> datetime:
    if isinstance(value, datetime):
        return value
    if isinstance(value, str):
        try:
            return datetime.fromisoformat(value.replace("Z", "+00:00"))
        except ValueError:
            pass
    return datetime.utcnow()


def _fifo_order(acquired_at: datetime, movement_id: str) -> str:
    return f"{acquired_at.isoformat(timespec='microseconds')}|{movement_id}"


@dataclass(frozen=True)
class InventoryMovement:
    movement_id: str
    product_id: str
    quantity_change: Decimal
    unit_cost: Decimal
    created_at: datetime
    movement_type: str
    reference_type: str = ""
    reference_id: str = ""
    reference_line_id: str | None = None
    lineage_id: str | None = None
    cost_correction_quantity: Decimal | None = None
    cost_correction_source_movement_id: str | None = None
    fifo_restorations: tuple[tuple[str, Decimal], ...] = ()

    @classmethod
    def from_row(cls, row: Mapping[str, Any]) -> "InventoryMovement":
        quantity = _as_decimal(row.get("quantity_change"), _as_decimal(row.get("quantity")))
        return cls(
            movement_id=str(row.get("id") or row.get("movement_id") or ""),
            product_id=str(row.get("product_id") or ""),
            quantity_change=quantity,
            unit_cost=_as_decimal(row.get("unit_cost")),
            created_at=_as_datetime(row.get("created_at")),
            movement_type=str(row.get("movement_type") or ""),
            reference_type=str(row.get("reference_type") or ""),
            reference_id=str(row.get("reference_id") or ""),
            reference_line_id=(row.get("reference_line_id") or None),
            lineage_id=(row.get("lineage_id") or row.get("parent_movement_id") or None),
            cost_correction_quantity=(
                _as_decimal(row.get("cost_correction_quantity"))
                if row.get("cost_correction_quantity") is not None
                else None
            ),
            cost_correction_source_movement_id=(
                str(row.get("cost_correction_source_movement_id"))
                if row.get("cost_correction_source_movement_id")
                else None
            ),
        )

    @classmethod
    def from_orm(
        cls,
        record: StockMovement,
        *,
        correction: FifoCostCorrection | None = None,
    ) -> "InventoryMovement":
        return cls(
            movement_id=record.id,
            product_id=record.product_id,
            quantity_change=Decimal(str(record.quantity_change)),
            unit_cost=Decimal(str(record.unit_cost or 0)),
            created_at=record.created_at or datetime.utcnow(),
            movement_type=record.movement_type,
            reference_type=record.reference_type or "",
            reference_id=record.reference_id or "",
            reference_line_id=getattr(record, "reference_line_id", None),
            lineage_id=getattr(record, "lineage_id", None),
            cost_correction_quantity=(
                Decimal(str(correction.quantity))
                if correction is not None
                else None
            ),
            cost_correction_source_movement_id=(
                correction.source_movement_id
                if correction is not None
                else None
            ),
        )


@dataclass(frozen=True)
class InventoryLot:
    product_id: str
    source_type: str
    source_id: str
    source_reference: str
    movement_id: str
    received_quantity: Decimal
    remaining_quantity: Decimal
    unit_cost: Decimal
    acquired_at: datetime
    lineage_id: str | None = None
    fifo_order: str | None = None
    parent_movement_id: str | None = None

    @property
    def quantity(self) -> Decimal:
        return self.remaining_quantity

    @property
    def received_base_quantity(self) -> Decimal:
        return self.received_quantity

    @property
    def remaining_base_quantity(self) -> Decimal:
        return self.remaining_quantity

    @property
    def total_value(self) -> Decimal:
        return self.remaining_quantity * self.unit_cost

    def copy_with(self, *, remaining_quantity: Decimal | None = None, quantity: Decimal | None = None) -> "InventoryLot":
        next_remaining = self.remaining_quantity if remaining_quantity is None else remaining_quantity
        if quantity is not None:
            next_remaining = quantity
        return InventoryLot(
            product_id=self.product_id,
            source_type=self.source_type,
            source_id=self.source_id,
            source_reference=self.source_reference,
            movement_id=self.movement_id,
            received_quantity=self.received_quantity,
            remaining_quantity=next_remaining,
            unit_cost=self.unit_cost,
            acquired_at=self.acquired_at,
            lineage_id=self.lineage_id,
            fifo_order=self.fifo_order,
            parent_movement_id=self.parent_movement_id,
        )

    def to_record(self, *, shop_id: str) -> InventoryLotRecord:
        return InventoryLotRecord(
            id=f"fifo-lot-{shop_id}-{self.product_id}-{self.movement_id}",
            shop_id=shop_id,
            product_id=self.product_id,
            movement_id=self.movement_id,
            source_type=self.source_type,
            source_id=self.source_id,
            source_reference=self.source_reference or self.source_id,
            received_quantity=float(self.received_quantity),
            remaining_quantity=float(self.remaining_quantity),
            unit_cost=float(self.unit_cost),
            acquired_at=self.acquired_at,
            lineage_id=self.lineage_id,
            fifo_order=self.fifo_order,
            parent_layer_id=(
                f"fifo-lot-{shop_id}-{self.product_id}-{self.parent_movement_id}"
                if self.parent_movement_id
                else None
            ),
        )


@dataclass(frozen=True)
class InventoryCostingResult:
    consumed_quantity: Decimal
    consumed_cost: Decimal
    remaining_quantity: Decimal
    remaining_value: Decimal
    remaining_lots: list[InventoryLot]
    consumed_lots: list[InventoryLot]

    @property
    def average_cost(self) -> Decimal:
        if self.consumed_quantity <= 0:
            return Decimal("0")
        return self.consumed_cost / self.consumed_quantity


class FifoInventoryCostingService:
    """Reconstruct and persist FIFO lots from stock movement history."""

    @staticmethod
    def _canonical_source_type(movement: InventoryMovement) -> str:
        movement_type = movement.movement_type.lower()
        if movement_type == "opening_stock":
            return "opening_stock"
        if movement_type in {
            "purchase",
            "adjustment",
            "adjustment_increase",
            "replenishment",
            "supplier_return",
            "return",
            "refund",
        }:
            return "purchase"
        if movement.reference_type:
            return movement.reference_type.lower()
        return "purchase"

    @classmethod
    def build_lots_from_movements(cls, movements: Iterable[InventoryMovement]) -> list[InventoryLot]:
        lots: list[InventoryLot] = []
        for movement in sorted(movements, key=lambda item: item.created_at):
            if movement.movement_type.lower() == "cost_correction":
                source_movement_id = (
                    movement.cost_correction_source_movement_id
                    or movement.lineage_id
                )
                correction_quantity = movement.cost_correction_quantity
                source_index = next(
                    (
                        index
                        for index, lot in enumerate(lots)
                        if lot.movement_id == source_movement_id
                    ),
                    None,
                )
                if (
                    source_index is None
                    or correction_quantity is None
                    or correction_quantity <= 0
                ):
                    raise ValueError(
                        f"Invalid FIFO cost correction {movement.movement_id}."
                    )
                source = lots[source_index]
                if correction_quantity > source.remaining_quantity:
                    raise ValueError(
                        f"FIFO cost correction {movement.movement_id} exceeds "
                        "the source layer's remaining quantity."
                    )
                lots[source_index] = source.copy_with(
                    remaining_quantity=source.remaining_quantity
                    - correction_quantity
                )
                corrected = InventoryLot(
                    product_id=source.product_id,
                    source_type="cost_correction",
                    source_id=movement.reference_id,
                    source_reference=source.source_reference,
                    movement_id=movement.movement_id,
                    received_quantity=correction_quantity,
                    remaining_quantity=correction_quantity,
                    unit_cost=movement.unit_cost,
                    acquired_at=source.acquired_at,
                    lineage_id=source.movement_id,
                    fifo_order=(
                        f"{source.fifo_order or _fifo_order(source.acquired_at, source.movement_id)}"
                        f"/{movement.created_at.isoformat()}|{movement.movement_id}"
                    ),
                    parent_movement_id=source.movement_id,
                )
                lots.insert(source_index + 1, corrected)
                continue

            if (
                movement.quantity_change > 0
                and movement.movement_type.lower() in {"refund", "exchange"}
                and movement.fifo_restorations
            ):
                restored_total = Decimal("0")
                for source_movement_id, restored_quantity in movement.fifo_restorations:
                    source_index = next(
                        (
                            index
                            for index, lot in enumerate(lots)
                            if lot.movement_id == source_movement_id
                        ),
                        None,
                    )
                    if source_index is None or restored_quantity <= 0:
                        raise ValueError(
                            f"Invalid FIFO restoration for movement {movement.movement_id}."
                        )
                    source = lots[source_index]
                    lots[source_index] = source.copy_with(
                        remaining_quantity=source.remaining_quantity
                        + restored_quantity
                    )
                    restored_total += restored_quantity
                if abs(restored_total - movement.quantity_change) > Decimal("0.000001"):
                    raise ValueError(
                        f"FIFO restoration quantity does not match movement "
                        f"{movement.movement_id}."
                    )
                continue

            if movement.quantity_change <= 0:
                remaining = abs(movement.quantity_change)
                index = 0
                while remaining > Decimal("0") and index < len(lots):
                    lot = lots[index]
                    consumed = min(remaining, lot.remaining_quantity)
                    if consumed > 0:
                        updated = lot.copy_with(remaining_quantity=lot.remaining_quantity - consumed)
                        lots[index] = updated
                        remaining -= consumed
                    index += 1
                if remaining > Decimal("0"):
                    raise ValueError(
                        f"Insufficient stock for {movement.product_id} while applying {movement.movement_type}."
                    )
                continue

            if movement.unit_cost < 0:
                raise ValueError(f"Negative unit cost for movement {movement.movement_id}.")

            source_ref = movement.reference_id or movement.movement_id
            lots.append(
                InventoryLot(
                    product_id=movement.product_id,
                    source_type=cls._canonical_source_type(movement),
                    source_id=movement.reference_id,
                    source_reference=source_ref,
                    movement_id=movement.movement_id,
                    received_quantity=movement.quantity_change,
                    remaining_quantity=movement.quantity_change,
                    unit_cost=movement.unit_cost,
                    acquired_at=movement.created_at,
                    lineage_id=movement.lineage_id,
                    fifo_order=_fifo_order(
                        movement.created_at, movement.movement_id
                    ),
                )
            )
        return [lot for lot in lots if lot.remaining_quantity > 0]

    @classmethod
    def apply_reduction(
        cls,
        lots: Iterable[InventoryLot],
        requested_quantity: Decimal | int | float | str,
    ) -> InventoryCostingResult:
        requested_quantity = _as_decimal(requested_quantity)
        if requested_quantity <= 0:
            raise ValueError("requested_quantity must be positive")

        working_lots = [
            InventoryLot(
                product_id=lot.product_id,
                source_type=lot.source_type,
                source_id=lot.source_id,
                source_reference=lot.source_reference,
                movement_id=lot.movement_id,
                received_quantity=lot.received_quantity,
                remaining_quantity=lot.remaining_quantity,
                unit_cost=lot.unit_cost,
                acquired_at=lot.acquired_at,
                lineage_id=lot.lineage_id,
                fifo_order=lot.fifo_order,
                parent_movement_id=lot.parent_movement_id,
            )
            for lot in lots
        ]
        consumed_lots: list[InventoryLot] = []
        remaining_to_consume = requested_quantity
        consumed_cost = Decimal("0")

        for index, lot in enumerate(working_lots):
            if lot.remaining_quantity <= 0:
                continue
            consumed = min(remaining_to_consume, lot.remaining_quantity)
            if consumed <= 0:
                continue
            consumed_lots.append(
                InventoryLot(
                    product_id=lot.product_id,
                    source_type=lot.source_type,
                    source_id=lot.source_id,
                    source_reference=lot.source_reference,
                    movement_id=lot.movement_id,
                    received_quantity=lot.received_quantity,
                    remaining_quantity=consumed,
                    unit_cost=lot.unit_cost,
                    acquired_at=lot.acquired_at,
                    lineage_id=lot.lineage_id,
                    fifo_order=lot.fifo_order,
                    parent_movement_id=lot.parent_movement_id,
                )
            )
            consumed_cost += consumed * lot.unit_cost
            remaining_to_consume -= consumed
            working_lots[index] = lot.copy_with(remaining_quantity=lot.remaining_quantity - consumed)
            if remaining_to_consume <= 0:
                break

        if remaining_to_consume > 0:
            raise ValueError(f"Insufficient stock to consume {requested_quantity} units.")

        remaining_lots = [lot for lot in working_lots if lot.remaining_quantity > 0]
        remaining_value = sum((lot.total_value for lot in remaining_lots), Decimal("0"))
        return InventoryCostingResult(
            consumed_quantity=requested_quantity,
            consumed_cost=consumed_cost,
            remaining_quantity=sum((lot.remaining_quantity for lot in remaining_lots), Decimal("0")),
            remaining_value=remaining_value,
            remaining_lots=remaining_lots,
            consumed_lots=consumed_lots,
        )

    @classmethod
    def rebuild_lots_from_history(cls, db: Session, product_id: str, *, shop_id: str | None = None) -> list[InventoryLot]:
        stmt = select(StockMovement).where(StockMovement.product_id == product_id)
        if shop_id is not None:
            stmt = stmt.where(StockMovement.shop_id == shop_id)
        stmt = stmt.order_by(StockMovement.created_at.asc(), StockMovement.id.asc())
        rows = db.execute(stmt).scalars().all()
        corrections = db.execute(
            select(FifoCostCorrection).where(
                FifoCostCorrection.product_id == product_id,
                *(
                    [FifoCostCorrection.shop_id == shop_id]
                    if shop_id is not None
                    else []
                ),
            )
        ).scalars().all()
        correction_by_movement = {
            correction.correction_movement_id: correction
            for correction in corrections
        }
        movements = []
        for row in rows:
            movement = InventoryMovement.from_orm(row)
            restorations: tuple[tuple[str, Decimal], ...] = ()
            if row.reference_line_id and row.movement_type.lower() in {
                "refund",
                "exchange",
            }:
                restore_stmt = (
                    select(
                        InventoryLotRecord.movement_id,
                        SaleItemFifoRestoration.restored_quantity,
                    )
                    .join(
                        SaleItemFifoAllocation,
                        SaleItemFifoAllocation.inventory_lot_id
                        == InventoryLotRecord.id,
                    )
                    .join(
                        SaleItemFifoRestoration,
                        SaleItemFifoRestoration.sale_item_fifo_allocation_id
                        == SaleItemFifoAllocation.id,
                    )
                    .where(
                        SaleItemFifoAllocation.shop_id == row.shop_id,
                        InventoryLotRecord.shop_id == row.shop_id,
                        or_(
                            SaleItemFifoRestoration.refund_item_id
                            == row.reference_line_id,
                            SaleItemFifoRestoration.exchange_item_id
                            == row.reference_line_id,
                        ),
                    )
                    .order_by(
                        SaleItemFifoRestoration.created_at.asc(),
                        SaleItemFifoRestoration.id.asc(),
                    )
                )
                restorations = tuple(
                    (
                        source_movement_id,
                        Decimal(str(restored_quantity)),
                    )
                    for source_movement_id, restored_quantity in db.execute(
                        restore_stmt
                    ).all()
                )
                if restorations:
                    movement = InventoryMovement(
                        movement_id=movement.movement_id,
                        product_id=movement.product_id,
                        quantity_change=movement.quantity_change,
                        unit_cost=movement.unit_cost,
                        created_at=movement.created_at,
                        movement_type=movement.movement_type,
                        reference_type=movement.reference_type,
                        reference_id=movement.reference_id,
                        reference_line_id=movement.reference_line_id,
                        lineage_id=movement.lineage_id,
                        fifo_restorations=restorations,
                    )
            correction = correction_by_movement.get(row.id)
            if correction is not None:
                movement = InventoryMovement(
                    movement_id=movement.movement_id,
                    product_id=movement.product_id,
                    quantity_change=movement.quantity_change,
                    unit_cost=movement.unit_cost,
                    created_at=movement.created_at,
                    movement_type=movement.movement_type,
                    reference_type=movement.reference_type,
                    reference_id=movement.reference_id,
                    reference_line_id=movement.reference_line_id,
                    lineage_id=movement.lineage_id,
                    fifo_restorations=movement.fifo_restorations,
                    cost_correction_quantity=Decimal(str(correction.quantity)),
                    cost_correction_source_movement_id=correction.source_movement_id,
                )
            movements.append(movement)
        return cls.build_lots_from_movements(movements)

    @classmethod
    def sync_persisted_lots(
        cls,
        db: Session,
        product_id: str,
        *,
        shop_id: str | None = None,
        lots: list[InventoryLot] | None = None,
    ) -> list[InventoryLot]:
        if lots is None:
            try:
                lots = cls.rebuild_lots_from_history(db, product_id, shop_id=shop_id)
            except ValueError:
                # Preserve compatibility for legacy balances that have
                # movement history only for sales/refunds and no acquisition
                # layer from which FIFO state can be reconstructed.
                lots = []
        if shop_id is None:
            shop_id = db.scalar(select(StockMovement.shop_id).where(StockMovement.product_id == product_id).limit(1))
        if shop_id is None:
            return lots
        existing = {
            row.movement_id: row
            for row in db.execute(
                select(InventoryLotRecord).where(
                    InventoryLotRecord.product_id == product_id,
                    InventoryLotRecord.shop_id == shop_id,
                )
            ).scalars()
        }
        for row in existing.values():
            row.remaining_quantity = 0
        for lot in lots:
            row = existing.get(lot.movement_id)
            if row is None:
                db.add(lot.to_record(shop_id=shop_id))
            else:
                row.source_type = lot.source_type
                row.source_id = lot.source_id
                row.source_reference = lot.source_reference
                row.received_quantity = float(lot.received_quantity)
                row.remaining_quantity = float(lot.remaining_quantity)
                row.unit_cost = float(lot.unit_cost)
                row.acquired_at = lot.acquired_at
                row.lineage_id = lot.lineage_id
                row.fifo_order = lot.fifo_order
                row.parent_layer_id = (
                    f"fifo-lot-{shop_id}-{lot.product_id}-{lot.parent_movement_id}"
                    if lot.parent_movement_id
                    else None
                )
        return lots

    @classmethod
    def lots_for_product(cls, db: Session, product_id: str, *, shop_id: str | None = None) -> list[InventoryLot]:
        movement_query = select(StockMovement.id).where(
            StockMovement.product_id == product_id
        )
        if shop_id is not None:
            movement_query = movement_query.where(StockMovement.shop_id == shop_id)
        if db.scalar(movement_query.limit(1)) is None:
            lot_query = select(InventoryLotRecord).where(
                InventoryLotRecord.product_id == product_id
            )
            if shop_id is not None:
                lot_query = lot_query.where(InventoryLotRecord.shop_id == shop_id)
            records = db.execute(lot_query).scalars().all()
            movement_by_layer_id = {record.id: record.movement_id for record in records}
            return [
                InventoryLot(
                    product_id=record.product_id,
                    source_type=record.source_type,
                    source_id=record.source_id,
                    source_reference=record.source_reference,
                    movement_id=record.movement_id,
                    received_quantity=Decimal(str(record.received_quantity)),
                    remaining_quantity=Decimal(str(record.remaining_quantity)),
                    unit_cost=Decimal(str(record.unit_cost)),
                    acquired_at=record.acquired_at or datetime.utcnow(),
                    lineage_id=record.lineage_id,
                    fifo_order=record.fifo_order,
                    parent_movement_id=movement_by_layer_id.get(
                        record.parent_layer_id
                    ),
                )
                for record in records
                if record.remaining_quantity > 0
            ]
        lots = cls.rebuild_lots_from_history(db, product_id, shop_id=shop_id)
        return cls.sync_persisted_lots(db, product_id, shop_id=shop_id, lots=lots)

    @classmethod
    def create_positive_lot(
        cls,
        db: Session,
        *,
        product_id: str,
        shop_id: str,
        quantity: Decimal | int | float | str,
        unit_cost: Decimal | int | float | str,
        movement_id: str,
        source_type: str,
        source_id: str | None = None,
        source_reference: str | None = None,
        acquired_at: datetime | None = None,
        lineage_id: str | None = None,
    ) -> InventoryLot:
        quantity = _as_decimal(quantity)
        unit_cost = _as_decimal(unit_cost)
        if quantity <= 0:
            raise ValueError("quantity must be positive")
        if unit_cost < 0:
            raise ValueError("unit_cost cannot be negative")

        acquired_at_value = acquired_at or datetime.utcnow()
        lot = InventoryLot(
            product_id=product_id,
            source_type=source_type,
            source_id=source_id or source_reference or movement_id,
            source_reference=source_reference or (source_id or movement_id),
            movement_id=movement_id,
            received_quantity=quantity,
            remaining_quantity=quantity,
            unit_cost=unit_cost,
            acquired_at=acquired_at_value,
            lineage_id=lineage_id,
            fifo_order=_fifo_order(acquired_at_value, movement_id),
        )
        existing = cls.lots_for_product(db, product_id, shop_id=shop_id)
        cls.sync_persisted_lots(db, product_id, shop_id=shop_id, lots=[*existing, lot])
        return lot

    @classmethod
    def consume_and_persist(
        cls,
        db: Session,
        product_id: str,
        requested_quantity: Decimal | int | float | str,
        *,
        shop_id: str | None = None,
    ) -> InventoryCostingResult:
        try:
            lots = cls.lots_for_product(db, product_id, shop_id=shop_id)
        except ValueError:
            # A legacy sale can be posted against an opening Product.stock
            # balance before any positive acquisition movement exists.
            return InventoryCostingResult(
                consumed_quantity=Decimal("0"),
                consumed_cost=Decimal("0"),
                remaining_quantity=Decimal("0"),
                remaining_value=Decimal("0"),
                remaining_lots=[],
                consumed_lots=[],
            )
        if not lots:
            # Legacy products may have an operational stock balance without
            # acquisition movements. Keep their existing Product.cost
            # fallback usable until a FIFO lot is created.
            return InventoryCostingResult(
                consumed_quantity=Decimal("0"),
                consumed_cost=Decimal("0"),
                remaining_quantity=Decimal("0"),
                remaining_value=Decimal("0"),
                remaining_lots=[],
                consumed_lots=[],
            )
        result = cls.apply_reduction(lots, requested_quantity)
        cls.sync_persisted_lots(db, product_id, shop_id=shop_id, lots=result.remaining_lots)
        return result

    @classmethod
    def consume_and_persist_for_sale_item(
        cls,
        db: Session,
        *,
        product_id: str,
        sale_item_id: str,
        requested_quantity: Decimal | int | float | str,
        shop_id: str,
    ) -> InventoryCostingResult:
        try:
            lots = cls.lots_for_product(db, product_id, shop_id=shop_id)
        except ValueError:
            lots = []
        if not lots:
            return InventoryCostingResult(
                consumed_quantity=Decimal("0"),
                consumed_cost=Decimal("0"),
                remaining_quantity=Decimal("0"),
                remaining_value=Decimal("0"),
                remaining_lots=[],
                consumed_lots=[],
            )
        result = cls.apply_reduction(lots, requested_quantity)
        cls.sync_persisted_lots(db, product_id, shop_id=shop_id, lots=result.remaining_lots)
        records = {
            row.movement_id: row
            for row in db.execute(
                select(InventoryLotRecord).where(
                    InventoryLotRecord.product_id == product_id,
                    InventoryLotRecord.shop_id == shop_id,
                )
            ).scalars()
        }
        for consumed in result.consumed_lots:
            record = records.get(consumed.movement_id)
            if record is None:
                continue
            allocation = db.scalar(
                select(SaleItemFifoAllocation).where(
                    SaleItemFifoAllocation.sale_item_id == sale_item_id,
                    SaleItemFifoAllocation.inventory_lot_id == record.id,
                )
            )
            if allocation is None:
                allocation = SaleItemFifoAllocation(
                    id=f"fifo-allocation-{uuid4().hex}",
                    shop_id=shop_id,
                    sale_item_id=sale_item_id,
                    inventory_lot_id=record.id,
                    allocated_quantity=0,
                    restored_quantity=0,
                    unit_cost_at_sale=float(consumed.unit_cost),
                    created_at=datetime.utcnow(),
                )
                db.add(allocation)
            elif allocation.unit_cost_at_sale is None:
                allocation.unit_cost_at_sale = float(consumed.unit_cost)
            allocation.allocated_quantity += float(consumed.remaining_quantity)
        db.flush()
        return result

    @classmethod
    def consume_quantity(
        cls,
        db: Session,
        product_id: str,
        requested_quantity: Decimal | int | float | str,
        *,
        shop_id: str | None = None,
    ) -> InventoryCostingResult:
        lots = cls.lots_for_product(db, product_id, shop_id=shop_id)
        return cls.apply_reduction(lots, requested_quantity)

    @classmethod
    def unit_cost_for_quantity(
        cls,
        db: Session,
        product_id: str,
        requested_quantity: Decimal | int | float | str,
        *,
        shop_id: str | None = None,
    ) -> Decimal:
        requested_quantity = _as_decimal(requested_quantity)
        if requested_quantity <= 0:
            return Decimal("0")
        try:
            result = cls.consume_quantity(db, product_id, requested_quantity, shop_id=shop_id)
        except ValueError:
            return Decimal("0")
        if result.consumed_quantity <= 0:
            return Decimal("0")
        return result.consumed_cost / result.consumed_quantity


__all__ = [
    "FifoInventoryCostingService",
    "InventoryCostingResult",
    "InventoryLot",
    "InventoryMovement",
]
