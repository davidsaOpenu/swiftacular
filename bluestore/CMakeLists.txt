cmake_minimum_required(VERSION 3.18...4.0)
project(${SKBUILD_PROJECT_NAME} LANGUAGES CXX)

find_package(Python 3.9 COMPONENTS Interpreter Development.Module REQUIRED)
find_package(nanobind CONFIG REQUIRED)

nanobind_add_module(_raw NB_STATIC src/store.cpp src/store.h)
target_compile_options(_raw PRIVATE
	-Wall -Wextra -fno-math-errno
	-ffunction-sections -fdata-sections
	-Wl,--gc-sections)

install(TARGETS _raw LIBRARY DESTINATION ${SKBUILD_PROJECT_NAME})
