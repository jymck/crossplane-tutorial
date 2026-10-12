# Azure SQL Demo Backend

This backend preserves the demo's `/`, `/healthz`, `/video?id=...&title=...`, and `/videos` HTTP endpoints, but connects to Microsoft SQL Server/Azure SQL using `github.com/microsoft/go-mssqldb`.

Required environment variables:

- `DB_ENDPOINT`: Azure SQL Server FQDN, without a scheme or port.
- `DB_PORT`: usually `1433`; defaults to `1433`.
- `DB_USERNAME`: SQL authentication login.
- `DB_PASSWORD`: SQL authentication password.
- `DB_NAME`: Azure SQL database name.

The process creates `dbo.videos` if it does not already exist. It requires network access to Azure SQL and a database login allowed to create that table. Connections use TLS encryption.

Build locally:

```sh
docker build -t azure-sql-demo:local apps/azure-sql-demo
```

GitHub Actions publishes `ghcr.io/<owner>/<repository>/azure-sql-demo` on changes to this directory. After the first successful publish, set the GHCR package visibility to Public (or configure an image pull secret for AKS) before using it in a claim.
