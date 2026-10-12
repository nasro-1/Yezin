import pytest

from app.development_safety import require_development_data_reset


@pytest.mark.parametrize("environment", ["production", "test", None])
def test_development_data_scripts_reject_non_development_environments(
    environment: str | None,
) -> None:
    with pytest.raises(RuntimeError, match="BAYAA_ENVIRONMENT"):
        require_development_data_reset(environment, "1")


@pytest.mark.parametrize("opt_in", [None, "", "true", "yes"])
def test_development_data_scripts_require_explicit_opt_in(
    opt_in: str | None,
) -> None:
    with pytest.raises(RuntimeError, match="BAYAA_ALLOW_DEV_DATA_RESET=1"):
        require_development_data_reset("development", opt_in)


def test_development_data_scripts_accept_explicit_development_opt_in() -> None:
    require_development_data_reset("development", "1")
