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
- [X] T002 [P] Add `ENABLE_MSSQL` option to top-level `CMakeLists.txt` (default OFF until v1).
- [X] T003 [P] Declare `mssql` as an optional autoloaded community extension in `extension_config.cmake`.
- [X] T004 Stand up a local SQL Server 2022 container via `docker compose` for development (file under `docker/`).

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Class skeleton + registration so the rest of the work can compile and link.

- [X] T005 Create `src/include/metadata_manager/sqlserver_metadata_manager.hpp` declaring `SQLServerMetadataManager : public DuckLakeMetadataManager`. (Minimum override set matches Postgres backend; additional T-SQL overrides deferred to triage in later phases.)
- [X] T006 Create `src/metadata_manager/sqlserver_metadata_manager.cpp` with working dispatch (Execute/Query through mssql_exec/mssql_scan), type mapping, and latest-snapshot query.
- [X] T007 Modify `src/metadata_manager/CMakeLists.txt` to compile the new source under `ENABLE_MSSQL`.
- [X] T008 Modify `src/storage/ducklake_metadata_manager.cpp` to register `"mssql"` and `"sqlserver"` aliases (guarded by `#ifdef DUCKLAKE_ENABLE_MSSQL`).
- [X] T009 Modify `src/metadata_manager/ducklake_metadata_manager_v1_1.cpp` to add `template class DuckLakeMetadataManagerV1_1<SQLServerMetadataManager>;` (guarded).
- [X] T010 Modify `src/storage/ducklake_initializer.cpp` `SetVersionedMetadataManager` to dispatch the V1.1 wrapper for `SQLServerMetadataManager` (guarded).
- [X] T011 Modify `src/functions/ducklake_settings.cpp` to normalize `mssql` → `sqlserver` in `ducklake_settings()` output.
- [X] T010a [US1] Add `test/sql/metadata/ducklake_mssql_txn_pinning.test` validating FR-003 transaction pinning (`@@SPID` constant within a DuckLake transaction; ROLLBACK discards writes).

**Checkpoint**: Code compiles with `ENABLE_MSSQL=ON`. `ATTACH 'ducklake:mssql:…'` resolves to `SQLServerMetadataManager` but every method throws `NotImplemented`.

---

## Phase 3: User Story 1 — Attach (Priority: P1) 🎯 MVP

**Goal**: ATTACH against an empty SQL Server schema creates the DuckLake metadata tables and lets `SHOW TABLES` succeed.

**Independent Test**: `test/sql/metadata/ducklake_attach_sqlserver.test`.

### Implementation

- [X] T012 [US1] Implement `Execute(snapshot, query)` dispatching `CALL mssql_exec(<db>, <sql>)`.
- [X] T013 [US1] Implement `Query(snapshot, query)` dispatching `SELECT * FROM mssql_scan(<db>, <sql>)`.
- [X] T014 [US1] Implement `GetColumnTypeInternal` per the type-mapping table.
- [X] T015 [US1] Implement `TypeIsNativelySupported` per `data-model.md`.
- [X] T016 [US1] T-SQL dialect rewrite pass in `RewriteForTSQL` rewrites `CREATE TABLE IF NOT EXISTS` → `IF OBJECT_ID(...) IS NULL CREATE TABLE` and `CREATE SCHEMA IF NOT EXISTS` → `IF SCHEMA_ID(...) IS NULL EXEC('CREATE SCHEMA [...]')`. Additional patterns added as test failures surface in Phase 8.
- [X] T017 [US1] Implement `GetLatestSnapshotQuery` using `SELECT TOP 1 …`.
- [X] T018 [US1] No override needed — base `ListAggregation` returns DuckDB-native `LIST({...})` which is evaluated on the DuckDB side after `mssql_scan` streams rows back. `LoadTags` / `LoadInlinedDataTables` / `LoadMacroImplementations` parse DuckDB `Value`s, not raw JSON.

### Tests

- [X] T019 [P] [US1] `test/sql/metadata/ducklake_attach_sqlserver.test` written.
- [X] T020 [P] [US1] `test/sql/metadata/ducklake_settings_sqlserver.test` written.
- [X] T020a [P] [US1] `test/sql/metadata/ducklake_v10_to_v11_migration_sqlserver.test` + `test/fixtures/ducklake_v10_sqlserver.sql` written.

**Checkpoint**: US1 acceptance scenarios pass. Re-attaching an existing catalog also works.

---

## Phase 4: User Story 2 — Writes, snapshots, time-travel (Priority: P1)

**Goal**: Full DDL + DML round-trip against SQL Server with snapshot isolation.

### Implementation

- [-] T021–T025 [US2] **Deferred — base-class SQL is mostly dialect-agnostic.** The Postgres backend ships ~150 lines with zero Write*/Drop* overrides; the base class uses portable SQL plus template-variable substitution. We follow the same pattern: implement only the overrides that test failures actually require. Specific T-SQL dialect rewrites (`CREATE TABLE IF NOT EXISTS`, `CREATE SCHEMA IF NOT EXISTS`) are handled in `RewriteForTSQL`. Additional rewrites (`RETURNING` → `OUTPUT`, `LIMIT` → `TOP/FETCH`, `ON CONFLICT` → `MERGE`) are added to `RewriteForTSQL` as Phase 8 stabilization triage surfaces them; any operation that resists rewrite gets a true virtual override.

### Tests

- [X] T026 [P] [US2] `test/sql/dml/ducklake_dml_sqlserver.test` written.
- [X] T027 [P] [US2] `test/sql/snapshots/ducklake_time_travel_sqlserver.test` written.
- [X] T028 [P] [US2] `test/sql/concurrency/ducklake_concurrent_commits_sqlserver.test` written.
- [X] T028a [P] [US2] `test/sql/errors/ducklake_identifier_length_sqlserver.test` written.

**Checkpoint**: US2 acceptance scenarios pass; the Postgres-equivalent test set runs green minus documented skips.

---

## Phase 5: User Story 3 — CI integration (Priority: P1)

- [X] T029 [US3] `test/configs/sqlserver.json` written.
- [X] T030 [US3] `.github/workflows/SqlServer.yml` with 2019+2022 Linux matrix written.
- [X] T030a [US3] `.github/workflows/SqlServerWindows.yml` with SQL Server 2022 on `windows-2022` via Chocolatey written.
- [X] T031 [US3] `specs/001-mssql-metadata-backend/skip-list.md` written; skip paths mirrored in `sqlserver.json`.
- [X] T031a [US3] Ratio gate scripted in `SqlServer.yml`'s "Compute ratio vs postgres" step (uses `PASSED_POSTGRES_BASELINE` env; integration with the actual postgres-baseline artifact is left as a follow-up TODO in the workflow).
- [X] T032 [US3] `make test-mssql` target added to root `Makefile`.
- [X] T032a [US3] `.github/workflows/no-vendored-mssql.yml` written.
- [X] T032b [US3] `.github/workflows/public-api-diff.yml` written (soft gate via warning; hard fail commented).

**Checkpoint**: CI runs the SQL Server backend on every push. Green required for merge. Vendored-source guard and public-API guard are wired in.

---

## Phase 6: User Story 4 — Maintenance (Priority: P2)

- [-] T033–T035 [US4] **Deferred — same rationale as T021–T025.** Maintenance queries in the base class are mostly portable; T-SQL-specific overrides are added only as test failures from T036–T038 surface them in Phase 8.

### Tests

- [X] T036 [P] [US4] `test/sql/maintenance/ducklake_expire_snapshots_sqlserver.test` written.
- [X] T037 [P] [US4] `test/sql/maintenance/ducklake_compaction_sqlserver.test` written.
- [X] T038 [P] [US4] `test/sql/inlined/ducklake_inlined_flush_sqlserver.test` written.

---

## Phase 7: User Story 5 — Error surface (Priority: P3)

- [X] T039 [US5] Constructor checks `ExtensionIsLoaded("mssql")` and either autoloads or throws `MissingExtensionException` with the `INSTALL mssql FROM community; LOAD mssql;` hint.
- [X] T040 [US5] Smoke coverage via T042.
- [X] T040a [US5] `WrapDispatchResult` in `sqlserver_metadata_manager.cpp` wraps `Execute` / `Query` errors with DuckLake op name and a 1 KiB SQL snippet while preserving the verbatim upstream message.
- [X] T041 [P] [US5] `test/sql/errors/ducklake_mssql_missing_extension.test` written.
- [X] T042 [P] [US5] `test/sql/errors/ducklake_mssql_bad_credentials.test` written.
- [X] T042a [P] [US5] `test/sql/errors/ducklake_mssql_error_wrapping.test` written.

---

## Phase 8: Stabilization

- [-] T043 **Deferred — post-CI activity.** Triage runs after Phases 1–7 land and the CI matrix is live; output drives skip-list updates and `RewriteForTSQL` additions.
- [X] T044 `test/perf/ducklake_commit_microbench.sql` written (CI harness wiring of the ratio gate is workflow-side TODO).
- [X] T045 `docs/metadata-backends/sqlserver.md` written.
- [-] T046 **Deferred — release-gate.** Flip happens once the suite is green on two consecutive releases (per NFR-002).

---

## Phase 9: Human-Validation Walkthrough (Metadata Inspection)

**Purpose**: A scripted, narrated end-to-end demo that exercises every DuckLake operation against MSSQL **and** dumps the metadata tables at each step, so a reviewer can read the catalog state with their own eyes. This is both a regression test and a living example.

**Scenario**: An "orders" data warehouse — schema `sales`, tables `orders(id BIGINT, customer NVARCHAR, amount DECIMAL(10,2), placed_at NVARCHAR(40))` and `order_items(order_id BIGINT, sku NVARCHAR, qty INT)`. Walks through: ATTACH → CREATE SCHEMA → CREATE TABLE → INSERT (snapshot S1) → UPDATE + INSERT (snapshot S2) → DELETE (snapshot S3) → time-travel back to S1 → compaction → expire S1.

- [X] T047 [P9] `test/fixtures/sqlserver_walkthrough_seed.sql` written.
- [X] T048 [P9] `test/sql/walkthrough/ducklake_mssql_orders_walkthrough.test` written.
- [X] T049 [P9] `scripts/ducklake_mssql_walkthrough.sh` written and made executable.
- [X] T050 [P9] `docs/metadata-backends/sqlserver-walkthrough.md` written.
- [X] T051 [P9] `make demo-mssql` target added to root `Makefile`.

**Checkpoint**: A reviewer can run `make demo-mssql`, scroll through the printed metadata dumps, and confirm every DuckLake invariant (snapshot monotonicity, file-stats accuracy, tag/schema linkage, expire/compaction effects) holds on the SQL Server backend.

---

## Phase 10: Dedicated CI Workflow — Upstream Extension Smoke + Metadata Dump

**Purpose**: A standalone GitHub Actions workflow that proves, on every PR and on a daily cron, that DuckLake `main` works against the **currently released** `hugr-lab/mssql-extension` and that the metadata catalog looks the way humans expect. The job log itself is the deliverable — anyone can open the run and read the metadata dumps.

**Distinct from T030**: T030 integrates MSSQL into the existing multi-backend test matrix (pass/fail gate). Phase 10 is the *human-readable* signal: a short smoke run with verbose metadata output, an attached HTML report, and a pinned extension version.

- [X] T052 [P10] `.github/workflows/mssql-smoke.yml` written (Linux+Windows matrix, pin assertion, walkthrough --ci, golden test, artifact upload, job-summary inline).
- [X] T053 [P10] `specs/001-mssql-metadata-backend/mssql-extension.version` written with `v0.2.0`.
- [X] T054 [P10] `scripts/ducklake_mssql_walkthrough.sh` supports `--ci` mode (`set -euo pipefail`, no terminal control codes).
- [X] T055 [P10] `docs/metadata-backends/sqlserver-ci.md` written.
- [-] T056 [P10] **Deferred — no root `README.md` exists yet.** Re-add when one is created; until then, the `sqlserver-ci.md` doc serves as the surface for run health.

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
