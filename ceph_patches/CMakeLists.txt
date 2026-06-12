# ── Swiftacular BlueStore tools ────────────────────────────────────────────────
# The tool list is the single source of truth in ceph_patches/tools.list, copied
# next to this snippet as swiftacular-tools.list by inject.sh.  Adding a tool is a
# one-line data change there — no edit to this build logic.
file(STRINGS "${CMAKE_CURRENT_SOURCE_DIR}/swiftacular-tools.list" _sw_tools)
foreach(_tgt ${_sw_tools})
  add_executable(${_tgt} ${_tgt}.cc)
  target_compile_options(${_tgt} PRIVATE -w)
  target_link_libraries(${_tgt}
    PRIVATE
      os kv global ceph-common)
endforeach()
