cmake_minimum_required(VERSION 3.21...4.0)

# The native engine builds from here.
# see DESIGN.md#building
project(${SKBUILD_PROJECT_NAME} LANGUAGES CXX)

set(BLUESTORE_EXTENTION_DIR "${CMAKE_CURRENT_SOURCE_DIR}/src/extension")
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

	GIT_SUBMODULES ""
	PATCH_COMMAND  git submodule update
		--init --recursive --depth 1 --progress --jobs 4

	SOURCE_SUBDIR do-not-configure
	SOURCE_DIR "${BLUESTORE_VENDOR_DIR}/ceph"
)

FetchContent_declare(boost-src
	URL https://download.ceph.com/qa/boost_1_87_0.tar.bz2
	URL_HASH SHA256=af57be25cb4c4f4b413ed692fe378affb4352ea50fbe294a11ef548f4d527d89
	DOWNLOAD_EXTRACT_TIMESTAMP FALSE

	SOURCE_SUBDIR do-not-configure
	SOURCE_DIR "${BLUESTORE_VENDOR_DIR}/ceph/src/boost"
)

# wheel builds should run under build isolation with sdist files.
# becuase of this (a) they should already have their dependencies
# and (b) They will redownlaod the ceph because of isolation.
if(NOT SKBUILD_STATE STREQUAL "wheel")
	FetchContent_MakeAvailable(ceph-src)
	FetchContent_MakeAvailable(boost-src)
endif()

ExternalProject_Add(ceph
	SOURCE_DIR "${BLUESTORE_VENDOR_DIR}/ceph"

	CMAKE_CACHE_ARGS
		-DCMAKE_PROJECT_ceph_INCLUDE:FILEPATH=${BLUESTORE_INJECTION_DIR}/CMakeLists.txt
		-DBLUESTORE_INJECTION_DIR:FILEPATH=${BLUESTORE_INJECTION_DIR}
		-DBLUESTORE_EXPORT_FILE:FILEPATH=${BLUESTORE_EXPORT_FILE}
		-DCMAKE_BUILD_TYPE:STRING=${CMAKE_BUILD_TYPE}

	USES_TERMINAL_BUILD TRUE
	BUILD_ALWAYS TRUE
	BUILD_COMMAND ${CMAKE_COMMAND} --build <BINARY_DIR>
		--target bluestore_export

	BUILD_BYPRODUCTS
		"${BLUESTORE_EXPORT_FILE}"

	INSTALL_COMMAND ""
)

ExternalProject_Add_StepDependencies(ceph configure
    "${BLUESTORE_INJECTION_DIR}/CMakeLists.txt")

ExternalProject_Add(ext
	SOURCE_DIR "${BLUESTORE_EXTENTION_DIR}"
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

install(DIRECTORY "${BLUESTORE_EXPORT_STAGE}/${SKBUILD_PROJECT_NAME}/"
	USE_SOURCE_PERMISSIONS DESTINATION "${SKBUILD_PROJECT_NAME}")

install(DIRECTORY "${BLUESTORE_EXPORT_STAGE}/scripts/"
	USE_SOURCE_PERMISSIONS DESTINATION "${SKBUILD_SCRIPTS_DIR}")
