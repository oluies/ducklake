# DuckLake on SQL Server — End-to-End Walkthrough

This document is the prose companion to [`scripts/ducklake_mssql_walkthrough.sh`](../../scripts/ducklake_mssql_walkthrough.sh) and the golden test [`test/sql/walkthrough/ducklake_mssql_orders_walkthrough.test`](../../test/sql/walkthrough/ducklake_mssql_orders_walkthrough.test). The goal is for a reviewer to read the metadata-table dumps and confirm every DuckLake invariant by eye.

## Setup

```bash
docker compose -f docker/sqlserver/docker-compose.yml up -d
export DUCKLAKE_MSSQL_CONNSTR="Server=localhost,1433;Database=ducklake_demo;User Id=sa;Password=DuckLake!2026;TrustServerCertificate=true;"
sqlcmd -S localhost -U sa -P "DuckLake!2026" -C -i test/fixtures/sqlserver_walkthrough_seed.sql
make demo-mssql
```

## Scenario

A small orders/order_items warehouse, walked through:

1. **ATTACH** — DuckLake initializes the metadata schema in SQL Server.
2. **CREATE SCHEMA `sales` + tables `orders`, `order_items`**.
3. **INSERT** initial rows (snapshot **S1**).
4. **UPDATE** one order + **INSERT** another (snapshot **S2**).
5. **DELETE** one order (snapshot **S3**).
6. **Time-travel** to S1 — assert original rows visible.
7. **Compaction** via `ducklake_merge_adjacent_files`.
8. **Expire S1** via `ducklake_expire_snapshots(... versions => 2)`.

At every step the script dumps:

- `ducklake_snapshot` — monotonic snapshot IDs, timestamps, author.
- `ducklake_schema` — schema rows with begin/end snapshot.
- `ducklake_table` — table rows with begin/end snapshot.
- `ducklake_column` — per-column metadata, including the T-SQL types from the mapping table.
- `ducklake_data_file` — Parquet file paths, row counts, snapshot ranges.
- `ducklake_file_column_stats` — min/max/null stats per column per file.
- `ducklake_tag` — any tags applied.
- `ducklake_snapshot_changes` — diff log per snapshot.

## What to verify visually

| Invariant | Where to look |
|---|---|
| Snapshot IDs increase monotonically | `ducklake_snapshot.snapshot_id` |
| Every commit produces exactly one new snapshot | `ducklake_snapshot_changes` rows per snapshot |
| Updated rows produce a new data file + delete file pair (copy-on-write) | `ducklake_data_file` after step 4 vs step 3 |
| Time-travel to S1 reads files whose `[begin_snapshot, end_snapshot)` includes S1 | `ducklake_data_file` snapshot ranges |
| Compaction reduces the number of `ducklake_data_file` rows for `sales.orders` | row count of `ducklake_data_file` before vs after step 7 |
| `ducklake_expire_snapshots(... versions => 2)` removes the oldest snapshot row | `ducklake_snapshot` count drops |
| All column types are persisted as T-SQL types (`BIGINT`, `NVARCHAR(MAX)`, `DECIMAL(10,2)`) | `ducklake_column.type` |

## Wire-level pinning

A single DuckLake transaction maps 1:1 to a TDS transaction on a pinned connection. To observe this against a running container:

```sql
-- In one DuckDB session:
ATTACH 'ducklake:mssql:...' AS lake (DATA_PATH '/tmp/lake');
USE lake;
BEGIN;
SELECT * FROM mssql_scan('lake', 'SELECT @@SPID AS spid');  -- e.g. 53
INSERT INTO sales.orders VALUES (99, 'pin', 1.00, '2026-01-03');
SELECT * FROM mssql_scan('lake', 'SELECT @@SPID AS spid');  -- still 53
COMMIT;
```

To watch the wire from the SQL Server side, enable Extended Events:

```sql
CREATE EVENT SESSION ducklake_xe ON SERVER
  ADD EVENT sqlserver.sql_batch_starting
ADD TARGET package0.ring_buffer;

ALTER EVENT SESSION ducklake_xe ON SERVER STATE = START;
-- Run the DuckLake transaction above, then:
SELECT
  CAST(event_data AS XML).value('(/event/data[@name="batch_text"]/value)[1]', 'NVARCHAR(MAX)') AS batch
FROM (
  SELECT CAST(t.target_data AS XML) td
  FROM sys.dm_xe_session_targets t
  JOIN sys.dm_xe_sessions s ON s.address = t.event_session_address
  WHERE s.name = 'ducklake_xe'
) x
CROSS APPLY td.nodes('//event') AS n(event_data);
```

The output shows `BEGIN TRAN`, the metadata `INSERT`s, and `COMMIT TRAN` all on the same SPID, proving the pinned-connection contract.

## CI

See [`sqlserver-ci.md`](./sqlserver-ci.md) — the `mssql-smoke` workflow runs this walkthrough on every PR and uploads the metadata-table dumps as a downloadable artifact (plus an inline excerpt in the job summary).
