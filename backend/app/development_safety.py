def require_development_data_reset(
    environment: str | None, opt_in: str | None
) -> None:
    if environment == "production":
        raise RuntimeError(
            "Development data scripts cannot run when BAYAA_ENVIRONMENT=production."
        )
    if environment != "development":
        raise RuntimeError(
            "Development data scripts require BAYAA_ENVIRONMENT=development."
        )
    if opt_in != "1":
        raise RuntimeError(
            "Set BAYAA_ALLOW_DEV_DATA_RESET=1 to run development data scripts."
        )
