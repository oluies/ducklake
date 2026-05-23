# Tasks: SQL Server Metadata Backend

**Input**: Design documents from `/specs/001-mssql-metadata-backend/`
**Prerequisites**: spec.md, plan.md, research.md, data-model.md

**Tests**: Included — DuckDB SQLLogicTest format, executed against a containerized SQL Server.

**Organization**: Grouped by user story (US1..US5) per the spec, so each story can land independently.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies).
- **[Story]**: User-story tag from spec.md.

## Path conventions

All paths relative to repo root.

---

## Phase 1: Setup

- [X] T001 Create `specs/001-mssql-metadata-backend/` (done as part of this PR).
- [ ] T002 [P] Add `ENABLE_MSSQL` option to top-level `CMakeLists.txt` (default OFF until v1).
- [ ] T003 [P] Declare `mssql` as an optional autoloaded community extension in `extension_config.cmake`.
- [ ] T004 Stand up a local SQL Server 2022 container via `docker compose` for development (file under `docker/`).

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Class skeleton + registration so the rest of the work can compile and link.

- [ ] T005 Create `src/include/metadata_manager/sqlserver_metadata_manager.hpp` declaring `SQLServerMetadataManager : public DuckLakeMetadataManager`. Override stubs: `TypeIsNativelySupported`, `SupportsInlining`, `SupportsAppender`, `MaxIdentifierLength`, `GetColumnTypeInternal`, `Execute`, `Query`, `GetLatestSnapshotQuery`, `ListAggregation`, `LoadTags`, `LoadInlinedDataTables`, `LoadMacroImplementations`, plus a static `Create`.
- [ ] T006 Create `src/metadata_manager/sqlserver_metadata_manager.cpp` with empty stubs that compile.
- [ ] T007 Modify `src/metadata_manager/CMakeLists.txt` to compile the new source under `ENABLE_MSSQL`.
- [ ] T008 Modify `src/storage/ducklake_metadata_manager.cpp` (lines 40–44) to register `"mssql"` and `"sqlserver"` aliases.
- [ ] T009 Modify `src/metadata_manager/ducklake_metadata_manager_v1_1.cpp` to add `template class DuckLakeMetadataManagerV1_1<SQLServerMetadataManager>;`.
- [ ] T010 Modify `src/storage/ducklake_initializer.cpp:285-304` (`SetVersionedMetadataManager`) to dispatch the V1.1 wrapper for `SQLServerMetadataManager`.
- [ ] T011 Modify `src/functions/ducklake_settings.cpp` to normalize the internal name `mssql` to `sqlserver` in `ducklake_settings()` output (FR-001 commits to both aliases).
- [ ] T010a [US1] Add `test/sql/metadata/ducklake_mssql_txn_pinning.test`: inside a single DuckLake transaction against an MSSQL-backed catalog, capture SQL Server `@@SPID` via `mssql_scan(<db>, 'SELECT @@SPID')` before/after multiple metadata reads and writes; assert SPID is identical until COMMIT and that ROLLBACK discards the writes. Validates FR-003 transaction pinning.

**Checkpoint**: Code compiles with `ENABLE_MSSQL=ON`. `ATTACH 'ducklake:mssql:…'` resolves to `SQLServerMetadataManager` but every method throws `NotImplemented`.

---

## Phase 3: User Story 1 — Attach (Priority: P1) 🎯 MVP

**Goal**: ATTACH against an empty SQL Server schema creates the DuckLake metadata tables and lets `SHOW TABLES` succeed.

**Independent Test**: `test/sql/metadata/ducklake_attach_sqlserver.test`.

### Implementation

- [ ] T012 [US1] Implement `Execute(snapshot, query)` to dispatch `CALL mssql_exec(<db>, <sql>)` with the same template-variable substitutions as the Postgres backend (`src/metadata_manager/postgres_metadata_manager.cpp:82-113` as the model).
- [ ] T013 [US1] Implement `Query(snapshot, query)` to dispatch `SELECT * FROM mssql_scan(<db>, <sql>)`.
- [ ] T014 [US1] Implement `GetColumnTypeInternal` per the type-mapping table in `data-model.md`.
- [ ] T015 [US1] Implement `TypeIsNativelySupported` per `data-model.md`.
- [ ] T016 [US1] Override `GetCreateTableStatements` (via the V1.1 wrapper if cleanest) to emit `IF OBJECT_ID(...) IS NULL CREATE TABLE …` for every metadata table.
- [ ] T017 [US1] Implement `GetLatestSnapshotQuery` using `SELECT TOP 1 …`.
- [ ] T018 [US1] Implement `ListAggregation` with `(SELECT … FOR JSON PATH)` and the matching `LoadTags` / `LoadInlinedDataTables` / `LoadMacroImplementations` parsers (parse JSON via DuckDB's `json_extract`).

### Tests

- [ ] T019 [P] [US1] `test/sql/metadata/ducklake_attach_sqlserver.test`: attach empty SQL Server schema, assert metadata tables exist, assert `SHOW TABLES` returns zero rows.
- [ ] T020 [P] [US1] `test/sql/metadata/ducklake_settings_sqlserver.test`: assert `ducklake_settings()` reports `sqlserver` as the metadata type.
- [ ] T020a [P] [US1] `test/sql/metadata/ducklake_v10_to_v11_migration_sqlserver.test`: seed an MSSQL catalog using a stored V1.0 SQL fixture (under `test/fixtures/ducklake_v10_sqlserver.sql`), detach, re-`ATTACH ... (AUTOMATIC_MIGRATION TRUE)`, assert `ducklake_settings()` reports V1.1 and that pre-existing snapshots/tables remain queryable. Covers US1 acceptance scenario #3.

**Checkpoint**: US1 acceptance scenarios pass. Re-attaching an existing catalog also works.

---

## Phase 4: User Story 2 — Writes, snapshots, time-travel (Priority: P1)

**Goal**: Full DDL + DML round-trip against SQL Server with snapshot isolation.

### Implementation

- [ ] T021 [US2] Override `WriteNewSchemas`, `WriteNewTables`, `WriteNewViews`, `WriteNewMacros`, `WriteNewColumns`, `WriteDroppedColumns`, `WriteNewTags`, `WriteNewColumnTags`, `WriteNewPartitionKeys`, `WriteNewSortKeys`, `WriteNewDataFiles`, `WriteNewDeleteFiles`, `WriteNewInlinedData`, `WriteNewInlinedDeletes`, `WriteNewInlinedFileDeletes`, `WriteNewInlinedTables` — anywhere the base SQL uses Postgres-only syntax.
- [ ] T022 [US2] Override `InsertSnapshot`, `WriteSnapshotChanges`, `UpdateGlobalTableStats`, `GetSnapshotAndStatsAndChanges` for T-SQL.
- [ ] T023 [US2] Override `DropSchemas`, `DropTables`, `DropViews`, `DropMacros`, `DropDataFiles`, `DropDeleteFiles`, `DeleteOverwrittenDeleteFiles` for T-SQL `DELETE` syntax.
- [ ] T024 [US2] Override `ConvertFilterPushdownToSQL` / `GenerateFilterFromExpression` / `CastValueToTarget` / `CastStatsToTarget` for T-SQL casting rules (`CAST(x AS NVARCHAR)`, `CONVERT(...)` where applicable).
- [ ] T025 [US2] Override `WriteNewColumnMappings`, `GetColumnMappings`, `WriteMergeAdjacent`, `WriteDeleteRewrites`, `WriteCompactions`.

### Tests

- [ ] T026 [P] [US2] `test/sql/dml/ducklake_dml_sqlserver.test`: CREATE/INSERT/UPDATE/DELETE round-trip; assert row counts and snapshots.
- [ ] T027 [P] [US2] `test/sql/snapshots/ducklake_time_travel_sqlserver.test`: insert across N snapshots, AT (SNAPSHOT => k) returns expected rows for each k.
- [ ] T028 [P] [US2] `test/sql/concurrency/ducklake_concurrent_commits_sqlserver.test`: two concurrent writers, exactly one succeeds.
- [ ] T028a [P] [US2] `test/sql/errors/ducklake_identifier_length_sqlserver.test`: attempt to create a table, schema, column, and tag whose name is 129 bytes (one over the SQL Server limit). Each case MUST raise `InvalidInputException` with a message naming the offending identifier and the 128-byte cap. Covers the edge case from spec.md and Constitution principle "Identifier-length safety".

**Checkpoint**: US2 acceptance scenarios pass; the Postgres-equivalent test set runs green minus documented skips.

---

## Phase 5: User Story 3 — CI integration (Priority: P1)

- [ ] T029 [US3] Add `test/configs/sqlserver.json` mirroring `postgres.json`.
- [ ] T030 [US3] Add a `mssql` service-container matrix to the GH Actions test job covering both SQL Server 2019 (`mcr.microsoft.com/mssql/server:2019-latest`) and SQL Server 2022 (`mcr.microsoft.com/mssql/server:2022-latest`) on Linux. Both legs MUST pass before merge. Linux is the gating leg per NFR-003.
- [ ] T030a [US3] Add a Windows CI leg: `windows-2022` runner with SQL Server 2022 installed via Chocolatey (`choco install sql-server-2022 -y`) or the official setup binary. Runs the same SQLLogicTest suite with `--config test/configs/sqlserver.json`. MUST be green on every PR; documented skips allowed (added to `skip-list.md` with `os: windows` annotation). Satisfies the Windows priority leg of NFR-003.
- [ ] T031 [US3] Tag tests unsupported on MSSQL (`STRUCT` columns, etc.) with `mode skip-sqlserver`. Maintain the canonical skip list in `specs/001-mssql-metadata-backend/skip-list.md`, one row per skip with justification.
- [ ] T031a [US3] Emit a CI summary at the end of the `sqlserver` test job: `passed / failed / skipped` counts plus the ratio `passed_sqlserver / passed_postgres` (the postgres baseline is collected by the existing postgres job and read from a workflow artifact). Fail the job if the ratio drops below 0.95. Validates SC-001 as a falsifiable gate.
- [ ] T032 [US3] Add `make test-mssql` target in the top-level `Makefile`.
- [ ] T032a [US3] Add `.github/workflows/no-vendored-mssql.yml` (or extend an existing lint workflow): fails the build if any `**/*.patch` file references `mssql-extension`, if `extension_config.cmake` declares a vendored mssql source path, or if `git ls-files` reports a directory named `third_party/mssql*` / `vendor/mssql*`. Enforces Constitution Principle II, NFR-001, and SC-003.
- [ ] T032b [US3] Add `.github/workflows/public-api-diff.yml`: on every PR touching `src/include/**`, run `git diff origin/main -- src/include/` and fail if the diff adds a class, function, or template that is not a single new metadata-manager declaration (heuristic: any new symbol outside `src/include/metadata_manager/sqlserver_metadata_manager.hpp` triggers a manual-approval label). Enforces NFR-004 / Constitution Principle I.

**Checkpoint**: CI runs the SQL Server backend on every push. Green required for merge. Vendored-source guard and public-API guard are wired in.

---

## Phase 6: User Story 4 — Maintenance (Priority: P2)

- [ ] T033 [US4] Override `GetOldFilesForCleanup`, `GetOrphanFilesForCleanup`, `GetFilesForCleanup`, `RemoveFilesScheduledForCleanup` for T-SQL.
- [ ] T034 [US4] Override `GetFilesForCompaction`, `GenerateDeleteFlushedInlinedData`.
- [ ] T035 [US4] Override `DeleteSnapshots`, `GetAllSnapshots`, `GetTableSizes`, `GetBeginSnapshotForTable`, `GetBeginSnapshotForSchemaVersion`, `GetNetDataFileRowCount`, `GetNetInlinedRowCount`.

### Tests

- [ ] T036 [P] [US4] `test/sql/maintenance/ducklake_expire_snapshots_sqlserver.test`.
- [ ] T037 [P] [US4] `test/sql/maintenance/ducklake_compaction_sqlserver.test`.
- [ ] T038 [P] [US4] `test/sql/inlined/ducklake_inlined_flush_sqlserver.test`.

---

## Phase 7: User Story 5 — Error surface (Priority: P3)

- [ ] T039 [US5] Wire the autoload helper (`src/storage/ducklake_autoload_helper.cpp`) to surface a clear error if `mssql` isn't installed.
- [ ] T040 [US5] Verify that connection failures from `mssql_exec` / `mssql_scan` propagate untouched (smoke test).
- [ ] T040a [US5] Wrap dispatch errors at the `Execute` / `Query` boundary in a `DuckLakeMetadataException` carrying (a) the verbatim SQL Server error message and code, (b) the originating DuckLake operation name, (c) the offending SQL (truncated to 1 KiB). The original message MUST appear verbatim in `.what()`. Implements FR-009.

### Tests

- [ ] T041 [P] [US5] `test/sql/errors/ducklake_mssql_missing_extension.test`.
- [ ] T042 [P] [US5] `test/sql/errors/ducklake_mssql_bad_credentials.test`.
- [ ] T042a [P] [US5] `test/sql/errors/ducklake_mssql_error_wrapping.test`: force a known T-SQL failure (e.g. divide-by-zero in a metadata write, or `INSERT` violating a check constraint) and assert the raised error (a) contains the verbatim SQL Server message string, (b) contains the DuckLake operation name, and (c) contains a snippet of the offending SQL. Positive coverage for FR-009.

---

## Phase 8: Stabilization

- [ ] T043 Triage every failing test from Phase 4–6 to either a pass or a documented skip.
- [ ] T044 Performance gate: add `test/perf/ducklake_commit_microbench.sql` (1,000 single-row commits against an empty catalog, reports median wall-clock per commit). Run it under both `sqlserver.json` and `postgres.json` in the same CI workflow run on the same runner; fail the job if `median(sqlserver) / median(postgres) > 2.0`. Locks the Performance Goal from plan.md.
- [ ] T045 Documentation: add `docs/metadata-backends/sqlserver.md` linking to this spec.
- [ ] T046 Flip `ENABLE_MSSQL` to `ON` by default once the suite is green for two consecutive releases.

---

## Phase 9: Human-Validation Walkthrough (Metadata Inspection)

**Purpose**: A scripted, narrated end-to-end demo that exercises every DuckLake operation against MSSQL **and** dumps the metadata tables at each step, so a reviewer can read the catalog state with their own eyes. This is both a regression test and a living example.

**Scenario**: An "orders" data warehouse — schema `sales`, tables `orders(id BIGINT, customer NVARCHAR, amount DECIMAL(10,2), placed_at NVARCHAR(40))` and `order_items(order_id BIGINT, sku NVARCHAR, qty INT)`. Walks through: ATTACH → CREATE SCHEMA → CREATE TABLE → INSERT (snapshot S1) → UPDATE + INSERT (snapshot S2) → DELETE (snapshot S3) → time-travel back to S1 → compaction → expire S1.

- [ ] T047 [P9] Add `test/fixtures/sqlserver_walkthrough_seed.sql`: idempotent T-SQL that drops & recreates the `ducklake_demo` database and an empty `dbo` schema on the target SQL Server.
- [ ] T048 [P9] Add `test/sql/walkthrough/ducklake_mssql_orders_walkthrough.test`: SQLLogicTest that executes the full scenario above. After **every** state-changing step, runs `SELECT * FROM mssql_scan(<db>, '...')` against each of `ducklake_snapshot`, `ducklake_schema`, `ducklake_table`, `ducklake_column`, `ducklake_data_file`, `ducklake_file_column_stats`, `ducklake_tag`, and `ducklake_snapshot_changes`, with golden expected results inline so any drift fails the test.
- [ ] T049 [P9] Add `scripts/ducklake_mssql_walkthrough.sh`: runs the same scenario interactively (no SQLLogicTest harness), printing each step's narration to stdout and pretty-printing every metadata-table snapshot via `duckdb -box`. Reviewers run this locally against a `docker compose up` SQL Server to eyeball the catalog.
- [ ] T050 [P9] Add `docs/metadata-backends/sqlserver-walkthrough.md`: prose companion to T049. Includes (a) a copy of each metadata-table dump at every step, (b) a diagram showing how `mssql_exec` / `mssql_scan` route to the pinned TDS connection, (c) the exact `BEGIN TRAN` / `COMMIT TRAN` sequence observed via SQL Server Profiler/XEvents during a single DuckLake transaction. Cross-link from T045's `docs/metadata-backends/sqlserver.md`.
- [ ] T051 [P9] Add `make demo-mssql` target that runs `scripts/ducklake_mssql_walkthrough.sh` against `docker compose`'s mssql service, for one-command human validation.

**Checkpoint**: A reviewer can run `make demo-mssql`, scroll through the printed metadata dumps, and confirm every DuckLake invariant (snapshot monotonicity, file-stats accuracy, tag/schema linkage, expire/compaction effects) holds on the SQL Server backend.

---

## Phase 10: Dedicated CI Workflow — Upstream Extension Smoke + Metadata Dump

**Purpose**: A standalone GitHub Actions workflow that proves, on every PR and on a daily cron, that DuckLake `main` works against the **currently released** `hugr-lab/mssql-extension` and that the metadata catalog looks the way humans expect. The job log itself is the deliverable — anyone can open the run and read the metadata dumps.

**Distinct from T030**: T030 integrates MSSQL into the existing multi-backend test matrix (pass/fail gate). Phase 10 is the *human-readable* signal: a short smoke run with verbose metadata output, an attached HTML report, and a pinned extension version.

- [ ] T052 [P10] Add `.github/workflows/mssql-smoke.yml`. Triggers: `pull_request` touching `src/metadata_manager/sqlserver_*`, `extension_config.cmake`, or `specs/001-mssql-metadata-backend/**`; plus `workflow_dispatch` and a daily `schedule:` cron at 06:00 UTC. Steps:
  1. Check out DuckLake at the PR SHA.
  2. Read the pinned `mssql` extension version from a new file `specs/001-mssql-metadata-backend/mssql-extension.version` (single line, e.g. `v0.2.0`).
  3. Start `mcr.microsoft.com/mssql/server:2022-latest` as a service container with a known SA password.
  4. Build DuckLake with `-DENABLE_MSSQL=ON`.
  5. Resolve the extension: `INSTALL mssql FROM community; LOAD mssql;` then assert via `SELECT extension_version FROM duckdb_extensions() WHERE extension_name='mssql'` matches the pinned version. Fail loudly if it doesn't.
  6. Run `scripts/ducklake_mssql_walkthrough.sh` (from T049) with `--ci` to emit deterministic output.
  7. Run the SQLLogicTest from T048 (`ducklake_mssql_orders_walkthrough.test`).
  8. Upload two artifacts: `metadata-dump.txt` (every `mssql_scan` dump from the walkthrough, in order) and `metadata-dump.html` (same content via `duckdb -markdown` piped through `pandoc`).
  9. Append a job summary using `$GITHUB_STEP_SUMMARY` that inlines the first ~200 lines of `metadata-dump.txt` so reviewers see it without downloading the artifact.
  10. Run the same steps on `windows-2022` (with SQL Server 2022 installed via Chocolatey) as a parallel matrix leg. Both Linux and Windows legs must be green for the workflow to pass.

- [ ] T053 [P10] Add `specs/001-mssql-metadata-backend/mssql-extension.version`: pinned tag (initially `v0.2.0`). Phase 10 fails closed if the resolved community-extension version differs from this file — prevents silent upstream drift.

- [ ] T054 [P10] Add `scripts/ducklake_mssql_walkthrough.sh --ci` mode: same scenario as T049 but with `set -euo pipefail`, no terminal control codes, and deterministic timestamps (snapshot author = `ci@ducklake`, snapshot times stubbed via a fixed clock setting if available, else stripped from golden output).

- [ ] T055 [P10] Add `docs/metadata-backends/sqlserver-ci.md`: explains how to read a Phase 10 run, where the metadata dumps live, how to bump `mssql-extension.version`, and how to reproduce the run locally with `act` or `make demo-mssql`. Cross-link from T050.

- [ ] T056 [P10] Add a status badge for the `mssql-smoke` workflow to the root `README.md` (or wherever existing backend badges live), so the freshness of MSSQL support is visible at a glance.

**Checkpoint**: Every PR that touches the MSSQL backend produces a GH Actions run whose summary panel shows the catalog metadata at each walkthrough step. A reviewer can approve without ever running anything locally. The daily cron catches upstream `mssql` extension regressions even when no DuckLake PR is open.

---

## Parallel-execution map

- T002, T003, T004 are independent of each other and of all later tasks → run in parallel.
- T012–T018 must run in series within a single contributor (they share `sqlserver_metadata_manager.cpp`) but T019, T020 can be written in parallel by a different contributor.
- T021–T025 share the same file; serialize within a contributor.
- T026, T027, T028 are different test files → parallel.
- T036, T037, T038 → parallel.
- T041, T042, T042a → parallel.
- T047, T048, T049, T050 share fixtures/docs but separate files → mostly parallel; T050 depends on T049 output.
- T052–T056 → T053 and T054 must land before T052 (workflow references them); T055 and T056 are independent and can land in parallel with T052.
