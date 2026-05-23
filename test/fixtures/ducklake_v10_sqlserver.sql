-- DuckLake V1.0 catalog fixture for SQL Server.
-- Used by ducklake_v10_to_v11_migration_sqlserver.test (T020a) to seed a SQL Server
-- database with a V1.0 catalog so the test can verify AUTOMATIC_MIGRATION TRUE drives
-- it to V1.1.
--
-- Statements are separated by single semicolons (no GO batch separators) because the
-- mssql extension's `mssql_exec` does NOT honor sqlcmd's GO directive. The test runner
-- splits this file on `;` and calls mssql_exec once per statement.
--
-- Schema is a minimal subset of the V1.0 schema — enough rows for the migration code
-- to recognize a V1.0 catalog and run the migration. Update when the V1.0 schema rev
-- changes upstream.

IF OBJECT_ID(N'dbo.ducklake_metadata', N'U') IS NULL CREATE TABLE dbo.ducklake_metadata ([key] NVARCHAR(64) NOT NULL, [value] NVARCHAR(MAX) NOT NULL);

IF OBJECT_ID(N'dbo.ducklake_snapshot', N'U') IS NULL CREATE TABLE dbo.ducklake_snapshot (snapshot_id BIGINT NOT NULL PRIMARY KEY, snapshot_time NVARCHAR(40) NOT NULL, schema_version BIGINT NOT NULL, next_catalog_id BIGINT NOT NULL, next_file_id BIGINT NOT NULL);

DELETE FROM dbo.ducklake_metadata;

INSERT INTO dbo.ducklake_metadata ([key], [value]) VALUES (N'version', N'0.1');

INSERT INTO dbo.ducklake_metadata ([key], [value]) VALUES (N'created_by', N'DuckLake-V10-fixture');

INSERT INTO dbo.ducklake_metadata ([key], [value]) VALUES (N'data_path', N'memory://ducklake/data/');

INSERT INTO dbo.ducklake_metadata ([key], [value]) VALUES (N'encrypted', N'false');

DELETE FROM dbo.ducklake_snapshot;

INSERT INTO dbo.ducklake_snapshot VALUES (0, N'2026-01-01T00:00:00Z', 0, 1, 0);
