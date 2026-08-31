set(WITH_RADOSGW OFF)
set(WITH_RBD OFF)
set(WITH_KRBD OFF)
set(WITH_CEPHFS OFF)
set(WITH_LIBCEPHFS OFF)
set(WITH_LIBCEPHSQLITE OFF)
set(WITH_MGR OFF)
set(WITH_MGR_DASHBOARD_FRONTEND OFF)
set(WITH_MGR_ROOK_CLIENT OFF)
set(WITH_FUSE OFF)
set(WITH_DOKAN OFF)
set(WITH_RDMA OFF)
set(WITH_OPENLDAP OFF)
set(WITH_LTTNG OFF)
set(WITH_BABELTRACE OFF)
set(WITH_MANPAGE OFF)
set(WITH_JAEGER OFF)
set(WITH_BLKIN OFF)
set(WITH_XFS OFF)
set(WITH_TESTS OFF)
set(WITH_CATCH2 OFF)
set(WITH_BREAKPAD OFF)
set(WITH_SYSTEMD OFF)
set(WITH_CRIMSON OFF)
set(WITH_SPDK OFF)
set(WITH_BLUESTORE_PMEM OFF)
set(WITH_DPDK OFF)
set(WITH_QATLIB OFF)
set(WITH_QATZIP OFF)
set(WITH_UADK OFF)
set(WITH_NVMEOF_GATEWAY_MONITOR_CLIENT OFF)
set(WITH_LIBURING OFF)

string(APPEND CMAKE_C_FLAGS   " -fPIC")
string(APPEND CMAKE_CXX_FLAGS " -fPIC")
string(APPEND CMAKE_ASM_FLAGS " -fPIC")

set(WITH_SYSTEM_ROCKSDB OFF)
set(WITH_SYSTEM_BOOST OFF)
set(ENABLE_SHARED OFF)
set(ALLOCATOR "libc")

add_library(bluestore_export SHARED
	"${BLUESTORE_INJECTION_DIR}/backend.cpp"
	"${BLUESTORE_INJECTION_DIR}/backend.h")

target_link_libraries(bluestore_export PRIVATE global ceph-common kv os)
set_target_properties(bluestore_export PROPERTIES
	LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/export"
	OUTPUT_NAME bluestore
	SOVERSION 0)

# bind internal cross-references so the dynamic linker can't interpose them
target_link_options(bluestore_export PRIVATE -Wl,-Bsymbolic-functions)

function(bluestore_export_update)
	get_property(inc DIRECTORY "${CMAKE_SOURCE_DIR}/src" PROPERTY INCLUDE_DIRECTORIES)
	get_property(def DIRECTORY "${CMAKE_SOURCE_DIR}/src" PROPERTY COMPILE_DEFINITIONS)
	get_target_property(std os CXX_STANDARD)

	target_include_directories(bluestore_export PRIVATE "${inc}")
	target_compile_definitions(bluestore_export PRIVATE "${def}")
	set_target_properties(bluestore_export PROPERTIES CXX_STANDARD "${std}")

	file(GENERATE OUTPUT "${BLUESTORE_EXPORT_FILE}" CONTENT "
	include_guard(GLOBAL)
	add_library(ceph SHARED IMPORTED GLOBAL)
	set_target_properties(ceph PROPERTIES
		IMPORTED_LOCATION \"$<TARGET_FILE:bluestore_export>\"
		IMPORTED_SONAME \"$<TARGET_SONAME_FILE_NAME:bluestore_export>\"
		INTERFACE_INCLUDE_DIRECTORIES \"${BLUESTORE_INJECTION_DIR}\"
		INTERFACE_COMPILE_FEATURES \"cxx_std_${std}\"
		INTERFACE_POSITION_INDEPENDENT_CODE TRUE)
	")
endfunction()

cmake_language(DEFER CALL bluestore_export_update)
