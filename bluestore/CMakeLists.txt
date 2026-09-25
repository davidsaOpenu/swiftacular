# Compiles nothing. Sets up and runs the builds that do, then collects what
# they produce for the wheel.
# see ARCHITECTURE.md#engine

cmake_minimum_required(VERSION 3.21...4.0)
project(${SKBUILD_PROJECT_NAME} LANGUAGES CXX)

set(BLUESTORE_EXTENSION_DIR "${CMAKE_CURRENT_SOURCE_DIR}/src/extension")
set(BLUESTORE_INJECTION_DIR "${CMAKE_CURRENT_SOURCE_DIR}/src/injection")
set(BLUESTORE_VENDOR_DIR "${CMAKE_CURRENT_SOURCE_DIR}/src/vendor")

set(BLUESTORE_EXPORT_FILE "${CMAKE_BINARY_DIR}/export.cmake")
set(BLUESTORE_EXPORT_STAGE "${CMAKE_BINARY_DIR}/stage")

include(ExternalProject)
include(FetchContent)

FetchContent_declare(ceph-src
	GIT_REPOSITORY         https://github.com/ceph/ceph
	GIT_TAG                v21.3.0
	GIT_SHALLOW            TRUE
	GIT_PROGRESS           TRUE
	UPDATE_DISCONNECTED    TRUE

	# Submodules by hand so they come down shallow; the default fetch does not.
	GIT_SUBMODULES ""
	PATCH_COMMAND  git submodule update
		--init --recursive --depth 1 --progress --jobs 4

	# Fetch only. Naming a subdirectory that does not exist is what stops
	# this build from also configuring what it downloaded; Ceph is
	# configured below, on our terms.
	SOURCE_SUBDIR do-not-configure
	SOURCE_DIR "${BLUESTORE_VENDOR_DIR}/ceph"
)

FetchContent_declare(boost-src
	URL https://download.ceph.com/qa/boost_1_87_0.tar.bz2
	URL_HASH SHA256=af57be25cb4c4f4b413ed692fe378affb4352ea50fbe294a11ef548f4d527d89
	DOWNLOAD_EXTRACT_TIMESTAMP FALSE

	# Fetch only, as above. Lands where Ceph expects to find it.
	SOURCE_SUBDIR do-not-configure
	SOURCE_DIR "${BLUESTORE_VENDOR_DIR}/ceph/src/boost"
)

FetchContent_MakeAvailable(ceph-src)
FetchContent_MakeAvailable(boost-src)

ExternalProject_Add(ceph
	SOURCE_DIR "${BLUESTORE_VENDOR_DIR}/ceph"

	CMAKE_CACHE_ARGS
		# The injection point: CMake reads this file at the top of Ceph's configuration.
		-DCMAKE_PROJECT_ceph_INCLUDE:FILEPATH=${BLUESTORE_INJECTION_DIR}/CMakeLists.txt

		-DBLUESTORE_INJECTION_DIR:FILEPATH=${BLUESTORE_INJECTION_DIR}
		-DBLUESTORE_EXPORT_FILE:FILEPATH=${BLUESTORE_EXPORT_FILE}

		-DCMAKE_PREFIX_PATH:STRING=${CMAKE_PREFIX_PATH}
		-DCMAKE_BUILD_TYPE:STRING=${CMAKE_BUILD_TYPE}
		-DSKBUILD_SOSABI:STRING=${SKBUILD_SOSABI}
		-DSKBUILD_SOABI:STRING=${SKBUILD_SOABI}
		-DPython3_EXECUTABLE:FILEPATH=${Python_EXECUTABLE}
		-DPython3_INCLUDE_DIR:PATH=${Python_INCLUDE_DIR}

		-DBOOST_J:STRING=2

	# Ask for our library and nothing else, so Ceph's servers and tools never
	# compile.
	BUILD_COMMAND CMAKE_BUILD_PARALLEL_LEVEL=2 ${CMAKE_COMMAND}
		--build <BINARY_DIR>
		--target bluestore_export

	BUILD_ALWAYS TRUE
	USES_TERMINAL_BUILD TRUE
	BUILD_BYPRODUCTS "${BLUESTORE_EXPORT_FILE}"

	INSTALL_COMMAND ""
)

ExternalProject_Add_StepDependencies(ceph configure
    "${BLUESTORE_INJECTION_DIR}/CMakeLists.txt")

ExternalProject_Add(ext
	SOURCE_DIR "${BLUESTORE_EXTENSION_DIR}"
	DEPENDS ceph

	CMAKE_CACHE_ARGS
		-DBLUESTORE_EXPORT_FILE:FILEPATH=${BLUESTORE_EXPORT_FILE}
		-DCMAKE_INSTALL_PREFIX:FILEPATH=${BLUESTORE_EXPORT_STAGE}
		-DSKBUILD_PROJECT_NAME:STRING=${SKBUILD_PROJECT_NAME}
		-DSKBUILD_SCRIPTS_DIR:STRING=scripts

		-DCMAKE_PREFIX_PATH:STRING=${CMAKE_PREFIX_PATH}
		-DCMAKE_BUILD_TYPE:STRING=${CMAKE_BUILD_TYPE}
		-DSKBUILD_SOSABI:STRING=${SKBUILD_SOSABI}
		-DSKBUILD_SOABI:STRING=${SKBUILD_SOABI}
		-DPython_EXECUTABLE:FILEPATH=${Python_EXECUTABLE}
		-DPython_INCLUDE_DIR:PATH=${Python_INCLUDE_DIR}

	USES_TERMINAL_BUILD TRUE
	BUILD_ALWAYS TRUE
)

ExternalProject_Add_StepDependencies(ext configure
	"${BLUESTORE_EXPORT_FILE}")

# The inner builds stage their output, and this copies it into the wheel: the
# module and the engine library into the package, the program onto PATH.
# see ARCHITECTURE.md#engine

install(DIRECTORY "${BLUESTORE_EXPORT_STAGE}/${SKBUILD_PROJECT_NAME}/"
	USE_SOURCE_PERMISSIONS DESTINATION "${SKBUILD_PROJECT_NAME}")

install(DIRECTORY "${BLUESTORE_EXPORT_STAGE}/scripts/"
	USE_SOURCE_PERMISSIONS DESTINATION "${SKBUILD_SCRIPTS_DIR}")
