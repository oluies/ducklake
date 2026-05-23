#include "metadata_manager/sqlserver_metadata_manager.hpp"
#include "common/ducklake_util.hpp"
#include "duckdb/main/database.hpp"
#include "duckdb/main/extension_helper.hpp"
#include "storage/ducklake_catalog.hpp"
#include "storage/ducklake_transaction.hpp"

namespace duckdb {

SQLServerMetadataManager::SQLServerMetadataManager(DuckLakeTransaction &transaction)
    : DuckLakeMetadataManager(transaction) {
	// FR-010 — surface a clear "install mssql extension" error early instead of letting the
	// first mssql_exec call fail with "function not found".
	auto context = transaction.context.lock();
	if (context && !context->db->ExtensionIsLoaded("mssql")) {
		if (ExtensionHelper::CanAutoloadExtension("mssql")) {
			ExtensionHelper::AutoLoadExtension(*context, "mssql");
		} else {
			throw MissingExtensionException(
			    "DuckLake catalog type 'mssql'/'sqlserver' requires the 'mssql' community extension. "
			    "Install with: INSTALL mssql FROM community; LOAD mssql;");
		}
	}
}

bool SQLServerMetadataManager::TypeIsNativelySupported(const LogicalType &type) {
	switch (type.id()) {
	// Composite / variable-shape types are not stored as native T-SQL columns.
	case LogicalTypeId::STRUCT:
	case LogicalTypeId::MAP:
	case LogicalTypeId::LIST:
	// T-SQL has no unsigned 64-bit / 128-bit integer types.
	case LogicalTypeId::UBIGINT:
	case LogicalTypeId::HUGEINT:
	case LogicalTypeId::UHUGEINT:
	// `datetime2` precision/range differs from DuckDB; we serialize timestamps via NVARCHAR
	// for parity with the Postgres backend.
	case LogicalTypeId::DATE:
	case LogicalTypeId::TIMESTAMP:
	case LogicalTypeId::TIMESTAMP_TZ:
	case LogicalTypeId::TIMESTAMP_TZ_NS:
	case LogicalTypeId::TIMESTAMP_SEC:
	case LogicalTypeId::TIMESTAMP_MS:
	case LogicalTypeId::TIMESTAMP_NS:
	// BLOB ↔ VARBINARY round-trip via the mssql extension still needs validation.
	case LogicalTypeId::BLOB:
	case LogicalTypeId::VARIANT:
	case LogicalTypeId::GEOMETRY:
		return false;
	default:
		return true;
	}
}

bool SQLServerMetadataManager::SupportsInlining(const LogicalType &type) {
	if (type.id() == LogicalTypeId::VARIANT) {
		return false;
	}
	return DuckLakeMetadataManager::SupportsInlining(type);
}

string SQLServerMetadataManager::GetColumnTypeInternal(const LogicalType &column_type) {
	switch (column_type.id()) {
	case LogicalTypeId::BOOLEAN:
		return "BIT";
	case LogicalTypeId::TINYINT:
		return "SMALLINT";
	case LogicalTypeId::SMALLINT:
		return "SMALLINT";
	case LogicalTypeId::INTEGER:
		return "INT";
	case LogicalTypeId::BIGINT:
		return "BIGINT";
	case LogicalTypeId::UTINYINT:
	case LogicalTypeId::USMALLINT:
		return "INT";
	case LogicalTypeId::UINTEGER:
		return "BIGINT";
	case LogicalTypeId::UBIGINT:
	case LogicalTypeId::HUGEINT:
	case LogicalTypeId::UHUGEINT:
		return "NVARCHAR(40)";
	case LogicalTypeId::FLOAT:
		return "REAL";
	case LogicalTypeId::DOUBLE:
		return "FLOAT";
	case LogicalTypeId::DATE:
	case LogicalTypeId::TIMESTAMP:
	case LogicalTypeId::TIMESTAMP_TZ:
	case LogicalTypeId::TIMESTAMP_TZ_NS:
	case LogicalTypeId::TIMESTAMP_SEC:
	case LogicalTypeId::TIMESTAMP_MS:
	case LogicalTypeId::TIMESTAMP_NS:
		return "NVARCHAR(40)";
	case LogicalTypeId::VARCHAR:
		return "NVARCHAR(MAX)";
	case LogicalTypeId::BLOB:
		return "VARBINARY(MAX)";
	case LogicalTypeId::UUID:
		return "UNIQUEIDENTIFIER";
	default:
		return column_type.ToString();
	}
}

string SQLServerMetadataManager::SubstituteTemplateVariables(DuckLakeSnapshot snapshot, string query) {
	auto &commit_info = transaction.GetCommitInfo();

	query = StringUtil::Replace(query, "{SNAPSHOT_ID}", to_string(snapshot.snapshot_id));
	query = StringUtil::Replace(query, "{SCHEMA_VERSION}", to_string(snapshot.schema_version));
	query = StringUtil::Replace(query, "{NEXT_CATALOG_ID}", to_string(snapshot.next_catalog_id));
	query = StringUtil::Replace(query, "{NEXT_FILE_ID}", to_string(snapshot.next_file_id));
	query = StringUtil::Replace(query, "{AUTHOR}", commit_info.author.ToSQLString());
	query = StringUtil::Replace(query, "{COMMIT_MESSAGE}", commit_info.commit_message.ToSQLString());
	query = StringUtil::Replace(query, "{COMMIT_EXTRA_INFO}", commit_info.commit_extra_info.ToSQLString());

	auto &ducklake_catalog = transaction.GetCatalog();
	auto catalog_identifier = DuckLakeUtil::SQLIdentifierToString(ducklake_catalog.MetadataDatabaseName());
	auto catalog_literal = DuckLakeUtil::SQLLiteralToString(ducklake_catalog.MetadataDatabaseName());
	auto schema_identifier = DuckLakeUtil::SQLIdentifierToString(ducklake_catalog.MetadataSchemaName());
	auto schema_identifier_escaped = StringUtil::Replace(schema_identifier, "'", "''");
	auto schema_literal = DuckLakeUtil::SQLLiteralToString(ducklake_catalog.MetadataSchemaName());
	auto metadata_path = DuckLakeUtil::SQLLiteralToString(ducklake_catalog.MetadataPath());
	auto data_path = DuckLakeUtil::SQLLiteralToString(ducklake_catalog.DataPath());

	query = StringUtil::Replace(query, "{METADATA_CATALOG_NAME_LITERAL}", catalog_literal);
	query = StringUtil::Replace(query, "{METADATA_CATALOG_NAME_IDENTIFIER}", catalog_identifier);
	query = StringUtil::Replace(query, "{METADATA_SCHEMA_NAME_LITERAL}", schema_literal);
	query = StringUtil::Replace(query, "{METADATA_CATALOG}", schema_identifier);
	query = StringUtil::Replace(query, "{METADATA_SCHEMA_ESCAPED}", schema_identifier_escaped);
	query = StringUtil::Replace(query, "{METADATA_PATH}", metadata_path);
	query = StringUtil::Replace(query, "{DATA_PATH}", data_path);
	return query;
}

// FR-009 — on dispatch failure, throw a wrapped exception that prepends DuckLake context (op
// name + offending-SQL snippet) and preserves the verbatim upstream SQL Server message via
// ErrorData::Throw's prefix mechanism.
static unique_ptr<QueryResult> WrapDispatchResult(unique_ptr<QueryResult> result, const string &op,
                                                  const string &sql) {
	if (result && result->HasError()) {
		string snippet = sql.length() > 1024 ? sql.substr(0, 1024) + "…" : sql;
		string prefix =
		    StringUtil::Format("DuckLake (SQL Server backend) mssql_%s failed (offending SQL: %s): ",
		                       op, snippet);
		result->GetErrorObject().Throw(prefix);
	}
	return result;
}

unique_ptr<QueryResult> SQLServerMetadataManager::RunMssqlExec(const string &catalog_literal, const string &sql) {
	auto &connection = transaction.GetConnection();
	auto result = connection.Query(StringUtil::Format("CALL mssql_exec(%s, %s)", catalog_literal, SQLString(sql)));
	return WrapDispatchResult(std::move(result), "mssql_exec", sql);
}

unique_ptr<QueryResult> SQLServerMetadataManager::RunMssqlScan(const string &catalog_literal, const string &sql) {
	auto &connection = transaction.GetConnection();
	auto result = connection.Query(
	    StringUtil::Format("SELECT * FROM mssql_scan(%s, %s)", catalog_literal, SQLString(sql)));
	return WrapDispatchResult(std::move(result), "mssql_scan", sql);
}

// Minimal T-SQL rewrites for base-class SQL that uses Postgres/DuckDB syntax.
// Each rewrite is conservative — only the cases we know the base class emits.
// Full dialect coverage emerges from running the SQLLogicTest suite and triaging
// failures (Phase 8 stabilization, tasks.md T043).
static string RewriteForTSQL(string sql) {
	// CREATE TABLE IF NOT EXISTS X(...) -> IF OBJECT_ID(N'X', N'U') IS NULL CREATE TABLE X(...)
	// We use a placeholder marker that DuckLake's template-var pass will have already filled.
	{
		const string needle = "CREATE TABLE IF NOT EXISTS ";
		size_t pos = 0;
		while ((pos = sql.find(needle, pos)) != string::npos) {
			size_t name_start = pos + needle.size();
			size_t name_end = sql.find_first_of(" (", name_start);
			if (name_end == string::npos) {
				break;
			}
			string name = sql.substr(name_start, name_end - name_start);
			string replacement = "IF OBJECT_ID(N'" + name + "', N'U') IS NULL CREATE TABLE " + name;
			sql.replace(pos, name_end - pos, replacement);
			pos += replacement.size();
		}
	}
	// CREATE SCHEMA IF NOT EXISTS X -> IF SCHEMA_ID(N'X') IS NULL EXEC('CREATE SCHEMA [X]')
	{
		const string needle = "CREATE SCHEMA IF NOT EXISTS ";
		size_t pos = 0;
		while ((pos = sql.find(needle, pos)) != string::npos) {
			size_t name_start = pos + needle.size();
			size_t name_end = sql.find_first_of(" ;\n", name_start);
			if (name_end == string::npos) {
				break;
			}
			string name = sql.substr(name_start, name_end - name_start);
			string replacement =
			    "IF SCHEMA_ID(N'" + name + "') IS NULL EXEC('CREATE SCHEMA [" + name + "]')";
			sql.replace(pos, name_end - pos, replacement);
			pos += replacement.size();
		}
	}
	return sql;
}

unique_ptr<QueryResult> SQLServerMetadataManager::Execute(DuckLakeSnapshot snapshot, string &query) {
	query = SubstituteTemplateVariables(snapshot, query);
	query = RewriteForTSQL(query);
	auto &ducklake_catalog = transaction.GetCatalog();
	auto catalog_literal = DuckLakeUtil::SQLLiteralToString(ducklake_catalog.MetadataDatabaseName());
	return RunMssqlExec(catalog_literal, query);
}

unique_ptr<QueryResult> SQLServerMetadataManager::Query(DuckLakeSnapshot snapshot, string &query) {
	query = SubstituteTemplateVariables(snapshot, query);
	query = RewriteForTSQL(query);
	auto &ducklake_catalog = transaction.GetCatalog();
	auto catalog_literal = DuckLakeUtil::SQLLiteralToString(ducklake_catalog.MetadataDatabaseName());
	return RunMssqlScan(catalog_literal, query);
}

string SQLServerMetadataManager::GetLatestSnapshotQuery() const {
	return R"(
	SELECT * FROM mssql_scan({METADATA_CATALOG_NAME_LITERAL},
		'SELECT TOP 1 snapshot_id, schema_version, next_catalog_id, next_file_id
		 FROM "{METADATA_SCHEMA_ESCAPED}".ducklake_snapshot
		 ORDER BY snapshot_id DESC;')
	)";
}

} // namespace duckdb
