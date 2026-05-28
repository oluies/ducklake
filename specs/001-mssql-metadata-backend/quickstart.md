# Quickstart: SQL Server-Backed DuckLake

## Prerequisites

- DuckDB ≥ the version bundled with this DuckLake build.
- `mssql` community extension ≥ v0.2.0 (autoloaded; no manual install needed if your DuckDB is internet-connected).
- A reachable SQL Server 2019 or 2022 instance with `CREATE TABLE` rights in the target database/schema.

## Attach a new DuckLake on SQL Server

```sql
-- One-liner: data files on local disk, metadata in SQL Server
ATTACH 'ducklake:mssql:Server=localhost,1433;Database=ducklake_meta;User Id=sa;Password=Strong!Pass;Encrypt=true'
    AS lake (DATA_PATH '/data/lake/');

USE lake;

CREATE SCHEMA analytics;
CREATE TABLE analytics.events AS
SELECT range AS event_id, 'click' AS kind FROM range(1_000_000);
```

## Attach an existing DuckLake on SQL Server

```sql
ATTACH 'ducklake:mssql:Server=localhost,1433;Database=ducklake_meta;User Id=sa;Password=Strong!Pass'
    AS lake;
```

DuckLake detects existing metadata tables and skips initialization. If the catalog is at an older DuckLake version, add `AUTOMATIC_MIGRATION=TRUE`:

```sql
ATTACH '…' AS lake (AUTOMATIC_MIGRATION TRUE);
```

## Equivalent explicit-type syntax

```sql
ATTACH 'Server=localhost,1433;Database=ducklake_meta;User Id=sa;Password=Strong!Pass'
    AS lake (TYPE ducklake, METADATA_TYPE 'mssql', DATA_PATH '/data/lake/');
```

(Internally these route to the same `SQLServerMetadataManager`.)

## Transactions

```sql
BEGIN TRANSACTION;
INSERT INTO lake.analytics.events VALUES (-1, 'manual');
INSERT INTO lake.analytics.events VALUES (-2, 'manual');
COMMIT;
```

DuckDB's `BEGIN` pins one TDS connection in the `mssql` extension; both `INSERT`s and the snapshot row land in the same SQL Server transaction. `ROLLBACK` discards both.

## Time travel

```sql
-- Snapshot list
SELECT * FROM ducklake_snapshots('lake');

-- Read a specific snapshot
SELECT * FROM lake.analytics.events AT (SNAPSHOT => 3);
```

## Maintenance

```sql
-- Compact small files
CALL ducklake_merge_adjacent_files('lake.analytics.events');

-- Drop snapshots older than 7 days
CALL ducklake_expire_snapshots('lake', older_than => NOW() - INTERVAL 7 DAY);

-- Clean up orphan files on storage
CALL ducklake_cleanup_old_files('lake', cleanup_all => TRUE);
```

## Error scenarios

| Symptom | What it means |
|---|---|
| `Catalog Error: extension "mssql" not loaded` | Autoload failed; install with `INSTALL mssql FROM community; LOAD mssql;`. |
| `IO Error: Failed to acquire connection for metadata refresh` | Upstream extension reported a connection failure — credentials or network. See the extension's `001-attach-connection-validation` spec. |
| `Invalid Input: identifier "…" exceeds maximum length 128` | A schema/table/column/tag name is too long for SQL Server. Rename. |
| `Not Implemented: column type STRUCT cannot be stored in SQL Server metadata` | Type not in the supported set — see [data-model.md](data-model.md). |
