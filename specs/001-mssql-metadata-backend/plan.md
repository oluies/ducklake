# Implementation Plan: SQL Server (MSSQL) Metadata Backend

**Branch**: `001-mssql-metadata-backend` | **Date**: 2026-05-22 | **Spec**: [spec.md](spec.md)
**Input**: Feature specification from `/specs/001-mssql-metadata-backend/spec.md`

## Summary

Add a SQL Server backend to DuckLake's `DuckLakeMetadataManager` registry, alongside the existing DuckDB/Postgres/SQLite backends. The new `SQLServerMetadataManager` dispatches metadata reads through `mssql_scan` and metadata writes through `mssql_exec`, using the upstream `hugr-lab/mssql-extension` (≥ v0.2.0) without vendoring or patching it. Transactions ride on the extension's pinned-connection model: a `BEGIN TRAN` issued through `mssql_exec` pins one TDS connection to that DuckDB transaction; every subsequent `mssql_exec` / `mssql_scan` on the same attached database hits the same TDS connection until `COMMIT` / `ROLLBACK`.

PR #1152 demonstrated this is feasible but ended up carrying seven extension patches. We avoid that by (a) targeting the current upstream API and (b) filing any required upstream change there first.

## Technical Context

**Language/Version**: C++17 (DuckDB extension standard)
**Primary Dependencies**: DuckDB, `hugr-lab/mssql-extension` ≥ v0.2.0 (autoloaded), existing DuckLake `DuckLakeMetadataManager` base class
**Storage**: SQL Server 2019 / 2022 (Linux container in CI)
**Testing**: DuckDB SQLLogicTest, run with `--config test/configs/sqlserver.json`
**Target Platform**: Linux, macOS, Windows (the extension already supports all three)
**Project Type**: Single (DuckDB extension)
**Performance Goals**: For the `ducklake_commit_microbench` microbenchmark (defined in `test/perf/ducklake_commit_microbench.sql`, runs 1,000 single-row commits against an empty catalog and reports median wall-clock per commit), the SQL Server backend's median MUST be ≤ 2.0 × the Postgres backend's median measured on the same CI runner in the same workflow run.
**Constraints**: No vendored copy of `mssql-extension`; opt-in CMake flag until v1
**Scale/Scope**: Same scale envelope as the Postgres backend (10s of millions of metadata rows)

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design. Principles defined in [`.specify/memory/constitution.md`](../../.specify/memory/constitution.md).*

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Reuse the Existing Pluggable Backend API | ✅ PASS | Subclasses `DuckLakeMetadataManager`, registers via `Register("mssql", …)` and `Register("sqlserver", …)`. Zero new public C++ API (NFR-004). |
| II. No Vendored Dependencies | ✅ PASS | Treats `mssql-extension` as an autoloaded community extension pinned via `mssql-extension.version`. Zero `.patch` files (SC-003). |
| III. Parity with Postgres Backend | ✅ PASS | Mirrors `PostgresMetadataManager` dispatch pattern. Deviations enumerated in `data-model.md`. |
| IV. Test Coverage Gate | ✅ PASS | Wires `test/configs/sqlserver.json` into the shared suite; skip list lives in `skip-list.md`; ratio gate (SC-001) enforced by T031a. |
| V. Backward Compatibility | ✅ PASS | New backend; no behavior change for existing catalogs. V1.0 → V1.1 migration tested on MSSQL via T020a. |

## Project Structure

### Documentation (this feature)

```text
specs/001-mssql-metadata-backend/
├── spec.md
├── plan.md                      # This file
├── research.md                  # Phase 0 output
├── data-model.md                # Type/schema mapping
├── quickstart.md                # End-user attach + DDL flow
├── skip-list.md                 # NEW — canonical skip list (T031)
├── mssql-extension.version      # NEW — pinned upstream tag (T053)
├── checklists/
│   └── requirements.md
└── tasks.md                     # Phase 2 output
```

### Source Code (repository root)

```text
src/
├── include/
│   ├── metadata_manager/
│   │   └── sqlserver_metadata_manager.hpp     # NEW
│   └── storage/
│       └── ducklake_metadata_manager.hpp      # MODIFY (add include — optional, only if needed)
├── metadata_manager/
│   ├── CMakeLists.txt                         # MODIFY (compile new .cpp)
│   ├── ducklake_metadata_manager_v1_1.cpp     # MODIFY (instantiate V1.1 wrapper)
│   └── sqlserver_metadata_manager.cpp         # NEW
├── storage/
│   ├── ducklake_metadata_manager.cpp          # MODIFY (register mssql + sqlserver)
│   └── ducklake_initializer.cpp               # MODIFY (V1.1 dynamic_cast branch)
└── functions/
    └── ducklake_settings.cpp                  # MODIFY (normalize "mssql" → "sqlserver")

test/
├── configs/
│   └── sqlserver.json                         # NEW
└── sql/
    └── metadata/
        └── ducklake_settings_sqlserver.test   # NEW

extension_config.cmake                          # MODIFY (declare mssql as optional autoload)

scripts/
└── ducklake_mssql_walkthrough.sh               # NEW — interactive metadata demo (T049)

test/fixtures/
├── sqlserver_walkthrough_seed.sql              # NEW — idempotent walkthrough seed (T047)
└── ducklake_v10_sqlserver.sql                  # NEW — V1.0 catalog fixture for migration test (T020a)

docs/metadata-backends/
├── sqlserver.md                                # NEW — backend overview (T045)
├── sqlserver-walkthrough.md                    # NEW — narrated walkthrough doc (T050)
└── sqlserver-ci.md                             # NEW — CI runbook (T055)

.github/workflows/
├── sqlserver-tests.yml                         # MODIFY/NEW — 2019+2022 matrix test job (T030)
├── mssql-smoke.yml                             # NEW — dedicated smoke + metadata dump (T052)
├── no-vendored-mssql.yml                       # NEW — .patch / vendored-source guard (T032a)
└── public-api-diff.yml                         # NEW — header-diff guard for NFR-004 (T032b)

Makefile                                        # MODIFY (test-mssql + demo-mssql targets, T032/T051)
README.md                                       # MODIFY (mssql-smoke status badge, T056)
```

## Phased Delivery

### Phase 0 — Research (output: [research.md](research.md))
- Confirm that DuckLake's standard `BEGIN`/`COMMIT`/`ROLLBACK` on the attached metadata DB round-trips to TDS `BEGIN TRAN`/`COMMIT TRAN`/`ROLLBACK TRAN` via the extension's transaction provider, pinning one TDS connection for the lifetime of the transaction. *(User-confirmed; verified by T010a.)*
- Confirm `mssql_scan` returns a `QueryResult` with schema matching DuckLake's loader code (no result-shaping shim needed).
- Audit base-class virtuals in `src/include/storage/ducklake_metadata_manager.hpp` for everything that emits SQL — list every override required for T-SQL.
- Canonical-name decision codified in *Resolved Decisions #4*: register both `mssql` and `sqlserver`, normalize to `sqlserver` in `ducklake_settings()` output.

### Phase 1 — Design (output: [data-model.md](data-model.md), [quickstart.md](quickstart.md))
- Lock the type-mapping table.
- Lock the T-SQL versions of every SQL snippet the base class emits (CREATE TABLE IF NOT EXISTS, list aggregation via `FOR JSON PATH`, LIMIT → TOP / OFFSET-FETCH, RETURNING → OUTPUT, BOOLEAN → BIT, etc.).
- Lock the autoload + extension-config wiring (Phase 0 may add an upstream PR as a hard prerequisite).

### Phase 2 — Implementation (output: [tasks.md](tasks.md))
- Foundational: header + skeleton class + registration + V1.1 instantiation.
- US1: `Execute` / `Query` / `GetLatestSnapshotQuery` + `GetColumnTypeInternal` + `TypeIsNativelySupported`.
- US2: T-SQL DDL/DML overrides surfaced by running the suite and triaging failures.
- US3: CI plumbing.
- US4: Compaction / cleanup / inlined-data flush overrides (mostly query rewrites).
- US5: Autoload error path.

### Phase 3 — Stabilization
- Drive remaining test failures to either pass or an explicit, justified skip.
- Lift the `ENABLE_MSSQL` opt-in flag once the suite is green for two consecutive releases.

### Phase 4 — Human-Validation Walkthrough (tasks.md Phase 9)
- Scripted orders/order_items demo that exercises every DuckLake operation against MSSQL and dumps every metadata table at each step.
- Deliverables: `test/fixtures/sqlserver_walkthrough_seed.sql`, `test/sql/walkthrough/ducklake_mssql_orders_walkthrough.test` (golden SQLLogicTest), `scripts/ducklake_mssql_walkthrough.sh` (interactive `duckdb -box` output), `docs/metadata-backends/sqlserver-walkthrough.md`, `make demo-mssql`.

### Phase 5 — Dedicated CI Smoke Workflow (tasks.md Phase 10)
- Standalone `mssql-smoke` GH Actions workflow that pins the upstream `mssql` extension via `specs/001-mssql-metadata-backend/mssql-extension.version`, runs the walkthrough on every PR and on a daily cron, and uploads `metadata-dump.txt` / `metadata-dump.html` plus a `$GITHUB_STEP_SUMMARY` inline of the catalog state.
- Deliverables: `mssql-extension.version`, `.github/workflows/mssql-smoke.yml`, CI-mode flag for the walkthrough script, `docs/metadata-backends/sqlserver-ci.md`, status badge in `README.md`.

## Risks and Mitigations

| Risk | Mitigation |
|------|------------|
| Upstream API drift (the seven patches in PR #1152) | Pin to a release tag; any required change goes upstream first. |
| T-SQL dialect surprises (`MERGE`, isolation levels, identifier quoting) | Catch via the full SQL test suite in CI; gate merge on green. |
| Transaction pinning doesn't round-trip when DuckDB wraps `mssql_exec` in its own transaction | User-confirmed it does. Re-verify in Phase 0 with a one-shot test. |
| `FOR JSON PATH` performance for list aggregation in hot paths (e.g., per-snapshot tag load) | Benchmark in Phase 1; fall back to multiple-row reads + client-side aggregation if needed. |
| SQL Server identifier-length / reserved-word collisions | `MaxIdentifierLength() = 128` + quoted-identifier mode (default in extension). Rejection verified by T028a. |
| Isolation-level mismatch between the extension's pinned-connection model and DuckLake's conflict-resolution contract (spec.md edge case) | Phase 0 probe records the effective isolation level (`READ COMMITTED SNAPSHOT` vs `SERIALIZABLE`) via `DBCC USEROPTIONS` from inside a pinned transaction. T028 + T028a exercise the concurrency contract; if the level is wrong, set it explicitly at session start through `mssql_exec`. |

## Resolved Decisions (formerly Open Questions)

- **Parameterized queries**: `mssql_scan` does not accept positional parameters in a way that round-trips DuckLake's template variables. The backend inlines literals via `SQLString(query)`, identical to the Postgres backend. T-SQL single-quote doubling is performed by `SQLString`; binary blobs use `0x…` hex literals.
- **Schema name handling**: The backend honors the `metadata_schema` ATTACH parameter the same way Postgres does. When unspecified, it defaults to `dbo` (the SQL Server built-in default schema). The chosen schema is created with `IF NOT EXISTS` semantics via `IF SCHEMA_ID(N'<name>') IS NULL EXEC('CREATE SCHEMA [<name>]')` because T-SQL forbids `CREATE SCHEMA` inside a multi-statement batch.
- **Encryption-at-rest config keys**: Reuse the existing DuckLake encryption-at-rest config. No SQL Server-specific keys are introduced. Server-side TDE / column encryption is the operator's concern and lives outside DuckLake's config surface.
- **Canonical ATTACH name**: Register both `mssql` (matches extension) and `sqlserver` (matches ATTACH `TYPE`), but normalize to `sqlserver` in `ducklake_settings()` output for consistency with the rest of the registry. Codified by FR-001 and T011.
