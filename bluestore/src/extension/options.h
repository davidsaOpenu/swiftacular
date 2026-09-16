#include <cstdint>
#include <istream>
#include <optional>
#include <ostream>
#include <string>

#include <bluestore.h>

#ifndef BLUESTORE_OPTIONS_H
#define BLUESTORE_OPTIONS_H

namespace bluestore {

// One function per value a command reads from opts, returning it as the type
// it is used as or throwing a message for the user.
Backend backend();
std::optional<uint64_t> capacity();
std::string object();
std::string metadata();
uint64_t size();
std::optional<uint64_t> timestamp();
std::istream& input();
std::ostream& output();

}

#endif
