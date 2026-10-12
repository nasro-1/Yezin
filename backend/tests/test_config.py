import pytest
from pydantic import ValidationError

from app.config import BACKEND_ROOT, Settings


def test_development_defaults_remain_local_friendly() -> None:
    settings = Settings(_env_file=None, environment="development")

    assert settings.jwt_secret == "change-this-local-secret"
    assert settings.cors_origin_list == ["*"]


def test_development_configuration_loads_from_environment_template(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.delenv("BAYAA_ENVIRONMENT", raising=False)
    settings = Settings(_env_file=BACKEND_ROOT / ".env.example")

    assert settings.environment == "development"
    assert settings.cors_origin_list == ["*"]


def test_dotenv_path_is_anchored_to_backend_directory() -> None:
    assert Settings.model_config["env_file"] == BACKEND_ROOT / ".env"


def test_documented_environment_variable_names_are_recognized(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("BAYAA_ENVIRONMENT", "development")
    monkeypatch.setenv(
        "BAYAA_DATABASE_URL", "sqlite:///C:/temp/bayaa-config-test.db"
    )
    monkeypatch.setenv("BAYAA_JWT_SECRET", "local-test-secret")
    monkeypatch.setenv(
        "BAYAA_CORS_ORIGINS", "http://localhost:3000,http://127.0.0.1:3000"
    )

    settings = Settings(_env_file=None)

    assert settings.environment == "development"
    assert settings.database_url == "sqlite:///C:/temp/bayaa-config-test.db"
    assert settings.jwt_secret == "local-test-secret"
    assert settings.cors_origin_list == [
        "http://localhost:3000",
        "http://127.0.0.1:3000",
    ]


def test_environment_must_be_explicit(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("BAYAA_ENVIRONMENT", raising=False)
    with pytest.raises(ValidationError, match="Set BAYAA_ENVIRONMENT"):
        Settings(_env_file=None)


def test_environment_rejects_invalid_value(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("BAYAA_ENVIRONMENT", "staging")

    with pytest.raises(ValidationError, match="BAYAA_ENVIRONMENT must be"):
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
