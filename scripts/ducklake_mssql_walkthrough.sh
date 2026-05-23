#!/usr/bin/env bash
# Narrated interactive walkthrough of the SQL Server-backed DuckLake catalog.
# Pretty-prints every metadata-table dump at each step via `duckdb -box`.
#
# Usage:
#   scripts/ducklake_mssql_walkthrough.sh           # interactive
#   scripts/ducklake_mssql_walkthrough.sh --ci      # deterministic output for CI
#
# Pre-req: SQL Server reachable at DUCKLAKE_MSSQL_CONNSTR (or default localhost:1433).
set -euo pipefail

CI_MODE=0
if [[ "${1-}" == "--ci" ]]; then
  CI_MODE=1
fi

CONNSTR="${DUCKLAKE_MSSQL_CONNSTR:-Server=localhost,1433;Database=ducklake_demo;User Id=sa;Password=DuckLake!2026;TrustServerCertificate=true;}"
DATA_PATH="${DATA_PATH:-/tmp/ducklake-walkthrough}"
DUCKDB="${DUCKDB:-duckdb}"

mkdir -p "${DATA_PATH}"

step() {
  if (( CI_MODE )); then
    printf '\n=== %s ===\n' "$1"
  else
    printf '\n\033[1;36m=== %s ===\033[0m\n' "$1"
  fi
}

run_sql() {
  local sql="$1"
  if (( CI_MODE )); then
    "${DUCKDB}" -markdown -bail -cmd "INSTALL ducklake; LOAD ducklake; INSTALL mssql FROM community; LOAD mssql; ATTACH 'ducklake:mssql:${CONNSTR}' AS lake (DATA_PATH '${DATA_PATH}'); USE lake;" -c "${sql}"
  else
    "${DUCKDB}" -box -bail -cmd "INSTALL ducklake; LOAD ducklake; INSTALL mssql FROM community; LOAD mssql; ATTACH 'ducklake:mssql:${CONNSTR}' AS lake (DATA_PATH '${DATA_PATH}'); USE lake;" -c "${sql}"
  fi
}

dump_metadata() {
  local label="$1"
  step "Metadata after: ${label}"
  for tbl in ducklake_snapshot ducklake_schema ducklake_table ducklake_column ducklake_data_file ducklake_file_column_stats ducklake_tag ducklake_snapshot_changes; do
    printf '\n-- %s --\n' "${tbl}"
    run_sql "SELECT * FROM (SELECT * FROM mssql_scan('lake', 'SELECT * FROM dbo.${tbl}')) LIMIT 100;" || true
  done
}

step "1. ATTACH"
run_sql "SELECT catalog_type, data_path FROM ducklake_settings('lake');"
dump_metadata "ATTACH"

step "2. CREATE SCHEMA + TABLES"
run_sql "CREATE SCHEMA IF NOT EXISTS sales;
         CREATE TABLE IF NOT EXISTS sales.orders(id BIGINT, customer VARCHAR, amount DECIMAL(10,2), placed_at VARCHAR);
         CREATE TABLE IF NOT EXISTS sales.order_items(order_id BIGINT, sku VARCHAR, qty INTEGER);"
dump_metadata "CREATE SCHEMA + TABLES"

step "3. INSERT (snapshot S1)"
run_sql "INSERT INTO sales.orders VALUES (1, 'alice', 19.99, '2026-01-01T10:00:00Z'), (2, 'bob', 42.00, '2026-01-01T11:30:00Z');
         INSERT INTO sales.order_items VALUES (1, 'sku-a', 1), (1, 'sku-b', 2), (2, 'sku-c', 1);"
dump_metadata "INSERT S1"

step "4. UPDATE + INSERT (snapshot S2)"
run_sql "UPDATE sales.orders SET amount = 24.99 WHERE id = 1;
         INSERT INTO sales.orders VALUES (3, 'carol', 99.50, '2026-01-02T09:00:00Z');"
dump_metadata "UPDATE + INSERT S2"

step "5. DELETE (snapshot S3)"
run_sql "DELETE FROM sales.orders WHERE id = 2;"
dump_metadata "DELETE S3"

step "6. Time-travel back to S1"
run_sql "WITH s1 AS (
           SELECT snapshot_id FROM ducklake_snapshots('lake')
           ORDER BY snapshot_id DESC OFFSET 2 ROWS FETCH NEXT 1 ROWS ONLY
         )
         SELECT * FROM sales.orders AT (SNAPSHOT => (SELECT snapshot_id FROM s1)) ORDER BY id;"

step "7. Compaction"
run_sql "CALL ducklake_merge_adjacent_files('lake');"
dump_metadata "After compaction"

step "8. Expire S1"
run_sql "CALL ducklake_expire_snapshots('lake', versions => 2);"
dump_metadata "After expire"

step "Done"
