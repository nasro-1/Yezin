from collections.abc import Generator

from sqlalchemy import create_engine, event
from sqlalchemy.engine import Engine
from sqlalchemy.orm import DeclarativeBase, Session, sessionmaker

from app.config import settings


class Base(DeclarativeBase):
    pass


connect_args = {"check_same_thread": False} if settings.database_url.startswith("sqlite") else {}


def configure_sqlite_foreign_keys(database_engine: Engine) -> None:
    if database_engine.dialect.name != "sqlite":
        return

    @event.listens_for(database_engine, "connect")
    def enable_foreign_keys(dbapi_connection, connection_record) -> None:
        cursor = dbapi_connection.cursor()
        try:
            cursor.execute("PRAGMA foreign_keys = ON")
        finally:
            cursor.close()

    with database_engine.connect() as connection:
        enabled = connection.exec_driver_sql("PRAGMA foreign_keys").scalar_one()
        if enabled != 1:
            raise RuntimeError("SQLite foreign-key enforcement could not be enabled")


engine = create_engine(settings.database_url, connect_args=connect_args)
configure_sqlite_foreign_keys(engine)
SessionLocal = sessionmaker(bind=engine, autoflush=False, expire_on_commit=False)


def get_db() -> Generator[Session, None, None]:
    with SessionLocal() as session:
        yield session
