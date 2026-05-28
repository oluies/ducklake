//===----------------------------------------------------------------------===//
//                         DuckDB
//
// metadata_manager/sqlserver_metadata_manager.hpp
//
//
//===----------------------------------------------------------------------===//

#pragma once

#include "storage/ducklake_metadata_manager.hpp"

namespace duckdb {

class SQLServerMetadataManager : public DuckLakeMetadataManager {
public:
	explicit SQLServerMetadataManager(DuckLakeTransaction &transaction);

	static unique_ptr<DuckLakeMetadataManager> Create(DuckLakeTransaction &transaction) {
		return make_uniq<SQLServerMetadataManager>(transaction);
	}

	bool TypeIsNativelySupported(const LogicalType &type) override;
	bool SupportsInlining(const LogicalType &type) override;
	bool SupportsAppender() const override {
		return false;
	}
	idx_t MaxIdentifierLength() const override {
		return 128;
	}

	string GetColumnTypeInternal(const LogicalType &type) override;

	unique_ptr<QueryResult> Execute(DuckLakeSnapshot snapshot, string &query) override;
	unique_ptr<QueryResult> Query(DuckLakeSnapshot snapshot, string &query) override;

protected:
	string GetLatestSnapshotQuery() const override;

private:
	string SubstituteTemplateVariables(DuckLakeSnapshot snapshot, string query);
	unique_ptr<QueryResult> RunMssqlExec(const string &catalog_literal, const string &sql);
	unique_ptr<QueryResult> RunMssqlScan(const string &catalog_literal, const string &sql);
};

} // namespace duckdb
