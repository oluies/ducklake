# Load the upstream hugr-lab/mssql community extension alongside DuckLake for CI tests.
# We do NOT vendor the source — APPLY_PATCHES is intentionally omitted (Constitution Principle II).
# Pinned tag is read from specs/001-mssql-metadata-backend/mssql-extension.version.

file(READ "${CMAKE_CURRENT_LIST_DIR}/../../../specs/001-mssql-metadata-backend/mssql-extension.version" MSSQL_EXTENSION_VERSION_RAW)
string(STRIP "${MSSQL_EXTENSION_VERSION_RAW}" MSSQL_EXTENSION_VERSION)

if(NOT MINGW AND NOT ${WASM_ENABLED})
    duckdb_extension_load(mssql
            DONT_LINK LOAD_TESTS
            GIT_URL https://github.com/hugr-lab/mssql-extension
            GIT_TAG ${MSSQL_EXTENSION_VERSION}
            )
endif()
