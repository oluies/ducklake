# Data Model: SQL Server Metadata Backend

## Overview

The DuckLake metadata schema (ducklake_snapshot, ducklake_schema, ducklake_table, ducklake_column, ducklake_data_file, ducklake_file_column_stats, …) is the same across all backends. This document fixes the T-SQL flavor: column-type translation, list-aggregation, and the dialect-specific SQL emitted by `SQLServerMetadataManager`.

## Type Mapping

DuckDB logical type → T-SQL column type used by `GetColumnTypeInternal`:

| DuckDB type | SQL Server type | Notes |
|---|---|---|
| `BOOLEAN` | `BIT` | Literal `TRUE` / `FALSE` rewritten to `1` / `0`. |
| `TINYINT` | `SMALLINT` | T-SQL `TINYINT` is unsigned 0–255; we want signed. |
| `SMALLINT` | `SMALLINT` | |
| `INTEGER` | `INT` | |
| `BIGINT` | `BIGINT` | |
| `UTINYINT`, `USMALLINT` | `INT` | |
| `UINTEGER` | `BIGINT` | |
| `UBIGINT`, `HUGEINT`, `UHUGEINT` | `NVARCHAR(40)` | String-stored, matches Postgres backend's approach. |
| `FLOAT` | `REAL` | |
| `DOUBLE` | `FLOAT` | T-SQL `FLOAT` is 8-byte IEEE 754. |
| `DATE`, `TIMESTAMP`, `TIMESTAMP_TZ`, `TIMESTAMP_TZ_NS`, `TIMESTAMP_SEC`, `TIMESTAMP_MS`, `TIMESTAMP_NS` | `NVARCHAR(40)` | Avoids `datetime2` range/precision quirks. |
| `VARCHAR` | `NVARCHAR(MAX)` | Unicode by default. |
| `BLOB` | `VARBINARY(MAX)` | |
| `DECIMAL(p,s)` | `DECIMAL(p,s)` | |
| `UUID` | `UNIQUEIDENTIFIER` | Verified at Phase 1 — fall back to `NVARCHAR(36)` if encoding issues arise. |
| `STRUCT`, `MAP`, `LIST`, `VARIANT`, `GEOMETRY` | (not natively supported) | `TypeIsNativelySupported` returns `false`; DuckLake stores these in Parquet, not in metadata columns. |

## `TypeIsNativelySupported`

Returns `false` for the same set Postgres rejects, plus T-SQL-specific exclusions:

```
STRUCT, MAP, LIST,
UBIGINT, HUGEINT, UHUGEINT,
DATE, TIMESTAMP, TIMESTAMP_TZ, TIMESTAMP_TZ_NS, TIMESTAMP_SEC, TIMESTAMP_MS, TIMESTAMP_NS,
BLOB,             -- because of varbinary encoding round-trip concerns; revisit in Phase 1
VARIANT,
GEOMETRY
```

`VARCHAR` is natively supported on SQL Server (unlike Postgres, which can't store null bytes).

## `SupportsInlining`

Same as base, except `VARIANT` is unconditionally excluded.

## Identifier Quoting and Length

- `MaxIdentifierLength()` returns `128`.
- All emitted identifiers are wrapped in `"…"` (works when `QUOTED_IDENTIFIER ON`, which is the extension default).
- Tag keys / column names exceeding 128 bytes are rejected at write time with `InvalidInputException`.

## List Aggregation (`FOR JSON PATH`)

Postgres backend emits:
```sql
jsonb_agg(jsonb_build_object('key', val, 'key2', val2))
```

T-SQL replacement:
```sql
(SELECT 'key' = val, 'key2' = val2 FOR JSON PATH)
```

`LoadTags` / `LoadInlinedDataTables` / `LoadMacroImplementations` parse the resulting `NVARCHAR(MAX)` JSON. DuckDB's `read_json_auto` over a single-row `VARCHAR` is the simplest implementation, mirroring the Postgres parsing of `jsonb_agg` output.

## Dispatch SQL Templates

### Execute (writes)

```cpp
auto sql_literal = SQLString(query);   // T-SQL-escaped (single-quote doubling)
auto attached    = SQLString(catalog.MetadataDatabaseName());
return connection.Query(
    StringUtil::Format("CALL mssql_exec(%s, %s)", attached, sql_literal));
```

### Query (reads)

```cpp
return connection.Query(
    StringUtil::Format("SELECT * FROM mssql_scan(%s, %s)", attached, sql_literal));
```

### Transaction boundaries

DuckLake already calls `transaction.Query("BEGIN")` / `transaction.Query("COMMIT")` for the metadata DB. With `TYPE mssql`, these are routed to the extension's transaction provider, which pins one TDS connection until commit/rollback. No DuckLake-side code change needed beyond making sure `Execute` and `Query` always go through the same attached DB name.

### Latest-snapshot query

```sql
SELECT TOP 1 snapshot_id, schema_version, next_catalog_id, next_file_id
FROM "{METADATA_SCHEMA_ESCAPED}".ducklake_snapshot
ORDER BY snapshot_id DESC;
```

(Wrapped in `SELECT * FROM mssql_scan(<db>, '<sql>')` by `Query`.)

## CREATE TABLE templates

Every base-class CREATE TABLE in `GetCreateTableStatements` is rewritten to:

```sql
IF OBJECT_ID(N'"{METADATA_SCHEMA_ESCAPED}".ducklake_snapshot', N'U') IS NULL
BEGIN
    CREATE TABLE "{METADATA_SCHEMA_ESCAPED}".ducklake_snapshot (
        snapshot_id      BIGINT      NOT NULL PRIMARY KEY,
        schema_version   BIGINT      NOT NULL,
        next_catalog_id  BIGINT      NOT NULL,
        next_file_id     BIGINT      NOT NULL,
        snapshot_time    NVARCHAR(40) NOT NULL,
        author           NVARCHAR(MAX),
        commit_message   NVARCHAR(MAX),
        commit_extra     NVARCHAR(MAX)
    );
END;
```

The same `IF OBJECT_ID(...) IS NULL` guard is used for every metadata table.

## DML / DDL substitutions

| Base-class snippet | T-SQL form |
|---|---|
| `INSERT … RETURNING id` | `INSERT … OUTPUT INSERTED.id INTO @ret …;` (or scoped via `OUTPUT` into a table variable). |
| `DELETE … WHERE id = ANY(?)` | `DELETE … WHERE id IN (…)`. |
| `LIMIT N` | `TOP (N)` for SELECT; `OFFSET 0 ROWS FETCH NEXT N` when ORDER BY is present. |
| `ON CONFLICT DO NOTHING` | `MERGE … WHEN MATCHED THEN … WHEN NOT MATCHED BY TARGET THEN INSERT …;`. |
| `string || string` | `CONCAT(string, string)` or `+`. |

## Indexing

Match the index set used by the Postgres backend, with T-SQL syntax (`CREATE NONCLUSTERED INDEX …`). Primary keys are clustered by default in SQL Server, which is what we want for snapshot/file/table-ID lookups.
