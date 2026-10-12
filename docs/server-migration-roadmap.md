# Bayaa Server Migration Roadmap

This roadmap is based on the repository audit. It does not migrate Sales or
change current Product, Category, or Stock Adjustment behavior.

## Phase 0 - Shared infrastructure (completed foundation)

Build once before migrating another transactional domain:

- Standard `ApiError`, status mapping, timeout, UTF-8, request IDs, and
  redacted logging in `BackendApiClient`.
- JWT expiry/refresh/logout and one authenticated request pipeline.
- Injected `DataAuthorityContext` and one configured repository graph.
- Central tenant/shop scope and role/permission dependencies.
- Command envelope with idempotency key, request hash, replayable result.
- Standard paged query/response and server ID/display-name mapping rules.
- Server document/status/audit conventions.
- Outbox/event and query invalidation contracts, without WebSocket yet.
- Backend migration/test harness against a fresh database.

Implemented in this phase:

- Shared authenticated `BackendApiClient` transport for all four HTTP verbs.
- Real JWT bearer injection, UTF-8 JSON content type, bounded timeouts, and
  typed transport/API errors.
- Shared client/server auth context and identity-mapping primitives.
- Reusable server authority vocabulary and backend transaction/context/stock
  contract helpers.
- Development startup checklist for detecting stale Uvicorn processes.
- Regression tests for bearer injection, status-code error kinds, UTF-8, and
  existing Product/Category/Stock Adjustment API paths.

Completed in the current Phase 0 foundation:

- Centralized role/permission enforcement for admin, manager, and cashier.
- Tenant-scoped persistent idempotency records with request hashes and replay.
- Draft/posted/cancelled/reversed lifecycle primitives.
- Decimal-safe financial arithmetic helpers and a documented Numeric migration plan.
- Reusable Decimal transactional contracts for customer ledger, payments, cash
  movements, and future documents.
- Shared authority context in the configured Flutter repository graph.
- JWT identifiers, revocation persistence, logout, and centralized 401 observability.
- Authenticated device context propagation into command infrastructure.

Intentionally deferred:

- Refresh-token rotation and external identity providers.
- Full Decimal/Numeric persistence migration for existing financial columns.
- Sales endpoints and posting remain deferred; future financial models must use
  SQLAlchemy `Numeric`/`Decimal`, never `Float`.
- Outbox persistence and event delivery.
- Retrofitting existing Product, Category, or Stock Adjustment records to lifecycle states.
- Wiring every future domain into the command service before that domain is migrated.

Exit criteria: existing Product, Category, and Stock Adjustment tests remain
green, a server-mode repository cannot invoke a local fallback, and the
remaining items above are explicitly deferred. The shared prerequisites for
server-authoritative Sales are now present; Sales itself must remain a later
phase after inventory, customer ledger, payment, cash, and invoice contracts
are implemented.

## Phase 1 - Master data

Preserve the current working server behavior and extend the same template to:

1. Users, roles, devices, and active shop context.
2. Shop settings versus device-local settings.
3. Categories and Products, including selling units and barcode uniqueness.
4. Customers.
5. Suppliers.

Each master-data domain needs list/detail/create/update/deactivate, tenant
isolation, role checks, Flutter API repository, mode-aware domain repository,
and refresh after mutation.

## Phase 2 - Inventory

Establish one server stock document/posting service:

1. Normalize opening stock into a general stock document shape.
2. Align stock adjustments with multi-line documents and replayable idempotency.
3. Add stock movement/history reads.
4. Add purchase stock-in and supplier-return stock-out.
5. Add sales-return and exchange stock effects.
6. Add quantity/unit conversion and concurrency protection.

No feature may update the product stock projection outside this service.

## Phase 3 - Sales

Only after Phase 0-2:

1. Product/barcode/selling-unit lookup.
2. Customer selection and credit policy.
3. Cart remains temporary client state.
4. `POST /sales` atomically posts sale, lines, stock decrement, movements,
   customer ledger, invoice/payment, and cash entries.
5. Add sale history, void, refund, and cross-device refresh.
6. Preserve local mode through the existing local repository.

Do not implement a client-side stock decrement or local fallback.

## Phase 4 - Purchases

- Purchase header/lines and supplier selection.
- Atomic stock-in, purchase ledger, supplier balance, and payment.
- Purchase history and supplier returns.
- Reuse the same document, money, stock, and idempotency infrastructure.

## Phase 5 - Financials

- Shifts and cash registers.
- Cash movements and reconciliation.
- Expenses plus cash movement.
- Customer/supplier payments and balance projections.
- Decimal money policy, audit, and reversal operations.

## Phase 6 - Orders, proformas, exchanges

- Server draft/status lifecycle.
- Reservation policy, if required.
- Order/proforma conversion to sale without double posting.
- Exchange document linking sale/return/replacement and both stock/financial
  effects.

## Phase 7 - Reports and analytics

- Server read models for stock, sales, purchases, balances, cash, and margins.
- Cursor/pagination and date/shop filters.
- Cross-device report refresh.
- Keep PDF generation client-side only when it consumes an authoritative
  server snapshot.

## Phase 8 - Offline and synchronization

This is a separate product decision, not a hidden fallback:

- Explicit cache classification.
- Durable client outbox for approved commands.
- Replay using idempotency keys.
- Conflict policy per document type.
- `updated_since`/cursor recovery.
- Never treat a stale cache as authoritative.

## Phase 9 - Event delivery

- Transactional outbox.
- WebSocket or SSE invalidation delivery.
- Event deduplication and missed-event recovery.
- Business logic remains in command services; events only invalidate/refetch.

## Per-domain completion gate

Before declaring a domain migrated:

1. Backend model, migration, schemas, routes, authorization, tenant tests.
2. Atomic service boundary for every business command.
3. Idempotency and retry/replay tests.
4. Flutter API client and API repository.
5. Mode-aware domain repository with no server-to-local fallback.
6. Cubit/BLoC refresh and error handling.
7. Local-mode regression tests.
8. Server-mode request/response tests.
9. Android and Windows cross-device verification.
10. Documentation of history/report read paths.

## Immediate next step

Implement Phase 0 only. Do not start Sales until the shared infrastructure
exit criteria and the Sales prerequisites in
[server-authoritative-architecture.md](server-authoritative-architecture.md)
are satisfied.
