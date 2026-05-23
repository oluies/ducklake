-- Idempotent seed for the orders/order_items walkthrough.
-- Run via sqlcmd against an MSSQL 2022 container; safe to re-run.

IF DB_ID(N'ducklake_demo') IS NULL
BEGIN
    CREATE DATABASE ducklake_demo;
END
GO

USE ducklake_demo;
GO

-- Drop any pre-existing DuckLake schema so the walkthrough starts clean.
IF EXISTS (SELECT 1 FROM sys.schemas WHERE name = N'dbo')
BEGIN
    DECLARE @stmt NVARCHAR(MAX) = N'';
    SELECT @stmt = @stmt + N'DROP TABLE [dbo].[' + name + N']; '
    FROM sys.tables WHERE schema_id = SCHEMA_ID('dbo') AND name LIKE 'ducklake_%';
    IF LEN(@stmt) > 0 EXEC sp_executesql @stmt;
END
GO
