# SQL Server Backend — Skip List

Canonical list of DuckLake tests that are skipped when running against the SQL Server backend, with justification. Used by:
- `test/configs/sqlserver.json` (skip patterns are duplicated there for the test runner).
- T031a's ratio gate (skipped tests do not count against either side of `passed_sqlserver / passed_postgres`).

Each entry must include: test path, skip category, and one-line reason. New skips require reviewer approval; do not add silently.

## Skipped because the test only applies to DuckDB-backed catalogs

| Test path | Reason |
|---|---|
| `test/sql/general/missing_parquet.test` | Exercises filesystem-only metadata layout. |
| `test/sql/general/paths.test` | DuckDB-specific path semantics. |
| `test/sql/general/default_path.test` | DuckDB-specific default-path resolution. |
| `test/sql/autoloading/autoload_data_path.test` | DuckDB autoload-specific. |
| `test/sql/general/metadata_parameters.test` | DuckDB metadata-parameter format. |
| `test/sql/issues/corrupted_catalog_fault_isolation.test` | Asserts DuckDB-specific recovery behavior. |
| `test/sql/metadata/ducklake_settings.test` | Generic settings test — replaced by `ducklake_settings_sqlserver.test`. |
| `test/sql/remove_orphans/metadata_in_data_path.test` | DuckDB filesystem-orphan model. |

## Skipped because SQL Server does not natively support the type

T-SQL has no native `STRUCT`, `MAP`, `LIST`, `VARIANT`, `GEOMETRY`, or unsigned 64-bit / 128-bit integer types. DuckLake on SQL Server serializes these via Parquet for data and `NVARCHAR(MAX)` for metadata, so the metadata-layer tests that exercise them are not meaningful here.

| Test path | Reason |
|---|---|
| `test/sql/types/struct.test` | STRUCT as catalog column not supported. |
| `test/sql/types/map.test` | MAP as catalog column not supported. |
| `test/sql/types/list.test` | LIST as catalog column not supported. |
| `test/sql/types/hugeint.test` | HUGEINT serialized as NVARCHAR(40); tests assume native. |
| `test/sql/types/uhugeint.test` | UHUGEINT serialized as NVARCHAR(40); tests assume native. |
| `test/sql/types/variant.test` | VARIANT not supported. |
| `test/sql/types/geometry.test` | GEOMETRY not supported. |

## Skipped because the test modifies the connection string in incompatible ways

| Test path | Reason |
|---|---|
| `test/sql/catalog/quoted_identifiers.test` | Hard-codes Postgres connection-string syntax. |
| `test/sql/stats/count_star_optimization_file_operations.test` | Hard-codes Postgres connection-string syntax. |

## OS-specific skips

Annotation convention: add an `os:` column when a skip applies only to one OS (e.g. `os: windows`).

| Test path | os | Reason |
|---|---|---|
| _(none yet)_ | | |
