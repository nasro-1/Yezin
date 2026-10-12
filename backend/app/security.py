from datetime import datetime, timedelta, timezone
from uuid import uuid4

import jwt
from fastapi import Depends, Header, HTTPException, status
from fastapi.security import OAuth2PasswordBearer
from passlib.context import CryptContext
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.config import settings
from app.database import get_db
from app.context import ServerContext
from app.models import RevokedToken, User


password_context = CryptContext(schemes=["bcrypt"], deprecated="auto")
oauth2_scheme = OAuth2PasswordBearer(tokenUrl="/api/v1/auth/login")


def hash_password(password: str) -> str:
    return password_context.hash(password)


def verify_password(password: str, password_hash: str) -> bool:
    return password_context.verify(password, password_hash)


def create_access_token(user: User) -> str:
    expires = datetime.now(timezone.utc) + timedelta(minutes=settings.access_token_minutes)
    payload = {"sub": user.id, "shop_id": user.shop_id, "role": user.role, "jti": uuid4().hex, "exp": expires}
    return jwt.encode(payload, settings.jwt_secret, algorithm=settings.jwt_algorithm)


def get_current_user(
    token: str = Depends(oauth2_scheme), db: Session = Depends(get_db)
) -> User:
    invalid = HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail="Invalid or expired access token",
        headers={"WWW-Authenticate": "Bearer"},
    )
    try:
        payload = jwt.decode(token, settings.jwt_secret, algorithms=[settings.jwt_algorithm])
        user_id = payload.get("sub")
        jti = payload.get("jti")
        if not isinstance(user_id, str) or not isinstance(jti, str):
            raise invalid
        if db.get(RevokedToken, jti) is not None:
            raise invalid
    except (jwt.InvalidTokenError, TypeError) as error:
        raise invalid from error
    user = db.scalar(select(User).where(User.id == user_id, User.is_active.is_(True)))
    if user is None:
        raise invalid
    return user


def get_server_context(
    current_user: User = Depends(get_current_user),
    device_id: str | None = Header(default=None, alias="X-Device-ID"),
) -> ServerContext:
    return ServerContext.from_user(current_user, device_id=device_id.strip() if device_id else None)
