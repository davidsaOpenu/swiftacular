#include <iostream>
#include <cstdint>
#include <string>
#include <vector>
#include <map>

#include "args.h"

namespace bluestore {
namespace {

const std::map<std::string, std::string> ARGS_STR = {
	{"--database", "database"},
	{"-d", "database"},
	{"--input", "input" },
	{"-i", "input" },
	{"--output", "output" },
	{"-o", "output" },
	{"--size", "size"},
	{"-s", "size"},
	{"--timestamp", "timestamp"},
	{"-t", "timestamp"},
	{"--capacity", "capacity"},
	{"-c", "capacity"}
};

const std::map<std::string, std::string> ARGS_BOOL = {
	{"--help", "show_help"},
	{"-h", "show_help"},
	{"--quiet", "quiet"},
	{"-q", "quiet" }
};

const std::map<std::string, std::vector<std::string>> ARGS_COMM = {
	{"list", {}},
	{"clean", {}},
	{"get", {"object"}},
	{"head", {"object"}},
	{"put", {"object", "metadata"}},
	{"post", {"object", "metadata"}},
	{"delete", {"object", "metadata"}}
};

const std::map<std::string, std::string> ARGS_DESC = {
	{"object", "name of the object, as Swift names it: account/container/object"},
	{"metadata", "metadata stored with the object, kept exactly as given. If missing it is empty"},
	{"database", "path to the bluestore database"},
	{"capacity", "size in bytes a store is created with or grown to. The file is sparse, but freed space is never given back, so a store grows toward this. If missing an existing store is left as it is and a new one gets 1 GiB; stores never shrink"},
	{"input", "path to the file used as an input for write operations. If missing stdin will be used"},
	{"output", "path to the file read data is written to. If missing stdout will be used"},
	{"size", "limit to the amount of bytes read or written"},
	{"timestamp", "timestamp the object is written with. If missing the current time is used"},
	{"show_help", "show the help menu"},
	{"quiet", "only print operation results"}
};

// Empty for a command argument, which no flag sets.
std::string flag_names(const std::string& key) {
	std::string names;

	for (const auto *flags : {&ARGS_BOOL, &ARGS_STR}) {
		for (const auto& [flag, name] : *flags) {
			if (name == key)
				names = flag + " " + names;
		}
	}

	return names;
}

}

std::map<std::string, std::string> opts;

void parse_args(int argc, char** argv) {
	std::vector<std::string> local;
	opts["bin"] = *argv;

	for (int i = 1; i < argc; ++i) {
		if (ARGS_BOOL.contains(argv[i])) {
			std::string key = ARGS_BOOL.at(argv[i]);
			opts[key] = "true";
		} else if (ARGS_STR.contains(argv[i])) {
			std::string key = ARGS_STR.at(argv[i]);

			if (i + 1 >= argc) {
				log("Missing '" + key + "' value");
				opts["parse_error"] = "true";
			} else {
				opts[key] = argv[++i];
			}
		} else if (argv[i][0] == '-' && argv[i][1] != '\0') {
			log("Unknown flag '" + std::string(argv[i]) + "'");
			opts["parse_error"] = "true";
		} else {
			local.push_back(argv[i]);
		}
	}

	if (opts["show_help"] == "true")
		return;

	if (local.empty()) {
		opts["parse_error"] = "true";
		log("Missing command");
		return;
	}

	std::string command = opts["command"] = local.front();
	local.erase(local.begin());

	if (!ARGS_COMM.contains(command)) {
		opts["parse_error"] = "true";
		log("Unknown command '" + command + "'");
		return;
	}

	std::vector<std::string> keys= ARGS_COMM.at(command);
	for (size_t j = 0; j < std::min(local.size(), keys.size()); ++j) {
		opts[keys[j]] = local[j];
	}
}

void log_help() {
	log("Usage: " + opts["bin"] + " [flags] [command] [arguments]");
	log("commands:");

	for (auto comm : ARGS_COMM) {
		std::string line = "\t" + comm.first;

		for (auto arg : comm.second) {
			line += " [" + arg + "]";

		}

		log(line);
	}

	log("arguments:");

	for (const auto& [key, desc] : ARGS_DESC) {
		if (flag_names(key).empty())
			log("\t[" + key + "]\t" + desc);
	}

	log("flags:");

	for (const auto& [key, desc] : ARGS_DESC) {
		std::string names = flag_names(key);
		if (!names.empty())
			log("\t" + names + "\t" + desc);
	}
}

void log(const std::string& msg) {
	if (opts["quiet"] == "true")
		return;

	std::cerr << msg << std::endl;
}

}
