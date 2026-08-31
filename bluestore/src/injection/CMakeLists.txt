# Read as part of Ceph's own configuration, before Ceph configures itself.
# Everything here therefore runs inside Ceph's build and can see its targets.
# see ARCHITECTURE.md#engine

# Ceph asks itself these questions during configuration and each has a
# default. We are read first, so answering here settles them: a question
# already answered is not asked again. Off is everything that is not storage.
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
set(WITH_LZ4 OFF)

# Ceph ties position-independent code to building its libraries as separate
# shared objects, and we want the opposite: everything static so it can be
# folded into one library of ours. So the internals are built static and the
# flag is set by hand instead.
set(ENABLE_SHARED OFF)
string(APPEND CMAKE_C_FLAGS   " -fPIC")
string(APPEND CMAKE_CXX_FLAGS " -fPIC")
string(APPEND CMAKE_ASM_FLAGS " -fPIC")

# One file that relies on as little of its surroundings as possible: Ceph's
# dependencies folded in rather than sitting beside us, and the system's own
# allocator rather than a replacement fighting whatever the host process uses.
set(WITH_SYSTEM_ROCKSDB OFF)
set(WITH_SYSTEM_BOOST OFF)
set(ALLOCATOR "libc")

# Our library, declared inside Ceph's build so the build itself works out the
# headers, definitions and link order for these internal targets. That
# calculation is exactly what cannot be reproduced from outside.
add_library(bluestore_export SHARED
	"${BLUESTORE_INJECTION_DIR}/backend.cpp"
	"${BLUESTORE_INJECTION_DIR}/backend.h")

target_link_libraries(bluestore_export PRIVATE global ceph-common kv os)
set_target_properties(bluestore_export PROPERTIES
	LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/export"
	OUTPUT_NAME bluestore
	SOVERSION 0)

# This gets loaded into a process already full of other code. Bind our calls
# to our own copies rather than leaving them open to whatever the process
# resolves them to, and drop what nothing reaches -- which is a great deal,
# given how much comes along behind the targets we asked for.
# see ARCHITECTURE.md#engine
target_link_options(bluestore_export PRIVATE
	-Wl,--gc-sections
	-Wl,-Bsymbolic-functions)

# The extension build cannot work out where this library ended up or how to
# use it, so we write it down. The settings are read off Ceph's own src
# directory and targets, which is where Ceph puts them.
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

# Deferred to the end of configuration. We run before Ceph configures itself
# -- that is what lets us answer its questions -- so at that point none of
# the settings we want to record exist yet.
cmake_language(DEFER CALL bluestore_export_update)
