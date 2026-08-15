cmake_minimum_required(VERSION 3.18...4.0)

# The native engine builds from here.
# see DESIGN.md#building
project(${SKBUILD_PROJECT_NAME} LANGUAGES CXX)

find_package(Python 3.9 COMPONENTS Interpreter Development.Module REQUIRED)
find_package(nanobind CONFIG REQUIRED)

add_library(bluestore INTERFACE)
target_compile_options(bluestore INTERFACE
	-Wall -Wextra -fno-math-errno
	-ffunction-sections -fdata-sections
	-Wl,--gc-sections)


add_library(backend src/backend.cpp src/backend.h)
target_link_libraries(backend PRIVATE bluestore)

add_executable(cli src/cli.cpp src/cli.h)
target_link_libraries(cli PRIVATE bluestore backend)
set_target_properties(cli PROPERTIES OUTPUT_NAME bluestore-cli)

nanobind_add_module(_raw NB_STATIC src/bind.cpp src/bind.h)
target_link_libraries(_raw PRIVATE bluestore backend)

# Two products: a module Python imports, and a program on PATH.
# see DESIGN.md#binding
install(TARGETS _raw LIBRARY DESTINATION ${SKBUILD_PROJECT_NAME})
install(TARGETS cli RUNTIME DESTINATION ${SKBUILD_SCRIPTS_DIR})
