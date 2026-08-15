<<<<<<< PATCH SET (13e2c8b1f387303a9910073eadabf869b04f1d09 Added mock binding and test)
cmake_minimum_required(VERSION 3.18...4.0)
=======
cmake_minimum_required(VERSION 3.15...4.0)

# The native engine builds from here.
# see DESIGN.md#building
>>>>>>> BASE      (1097794c6172b47b75e1f3787b4a95bc2c657108 Added initial native bluestore support)
project(${SKBUILD_PROJECT_NAME} LANGUAGES CXX)

<<<<<<< PATCH SET (13e2c8b1f387303a9910073eadabf869b04f1d09 Added mock binding and test)
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

install(TARGETS _raw LIBRARY DESTINATION ${SKBUILD_PROJECT_NAME})
install(TARGETS cli RUNTIME DESTINATION ${SKBUILD_SCRIPTS_DIR})
=======
# The .pth is not a module but has to land beside them in site-packages,
# since Python only reads .pth files from there.
# Anything installed to SKBUILD_PLATLIB_DIR ends up in the wheel.
# see DESIGN.md#policy
install(FILES bluestore/hook_apply.pth DESTINATION ${SKBUILD_PLATLIB_DIR})
>>>>>>> BASE      (1097794c6172b47b75e1f3787b4a95bc2c657108 Added initial native bluestore support)
