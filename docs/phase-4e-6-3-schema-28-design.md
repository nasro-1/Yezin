# PHASE 4E.6.3 — FINAL DESIGN APPROVAL

This document records the approved Schema 28 design. It is design-only.
No SQL in this document has been executed.

## Product unit policy

- `STANDARD`: integer quantity, base unit `piece`.
- `WEIGHTED`: decimal quantity, with product-configured precision. The default
  precision is 3 decimal places.
- `PACKAGED`: one product, one base unit, and multiple explicitly configured
  selling units. Each selling unit has its own conversion and price.

## Partial package rule

`allow_partial_package_sale` is a product-level setting.

When it is enabled, a smaller sale is allowed only when the smaller selling
unit exists explicitly in `product_selling_units`. The system must never infer
or synthesize a smaller selling unit.

For example, if `Pack` has conversion `6`, individual bottles may be sold only
when an explicit `Bottle` selling unit with conversion `1` exists.

All availability checks and stock movements use the authoritative base-unit
quantity. The setting does not create independent pack or bottle stock.

## Weighted precision

Weighted precision is a product configuration property, for example:

```text
products.quantity_precision = 3
```

The default is 3 decimal places. The implementation must validate and preserve
quantities at the configured precision without truncating them to integers.
Future unit types must not be forced into one global scale unless their product
configuration explicitly selects it.

## Identity and barcode model

```text
products.id                         immutable database identity
products.internal_reference         stable unique business reference
products.barcode                    optional legacy/product barcode
product_selling_units.id            commercial selling-unit identity
product_selling_units.barcode       optional unit barcode
```

`internal_reference` is generated once, independently of name and barcode,
using the transactional document sequence. It remains stable after renaming.
Barcodes are never primary keys.

Unit barcodes are globally unique when non-null and must not collide with a
non-null legacy product barcode. Lookup precedence is:

1. Exact selling-unit barcode.
2. Exact legacy product barcode, resolved to the active default unit.
3. Not found.

Any ambiguous collision is an explicit data-integrity error; lookup must never
silently choose a product.

## Schema 28 target

Retain all existing `products` columns and add:

```text
internal_reference TEXT NOT NULL UNIQUE
product_type TEXT NOT NULL DEFAULT 'STANDARD'
base_unit TEXT NOT NULL DEFAULT 'piece'
quantity_precision INTEGER NOT NULL DEFAULT 3
allow_partial_package_sale INTEGER NOT NULL DEFAULT 0
```

Create `product_selling_units` with:

```text
id TEXT PRIMARY KEY NOT NULL
product_id TEXT NOT NULL
name TEXT NOT NULL
conversion_to_base REAL NOT NULL
selling_price REAL NOT NULL
wholesale_price REAL
barcode TEXT
is_default INTEGER NOT NULL DEFAULT 0
is_active INTEGER NOT NULL DEFAULT 1
created_at TEXT NOT NULL
updated_at TEXT NOT NULL
```

Required constraints include positive conversion, nonnegative prices, allowed
product types, positive precision, boolean flags, product ownership, unique
unit names per product, globally unique non-null unit barcodes, and at most
one active default unit per product.

The following nullable snapshot columns are added to `sale_items`,
`purchase_items`, and `exchange_items` as applicable:

```text
selling_unit_id
selling_quantity
base_quantity
conversion_factor_snapshot
selling_unit_name_snapshot
base_unit_snapshot
```

Exchange items store independent original and replacement snapshots. Refunds
continue to use refund `sales` and `sale_items`; no separate refund table is
required.

## Legacy transaction contract

After Schema 28, legacy transaction rows with `selling_unit_id IS NULL` remain
fully supported.

```text
if selling_unit_id IS NULL:
    use legacy quantity/price semantics

if selling_unit_id IS NOT NULL:
    use unit-aware selling_quantity,
    base_quantity,
    conversion_factor_snapshot,
    and historical selling-unit snapshot
```

No existing historical sale, refund, purchase, or exchange may be invalidated
because its new unit fields are `NULL`.

Legacy products preserve their IDs, barcodes, names, prices, costs, stock, and
timestamps. They are classified as `STANDARD` with base unit `piece`, receive a
stable internal reference, and may receive one compatibility selling unit with
conversion `1`. Historical transaction rows are not rewritten and do not
receive invented package or unit information.

## Financial and inventory equations

```text
base_quantity = selling_quantity × conversion_to_base
stock_delta = ± base_quantity
financial_total = selling_quantity × selling_unit_price
```

Selling-unit price and conversion snapshots are authoritative for the
transaction. Stock uses base quantity; cash and ledgers use the financial
total. Historical transactions never consult current product configuration.

## Refund and exchange behavior

- One bottle refund restores `1` base unit.
- One pack refund restores its historical conversion, for example `6` bottles.
- A weighted refund such as `0.300 kg` restores exactly `0.300 kg`.
- Refund availability is measured in original base quantity.
- `1 pack → 2 bottles`, `2 bottles → 1 pack`, and `1 pack → 1 pack` are
  validated in base units.
- Exchange financial difference uses historical original and replacement
  selling values.
- Partial package behavior is allowed only through explicitly configured
  selling units and the product policy.

## Migration 27 → 28 plan

1. Acquire the write lock and create a timestamped database/WAL/SHM backup.
2. Record schema, DDL, row counts, stock totals, sales totals, cash totals,
   and ledger totals.
3. Add and populate product metadata, generating unique internal references.
4. Create the selling-unit table and compatibility units for legacy products.
5. Add nullable transaction snapshot columns.
6. Preserve all legacy transaction values and leave their unit fields `NULL`.
7. Create indexes, foreign keys, checks, and validation triggers.
8. Verify row counts, aggregates, references, uniqueness, and stock totals.
9. Run `PRAGMA foreign_key_check` and `PRAGMA integrity_check`.
10. Commit only after all checks pass; otherwise roll back and restore backup.

## Acceptance gates

### Migration gate

Pass only if backup, row counts, financial aggregates, stock totals,
`foreign_key_check`, and `integrity_check` all pass. Legacy rows with
`selling_unit_id IS NULL` must remain readable and operational.

### Model gate

Pass only if standard quantities remain integer-based, weighted quantities
preserve the configured decimal precision, and packaged products use explicit
selling units only. Partial package sales must reject absent smaller units.

### Sales, stock, refund, and exchange gates

Pass only if:

- NULL unit fields invoke legacy quantity/price semantics.
- Non-NULL unit fields use selling/base quantities and snapshots.
- Stock posts base quantities.
- Financial totals use selling-unit prices.
- Refunds use historical conversion snapshots.
- Exchanges validate returned/replacement base quantities and use historical
  prices.

### Reporting and POS gates

Pass only if legacy rows with NULL unit fields remain displayable and
reportable, while unit-aware rows display their historical selling unit,
selling quantity, base quantity, price, and total.

### Historical compatibility gate

Pass only if no historical sale, refund, purchase, or exchange is invalidated,
rewritten, or reinterpreted merely because new unit fields are `NULL`.

## Implementation status

Production changes: `0`

SQL executed: `NO`

Migration created: `NO`

Production database: `NOT TOUCHED`

## Final approval

All three clarifications added: `PASS`

Schema 28 design: `APPROVED FOR IMPLEMENTATION`

**PHASE 4E.6.3 DESIGN APPROVED — IMPLEMENTATION MAY BEGIN**
