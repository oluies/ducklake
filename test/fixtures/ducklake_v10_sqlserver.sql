-- DuckLake V1.0 catalog fixture for SQL Server.
-- Used by ducklake_v10_to_v11_migration_sqlserver.test (T020a) to seed a SQL Server
-- database with a V1.0 catalog so the test can verify AUTOMATIC_MIGRATION TRUE drives
-- it to V1.1.
--
-- This is a minimal subset of the V1.0 schema — just enough rows for the migration code
-- to recognize a V1.0 catalog and run the migration. Update when the V1.0 schema rev
-- changes upstream.

IF SCHEMA_ID(N'dbo') IS NULL EXEC('CREATE SCHEMA [dbo]');
GO

IF OBJECT_ID(N'dbo.ducklake_metadata', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.ducklake_metadata (
        [key]   NVARCHAR(64)   NOT NULL,
        [value] NVARCHAR(MAX)  NOT NULL
    );
END
GO

IF OBJECT_ID(N'dbo.ducklake_snapshot', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.ducklake_snapshot (
        snapshot_id      BIGINT       NOT NULL PRIMARY KEY,
        snapshot_time    NVARCHAR(40) NOT NULL,
        schema_version   BIGINT       NOT NULL,
        next_catalog_id  BIGINT       NOT NULL,
        next_file_id     BIGINT       NOT NULL
    );
END
GO

DELETE FROM dbo.ducklake_metadata;
INSERT INTO dbo.ducklake_metadata ([key], [value]) VALUES
    (N'version', N'0.1'),
    (N'created_by', N'DuckLake-V10-fixture'),
    (N'data_path', N'memory://ducklake/data/'),
    (N'encrypted', N'false');

DELETE FROM dbo.ducklake_snapshot;
INSERT INTO dbo.ducklake_snapshot VALUES
    (0, N'2026-01-01T00:00:00Z', 0, 1, 0);
GO
