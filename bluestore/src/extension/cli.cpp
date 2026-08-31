#include <iostream>
#include <sstream>
#include <cstdint>
#include <string>
#include <vector>

#include "backend.h"
#include "cli.h"

int main(int argc, char** argv) {
    std::string file = "bluestore.db";
    std::vector<std::string> args;
	bool machine = false;

    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];

        if (arg == "-d" || arg == "--database") {
            if (++i >= argc) {
				std::cerr << "missing value for " << arg << std::endl;
				return 2;
			}
            file = argv[i];
        } else if (arg == "-m" || arg == "--machine") {
			machine = true;
        } else if (arg.size() > 1 && arg[0] == '-') {
            std::cerr << "Unknown flag " << arg << std::endl;
            return 2;
        } else {
            args.push_back(arg);
        }
    }

	if (args.empty()) {
		std::cerr << "Nothing to do." << std::endl;
		return 2;
	}

	Backend back(file);

	if (args[0] == "fake_read") {
		if (args.size() < 2) {
			std::cerr << "Missing object" << std::endl;
			return 2;
		}

		size_t size = 512;
		if (args.size() >= 3)
			std::sscanf(args[2].c_str(), "%zu", &size);

		std::vector<uint8_t> buf(size);
		size_t out = back.fake_read(args[1], (void*)buf.data(), size);

		buf.resize(out);
		for (auto &i: buf)
			std::cout << i;

		if (!machine)
			std::cout << std::endl;
	} else if (args[0] == "fake_write") {
		std::string object = "_";

		if (args.size() < 2) {
			std::cerr << "Missing object" << std::endl;
			return 2;
		}

		std::ostringstream ss;
		ss << std::cin.rdbuf();
		std::string buf = ss.str();

		size_t out = back.fake_write(args[1], buf.data(), buf.size());
		std::cout << out;

		if (!machine)
			std::cout << std::endl;
	} else {
		std::cerr << "Unkown command " << args[0] << std::endl;
		return 2;
	}

    return 0;
}
