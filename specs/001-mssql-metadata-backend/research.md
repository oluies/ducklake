# Research: SQL Server Metadata Backend

## Overview

This document captures findings on the upstream `mssql-extension`, the existing DuckLake metadata-manager extension points, and the lessons learned from PR #1152.

## 1. Upstream extension: `hugr-lab/mssql-extension`

Pinned version: **v0.2.0** (2026-05-20).

### Functions used by DuckLake

| Function | Signature | Use in DuckLake |
|---|---|---|
| `mssql_scan(db, query)` | table function, streams result set | All reads (`Query` path). |
| `mssql_exec(db, sql)` | scalar function, returns affected row count | All writes (`Execute` path), including `BEGIN TRAN` / `COMMIT TRAN`. |
| `mssql_refresh_cache(db)` | scalar | Optional — used only if we hit catalog cache staleness during tests. |
| `mssql_pool_stats()` | table | Diagnostics; not in the hot path. |
| `mssql_version()` | scalar | Used for the autoload error path to confirm the loaded extension is recent enough. |

### Catalog integration

`ATTACH '<conn-str>' AS <name> (TYPE mssql)` is fully supported by the extension. DuckLake's `DuckLakeInitializer::Initialize` already does an `ATTACH OR REPLACE {METADATA_PATH} AS {METADATA_CATALOG_NAME_IDENTIFIER}` and stamps the type. We rely on this unchanged.

### Transaction model — confirmed

> *User-confirmed 2026-05-22*: "transaction is supported. when begin was called the connection is pinned and all functions get the same connection (it's mean pinned connection)"

So the dispatch is:

```sql
CALL mssql_exec(:db, 'BEGIN TRAN');
-- subsequent CALL mssql_exec(:db, ...) / SELECT … FROM mssql_scan(:db, …)
-- all run on the same pinned TDS connection
CALL mssql_exec(:db, 'COMMIT TRAN');
```

This means DuckLake transactions translate one-to-one to SQL Server transactions: when DuckLake calls `transaction.Query("BEGIN")` on the attached metadata DB, the `mssql` extension intercepts the wrapping DuckDB transaction lifecycle and pins. We do **not** need to invent a transaction wrapper.

## 2. Current DuckLake extension points

### Registration

`src/storage/ducklake_metadata_manager.cpp:40-44`:

```cpp
unordered_map<string, create_t> metadata_managers = {
    {"postgres", PostgresMetadataManager::Create},
    {"postgres_scanner", PostgresMetadataManager::Create},
    {"sqlite", SQLiteMetadataManager::Create},
    {"sqlite_scanner", SQLiteMetadataManager::Create},
};
```

We add `{"mssql", SQLServerMetadataManager::Create}` and `{"sqlserver", SQLServerMetadataManager::Create}`.

The dispatch happens in `DuckLakeMetadataManager::Create`, which reads `catalog.MetadataType()`. `metadata_type` is populated from either the `type` option of ATTACH or by `DBPathAndType::ExtractExtensionPrefix(path, metadata_type)` (so paths like `ducklake:mssql:Server=…` set `metadata_type = "mssql"` automatically).

### V1.1 wrapper

`src/storage/ducklake_initializer.cpp:285-304` uses `dynamic_cast` on the current base manager to pick the V1.1 template instance. We add an `else if (dynamic_cast<SQLServerMetadataManager*>(...))` branch.

`src/metadata_manager/ducklake_metadata_manager_v1_1.cpp` adds:

```cpp
template class DuckLakeMetadataManagerV1_1<SQLServerMetadataManager>;
```

### Virtuals to override

From `src/include/storage/ducklake_metadata_manager.hpp`:

| Virtual | Required override? | Why |
|---|---|---|
| `TypeIsNativelySupported(const LogicalType&)` | YES | T-SQL has no unsigned ints, HUGEINT, STRUCT/MAP/LIST, VARIANT, GEOMETRY, etc. |
| `SupportsInlining(const LogicalType&)` | YES | At minimum VARIANT must be excluded. |
| `SupportsAppender()` | YES (→ `false`) | Appender is a DuckDB-only optimization. |
| `MaxIdentifierLength()` | YES (→ `128`) | SQL Server hard limit. |
| `GetColumnTypeInternal(const LogicalType&)` | YES | DuckDB → T-SQL type mapping. |
| `Execute(snapshot, query)` | YES | Dispatches via `CALL mssql_exec(...)`. |
| `Query(snapshot, query)` | YES | Dispatches via `SELECT … FROM mssql_scan(...)`. |
| `GetLatestSnapshotQuery()` | YES | T-SQL `MAX()` is fine; the wrap differs. |
| `ListAggregation(...)` | YES | T-SQL has no `jsonb_agg`. Use `FOR JSON PATH`. |
| `LoadTags`, `LoadInlinedDataTables`, `LoadMacroImplementations` | YES | Parse the JSON returned by the new `ListAggregation`. |
| `TransformInlinedData(...)` | Likely NO | Only override if blob/varchar reinterpret is needed (Postgres needs it; SQL Server's `VARBINARY` round-trips cleanly). |
| `GetCreateTableStatements` (via V1.1 wrapper) | Indirect | Base statements need T-SQL adjustments (see [data-model.md](data-model.md)). |

## 3. Lessons from PR #1152

The PR author's seven patches and what they tell us:

| Patch | Cause | Avoidable? |
|---|---|---|
| `duckdb-api-compat.patch` | `FlatVector::GetData` → `GetDataMutable` and bind signature change | Yes — caused by targeting an outdated extension version. Pin to ≥ v0.2.0. |
| `duckdb-interrupt-api-compat.patch` | Manual `context.interrupted` checks no longer compile | Yes — v0.2.0 already uses DuckDB's built-in mechanism. |
| `duckdb-refresh-cache-api-compat.patch` | Same root cause as above | Yes. |
| `duckdb-scan-pushdown-api-compat.patch` | Pushdown API change | Yes. |
| `duckdb-z-datachunk-cardinality-compat.patch` | DataChunk API change | Yes. |
| `duckdb-z-macos-httplib-link.patch` | Build-system issue | Out of our scope — file upstream if it recurs. |
| `duckdb-z-transaction-provider-compat.patch` | Author worked around transaction descriptor API by routing helper calls to pooled autocommit connections | **No longer needed** — the pinned-connection model in v0.2.0 is exactly what we want. |

Net: by tracking a current upstream release, we expect to ship zero patches.

The author also closed the PR with: *"intended to iterate on fork first via origin PR instead of upstream for now"* and proposed *"a separate PR to the mssql-extension repository to add an attach option designating the attached database as the DuckLake catalog"*. We treat that as an optional Phase 0 follow-up — useful if the extension ever needs DuckLake-aware behavior, but the current API is enough to ship without it.

## 4. T-SQL dialect items to address

Sourced from the base-class SQL templates (see `src/storage/ducklake_metadata_manager.cpp`):

| Postgres / DuckDB construct | T-SQL replacement |
|---|---|
| `CREATE TABLE IF NOT EXISTS X` | `IF OBJECT_ID(N'X', N'U') IS NULL CREATE TABLE X (...)` |
| `BOOLEAN` / `TRUE` / `FALSE` | `BIT` / `1` / `0` |
| `BLOB`, unbounded `VARCHAR` | `VARBINARY(MAX)`, `NVARCHAR(MAX)` |
| Unsigned ints / HUGEINT | `NVARCHAR(40)` (string-stored, same as Postgres backend) |
| `TIMESTAMP*`, `DATE` | `NVARCHAR(40)` |
| `RETURNING …` | `OUTPUT INSERTED.…` |
| `LIMIT N` | `TOP (N)` or `OFFSET 0 ROWS FETCH NEXT N ROWS ONLY` |
| `jsonb_agg(jsonb_build_object(...))` | `(SELECT … FOR JSON PATH)` |
| `'…'` literal escape (`''`) | Same. |
| Identifier quoting | `[…]` or `"…"` (`QUOTED_IDENTIFIER ON` is the extension default; we use `"…"` for portability). |
| `MERGE … ON CONFLICT` | `MERGE INTO … WHEN MATCHED … WHEN NOT MATCHED …;` |

## 5. Connection-string and ATTACH handling

The extension already validates the connection string up front (per their spec `001-attach-connection-validation`). DuckLake forwards the metadata path verbatim through `ATTACH OR REPLACE`. No additional parsing needed on our side.

## 6. CI

- Service-container matrix on Linux: `mcr.microsoft.com/mssql/server:2019-latest` **and** `mcr.microsoft.com/mssql/server:2022-latest`, env `ACCEPT_EULA=Y`, `SA_PASSWORD=…`. Both legs must pass before merge (NFR-003, T030).
- Main test job mirrors `postgres.yml`, sets `DUCKLAKE_TEST_BACKEND=sqlserver`, runs the SQL suite with `--config test/configs/sqlserver.json`. Skip list lives in `specs/001-mssql-metadata-backend/skip-list.md` (T031). The `passed_sqlserver / passed_postgres ≥ 0.95` ratio gate is enforced by T031a.
- Dedicated `mssql-smoke` workflow (T052) runs the human-validation walkthrough against the pinned `mssql` extension version on every PR plus a daily cron, uploading metadata dumps as artifacts and inlining them into the job summary.
- Repo-hygiene guards (T032a, T032b) enforce NFR-001 / NFR-004 by failing builds that introduce vendored mssql sources, `.patch` files against the extension, or public-header additions outside `sqlserver_metadata_manager.hpp`.
- Gating legs:
  - **Linux (priority 1)**: SQL Server 2019 + 2022 service containers as above; must be green to merge.
  - **Windows (priority 2)**: `windows-2022` runner with SQL Server 2022 installed via Chocolatey (`choco install sql-server-2022`) or the Microsoft setup binary; runs the same suite. Must be green on every PR; documented skips allowed, silent failure not allowed.
  - **macOS**: out of scope for v1 (no Microsoft-supported SQL Server image for macOS).
