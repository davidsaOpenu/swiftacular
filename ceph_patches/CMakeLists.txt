# ── Swiftacular BlueStore tools ────────────────────────────────────────────────
foreach(_tgt bs_util objectstore_bench test_kv bs_ondisk bs_xattr)
  add_executable(${_tgt} ${_tgt}.cc)
  target_compile_options(${_tgt} PRIVATE -w)
  target_link_libraries(${_tgt}
    PRIVATE
      os kv global ceph-common)
endforeach()
