# DuckLake SQL Server Metadata Backend

Status: **Incubating (opt-in via `-DENABLE_MSSQL=ON`).**
Spec: [`specs/001-mssql-metadata-backend/spec.md`](../../specs/001-mssql-metadata-backend/spec.md)

## Overview

DuckLake supports Microsoft SQL Server (2019 / 2022) as a metadata catalog backend alongside DuckDB, Postgres, and SQLite. Metadata reads dispatch through the upstream [`hugr-lab/mssql-extension`](https://github.com/hugr-lab/mssql-extension)'s `mssql_scan`; writes dispatch through `mssql_exec`. Transactions ride on the extension's pinned-connection model: DuckDB `BEGIN` / `COMMIT` / `ROLLBACK` translate into TDS `BEGIN TRAN` / `COMMIT TRAN` / `ROLLBACK TRAN` and pin one TDS connection for the lifetime of the transaction.

DuckLake does **not** vendor the `mssql` extension or carry patches against it (NFR-001 / SC-003 / Constitution Principle II).

## Quick start

```sql
INSTALL ducklake;
INSTALL mssql FROM community;
LOAD ducklake;
LOAD mssql;

ATTACH 'ducklake:mssql:Server=localhost,1433;Database=ducklakedb;User Id=sa;Password=...;TrustServerCertificate=true;'
    AS lake (DATA_PATH 's3://my-bucket/lake/');

USE lake;
CREATE TABLE orders(id BIGINT, amount DECIMAL(10,2));
INSERT INTO orders VALUES (1, 9.99), (2, 19.99);

SELECT catalog_type FROM ducklake_settings('lake');
-- sqlserver
```

ATTACH accepts both `ducklake:mssql:...` and `ducklake:sqlserver:...`; both resolve to the same backend, and `ducklake_settings()` reports the canonical name `sqlserver`.

## Build

```bash
make release CMAKE_FLAGS="-DENABLE_MSSQL=ON"
```

`ENABLE_MSSQL` defaults to `OFF` until the suite is green for two consecutive releases (NFR-002).

## Type mapping

See [`data-model.md`](../../specs/001-mssql-metadata-backend/data-model.md#type-mapping).

Highlights:
- `BOOLEAN` → `BIT`
- `INTEGER` → `INT`
- `DOUBLE` → `FLOAT`
- `VARCHAR` → `NVARCHAR(MAX)` (unlike Postgres — SQL Server can store null bytes)
- `BLOB` → `VARBINARY(MAX)`
- `UUID` → `UNIQUEIDENTIFIER`
- Timestamp / unsigned / 128-bit types → `NVARCHAR(40)` (parity with the Postgres backend)
- `STRUCT` / `MAP` / `LIST` / `VARIANT` / `GEOMETRY` → not natively supported; DuckLake stores them in Parquet, not in metadata columns.

## Identifier safety

`MaxIdentifierLength()` is `128` bytes. DuckLake rejects longer identifiers at write time with `InvalidInputException` rather than truncating silently (Constitution: Identifier-length safety).

## Schema handling

The backend honors the `metadata_schema` ATTACH parameter and defaults to `dbo` when unspecified. The schema is created with `IF SCHEMA_ID(N'<name>') IS NULL EXEC('CREATE SCHEMA [<name>]')` because T-SQL forbids `CREATE SCHEMA` inside a multi-statement batch.

## Testing

```bash
docker compose -f docker/sqlserver/docker-compose.yml up -d
export DUCKLAKE_MSSQL_CONNSTR="Server=localhost,1433;Database=ducklakedb;User Id=sa;Password=DuckLake!2026;TrustServerCertificate=true;"
make test-mssql
```

Skip list: [`specs/001-mssql-metadata-backend/skip-list.md`](../../specs/001-mssql-metadata-backend/skip-list.md).

## CI

- [`.github/workflows/SqlServer.yml`](../../.github/workflows/SqlServer.yml) — Linux matrix for SQL Server 2019 + 2022 (gating leg per NFR-003).
- [`.github/workflows/SqlServerWindows.yml`](../../.github/workflows/SqlServerWindows.yml) — Windows 2022 + SQL Server 2022 priority leg.
- [`.github/workflows/mssql-smoke.yml`](../../.github/workflows/mssql-smoke.yml) — daily smoke + metadata-dump artifact (see [`sqlserver-ci.md`](./sqlserver-ci.md)).
- [`.github/workflows/no-vendored-mssql.yml`](../../.github/workflows/no-vendored-mssql.yml) — repo-hygiene guard.
- [`.github/workflows/public-api-diff.yml`](../../.github/workflows/public-api-diff.yml) — NFR-004 guard.

## Limitations / known follow-ups

- T-SQL dialect rewrites currently cover `CREATE TABLE IF NOT EXISTS` and `CREATE SCHEMA IF NOT EXISTS`. Additional rewrites (`RETURNING` → `OUTPUT`, `LIMIT` → `TOP/FETCH`, `ON CONFLICT` → `MERGE`) land as Phase 8 stabilization test failures surface them.
- macOS CI runs are out of scope for v1 (no Microsoft-supported SQL Server image for macOS).
- Performance gate: write throughput must stay within `2.0 ×` of the Postgres backend on the `ducklake_commit_microbench` microbenchmark (see [`test/perf/ducklake_commit_microbench.sql`](../../test/perf/ducklake_commit_microbench.sql)).

## Walkthrough

See [`sqlserver-walkthrough.md`](./sqlserver-walkthrough.md) for a narrated end-to-end demo that dumps the metadata catalog at each step.
