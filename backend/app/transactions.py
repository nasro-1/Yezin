from collections.abc import Iterator
from contextlib import contextmanager
from hashlib import sha256
import json

from sqlalchemy.orm import Session

from app.context import ServerContext


@contextmanager
def atomic_command(db: Session) -> Iterator[Session]:
    """Run a business command as one commit-or-rollback boundary."""

    try:
        yield db
        db.commit()
    except Exception:
        db.rollback()
        raise


def request_hash(payload: object) -> str:
    encoded = json.dumps(payload, sort_keys=True, separators=(",", ":"), default=str)
    return sha256(encoded.encode("utf-8")).hexdigest()


def scoped_idempotency_key(context: ServerContext, key: str) -> tuple[str, str]:
    """Return the tenant scope and normalized key for command persistence."""

    normalized = key.strip()
    if not normalized:
        raise ValueError("Idempotency key is required")
    return context.shop_id, normalized
