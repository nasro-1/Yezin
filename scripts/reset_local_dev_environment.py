"""Reset the active Flutter development data root without changing migrations."""

from __future__ import annotations

from datetime import datetime
import json
import os
from pathlib import Path
import shutil
import sqlite3


APP_DIR_NAME = "Bayaa"
SYSTEM_CONFIG_NAME = "system_config.json"
DATABASE_NAME = "sales.db"
SCHEMA_VERSION = 32
PRESERVED_TABLES = {"store_settings", "cash_registers"}


def discover_root() -> tuple[Path, Path]:
    appdata = os.environ.get("APPDATA")
    if not appdata:
        raise RuntimeError("APPDATA is not set; cannot resolve the Flutter data root.")
    system_config = Path(appdata) / APP_DIR_NAME / SYSTEM_CONFIG_NAME
    if not system_config.is_file():
        raise FileNotFoundError(f"Missing data-root configuration: {system_config}")
    config = json.loads(system_config.read_text(encoding="utf-8"))
    configured_root = config.get("data_root_path")
    if not isinstance(configured_root, str) or not configured_root.strip():
        raise RuntimeError(f"Invalid data_root_path in {system_config}")
    root = Path(configured_root).expanduser().resolve()
    mode_config = root / "config" / "bayaa.json"
    if not mode_config.is_file():
        raise FileNotFoundError(f"Missing local configuration: {mode_config}")
    mode = json.loads(mode_config.read_text(encoding="utf-8"))
    if mode.get("app_mode") != "development":
        raise RuntimeError(
            f"Refusing to reset non-development data root: {mode.get('app_mode')!r}"
        )
    database = root / "db" / DATABASE_NAME
    if not database.is_file():
        raise FileNotFoundError(f"Missing local database: {database}")
    return root, database


def backup_database(database: Path) -> Path:
    timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    backup = database.with_name(f"{database.name}.backup-{timestamp}")
    suffix = 1
    while backup.exists():
        backup = database.with_name(f"{database.name}.backup-{timestamp}-{suffix}")
        suffix += 1
    source = sqlite3.connect(str(database))
    target = sqlite3.connect(str(backup))
    try:
        source.backup(target)
    finally:
        target.close()
        source.close()
    return backup


def table_names(connection: sqlite3.Connection) -> list[str]:
    return [
        row[0]
        for row in connection.execute(
            "SELECT name FROM sqlite_master "
            "WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"
        )
    ]


def reset_database(database: Path) -> tuple[int, dict[str, int]]:
    connection = sqlite3.connect(str(database))
    try:
        connection.execute("PRAGMA foreign_keys = OFF")
        schema_version = connection.execute("PRAGMA user_version").fetchone()[0]
        if schema_version != SCHEMA_VERSION:
            raise RuntimeError(
                f"Expected local schema {SCHEMA_VERSION}, found {schema_version}"
            )

        tables = table_names(connection)
        before = {
            table: connection.execute(f' SELECT COUNT(*) FROM "{table}"').fetchone()[0]
            for table in tables
        }

        # The application deliberately protects posted history from deletion.
        # A development reset may remove that history, so suspend and restore
        # the existing trigger definitions within this single transaction.
        triggers = [
            row[0]
            for row in connection.execute(
                "SELECT sql FROM sqlite_master "
                "WHERE type = 'trigger' AND sql IS NOT NULL"
            )
        ]
        trigger_names = [
            row[0]
            for row in connection.execute(
                "SELECT name FROM sqlite_master WHERE type = 'trigger'"
            )
        ]
        for trigger_name in trigger_names:
            connection.execute(f'DROP TRIGGER "{trigger_name}"')

        for table in tables:
            if table not in PRESERVED_TABLES:
                connection.execute(f'DELETE FROM "{table}"')

        # A single default register is required by cash/session services.
        if "cash_registers" in tables:
            connection.execute('DELETE FROM "cash_registers"')
            connection.execute(
                'INSERT INTO "cash_registers" '
                "(id, name, code, is_active, created_at, updated_at, created_by) "
                "VALUES (?, ?, ?, ?, ?, ?, ?)",
                (
                    "main-register",
                    "Main Register",
                    "MAIN",
                    1,
                    datetime.now().isoformat(),
                    datetime.now().isoformat(),
                    None,
                ),
            )

        if "store_settings" in tables:
            columns = {
                row[1]
                for row in connection.execute('PRAGMA table_info("store_settings")')
            }
            for column, definition in (
                ("show_logo", "INTEGER NOT NULL DEFAULT 1"),
                ("show_vat", "INTEGER NOT NULL DEFAULT 1"),
                ("show_amount_in_words", "INTEGER NOT NULL DEFAULT 1"),
                ("show_barcode", "INTEGER NOT NULL DEFAULT 1"),
            ):
                if column not in columns:
                    connection.execute(
                        f'ALTER TABLE "store_settings" ADD COLUMN {column} {definition}'
                    )
            now = datetime.now().isoformat()
            settings = {
                "store_name": "Yezin",
                "store_address": "",
                "store_phone": "",
                "store_email": "",
                "logo_path": "",
                "tax_number": "",
                "tax_rate": 0.0,
                "currency": "DZD",
                "invoice_prefix": "INV",
                "last_invoice_number": 0,
                "show_logo": 1,
                "show_vat": 1,
                "show_amount_in_words": 1,
                "show_barcode": 1,
                "updated_at": now,
            }
            existing = connection.execute(
                'SELECT id FROM "store_settings" LIMIT 1'
            ).fetchone()
            if existing is None:
                settings.update(
                    {
                        "id": "store_settings_singleton",
                        "created_at": now,
                    }
                )
                columns_sql = ", ".join(settings)
                values_sql = ", ".join("?" for _ in settings)
                connection.execute(
                    f'INSERT INTO "store_settings" ({columns_sql}) VALUES ({values_sql})',
                    tuple(settings.values()),
                )
            else:
                assignments = ", ".join(f'"{key}" = ?' for key in settings)
                connection.execute(
                    f'UPDATE "store_settings" SET {assignments} WHERE id = ?',
                    (*settings.values(), existing[0]),
                )

        # Numbering is local and development-only.
        if "document_sequences" in tables:
            connection.execute('DELETE FROM "document_sequences"')

        for trigger_sql in triggers:
            connection.execute(trigger_sql)
        connection.execute(f"PRAGMA user_version = {SCHEMA_VERSION}")
        connection.commit()
        after = {
            table: connection.execute(f' SELECT COUNT(*) FROM "{table}"').fetchone()[0]
            for table in tables
        }
        return schema_version, {"before": before, "after": after}
    finally:
        connection.close()


def clear_known_runtime_files(root: Path) -> list[str]:
    cleared: list[str] = []
    for directory_name in ("ledger", "checkpoints", "logs"):
        directory = root / directory_name
        if not directory.is_dir():
            continue
        for child in directory.iterdir():
            if child.is_file():
                child.unlink()
                cleared.append(str(child))
            elif child.is_dir() and directory_name == "checkpoints":
                shutil.rmtree(child)
                cleared.append(str(child))

    assets = root / "assets"
    if assets.is_dir():
        for child in assets.iterdir():
            if child.is_file():
                child.unlink()
                cleared.append(str(child))
    return cleared


def reset_config(root: Path) -> None:
    config_path = root / "config" / "bayaa.json"
    config = json.loads(config_path.read_text(encoding="utf-8"))
    config["app_mode"] = "development"
    config["development_data_root_path"] = str(root)
    config.pop("lastCheckpoint", None)
    config.pop("lastCheckpointReason", None)
    config_path.write_text(
        json.dumps(config, indent=2) + "\n", encoding="utf-8"
    )


def main() -> None:
    root, database = discover_root()
    print(f"LOCAL DATA ROOT: {root}")
    print(f"LOCAL DATABASE: {database}")
    backup = backup_database(database)
    print(f"LOCAL BACKUP: {backup}")
    schema_version, counts = reset_database(database)
    reset_config(root)
    cleared = clear_known_runtime_files(root)

    print("\nLOCAL DEVELOPMENT ENVIRONMENT RESET")
    print(f"Schema: {schema_version}")
    print("Mode: development")
    print("Currency: DZD / DA")
    print("Printing: logo=on, VAT=on, amount-in-words=on, barcode=on")
    print("Document sequences: reset")
    print(f"Runtime files cleared: {len(cleared)}")
    print("\nCOUNTS AFTER RESET")
    for table, count in sorted(counts["after"].items()):
        print(f"{table}: {count}")
    print("\nNOT PRESENT")
    print("No local server-auth configuration was removed.")


if __name__ == "__main__":
    main()
