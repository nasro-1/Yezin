# Yezin Phase 1 Local Backend

This isolated FastAPI server owns `backend\data\bayaa_server.db`; it does not
open, migrate, or replace the Flutter application's SQLite database.

## Windows commands

```powershell
cd backend
if (-not (Test-Path .env)) { Copy-Item .env.example .env }
py -3 -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -e ".[dev]"
python -m alembic upgrade head
python -m pytest -vv
python -m uvicorn app.main:app --host 0.0.0.0 --port 8010
```

The checked-in `.env.example` contains only the explicit development
environment setting. Copy it to the ignored local `.env` before starting the
backend. Settings load that file from the backend directory regardless of the
process working directory. Alternatively, set
`$env:BAYAA_ENVIRONMENT = "development"` in PowerShell before starting Uvicorn.
Swagger is at `http://127.0.0.1:8010/docs`. A phone on the same Wi-Fi can use
`http://LAPTOP_IP:8010`. Allow inbound TCP 8010 for the private
network profile in Windows Firewall if needed; firewall rules are not changed
automatically.

Every backend process must explicitly set `BAYAA_ENVIRONMENT` to `development`,
`test`, or `production`; startup fails if it is missing or invalid. Configuration
also uses `BAYAA_DATABASE_URL`, `BAYAA_JWT_SECRET`, and
`BAYAA_CORS_ORIGINS`. Development retains local-friendly defaults. Production
startup rejects known development JWT-secret placeholders, secrets shorter than
32 characters, and wildcard or missing CORS origins. Set a unique secret of at
least 32 characters and a comma-separated list of allowed origins in production.
The default database is not the Flutter SQLite file.

## Endpoints

- `GET /api/v1/health` (public, verifies database access)
- `GET /api/v1/version` (public)
- `POST /api/v1/auth/login` (JWT plus user ID, shop ID, and role)
- `POST /api/v1/auth/logout` (revokes the current JWT)
- `GET /api/v1/products` (Bearer token; pagination, search, active, category)
- `GET /api/v1/products/{id}` (Bearer token)
- `GET /api/v1/products/barcode/{barcode}` (Bearer token)
- `GET /api/v1/stock/summary` (Bearer token)
- `GET/POST /api/v1/sales/drafts` (authenticated; owner-scoped list/create drafts)
- `GET /api/v1/sales/drafts/{id}` and item add/update/delete (authenticated)
- `POST /api/v1/sales/drafts/{id}/hold`, `/resume`, `/clear`, `/checkout`
- `WS /api/v1/sales/drafts/ws?token=...` (authenticated draft events)

The backend owns a database separate from Flutter's local SQLite database.
The Flutter client already integrates with selected backend APIs, including
server-authoritative products, sales drafts, suppliers, and purchases; there is
no general-purpose offline sync. Customers remain local-only and cannot be
selected from the Flutter customer database for server-authoritative sales.
The backend can record opaque customer IDs for direct server clients but does
not provide a customer directory or local-to-server identity mapping.
PostgreSQL is not included. Open and held sale drafts are server-authoritative
and do not change stock until checkout. Draft mutations use an optimistic
`version`; stale `expected_version` values return HTTP 409 with the current version.

Phase 0 records idempotent commands per shop and preserve the exact response for
safe retries. `X-Device-ID` is captured on authenticated stock movements.
Sales are server-authoritative: posting atomically writes the sale, payment,
cash/ledger entry, stock movement, and idempotency record. On SQLite, sale
posting uses a process-local serialized write lock in addition to the database
transaction because SQLite permits only one writer. Sale documents are
immutable after posting; lifecycle values are `DRAFT`, `POSTED`, `CANCELLED`,
and `REVERSED` (the API currently creates `POSTED` documents and exposes GET).
Existing financial columns remain `Float` for API/database compatibility; new
calculations use decimal arithmetic (`app.finance`). A Numeric migration is
deferred until an explicit compatibility/versioning plan exists.

## Development LAN read test

Seed only the local server database with development data:

```powershell
$env:BAYAA_ENVIRONMENT = "development"
$env:BAYAA_ALLOW_DEV_DATA_RESET = "1"
python scripts/seed_dev_data.py
Remove-Item Env:\BAYAA_ALLOW_DEV_DATA_RESET
```

This creates the fixed `dev-shop` tenant and development-only seed accounts.
The script is not an API endpoint and must not be used as production
provisioning. Both this script and `scripts/reset_dev_environment.py` refuse to
run unless `BAYAA_ENVIRONMENT=development` and
`BAYAA_ALLOW_DEV_DATA_RESET=1` are set. The opt-in applies to either script;
remove it immediately after use.

Replace `<LAN-IP>` with the backend machine's local network address:

```text
http://<LAN-IP>:8010/api/v1
```

The address is environment-specific and must not be hardcoded into application
source. From the repository root, replace `<LAN-IP>` in the test URL before running
the Flutter-only LAN read test:

```powershell
$env:BAYAA_API_BASE_URL = "http://<LAN-IP>:8010/api/v1"
flutter test test/product_server_lan_test.dart
```

The test explicitly constructs `ProductReadMode.server`, performs login,
`GET /products`, and `GET /products/barcode/123456789`. Normal Flutter startup
defaults to local SQLite mode, while server mode uses the API as the authority
for product reads and writes. Each product has one product-level barcode;
active barcode uniqueness is scoped to a shop, and deactivation releases the
barcode for reuse.
