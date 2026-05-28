#!/usr/bin/env bash
# Narrated walkthrough of the SQL Server-backed DuckLake catalog.
# Builds a single SQL document with .print step markers and runs one `duckdb`
# invocation — INSTALL/LOAD/ATTACH happens once, not per step.
#
# Usage:
#   scripts/ducklake_mssql_walkthrough.sh           # interactive (-box output)
#   scripts/ducklake_mssql_walkthrough.sh --ci      # deterministic CI output (-markdown)
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
DUCKDB_OUTPUT_FLAG="-box"
if (( CI_MODE )); then
  DUCKDB_OUTPUT_FLAG="-markdown"
fi

mkdir -p "${DATA_PATH}"

# Metadata catalog tables to dump after each step (one mssql_scan per table).
METADATA_TABLES=(
  ducklake_snapshot ducklake_schema ducklake_table ducklake_column
  ducklake_data_file ducklake_file_column_stats ducklake_tag ducklake_snapshot_changes
)

# Build the full SQL document into a tmpfile.
script_file="$(mktemp -t ducklake_mssql_walkthrough.XXXXXX.sql)"
trap 'rm -f "${script_file}"' EXIT

emit() { printf '%s\n' "$@" >> "${script_file}"; }

dump_metadata_block() {
  local label="$1"
  emit ".print"
  emit ".print === Metadata after: ${label} ==="
  for tbl in "${METADATA_TABLES[@]}"; do
    emit ".print"
    emit ".print -- ${tbl} --"
    emit "SELECT * FROM mssql_scan('lake', 'SELECT * FROM dbo.${tbl}') LIMIT 100;"
  done
}

# One-time setup: INSTALL/LOAD and ATTACH happen exactly once.
emit "INSTALL ducklake;"
emit "LOAD ducklake;"
emit "INSTALL mssql FROM community;"
emit "LOAD mssql;"
emit "ATTACH 'ducklake:mssql:${CONNSTR}' AS lake (DATA_PATH '${DATA_PATH}');"
emit "USE lake;"

emit ".print"
emit ".print === 1. ATTACH ==="
emit "SELECT catalog_type, data_path FROM ducklake_settings('lake');"
dump_metadata_block "ATTACH"

emit ".print"
emit ".print === 2. CREATE SCHEMA + TABLES ==="
emit "CREATE SCHEMA IF NOT EXISTS sales;"
emit "CREATE TABLE IF NOT EXISTS sales.orders(id BIGINT, customer VARCHAR, amount DECIMAL(10,2), placed_at VARCHAR);"
emit "CREATE TABLE IF NOT EXISTS sales.order_items(order_id BIGINT, sku VARCHAR, qty INTEGER);"
dump_metadata_block "CREATE SCHEMA + TABLES"

emit ".print"
emit ".print === 3. INSERT (snapshot S1) ==="
emit "INSERT INTO sales.orders VALUES (1, 'alice', 19.99, '2026-01-01T10:00:00Z'), (2, 'bob', 42.00, '2026-01-01T11:30:00Z');"
emit "INSERT INTO sales.order_items VALUES (1, 'sku-a', 1), (1, 'sku-b', 2), (2, 'sku-c', 1);"
dump_metadata_block "INSERT S1"

emit ".print"
emit ".print === 4. UPDATE + INSERT (snapshot S2) ==="
emit "UPDATE sales.orders SET amount = 24.99 WHERE id = 1;"
emit "INSERT INTO sales.orders VALUES (3, 'carol', 99.50, '2026-01-02T09:00:00Z');"
dump_metadata_block "UPDATE + INSERT S2"

emit ".print"
emit ".print === 5. DELETE (snapshot S3) ==="
emit "DELETE FROM sales.orders WHERE id = 2;"
dump_metadata_block "DELETE S3"

emit ".print"
emit ".print === 6. Time-travel back to S1 ==="
emit "WITH s1 AS ("
emit "  SELECT snapshot_id FROM ducklake_snapshots('lake')"
emit "  ORDER BY snapshot_id DESC OFFSET 2 ROWS FETCH NEXT 1 ROWS ONLY"
emit ")"
emit "SELECT * FROM sales.orders AT (SNAPSHOT => (SELECT snapshot_id FROM s1)) ORDER BY id;"

emit ".print"
emit ".print === 7. Compaction ==="
emit "CALL ducklake_merge_adjacent_files('lake');"
dump_metadata_block "After compaction"

emit ".print"
emit ".print === 8. Expire S1 ==="
emit "CALL ducklake_expire_snapshots('lake', versions => 2);"
dump_metadata_block "After expire"

emit ".print"
emit ".print === Done ==="

# Single duckdb invocation.
"${DUCKDB}" "${DUCKDB_OUTPUT_FLAG}" -bail -f "${script_file}"
