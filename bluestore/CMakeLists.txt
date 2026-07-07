cmake_minimum_required(VERSION 3.15...4.0)

# The native engine builds from here.
# see DESIGN.md#building
project(${SKBUILD_PROJECT_NAME} LANGUAGES CXX)

# The .pth is not a module but has to land beside them in site-packages,
# since Python only reads .pth files from there.
# Anything installed to SKBUILD_PLATLIB_DIR ends up in the wheel.
# see DESIGN.md#policy
install(FILES bluestore/hook_apply.pth DESTINATION ${SKBUILD_PLATLIB_DIR})
