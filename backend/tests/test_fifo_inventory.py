
from datetime import datetime
from decimal import Decimal

from sqlalchemy import create_engine, select
from sqlalchemy.orm import Session

from app.database import Base, configure_sqlite_foreign_keys
from app.fifo_inventory import FifoInventoryCostingService, InventoryMovement
from app.returns_service import _restore_fifo_allocations
from app.models import (
    InventoryLotRecord,
    Product,
    SaleDocument,
    SaleItem,
    SaleItemFifoAllocation,
    Shop,
    StockMovement,
)


def test_fifo_handles_multi_lot_acquisitions_and_sale_spanning_lots() -> None:
    service = FifoInventoryCostingService()
    lots = service.build_lots_from_movements([
        InventoryMovement(
            movement_id='purchase-1',
            product_id='p-1',
            quantity_change=Decimal('10'),
            unit_cost=Decimal('5.00'),
            created_at=datetime(2024, 1, 1),
            movement_type='purchase',
            reference_type='purchase',
            reference_id='purchase-1',
        ),
        InventoryMovement(
            movement_id='purchase-2',
            product_id='p-1',
            quantity_change=Decimal('6'),
            unit_cost=Decimal('7.00'),
            created_at=datetime(2024, 1, 2),
            movement_type='purchase',
            reference_type='purchase',
            reference_id='purchase-2',
        ),
    ])

    result = service.apply_reduction(lots, Decimal('12'))

    assert result.consumed_quantity == Decimal('12')
    assert result.consumed_cost == Decimal('10') * Decimal('5.00') + Decimal('2') * Decimal('7.00')
    assert result.remaining_quantity == Decimal('4')
    assert result.remaining_value == Decimal('28.00')
    assert result.remaining_lots[0].unit_cost == Decimal('7.00')


def test_opening_stock_movements_keep_their_fifo_source_type() -> None:
    lots = FifoInventoryCostingService.build_lots_from_movements([
        InventoryMovement(
            movement_id="opening-1",
            product_id="p-1",
            quantity_change=Decimal("10"),
            unit_cost=Decimal("100"),
            created_at=datetime(2024, 1, 1),
            movement_type="opening_stock",
            reference_type="opening_stock",
            reference_id="opening-1",
        ),
    ])

    assert len(lots) == 1
    assert lots[0].source_type == "opening_stock"
    assert lots[0].remaining_quantity == Decimal("10")
    assert lots[0].total_value == Decimal("1000")


def test_fifo_tracks_current_valuation_across_remaining_lots() -> None:
    service = FifoInventoryCostingService()
    lots = service.build_lots_from_movements([
        InventoryMovement(
            movement_id='purchase-1',
            product_id='p-1',
            quantity_change=Decimal('15'),
            unit_cost=Decimal('3.50'),
            created_at=datetime(2024, 1, 1),
            movement_type='purchase',
            reference_type='purchase',
            reference_id='purchase-1',
        ),
        InventoryMovement(
            movement_id='purchase-2',
            product_id='p-1',
            quantity_change=Decimal('8'),
            unit_cost=Decimal('4.25'),
            created_at=datetime(2024, 1, 3),
            movement_type='purchase',
            reference_type='purchase',
            reference_id='purchase-2',
        ),
        InventoryMovement(
            movement_id='sale-1',
            product_id='p-1',
            quantity_change=Decimal('-12'),
            unit_cost=Decimal('3.50'),
            created_at=datetime(2024, 1, 4),
            movement_type='sale',
            reference_type='sale',
            reference_id='sale-1',
        ),
    ])

    assert len(lots) == 2
    assert lots[0].remaining_quantity == Decimal('3')
    assert lots[0].unit_cost == Decimal('3.50')
    assert lots[-1].remaining_quantity == Decimal('8')
    assert lots[-1].unit_cost == Decimal('4.25')
    assert sum((lot.total_value for lot in lots), Decimal('0')) == Decimal('3') * Decimal('3.50') + Decimal('8') * Decimal('4.25')


def test_fifo_preserves_refund_and_exchange_lineage_on_stock_movement_records() -> None:
    service = FifoInventoryCostingService()
    movements = [
        InventoryMovement(
            movement_id='purchase-1',
            product_id='p-1',
            quantity_change=Decimal('10'),
            unit_cost=Decimal('8.00'),
            created_at=datetime(2024, 1, 1),
            movement_type='purchase',
            reference_type='purchase',
            reference_id='purchase-1',
        ),
        InventoryMovement(
            movement_id='sale-1',
            product_id='p-1',
            quantity_change=Decimal('-6'),
            unit_cost=Decimal('8.00'),
            created_at=datetime(2024, 1, 2),
            movement_type='sale',
            reference_type='sale',
            reference_id='sale-1',
        ),
        InventoryMovement(
            movement_id='refund-1',
            product_id='p-1',
            quantity_change=Decimal('2'),
            unit_cost=Decimal('8.00'),
            created_at=datetime(2024, 1, 3),
            movement_type='refund',
            reference_type='refund',
            reference_id='refund-1',
            lineage_id='sale-1',
        ),
        InventoryMovement(
            movement_id='exchange-1',
            product_id='p-1',
            quantity_change=Decimal('-1'),
            unit_cost=Decimal('8.00'),
            created_at=datetime(2024, 1, 4),
            movement_type='exchange',
            reference_type='exchange',
            reference_id='exchange-1',
            lineage_id='sale-1',
        ),
    ]

    lots = service.build_lots_from_movements(movements)
    assert lots[-1].source_type == 'purchase'
    assert movements[2].reference_type == 'refund'
    assert movements[2].lineage_id == 'sale-1'
    assert movements[3].reference_type == 'exchange'
    assert movements[3].lineage_id == 'sale-1'
    assert sum((lot.remaining_quantity for lot in lots), Decimal('0')) == Decimal('5')


def test_fifo_persists_remaining_lots_and_sale_cogs_in_db() -> None:
    engine = create_engine('sqlite:///:memory:')
    configure_sqlite_foreign_keys(engine)
    Base.metadata.create_all(bind=engine)
    with Session(engine) as db:
        shop = Shop(id='shop-1', name='Demo')
        product = Product(
            id='p-1',
            shop_id='shop-1',
            name='Widget',
            code='W-1',
            price=0,
            cost=0,
            stock=0,
            min_stock=0,
            is_active=True,
            product_type='STANDARD',
            base_unit='piece',
            quantity_precision=3,
        )
        db.add(shop)
        db.flush()
        db.add(product)
        db.flush()

        db.add_all([
            StockMovement(
                id='m1',
                shop_id='shop-1',
                product_id='p-1',
                movement_type='purchase',
                quantity_change=10.0,
                unit_cost=5.0,
                running_stock=10.0,
                reference_type='purchase',
                reference_id='po-1',
                created_at=datetime(2024, 1, 1),
            ),
            StockMovement(
                id='m2',
                shop_id='shop-1',
                product_id='p-1',
                movement_type='purchase',
                quantity_change=6.0,
                unit_cost=7.0,
                running_stock=16.0,
                reference_type='purchase',
                reference_id='po-2',
                created_at=datetime(2024, 1, 2),
            ),
        ])
        db.flush()
        lots = FifoInventoryCostingService.rebuild_lots_from_history(db, 'p-1', shop_id='shop-1')
        FifoInventoryCostingService.sync_persisted_lots(db, 'p-1', shop_id='shop-1', lots=lots)

        pre_sale_cost = FifoInventoryCostingService.unit_cost_for_quantity(db, 'p-1', Decimal('12'), shop_id='shop-1')
        assert pre_sale_cost == Decimal('64') / Decimal('12')

        result = FifoInventoryCostingService.consume_and_persist(
            db,
            'p-1',
            Decimal('12'),
            shop_id='shop-1',
        )
        assert result.consumed_cost == Decimal('64.00')
        assert result.remaining_quantity == Decimal('4')

        persisted = db.execute(
            select(InventoryLotRecord)
            .where(InventoryLotRecord.product_id == 'p-1')
            .order_by(InventoryLotRecord.acquired_at.asc(), InventoryLotRecord.movement_id.asc())
        ).scalars().all()
        assert sum(record.remaining_quantity for record in persisted) == 4.0
        assert persisted[-1].unit_cost == 7.0


def test_fifo_persists_exact_sale_item_lot_allocations() -> None:
    engine = create_engine("sqlite:///:memory:")
    configure_sqlite_foreign_keys(engine)
    Base.metadata.create_all(bind=engine)
    with Session(engine) as db:
        db.add(Shop(id="shop-1", name="Demo"))
        db.flush()
        db.add(Product(
            id="p-1", shop_id="shop-1", name="Widget", base_unit="piece",
            price=0, cost=0, stock=200, min_stock=0, is_active=True,
            product_type="STANDARD", quantity_precision=3,
        ))
        db.flush()
        db.add_all([
            StockMovement(
                id="m1", shop_id="shop-1", product_id="p-1",
                movement_type="purchase", quantity_change=100, unit_cost=5,
                running_stock=100, reference_type="purchase",
                reference_id="po-1", created_at=datetime(2024, 1, 1),
            ),
            StockMovement(
                id="m2", shop_id="shop-1", product_id="p-1",
                movement_type="purchase", quantity_change=100, unit_cost=8,
                running_stock=200, reference_type="purchase",
                reference_id="po-2", created_at=datetime(2024, 1, 2),
            ),
        ])
        sale = SaleDocument(
            id="sale-1", shop_id="shop-1", idempotency_key="sale-1",
            document_reference="SALE-1", status="POSTED", payment_method="cash",
            subtotal=0, discount=0, total=0, payment_result=0,
            remaining_amount=0, stock_posting_reference="sale:sale-1",
            posted_by="admin", posted_at=datetime(2024, 1, 3),
        )
        item = SaleItem(
            id="sale-item-1", sale_id="sale-1", product_id="p-1",
            unit="piece", quantity=150, base_quantity=150, unit_price=1,
            line_total=150, refunded_quantity=0, exchanged_quantity=0,
        )
        db.add(sale)
        db.flush()
        db.add(item)
        db.flush()
        lots = FifoInventoryCostingService.rebuild_lots_from_history(
            db, "p-1", shop_id="shop-1"
        )
        FifoInventoryCostingService.sync_persisted_lots(
            db, "p-1", shop_id="shop-1", lots=lots
        )
        result = FifoInventoryCostingService.consume_and_persist_for_sale_item(
            db, product_id="p-1", sale_item_id=item.id,
            requested_quantity=150, shop_id="shop-1",
        )
        db.flush()

        allocations = db.execute(
            select(SaleItemFifoAllocation)
            .where(SaleItemFifoAllocation.sale_item_id == item.id)
            .order_by(SaleItemFifoAllocation.created_at, SaleItemFifoAllocation.id)
        ).scalars().all()
        persisted = db.execute(
            select(InventoryLotRecord)
            .where(InventoryLotRecord.product_id == "p-1")
            .order_by(InventoryLotRecord.acquired_at)
        ).scalars().all()
        assert result.consumed_cost == Decimal("900")
        assert [(row.allocated_quantity, row.inventory_lot_id) for row in allocations] == [
            (100.0, persisted[0].id),
            (50.0, persisted[1].id),
        ]
        assert [row.remaining_quantity for row in persisted] == [0.0, 50.0]
        assert sum(row.remaining_quantity for row in persisted) == 50.0
        assert sum(row.remaining_quantity * row.unit_cost for row in persisted) == 400.0


def test_fifo_refund_restores_last_sale_allocations_across_repeated_refunds() -> None:
    engine = create_engine("sqlite:///:memory:")
    configure_sqlite_foreign_keys(engine)
    Base.metadata.create_all(bind=engine)
    with Session(engine) as db:
        db.add(Shop(id="shop-1", name="Demo"))
        db.flush()
        db.add(Product(
            id="p-1", shop_id="shop-1", name="Widget", base_unit="piece",
            price=0, cost=0, stock=150, min_stock=0, is_active=True,
            product_type="STANDARD", quantity_precision=3,
        ))
        db.flush()
        db.add_all([
            StockMovement(
                id="m1", shop_id="shop-1", product_id="p-1",
                movement_type="purchase", quantity_change=100, unit_cost=5,
                running_stock=100, reference_type="purchase",
                reference_id="po-1", created_at=datetime(2024, 1, 1),
            ),
            StockMovement(
                id="m2", shop_id="shop-1", product_id="p-1",
                movement_type="purchase", quantity_change=50, unit_cost=8,
                running_stock=150, reference_type="purchase",
                reference_id="po-2", created_at=datetime(2024, 1, 2),
            ),
        ])
        sale = SaleDocument(
            id="sale-1", shop_id="shop-1", idempotency_key="sale-1",
            document_reference="SALE-1", status="POSTED", payment_method="cash",
            subtotal=0, discount=0, total=0, payment_result=0,
            remaining_amount=0, stock_posting_reference="sale:sale-1",
            posted_by="admin", posted_at=datetime(2024, 1, 3),
        )
        item = SaleItem(
            id="sale-item-1", sale_id="sale-1", product_id="p-1",
            unit="piece", quantity=150, base_quantity=150, unit_price=1,
            line_total=150, refunded_quantity=0, exchanged_quantity=0,
        )
        db.add(sale)
        db.flush()
        db.add(item)
        db.flush()
        lots = FifoInventoryCostingService.rebuild_lots_from_history(
            db, "p-1", shop_id="shop-1"
        )
        FifoInventoryCostingService.sync_persisted_lots(
            db, "p-1", shop_id="shop-1", lots=lots
        )
        FifoInventoryCostingService.consume_and_persist_for_sale_item(
            db, product_id="p-1", sale_item_id=item.id,
            requested_quantity=150, shop_id="shop-1",
        )
        first_cost = _restore_fifo_allocations(
            db, item=item, base_quantity=20, shop_id="shop-1"
        )
        second_cost = _restore_fifo_allocations(
            db, item=item, base_quantity=40, shop_id="shop-1"
        )
        db.flush()
        persisted = db.execute(
            select(InventoryLotRecord)
            .where(InventoryLotRecord.product_id == "p-1")
            .order_by(InventoryLotRecord.acquired_at)
        ).scalars().all()
        assert first_cost == Decimal("160")
        assert second_cost == Decimal("290")
        assert [row.remaining_quantity for row in persisted] == [10.0, 50.0]
