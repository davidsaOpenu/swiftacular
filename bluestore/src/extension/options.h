#include <cstdint>
#include <istream>
#include <ostream>
#include <string>

#include "backend.h"

#ifndef BLUESTORE_OPTIONS_H
#define BLUESTORE_OPTIONS_H

namespace bluestore {

// One function per value a command reads from opts, returning it as the type
// it is used as or throwing a message for the user.
Backend backend();
uint64_t capacity();
std::string object();
std::string metadata();
uint64_t size();
uint64_t timestamp(uint64_t current);
std::istream& input();
std::ostream& output();

}

#endif
