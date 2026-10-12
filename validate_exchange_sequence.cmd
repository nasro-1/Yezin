@echo off
setlocal enabledelayedexpansion
cd /d "%~dp0"
call :run "fvm flutter test --no-pub test/exchange_service_test.dart"
call :run "fvm flutter test --no-pub test/exchange_schema_migration_test.dart"
call :run "fvm flutter test --no-pub test/refund_idempotency_test.dart"
call :run "fvm flutter test --no-pub test/cash_foundation_test.dart"
call :run "fvm flutter test --no-pub test/ledger_authority_hardening_test.dart"
call :run "fvm flutter test --no-pub test/task_3_session_logger_integration_test.dart"
call :run "fvm flutter test --no-pub test/historical_review_service_test.dart"
call :run "fvm flutter test --no-pub test/compatibility_repair_service_test.dart"
call :run "fvm flutter test --no-pub test/repair_preview_service_test.dart"
call :run "fvm flutter test --no-pub"
call :run "fvm flutter test --no-pub --concurrency=1"
call :run "fvm flutter analyze --no-pub"
call :run "git diff --check"
call :run "fvm flutter build windows --release"
exit /b 0

:run
  echo =======> %~1
  call %~1 > validation.log 2>&1
  if errorlevel 1 (
    echo FAILED: %~1
    type validation.log
    exit /b 1
  )
  echo PASS: %~1
  exit /b 0
