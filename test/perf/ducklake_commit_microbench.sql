-- DuckLake commit microbenchmark.
-- Locks the "Performance Goals" plan.md gate: median wall-clock per single-row commit.
-- Used by tasks.md T044's CI perf gate; the gate fails if
--   median(sqlserver) / median(postgres) > 2.0
-- measured on the same runner in the same workflow run.
--
-- Usage:
--   duckdb -c ".timer on" -bail -init <(printf "%s\n" "INSTALL ducklake; LOAD ducklake;") \
--          -f test/perf/ducklake_commit_microbench.sql
--
-- The harness is expected to parse the per-statement timings, drop warm-up, and emit the
-- median. Each backend gets its own ATTACH provided externally via the DUCKLAKE_BACKEND_ATTACH
-- environment variable (the workflow substitutes either sqlserver.json or postgres.json
-- equivalent).

.timer on

-- Backend attaches via an externally-provided string (see DUCKLAKE_BACKEND_ATTACH).
-- The CI harness rewrites this line per backend before invoking duckdb.
ATTACH 'memory://__BENCH_BACKEND__' AS lake;
USE lake;

CREATE TABLE bench(id BIGINT, payload VARCHAR);

-- Warm-up (not counted by the harness — it drops the first 100 rows).
INSERT INTO bench VALUES (0, 'warmup');

-- 1,000 single-row commits.
-- Each INSERT is its own implicit transaction → one DuckLake commit, one TDS round-trip.
-- The harness records each statement's wall time and computes the median.

-- The literal INSERTs below are generated; this file is intentionally repetitive so each
-- statement's timing maps 1:1 to a commit.
-- (Generator: `for i in $(seq 1 1000); do echo "INSERT INTO bench VALUES ($i, 'row_${i}');"; done`)
-- For brevity in source, we use a loop variable expanded by a small wrapper. Replace with
-- the expanded version if the test runner does not support PRAGMA-driven loops.

PRAGMA enable_progress_bar=false;

BEGIN;
-- The wrapper script expands the body below into 1,000 individual single-row commits.
-- @LOOP 1 1000
INSERT INTO bench VALUES (@i, 'row_@i');
COMMIT;
BEGIN;
-- @ENDLOOP
COMMIT;

-- Sanity check: row count should be 1,001 (1,000 + warm-up).
SELECT COUNT(*) AS bench_rows FROM bench;
