#include <nanobind/nanobind.h>
#include <optional>

#ifndef __BLUESTORE_STORE_H
#define __BLUESTORE_STORE_H

nanobind::bytearray fake_read(std::string& object);
size_t fake_write(std::string& object, std::optional<nanobind::bytes> data);

#endif
