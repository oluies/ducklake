# DuckLake MSSQL CI Runbook

This document explains the `mssql-smoke` workflow ([`.github/workflows/mssql-smoke.yml`](../../.github/workflows/mssql-smoke.yml)) — how to read a run, where the metadata dumps live, how to bump the pinned extension version, and how to reproduce a run locally.

## What the workflow does

On every PR that touches the SQL Server backend (plus a daily 06:00 UTC cron), the workflow:

1. Reads the pinned upstream `mssql` extension version from [`specs/001-mssql-metadata-backend/mssql-extension.version`](../../specs/001-mssql-metadata-backend/mssql-extension.version).
2. Starts a SQL Server 2022 instance: Docker on Linux, Chocolatey on Windows.
3. Builds DuckLake with `-DENABLE_MSSQL=ON`.
4. Installs the `mssql` extension from the DuckDB community repo and **asserts the resolved version matches the pin**. Mismatch fails the workflow — this catches silent upstream drift.
5. Seeds the demo database with [`test/fixtures/sqlserver_walkthrough_seed.sql`](../../test/fixtures/sqlserver_walkthrough_seed.sql).
6. Runs [`scripts/ducklake_mssql_walkthrough.sh --ci`](../../scripts/ducklake_mssql_walkthrough.sh) and captures every metadata-table dump.
7. Runs the golden SQLLogicTest [`ducklake_mssql_orders_walkthrough.test`](../../test/sql/walkthrough/ducklake_mssql_orders_walkthrough.test).
8. Uploads `metadata-dump.txt` and `metadata-dump.html` as workflow artifacts.
9. Inlines the first 200 lines of `metadata-dump.txt` into the GitHub Actions job summary.

## How to read a run

- Open the workflow run from the Checks tab on the PR.
- The **Summary** panel inlines a markdown excerpt of the metadata catalog state at each walkthrough step. Most reviews can stop here.
- For the full dump, expand **Artifacts** at the bottom of the run and download `metadata-dump-ubuntu-latest` or `metadata-dump-windows-2022`.
- If a step labelled "Assert resolved mssql extension version matches pin" failed, the upstream extension shipped a new version that doesn't match `mssql-extension.version`. See "Bumping the pin" below.
- If the golden SQLLogicTest failed, expand its step output — the failing assertion line is the first place to look.

## Bumping the pin

```bash
# 1. Pick the new tag (https://github.com/hugr-lab/mssql-extension/releases).
# 2. Bump the file.
echo "v0.3.0" > specs/001-mssql-metadata-backend/mssql-extension.version
# 3. Open a PR. Phase 10 will rerun against the new tag.
# 4. If the run is green, merge. If it goes red, attach the failing run's
#    metadata-dump artifact to the PR description so reviewers can see what changed.
```

The pin is read by both [`.github/config/extensions/mssql.cmake`](../../.github/config/extensions/mssql.cmake) (build-time) and the workflow's version assertion (runtime).

## Reproducing locally

```bash
docker compose -f docker/sqlserver/docker-compose.yml up -d
export DUCKLAKE_MSSQL_CONNSTR="Server=localhost,1433;Database=ducklake_demo;User Id=sa;Password=DuckLake!2026;TrustServerCertificate=true;"
sqlcmd -S localhost -U sa -P "DuckLake!2026" -C -i test/fixtures/sqlserver_walkthrough_seed.sql
make demo-mssql
```

To reproduce the workflow exactly, use [`act`](https://github.com/nektos/act):

```bash
act -W .github/workflows/mssql-smoke.yml -j smoke --matrix os:ubuntu-latest
```

## Cross-references

- Backend overview: [`sqlserver.md`](./sqlserver.md)
- Narrated walkthrough: [`sqlserver-walkthrough.md`](./sqlserver-walkthrough.md)
- Spec / plan / tasks: [`specs/001-mssql-metadata-backend/`](../../specs/001-mssql-metadata-backend/)
