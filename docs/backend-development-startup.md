# Backend development startup checklist

Use the authoritative backend worktree and do not start a second server while
port `8010` is occupied.

1. Inspect the listener:

   ```powershell
   Get-NetTCPConnection -LocalPort 8010 -State Listen
   ```

2. If the listener is stale, identify its owning process:

   ```powershell
   Get-Process -Id <PID>
   ```

3. Stop only that identified stale process:

   ```powershell
   Stop-Process -Id <PID>
   ```

4. Start the authoritative backend from:

   ```text
   the repository's `backend` directory
   ```

   Prepare local development configuration once:

   ```powershell
   if (-not (Test-Path .env)) { Copy-Item .env.example .env }
   ```

   `.env.example` sets only `BAYAA_ENVIRONMENT=development`; the local `.env`
   is ignored by Git. Alternatively, set
   `$env:BAYAA_ENVIRONMENT = "development"` in this PowerShell session.

   ```powershell
   python -m uvicorn app.main:app --host 0.0.0.0 --port 8010
   ```

5. Verify health:

   ```powershell
   Invoke-RestMethod http://127.0.0.1:8010/api/v1/health
   ```

6. Verify the loaded route set:

   ```powershell
   $openapi = Invoke-RestMethod http://127.0.0.1:8010/openapi.json
   $openapi.paths.PSObject.Properties.Name
   ```

7. Apply the authoritative schema before testing a fresh backend database:

   ```powershell
   Set-Location .\backend
   python -m alembic upgrade head
   ```

The current Phase 0 schema includes tenant-scoped idempotency records, revoked
JWT identifiers, and device context on stock movements. Never reuse a
production database for migration tests.

The OpenAPI response and process path must correspond to the authoritative
worktree before runtime testing. Never log or paste JWTs.
