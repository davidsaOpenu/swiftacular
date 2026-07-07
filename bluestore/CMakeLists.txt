cmake_minimum_required(VERSION 3.15...4.0)
project(${SKBUILD_PROJECT_NAME} LANGUAGES CXX)

# This is temporary untill a newer version of scikit-build-core
install(FILES bluestore/hook_apply.pth DESTINATION ${SKBUILD_PLATLIB_DIR})
