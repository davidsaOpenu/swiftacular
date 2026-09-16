#include <string>
#include <map>

#ifndef BLUESTORE_ARGS_H
#define BLUESTORE_ARGS_H

namespace bluestore {

extern std::map<std::string, std::string> opts;
void parse_args(int argc, char** argv);
void log_help();
void log(const std::string& msg);

}

#endif
