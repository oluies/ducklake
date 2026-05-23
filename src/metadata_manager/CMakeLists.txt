set(DUCKLAKE_METADATA_MANAGER_SOURCES
    ducklake_metadata_manager_v1_1.cpp
    postgres_metadata_manager.cpp
    sqlite_metadata_manager.cpp)

if(ENABLE_MSSQL)
  list(APPEND DUCKLAKE_METADATA_MANAGER_SOURCES sqlserver_metadata_manager.cpp)
endif()

add_library(ducklake_metadata_manager OBJECT ${DUCKLAKE_METADATA_MANAGER_SOURCES})
set(ALL_OBJECT_FILES
    ${ALL_OBJECT_FILES} $<TARGET_OBJECTS:ducklake_metadata_manager>
    PARENT_SCOPE)
