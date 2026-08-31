cmake_minimum_required(VERSION 3.21...4.0)
project(${SKBUILD_PROJECT_NAME}-ext LANGUAGES CXX)

find_package(Python 3.9 COMPONENTS Interpreter Development.Module REQUIRED)
find_package(nanobind CONFIG REQUIRED)

# What the inner build wrote down. Gives us `ceph` as something to link
# against, as though we had built it ourselves.
# see ARCHITECTURE.md#engine
include("${BLUESTORE_EXPORT_FILE}")

add_library(bluestore INTERFACE)
target_compile_options(bluestore INTERFACE
	-Wall -Wextra -fno-math-errno
	-ffunction-sections -fdata-sections)

nanobind_add_module(_raw NB_STATIC bind.cpp)
target_link_libraries(_raw PRIVATE bluestore ceph)
set_target_properties(_raw PROPERTIES
	INSTALL_RPATH "$ORIGIN")

add_executable(cli cli.cpp)
target_link_libraries(cli PRIVATE bluestore ceph)
string(JOIN ";" rpath
	"$ORIGIN/../lib/python${Python_VERSION_MAJOR}.${Python_VERSION_MINOR}/site-packages/${SKBUILD_PROJECT_NAME}"
	"$ORIGIN/../lib64/python${Python_VERSION_MAJOR}.${Python_VERSION_MINOR}/site-packages/${SKBUILD_PROJECT_NAME}"
	"$ORIGIN/../lib/python${Python_VERSION_MAJOR}/dist-packages/${SKBUILD_PROJECT_NAME}")
set_target_properties(cli PROPERTIES
	OUTPUT_NAME bluestore-cli
	INSTALL_RPATH "${rpath}")

# Clear the staging area first: it is copied wholesale into the wheel, so
# anything left behind from an earlier build would be shipped.
file(REMOVE_RECURSE "${CMAKE_INSTALL_PREFIX}")

# The engine library travels inside the wheel and sits beside the module that
# loads it. The rpaths above are how each finds it at run time, without
# anything installed on the machine or set in the environment.
# see ARCHITECTURE.md#building
install(IMPORTED_RUNTIME_ARTIFACTS ceph LIBRARY DESTINATION "${SKBUILD_PROJECT_NAME}")
install(TARGETS _raw LIBRARY DESTINATION "${SKBUILD_PROJECT_NAME}")
install(TARGETS cli RUNTIME DESTINATION "${SKBUILD_SCRIPTS_DIR}")
