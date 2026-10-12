from pathlib import Path
from typing import Literal

from pydantic import model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


BACKEND_ROOT = Path(__file__).resolve().parent.parent
DATA_DIR = BACKEND_ROOT / "data"
DATA_DIR.mkdir(parents=True, exist_ok=True)


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="BAYAA_", env_file=".env")

    environment: Literal["development", "test", "production"]
    database_url: str = f"sqlite:///{(DATA_DIR / 'bayaa_server.db').as_posix()}"
    api_version: str = "1.0.0"
    jwt_secret: str = "change-this-local-secret"
    jwt_algorithm: str = "HS256"
    access_token_minutes: int = 60
    cors_origins: str = "*"

    @property
    def cors_origin_list(self) -> list[str]:
        return [x.strip() for x in self.cors_origins.split(",") if x.strip()]

    @model_validator(mode="after")
    def validate_production_security(self) -> "Settings":
        if self.environment == "production":
            known_placeholders = {
                "change-this-local-secret",
                "change-me",
                "changeme",
                "development-secret",
                "replace-me",
                "replace-this-with-a-secure-secret",
                "test-secret",
                "your-secret-here",
                "your-secret-key",
            }
            jwt_secret = self.jwt_secret.strip()
            if (
                jwt_secret.casefold() in known_placeholders
                or len(jwt_secret) < 32
            ):
                raise ValueError(
                    "Production requires BAYAA_JWT_SECRET with at least 32 characters."
                )
            if not self.cors_origin_list or "*" in self.cors_origin_list:
                raise ValueError(
                    "Production requires explicit BAYAA_CORS_ORIGINS; wildcard CORS is not allowed."
                )
        return self


settings = Settings()
