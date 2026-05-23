PROJ_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))

# Configuration of extension
EXT_NAME=ducklake
EXT_CONFIG=${PROJ_DIR}extension_config.cmake

# Core extensions that we need for crucial testing
DEFAULT_TEST_EXTENSION_DEPS=
# For cloud testing we also need these extensions
FULL_TEST_EXTENSION_DEPS=httpfs

# Aws and Azure have vcpkg dependencies and therefore need vcpkg merging
ifeq (${BUILD_EXTENSION_TEST_DEPS}, full)
	USE_MERGED_VCPKG_MANIFEST:=1
endif

# Include the Makefile from extension-ci-tools
include extension-ci-tools/makefiles/duckdb_extension.Makefile

# SQL Server backend convenience targets (NFR-002: opt-in via ENABLE_MSSQL).
.PHONY: test-mssql demo-mssql

test-mssql:
	@test -n "$$DUCKLAKE_MSSQL_CONNSTR" || { echo "DUCKLAKE_MSSQL_CONNSTR must be set (e.g. via docker/sqlserver/docker-compose.yml)"; exit 1; }
	build/release/test/unittest --test-config test/configs/sqlserver.json --test-dir ./ "test/sql/*"

demo-mssql:
	@test -x scripts/ducklake_mssql_walkthrough.sh || { echo "scripts/ducklake_mssql_walkthrough.sh not executable"; exit 1; }
	scripts/ducklake_mssql_walkthrough.sh
