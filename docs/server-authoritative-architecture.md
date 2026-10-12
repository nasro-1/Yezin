# Bayaa Server-Authoritative Architecture

Status: architecture and audit baseline. This document does not migrate Sales or
change runtime behavior.

## 1. Current architecture

The application is a Flutter client with a local SQLite database and a small
FastAPI/SQLAlchemy server. SQLite is the authority by default. Product reads
and writes, category reads/writes, and stock-adjustment writes can be routed to
the server through compile-time product read/write modes. Other domains remain
local-only.

Current server routes are:

- `GET /api/v1/health`
- `GET /api/v1/version`
- `POST /api/v1/auth/login`
- Product list/detail/barcode/create/update/delete
- Category list/create/delete
- `GET /api/v1/stock/summary`
- `POST /api/v1/stock/adjustments`

The authoritative Flutter integration is:

```text
UI -> Cubit/BLoC -> domain repository -> local repository
                                      -> server API repository -> BackendApiClient
```

This is not yet a universal pattern. Most feature repositories still write
SQLite directly or through a local service.

## 2. Target architecture

Each business capability will have one domain repository and two explicit
implementations:

```text
UI
 -> Cubit/BLoC
 -> domain repository (mode policy, no persistence details)
    -> local repository (LOCAL mode only)
    -> server repository (SERVER mode only)
       -> shared API client
          -> authenticated FastAPI endpoint
             -> tenant-scoped application service
                -> one database transaction
```

Mode selection must be injected as a `DataAuthorityContext`, not read from
globals in every feature. A server operation must never call a local
repository as fallback. Local mode remains supported and unchanged.

## 3. System diagram

```text
Flutter UI
  |  display labels and temporary state
  v
Cubit/BLoC
  |  domain commands and query objects
  v
Domain repository
  |-----------------------------|
  v                             v
Local repository            Server repository
  |                             |
SQLite (LOCAL authority)    BackendApiClient
                                |
                                v
                         FastAPI application
                                |
                    auth + tenant + permission
                                |
                    application command/query service
                                |
                       SQLAlchemy transaction
                                |
                         SQLite server DB
```

Future invalidation events should be emitted by the server after commit. The
first implementation can continue polling/refreshing; event delivery must not
be coupled to business logic.

## 4. Client/server responsibilities

### Client

- Render UI labels and local transient state.
- Resolve display names to stable server IDs before requests.
- Validate obvious input for UX only.
- Send authenticated commands with idempotency keys.
- Refresh authoritative server queries after successful commands.
- Keep local SQLite authoritative only in explicit LOCAL mode.
- Never calculate authoritative stock, balances, totals, or document numbers.

### Server

- Authenticate the user and resolve the current shop.
- Authorize the operation by role/permission.
- Validate all IDs, units, prices, quantities, statuses, and relationships.
- Own document numbers, timestamps, stock, balances, totals, and audit data.
- Execute related mutations in one transaction.
- Return stable resource IDs and current projections.

## 5. Local SQLite strategy

Every persisted item must be classified:

| Classification | Meaning |
|---|---|
| Local authority | Existing SQLite business data in LOCAL mode |
| Server authority | Server business data in SERVER mode; no local write |
| Cache | Explicitly replaceable copy, not currently implemented |
| Device-local | Logs, preferences, UI state, or device metadata |
| Temporary | In-memory form/cart state |
| Obsolete | Persistence retained only until a planned removal |

Current mode policy:

- LOCAL mode: existing SQLite behavior remains authoritative.
- SERVER mode: products, categories, and stock adjustments use the server
  paths already implemented; they must not mirror server data into SQLite.
- Other domains are not server-ready and therefore must not be presented as
  partially migrated server features.

There must be no implicit read-through, write-through, fallback, or local
transaction after a successful server command.

## 6. Authentication architecture

`BackendApiClient` owns HTTP transport and uses `BackendTokenStore` for the
runtime JWT. Requests use:

```text
Authorization: Bearer <actual JWT>
Content-Type: application/json; charset=utf-8
```

The token must never be logged. The shared auth layer should be extended with:

1. Access-token expiry parsing and refresh.
2. A single-flight refresh lock.
3. Clearing credentials on unrecoverable 401.
4. Explicit login/logout state.
5. Device identity and shop context.

The backend token currently contains `sub`, `shop_id`, and `role`; the database
user remains authoritative. Future authorization must use centralized
permission checks, not route-specific role assumptions.

## 7. Tenant/shop isolation

Every business table must contain `shop_id` directly or inherit it through a
tenant-owned parent. Every query and mutation must scope by the authenticated
user's active shop. Cross-shop IDs must behave as not-found unless policy
requires a different response.

Required database conventions:

- `(shop_id, idempotency_key)` unique constraints.
- `(shop_id, reference_number)` unique constraints.
- Tenant-scoped username uniqueness if usernames are shop-local.
- Tenant-scoped product/category/business identifiers unless globally scoped
  IDs are deliberately documented.
- Central `TenantContext` query helpers and authorization dependencies.

## 8. Shared networking layer

Extend the existing `BackendApiClient` rather than adding per-feature HTTP
helpers. It should provide:

- GET, POST, PUT/PATCH, DELETE.
- UTF-8 JSON encoding/decoding.
- Timeout and connection error normalization.
- Standard `ApiError` with status, code, message, field errors, and request ID.
- Redacted request logging containing method/path/status/duration only.
- Retry only for safe reads and explicitly idempotent commands.
- Idempotency header/body support.

Error mapping:

| HTTP | Client meaning |
|---|---|
| 400 | Invalid business command |
| 401 | Missing/expired authentication |
| 403 | Authenticated but not permitted |
| 404 | Resource absent in the current shop |
| 409 | State conflict or key reuse |
| 422 | Schema/field validation |
| 500/503 | Server or database failure |
| network/timeout | Transport failure; command result unknown |

## 9. Shared repository pattern

Normal reads and writes use:

```text
FeatureCubit
 -> FeatureRepository (mode-aware)
    -> FeatureLocalRepository
    -> FeatureApiRepository
```

The domain repository accepts typed query/command objects. It does not know
SQLite table names or HTTP paths. API repositories map JSON to domain models.
Local repositories preserve existing behavior until the feature is migrated.

The DI container must create one configured repository graph. Constructors such
as `ProductRepositoryImp()` inside another feature are prohibited because they
silently reset the mode to local.

## 10. Read architecture

All server list endpoints should accept a consistent query shape:

```text
page, page_size, search, active, sort, order, updated_since, cursor, filters
```

Stable server IDs, not display names, are sent for filters. `All` is a
UI-only sentinel and is omitted from requests. Responses include items,
pagination metadata, and optional `server_time`/`next_cursor`.

Reads are authoritative snapshots. After a successful write, invalidate the
affected query keys and refresh from the server. Do not locally append an
unconfirmed server entity.

## 11. Write architecture

Normal commands:

- `POST` creates a server-generated or globally unique resource.
- `PUT/PATCH` updates an existing resource with server validation.
- `DELETE` means the documented business semantic, usually deactivation or
  voiding for historical records.

Every command returns the authoritative resource or a command result. The
client must not update stock, balances, document numbers, or ledgers locally
after a server command.

## 12. Transaction architecture

The backend application service owns transaction boundaries. A transaction
must include the document header, lines, projections, movements, ledgers,
cash entries, and idempotency record that belong to one business command.

Required lifecycle for posted documents:

```text
draft -> posted -> voided/reversed
```

Posted records are immutable. Corrections create reversals or return documents.
Destructive deletes are restricted to non-posted master data.

## 13. Stock architecture

One canonical server stock posting service must handle:

- opening stock
- adjustments
- sales
- purchases
- sales returns
- supplier returns
- exchanges
- future transfers and corrections

Each posting creates an append-only stock movement and updates the current
stock projection atomically. Unit conversion is validated against active
selling units. No feature may independently mutate product stock.

The current adjustment endpoint is the first implementation. It should later
be aligned with a general stock-document model; its current document-level
`product_id` is insufficient for multi-line documents.

## 14. Financial architecture

Use one server posting/accounting layer for:

- sale receivables and payments
- purchase payables and payments
- customer/supplier balances
- cash register movements
- expenses
- refunds, returns, and exchanges

Financial entries are append-only and linked to their source document. Cash
and ledger projections are derived within the same transaction as the source
document. Use `Decimal`/SQL `Numeric`, not floating-point money columns.

## 15. Idempotency strategy

Every retryable command carries an idempotency key generated by the client and
stable across retries. The server stores:

- shop ID
- key
- command type
- request hash
- result resource ID/status
- response payload or replay reference
- created/expiry timestamps

Same shop/key/same payload replays the original result. Same key/different
payload returns 409. Keys are tenant-scoped. The current adjustment behavior
returns 409 for a duplicate and must be improved before unstable-network
commands are migrated.

## Phase 0 completion status

The critical shared foundation is implemented:

- Backend role/permission enforcement is centralized and tenant-scoped.
- Idempotency records persist by shop and command key, including request hashes
  and successful response replay. Stock Adjustment business rows and the
  idempotency record are flushed and committed in one transaction; a retry
  never creates a second document or movement.
- Shared document lifecycle primitives define `draft`, `posted`, `cancelled`,
  and `reversed` transitions.
- Decimal-safe arithmetic is available for new financial commands. Existing
  floating-point columns remain documented for a controlled future migration.
- Flutter authority context and configured dependency injection prevent a
  server-mode Product repository from silently constructing a local fallback.
- JWT identifiers, revocation, logout, device context, and centralized client
  401 observability are available.

The prerequisites are sufficient for a future server-authoritative Sales phase,
but Sales remains intentionally deferred until the inventory, customer ledger,
payment, cash, and invoice contracts are implemented.

### New transactional money rule

All new transactional monetary persistence must use SQLAlchemy `Numeric` with
`Decimal` application values. This applies to future customer-ledger entries,
payments, cash movements, invoices, sale items, and related aggregates.
Existing legacy `Float` columns are intentionally not migrated in Phase 0.
The reusable contracts in `backend/app/transactional_contracts.py` enforce
Decimal values at the application boundary without implementing any Sales
endpoint or posting flow.

## 16. Cross-device consistency

For the current phase:

1. Server commits the command.
2. Client invalidates affected local view state.
3. Client refreshes from the server.
4. Other devices see changes on their next refresh.

No WebSocket is required now. Future events should contain:
`event_id`, `shop_id`, `aggregate_type`, `aggregate_id`, `version`,
`occurred_at`, and `changed_fields`. WebSocket/SSE delivery should only
invalidate queries; it must not contain duplicated business mutation logic.

## 17. Future WebSocket strategy

Add an outbox table written in the same transaction as business changes.
Publish committed outbox events to WebSocket clients. Clients deduplicate by
`event_id`, update invalidation keys, and refetch authoritative data. Missed
events are recovered through `updated_since` or a cursor endpoint.

## 18. Complete domain migration matrix

| Domain | Read | Create | Update | Delete | Transaction | Stock effect | Financial effect | Current authority | Target authority |
|---|---|---|---|---|---|---|---|---|---|
| Products | Server/local | Server/local | Server/local | Server deactivate/local | Product + opening stock | Opening stock | Cost baseline | Mode-dependent | Server in SERVER |
| Categories | Server/local | Server/local | Not exposed | Server deactivate/local | Master-data command | None | None | Mode-dependent | Server in SERVER |
| Selling units | Product detail/local | Product command/local | Product command/local | Deactivate/local | Product aggregate | Unit conversion | Prices | Mode-dependent | Server in SERVER |
| Stock adjustments | Server/local | Server/local | No | No destructive delete | Adjustment + movement + stock | Yes | Cost/history | Mode-dependent | Server |
| Opening stock | Local | Local | Local | Local | Product + document + movement | Yes | Cost baseline | SQLite | Server |
| Stock movements | Local | Local service | No | No | Canonical posting | Yes | Possible cost | SQLite | Server |
| Sales | Local | Local | Local | Local/void paths | Sale + lines + stock + ledger + cash | Decrease | Receivable/cash | SQLite | Server |
| Sale items | Local | Sale transaction | Sale transaction | Sale reversal | Parent sale | Decrease | Revenue | SQLite | Server |
| Invoices/refunds | Local | Local Cubit/service | Local | Local/reversal | Invoice + payment/refund | Return where applicable | Yes | SQLite | Server |
| Customers | Local | Local | Local | Local | Master/ledger commands | No | Balance | SQLite | Server |
| Customer payments | Local | Local | No | No/reversal | Payment + ledger + cash | No | Receivable/cash | SQLite | Server |
| Suppliers | Local | Local | Local | Local | Master/ledger commands | No | Balance | SQLite | Server |
| Purchases | Local | Local | Local | Local/return | Purchase + lines + stock + ledger + cash | Increase | Payable/cash | SQLite | Server |
| Purchase items | Local | Purchase transaction | Purchase transaction | Reversal | Parent purchase | Increase | Cost | SQLite | Server |
| Supplier payments | Local | Local | No | Reversal | Payment + ledger + cash | No | Payable/cash | SQLite | Server |
| Supplier returns | Local | Local | No | Reversal | Return + stock + ledger | Decrease | Payable | SQLite | Server |
| Orders | Local | Local | Local status | Local | Draft/reservation only | Optional reservation | No | SQLite | Server |
| Proformas | Local | Local | Local status | Local | Draft document | No until conversion | No | SQLite | Server |
| Expenses | Local | Local | Local | Local/reversal | Expense + cash | No | Expense/cash | SQLite | Server |
| Shifts/cash | Local | Local | Local close | Local | Shift + cash movement | No | Cash | SQLite | Server |
| Users | Local login/admin | Local | Local | Local | Auth/admin | No | No | Mixed | Server |
| Settings | Local | Local | Local | Local | None | No | No | SQLite | Shop server + device local |
| Notifications | In-memory | In-memory | In-memory | In-memory | None | No | No | UI memory | Server events/read model |
| Reports | Local-derived | File output | No | Files | Query snapshot | Derived | Derived | SQLite | Server read models |
| Analytics | Local-derived | No | No | No | Query snapshot | Derived | Derived | SQLite | Server read models |
| Activity/audit | Local | Local | Append/delete paths | Local | Source transaction | Audit | Audit | SQLite | Server append-only |
| Exchanges | Local | Local | Local | Local | Exchange + return/sale + stock + ledgers | Both | Both | SQLite | Server |

## 19. Dependency order

1. **Phase 0: shared infrastructure** - API errors, auth refresh, tenant
   context, mode-aware DI, request IDs, idempotency, server transaction and
   audit conventions.
2. **Phase 1: master data** - users/roles/devices, shops/settings, categories,
   products, selling units, customers, suppliers.
3. **Phase 2: inventory** - canonical stock documents, opening stock,
   adjustments, movements, purchase stock effects, returns.
4. **Phase 3: sales** - product lookup, cart command, sale posting, payments,
   customer balances, invoices, refunds, history.
5. **Phase 4: purchases** - purchase documents, supplier balances/payments,
   returns.
6. **Phase 5: financials** - shifts, registers, cash movements, expenses,
   ledger projections and reconciliation.
7. **Phase 6: orders/proformas and exchanges** - statuses, reservations,
   conversion, reversal rules.
8. **Phase 7: reports/analytics** - server read models and cross-device
   reporting.
9. **Phase 8: offline sync** - explicit cache/outbox/conflict policy; not a
   prerequisite for online server authority.
10. **Phase 9: event delivery** - outbox-backed WebSocket/SSE invalidation.

Sales must follow the stock and financial foundations, not precede them.

## 20. API contract catalog

All endpoints require JWT, shop scope, and role checks unless marked auth.
Write commands require `Idempotency-Key` and return the authoritative result.

| Method/path | Request/response | Errors | Transaction |
|---|---|---|---|
| POST `/auth/login` | credentials -> token/context | 401, 422 | No |
| POST `/auth/refresh` | refresh token -> token | 401 | No |
| GET `/products` | paged filters -> product page | 401, 422 | No |
| GET `/products/{id}` | none -> product | 401, 404 | No |
| GET `/products/barcode/{barcode}` | none -> product | 401, 404 | No |
| POST `/products` | product/opening command -> product | 401, 409, 422 | Product + opening stock |
| PUT `/products/{id}` | product patch -> product | 401, 404, 409, 422 | Product aggregate |
| DELETE `/products/{id}` | none -> deactivated product | 401, 404, 409 | Master data |
| GET `/categories` | filters -> category list | 401 | No |
| POST `/categories` | name -> category | 401, 409, 422 | Master data |
| DELETE `/categories/{id}` | none -> category | 401, 404, 409 | Master data |
| GET `/stock/summary` | filters -> summary | 401 | No |
| POST `/stock/adjustments` | lines/reason/units/key -> posted result | 401, 404, 409, 422 | Adjustment + movement + stock |
| GET `/stock/movements` | paged filters -> movement page | 401 | No |
| GET `/stock/adjustments` | paged filters -> documents | 401 | No |
| POST `/opening-stock` | lines/key -> posted result | 401, 404, 409, 422 | Opening + movement + stock |
| GET/POST `/customers` | list/create -> customer | 401, 409, 422 | Master data |
| GET/PUT/DELETE `/customers/{id}` | detail/patch/deactivate | 401, 404, 409 | Master data |
| GET `/customers/{id}/ledger` | paged ledger | 401, 404 | No |
| POST `/customers/{id}/payments` | payment/key -> payment | 401, 404, 409, 422 | Payment + ledger + cash |
| GET/POST `/suppliers` | list/create -> supplier | 401, 409, 422 | Master data |
| GET/PUT/DELETE `/suppliers/{id}` | detail/patch/deactivate | 401, 404, 409 | Master data |
| GET `/suppliers/{id}/ledger` | paged ledger | 401, 404 | No |
| POST `/suppliers/{id}/payments` | payment/key -> payment | 401, 404, 409, 422 | Payment + ledger + cash |
| POST `/sales` | sale lines/payments/key -> posted sale | 401, 404, 409, 422 | Sale + stock + ledger + cash |
| GET `/sales` and `/sales/{id}` | page/detail -> sale | 401, 404 | No |
| POST `/sales/{id}/void` | reason/key -> void result | 401, 404, 409, 422 | Reversal + stock + ledger |
| POST `/sales/{id}/refund` | lines/payment/key -> refund | 401, 404, 409, 422 | Refund + stock + ledger + cash |
| POST `/purchases` | lines/payments/key -> posted purchase | 401, 404, 409, 422 | Purchase + stock + ledger + cash |
| GET `/purchases` and `/purchases/{id}` | page/detail -> purchase | 401, 404 | No |
| POST `/purchases/{id}/return` | lines/key -> return | 401, 404, 409, 422 | Return + stock + ledger |
| POST `/expenses` | expense/payment/key -> expense | 401, 409, 422 | Expense + cash |
| GET `/expenses` | page/filter -> expenses | 401 | No |
| POST `/shifts/open` | opening cash/key -> shift | 401, 409, 422 | Shift + cash |
| POST `/shifts/{id}/close` | counted cash/key -> close result | 401, 404, 409, 422 | Shift + reconciliation |
| POST `/cash/movements` | movement/key -> movement | 401, 409, 422 | Cash + audit |
| GET/POST `/orders` and `/proformas` | draft CRUD -> document | 401, 404, 409, 422 | Draft/status |
| POST `/orders/{id}/convert-to-sale` | key -> sale | 401, 404, 409, 422 | Conversion + sale |
| GET `/reports/*` and `/analytics/*` | filters -> read model | 401, 422 | No |
| GET `/sync/changes` | cursor/updated_since -> events | 401, 422 | No |

## 21. Database model roadmap

The current server has `shops`, `users`, `devices`, `categories`, `products`,
`product_selling_units`, opening-stock tables, stock movements, and adjustment
tables. The local schema additionally has customers, suppliers, sales, sale
items, purchases, purchase items, ledgers, payments, cash registers,
cash movements, shifts, expenses, orders, proformas, returns, exchanges,
activity logs, settings, and document sequences.

Every new server document should include:

```text
id, shop_id, reference_number, status, idempotency_key, request_hash,
created_at, created_by, updated_at, updated_by, posted_at, posted_by,
voided_at, voided_by, reversal_of_id
```

Every line should include:

```text
id, document_id, shop_id, source references, product/unit IDs,
quantity, unit price/cost, tax/discount fields, created_at
```

Add foreign keys and indexes for shop, status, date, source document, product,
customer/supplier, and idempotency. Use `Numeric` for money, deliberate
decimal scale for quantities, append-only movements/ledgers, and server-side
reference sequences.

## 22. Risk register

| Severity | Risk | Consequence | Required control |
|---|---|---|---|
| CRITICAL | Sales/purchases have no server transaction | Cross-device stock and money corruption | Implement server posting services before migration |
| CRITICAL | Multiple local sales write paths | Duplicate or divergent effects | Consolidate one domain command path |
| CRITICAL | Float money/quantity columns | Rounding and balance drift | Decimal/Numeric plus explicit rounding |
| HIGH | Server mode is not universal | Features silently remain device-local | Per-domain authority gate and migration checklist |
| HIGH | ProductRepository constructed without DI | Server mode can silently become local | Inject one configured graph |
| HIGH | Adjustment duplicate returns 409, not replay | Timeout retry cannot prove outcome | Persist/replay command result |
| HIGH | Global idempotency uniqueness | One shop can collide with another | Composite shop/key constraint |
| HIGH | No server role enforcement | Unauthorized mutations | Central permission policy |
| HIGH | Local reports/analytics | Devices show stale business state | Server read models |
| MEDIUM | No status/reversal lifecycle | Destructive edits of history | Posted/voided/reversal model |
| MEDIUM | Missing movement/history reads | No authoritative audit UI | Add server history queries |
| MEDIUM | Stale Uvicorn process risk | Runtime differs from source | Deployment/version health checks |
| LOW | Legacy helper methods remain | Maintenance confusion | Remove only after migration coverage |
| LOW | No event delivery | Refresh latency | Outbox plus future WebSocket/SSE |

## 23. Known inconsistencies

- Product/category/adjustment support is mode-aware, but most domains are not.
- A `ProductRepositoryImp()` constructed outside configured DI can default local;
  this was observed in stock-related wiring.
- Local adjustment repositories and server adjustment APIs coexist; history
  reads remain local and must not be silently mixed.
- Sales, invoice, exchange, purchase, payment, and return paths contain
  independent local transaction logic.
- Local destructive operations conflict with append-only server documents.
- Server APIs do not yet expose stock movement or adjustment history.
- Backend role checks, device auth, refresh tokens, request IDs, and a shared
  tenant query layer are absent.
- Backend multi-line adjustment documents retain a scalar document `product_id`.
- Product/category identifiers, display names, and UI sentinels require
  explicit mapping; the category filter bug demonstrated this risk.
- Flutter analysis currently has unrelated existing test type errors in
  `test/packaged_display_read_path_test.dart`.

These are audit findings, not changes made by this document.

## 24. Migration phases

See [server-migration-roadmap.md](server-migration-roadmap.md) for the
execution sequence. Each phase must add backend migrations, API contracts,
Flutter API/repository wiring, mode tests, backend transaction tests, and
cross-device refresh validation before the next dependent phase.

## 25. Sales prerequisites

Sales must not be migrated until the following are server-ready:

1. Auth, tenant, role, idempotency, and API error infrastructure.
2. Product detail/barcode reads including selling-unit conversion and price.
3. Customer master and customer ledger/payment contracts.
4. Canonical stock posting with decrement, movement history, and reversal.
5. Sale header/line schema with discounts, prices, tax policy, and totals.
6. Cash register/shift and payment allocation model.
7. Invoice numbering and posted/voided/refunded lifecycle.
8. Atomic sale transaction:
   sale + lines + stock decrement + movements + customer balance
   + invoice/payment + cash entries.
9. Replay-safe idempotency for unstable Wi-Fi.
10. Server sale history and refresh/invalidation.
11. Explicit policy for offline cart state; no offline business commit yet.
12. Backend tests for insufficient stock, invalid unit, inactive product,
    wrong-shop IDs, duplicate submissions, refund/void, and rollback.

No Sales implementation is included in this architecture task.

## Phase 0 implementation status

Phase 0 shared infrastructure is partially implemented without changing
business behavior:

- `BackendApiClient` remains the single client for GET, POST, PUT, and DELETE.
- The transport now has bounded connection/response timeouts and maps connection
  and timeout failures to typed `BackendApiException` values.
- Authenticated requests are normalized through one transport wrapper. The
  runtime sends the real `Bearer <JWT>` value; tokens remain absent from debug
  logs.
- `BackendAuthContext` and `BackendServerContext` carry access token, user ID,
  shop ID, device ID, and role without changing the login UI.
- `BackendApiErrorKind` standardizes authentication, authorization, not-found,
  conflict, validation, server, connection, timeout, and protocol errors.
- `IdentityMapping` formalizes display-value/server-ID separation. Existing
  Product category mapping remains the owner of its current category map.
- `ServerAuthority` provides the reusable local/server authority vocabulary.
  Existing Product read/write modes remain the compatibility boundary.
- Backend `ServerContext`, `atomic_command`, request hashing, and scoped
  idempotency helpers provide the foundation for future commands.
- `StockPostingCommand` and `StockPostingLine` document the canonical stock
  posting contract without changing the existing adjustment endpoint.
- The development startup checklist is in
  [backend-development-startup.md](backend-development-startup.md).

Remaining Phase 0 work is intentionally deferred: refresh-token lifecycle,
central role middleware, tenant-scoped idempotency schema migration, replayable
command-result storage, universal DI authority context, and outbox events.

### Financial precision audit

Current backend financial and quantity fields use SQLAlchemy `Float` in
`Product.price`, `Product.min_price`, `Product.wholesale_price`, `Product.cost`,
`Product.stock`, `Product.min_stock`, selling-unit prices/costs, opening-stock
amounts, and stock-adjustment amounts. The target is `Numeric`/`Decimal` for
money with explicit scale and rounding; quantities require a documented
decimal scale. This is a prerequisite for Sales, Purchases, Payments, Expenses,
and ledger migrations and is not changed in Phase 0.
