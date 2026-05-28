# Feature Specification: SQL Server (MSSQL) Metadata Backend for DuckLake

**Feature Branch**: `001-mssql-metadata-backend`
**Created**: 2026-05-22
**Status**: Draft
**Input**: User description: "MetadataManager in the ducklake extension to use the hugr-lab mssql plugin. Do the same as PR #1152 but as a clean upstream-friendly path."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Attach a DuckLake whose catalog lives in SQL Server (Priority: P1)

As a data engineer, I want to attach a DuckLake whose metadata catalog is hosted on Microsoft SQL Server, so that organizations already standardized on SQL Server can adopt DuckLake without standing up a separate Postgres or DuckDB metadata store.

**Why this priority**: This is the core value of the feature. Without it the integration delivers nothing. All other stories build on a working ATTACH.

**Independent Test**: Run `ATTACH 'ducklake:mssql:<conn-str>' AS my_lake (DATA_PATH '...')` against a SQL Server 2019+ instance with an empty schema, then `SHOW TABLES FROM my_lake` — succeeds and returns zero rows. Creating a table afterwards persists in SQL Server.

**Acceptance Scenarios**:

1. **Given** a SQL Server instance and a valid connection string, **When** the user runs `ATTACH 'ducklake:mssql:...' AS lake`, **Then** the DuckLake metadata schema is created in SQL Server and the catalog is queryable.
2. **Given** an existing DuckLake catalog on SQL Server, **When** the user attaches it, **Then** existing tables, schemas, views, macros, and snapshots are visible.
3. **Given** a DuckLake configured for `ducklake_version` V1.0 on SQL Server, **When** the extension is upgraded and the catalog is reattached with `AUTOMATIC_MIGRATION=TRUE`, **Then** the catalog migrates to V1.1.

---

### User Story 2 - Write, snapshot, and time-travel against an MSSQL-backed DuckLake (Priority: P1)

As an analytics user, I want all DML and snapshot operations on a DuckLake to commit atomically against the SQL Server catalog, so that I get the same correctness guarantees as the DuckDB and Postgres backends.

**Why this priority**: Read-only attach is not useful on its own. Atomic writes are the defining DuckLake feature.

**Independent Test**: Create a table, insert rows in three separate transactions, take a snapshot between each, then `SELECT ... FROM table AT (SNAPSHOT => N)` for each snapshot — all three return the expected row counts.

**Acceptance Scenarios**:

1. **Given** an empty MSSQL-backed DuckLake, **When** the user runs `CREATE TABLE t AS SELECT * FROM range(1000)`, **Then** the data file is written to `DATA_PATH`, ducklake metadata rows are inserted in SQL Server, and a snapshot is recorded — all within a single SQL Server transaction.
2. **Given** two concurrent writers, **When** both attempt to commit overlapping table changes, **Then** one commit succeeds and the loser retries or errors per the existing DuckLake conflict-resolution contract.
3. **Given** a successful commit, **When** the user runs `SELECT * FROM ducklake_snapshots('lake')`, **Then** the new snapshot appears with the expected author, message, and timestamps.

---

### User Story 3 - Run the full DuckLake test suite against SQL Server in CI (Priority: P1)

As a maintainer, I want the existing DuckLake SQL test suite to be runnable with `--config sqlserver.json`, so that regressions in the MSSQL backend are caught automatically.

**Why this priority**: Without CI coverage the backend will drift. P1 because the test plumbing is what protects every other guarantee here.

**Independent Test**: `make test-mssql` (or the equivalent CI job) brings up a SQL Server container, runs the suite tagged for non-DuckDB backends, and reports pass/fail.

**Acceptance Scenarios**:

1. **Given** a SQL Server service container, **When** the test runner is launched with the sqlserver config, **Then** the same set of tests that pass for `postgres.json` and `sqlite.json` also passes for `sqlserver.json` (modulo documented skips).
2. **Given** a documented skip list for tests that exercise unsupported types (e.g. STRUCT/MAP/LIST as catalog columns), **When** those tests are run, **Then** they are reported as `skipped`, not `failed`.

---

### User Story 4 - Compaction, cleanup, and inlined-data flush against SQL Server (Priority: P2)

As an operator, I want background DuckLake maintenance (compaction, expired-snapshot cleanup, inlined-data flush) to work against SQL Server, so that long-running deployments do not accumulate metadata or storage bloat.

**Why this priority**: Lower than core read/write because deployments can survive without maintenance for a while, but a backend that can't be cleaned up is not production-ready.

**Acceptance Scenarios**:

1. **Given** a DuckLake with old snapshots, **When** the user runs `CALL ducklake_expire_snapshots('lake', older_than => ...)`, **Then** snapshot rows are deleted in SQL Server and orphaned files are queued for cleanup.
2. **Given** a small inlined table that crosses the inlining threshold, **When** the next commit triggers a flush, **Then** the inlined rows are written to Parquet, the SQL Server inline rows are deleted, and the snapshot reflects the new file.

---

### User Story 5 - Clear error surface when the MSSQL extension is missing or misconfigured (Priority: P3)

As a user, when I attach a `ducklake:mssql:` path without the `mssql` extension installed, I want a single actionable error telling me what to install, so that I do not have to chase opaque catalog errors.

**Acceptance Scenarios**:

1. **Given** the `mssql` extension is not installed, **When** the user attaches an MSSQL-backed DuckLake, **Then** the error message names the missing extension and the install command.
2. **Given** invalid SQL Server credentials, **When** the user attaches, **Then** the error surfaces the underlying connection failure from the `mssql` extension — DuckLake does not swallow it.

---

### Edge Cases

- T-SQL has no native unsigned ints, `HUGEINT`, `UBIGINT`, `UHUGEINT`, `STRUCT`, `MAP`, `LIST`, `VARIANT`, or `GEOMETRY`. The backend must store these as `NVARCHAR(MAX)` (or refuse, consistent with how Postgres handles them).
- SQL Server identifier limit is 128 chars. Tables, schemas, columns, and tags whose names exceed this must be rejected at write time with a clear error.
- `datetime2` precision and range differ from DuckDB's timestamp types. Timestamps are stored as `NVARCHAR` (mirrors Postgres backend behavior).
- Concurrent commits must use SQL Server's `SERIALIZABLE` or `READ COMMITTED SNAPSHOT` isolation — verify which the `mssql` extension's pinned-connection model exposes.
- The `mssql` extension pins one TDS connection between `BEGIN` and `COMMIT`/`ROLLBACK`. DuckLake's transaction code must drive `BEGIN` / `COMMIT` through `mssql_exec` so the pin engages.
- ATTACH against an unreachable SQL Server should fail fast (the upstream extension already addresses this in their spec 001-attach-connection-validation).

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The system MUST register an `SQLServerMetadataManager` for catalog types `mssql` and `sqlserver`.
- **FR-002**: The system MUST drive all SQL Server I/O through the `mssql` community extension's `mssql_exec` and `mssql_scan` table/scalar functions; it MUST NOT link or vendor any SQL Server driver directly.
- **FR-003**: The system MUST drive DuckLake transaction boundaries through DuckDB's standard `BEGIN` / `COMMIT` / `ROLLBACK` on the attached metadata database. The `mssql` extension's transaction provider MUST translate these into TDS `BEGIN TRAN` / `COMMIT TRAN` / `ROLLBACK TRAN` and pin one TDS connection for the lifetime of the transaction, so every subsequent `mssql_exec` / `mssql_scan` call against the same attached database lands on that pinned connection.
- **FR-004**: The system MUST persist the same DuckLake schema (ducklake_snapshot, ducklake_table, ducklake_column, etc.) currently used by the Postgres and SQLite backends, adapted to T-SQL.
- **FR-005**: The system MUST translate DuckDB logical types to T-SQL column types per the [type-mapping](./data-model.md#type-mapping) table.
- **FR-006**: The system MUST cap identifier length at 128 bytes (`MaxIdentifierLength() = 128`).
- **FR-007**: The system MUST disable the DuckDB Appender path (`SupportsAppender() = false`).
- **FR-008**: The system MUST integrate with the existing `DuckLakeMetadataManagerV1_1<Base>` template via an explicit instantiation for `SQLServerMetadataManager`.
- **FR-009**: The system MUST surface SQL Server errors verbatim (wrapped in DuckLake context) without swallowing them.
- **FR-010**: The system MUST autoload the `mssql` extension when a `ducklake:mssql:` path is attached, falling back to a clear "install mssql extension" error if autoload fails.

### Non-Functional Requirements

- **NFR-001**: No vendored copy of `mssql-extension` and no patches against it in this repository. Any required upstream change is filed as a PR to `hugr-lab/mssql-extension` first.
- **NFR-002**: The MSSQL backend MUST be opt-in at build time (`-DENABLE_MSSQL=ON`) until the dependency stabilizes, after which it ships by default.
- **NFR-003**: The full DuckLake SQL test suite MUST run green against SQL Server 2019 and 2022 on Linux (gating leg) before merge. A Windows leg covering SQL Server 2022 MUST also run on every PR as a priority second leg; failures on the Windows leg block merge unless the failure is documented in the skip list.
- **NFR-004**: No new public C++ API in DuckLake beyond the registration of one new metadata manager.

### Out of Scope

- SQL Server as a *data* file backend (Parquet remains the only data format).
- Azure-specific authentication flows (those are the `mssql` extension's domain — DuckLake just passes the connection string through).
- Pre-V1.0 DuckLake catalog versions on SQL Server.
- macOS CI runs of the SQL Server test job (Linux is the v1 gating leg; Windows is in scope as a parallel priority — see NFR-003).

## Success Criteria *(mandatory)*

- **SC-001**: For every CI run, `passed_sqlserver / passed_postgres ≥ 0.95`, where both counts come from the same test set run against `sqlserver.json` and `postgres.json` respectively. Tests explicitly tagged `mode skip-sqlserver` and listed in `specs/001-mssql-metadata-backend/skip-list.md` (with justification) do not count against either side of the ratio.
- **SC-002**: A user can attach, write, snapshot, time-travel, compact, and expire snapshots end-to-end against a SQL Server 2022 instance using only released artifacts (no patched extension).
- **SC-003**: The DuckLake repository contains zero `.patch` files against the `mssql` extension.
