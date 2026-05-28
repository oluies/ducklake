# DuckLake Constitution

These principles govern every feature spec and implementation plan in this repository. They are referenced by `/speckit-plan`'s Constitution Check gate. Violations require an explicit amendment to this document — not silent dilution in a plan.

## Core Principles

### I. Reuse the Existing Pluggable Backend API (NON-NEGOTIABLE)

New metadata or data backends MUST subclass `DuckLakeMetadataManager` (or the corresponding base) and register through the existing factory in `src/storage/ducklake_metadata_manager.cpp`. New public C++ API is forbidden unless an existing virtual cannot be made to fit and the gap is documented in the plan.

**Rationale**: Every backend that has added bespoke public API has produced a downstream migration cost. The plug-in surface is intentional; widen it only with explicit governance approval.

### II. No Vendored Dependencies (NON-NEGOTIABLE)

External database drivers, extensions, or runtimes MUST be consumed as released upstream artifacts (community extensions, package-manager dependencies, or pinned tags). The repository MUST NOT contain `.patch` files against third-party sources, vendored source trees, or build-time fork URLs.

**Rationale**: PR #1152 demonstrated the maintenance cost of carrying patches against a fast-moving upstream. Any required upstream change is filed upstream first; if it cannot land there, the feature waits.

### III. Parity with the Postgres Backend

Any new metadata backend MUST mirror the dispatch shape, schema layout, and behavioral contract of `PostgresMetadataManager`. Deviations are allowed only where the target SQL dialect or runtime forces them, and each deviation MUST be enumerated in the feature's `data-model.md`.

**Rationale**: The Postgres backend is the reference implementation. Divergence without justification produces backend-specific bugs that are expensive to triage.

### IV. Test Coverage Gate (NON-NEGOTIABLE)

Every backend MUST be wired into the existing multi-backend SQLLogicTest suite via a `test/configs/<backend>.json` file, and MUST pass that suite (modulo an explicit, justified skip list) in CI before merge. CI MUST run the same tests across all backends — no backend-specific test forks.

**Rationale**: The shared test suite is what prevents backend drift. Backend-specific test sets hide regressions that only surface in production.

### V. Backward Compatibility

Existing catalogs MUST continue to attach and operate without manual migration steps. New backends are additive: they introduce new ATTACH types, not changes to existing ones. Schema-version bumps (e.g. V1.0 → V1.1) are governed by the `AUTOMATIC_MIGRATION` contract and MUST be tested on every supported backend.

**Rationale**: DuckLake's value proposition is durable catalogs. A breaking change to an existing backend invalidates that promise.

## Additional Constraints

- **Build-time opt-in for incubating backends**: New backends ship behind a CMake flag (default OFF) until their CI suite is green for two consecutive releases.
- **Error transparency**: Backend implementations MUST surface underlying driver/extension errors verbatim, wrapped (not replaced) with DuckLake context. Swallowing upstream errors is a constitution violation.
- **Identifier-length safety**: Backends MUST advertise `MaxIdentifierLength()` honestly and reject over-length identifiers at write time with a clear error rather than truncating silently.

## Development Workflow

- Every feature follows the Spec Kit flow: `/speckit-specify` → `/speckit-plan` → `/speckit-tasks` → `/speckit-analyze` → `/speckit-implement`.
- The Constitution Check in `plan.md` MUST list every principle above with a PASS/FAIL status and a one-line justification. A FAIL blocks the plan until either the design changes or the constitution is amended.
- Any task that touches an upstream-dependency version pin (e.g. a community-extension tag) MUST also bump the corresponding `*.version` file under the feature's spec directory and rerun the matching CI smoke job.

## Governance

This constitution supersedes any preference, convention, or "we've always done it this way" argument expressed in code review. Amendments require:

1. A PR that modifies this file, with the rationale in the PR body.
2. Approval from a maintainer.
3. A migration note in `CHANGELOG.md` if any in-flight feature spec must be updated to comply.

`/speckit-analyze` treats any constitution conflict as CRITICAL severity. The remediation is always to adjust the spec, plan, or tasks — never to reinterpret or silently ignore a principle.

**Version**: 1.0.0 | **Ratified**: 2026-05-23 | **Last Amended**: 2026-05-23
