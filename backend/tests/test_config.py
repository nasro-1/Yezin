import pytest
from pydantic import ValidationError

from app.config import Settings


def test_development_defaults_remain_local_friendly() -> None:
    settings = Settings(_env_file=None, environment="development")

    assert settings.jwt_secret == "change-this-local-secret"
    assert settings.cors_origin_list == ["*"]


def test_environment_must_be_explicit(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("BAYAA_ENVIRONMENT", raising=False)
    with pytest.raises(ValidationError, match="environment"):
        Settings(_env_file=None)


def test_production_rejects_placeholder_or_short_jwt_secret() -> None:
    with pytest.raises(ValidationError, match="BAYAA_JWT_SECRET"):
        Settings(
            _env_file=None,
            environment="production",
            jwt_secret="change-this-local-secret",
            cors_origins="https://pos.example.com",
        )

    with pytest.raises(ValidationError, match="BAYAA_JWT_SECRET"):
        Settings(
            _env_file=None,
            environment="production",
            jwt_secret="too-short",
            cors_origins="https://pos.example.com",
        )

    with pytest.raises(ValidationError, match="BAYAA_JWT_SECRET"):
        Settings(
            _env_file=None,
            environment="production",
            jwt_secret="replace-this-with-a-secure-secret",
            cors_origins="https://pos.example.com",
        )


def test_production_rejects_wildcard_or_missing_cors_origins() -> None:
    for cors_origins in ("*", ""):
        with pytest.raises(ValidationError, match="BAYAA_CORS_ORIGINS"):
            Settings(
                _env_file=None,
                environment="production",
                jwt_secret="a-production-secret-that-is-at-least-32-chars",
                cors_origins=cors_origins,
            )


def test_production_accepts_explicit_secret_and_origins() -> None:
    settings = Settings(
        _env_file=None,
        environment="production",
        jwt_secret="a-production-secret-that-is-at-least-32-chars",
        cors_origins="https://pos.example.com,https://admin.example.com",
    )

    assert settings.cors_origin_list == [
        "https://pos.example.com",
        "https://admin.example.com",
    ]
