#include <cstdint>
#include <fstream>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <string>

#include <bluestore.h>

#include "args.h"
#include "options.h"

namespace bluestore {

namespace {

std::string text(const std::string& key) {
	const std::string& value = opts[key];
	if (value == "")
		throw std::runtime_error("Missing " + key);

	return value;
}

uint64_t number(const std::string& key) {
	std::string value = text(key);

	try {
		size_t end;
		uint64_t out = std::stoull(value, &end);
		if (end == value.size())
			return out;
	} catch (const std::exception&) {
	}

	throw std::runtime_error("Invalid " + key + " '" + value + "'");
}

}

Backend backend() {
	std::string path = text("database");

	try {
		return Backend(path, capacity());
	} catch (const std::runtime_error& e) {
		throw std::runtime_error(std::string(e.what()) +
			"\nThe store may be in use by another process");
	}
}

std::optional<uint64_t> capacity() {
	if (opts["capacity"] == "")
		return {};

	return number("capacity");
}

std::string object() {
	return text("object");
}

std::string metadata() {
	return opts["metadata"];
}

uint64_t size() {
	if (opts["size"] == "")
		return std::numeric_limits<uint64_t>::max();

	return number("size");
}

std::optional<uint64_t> timestamp() {
	if (opts["timestamp"] == "")
		return {};

	return number("timestamp");
}

std::istream& input() {
	static std::ifstream file;
	if (opts["input"] == "")
		return std::cin;

	file.open(opts["input"], std::ios::binary);
	if (!file)
		throw std::runtime_error("Cannot open " + opts["input"]);

	return file;
}

std::ostream& output() {
	static std::ofstream file;
	if (opts["output"] == "")
		return std::cout;

	file.open(opts["output"], std::ios::binary);
	if (!file)
		throw std::runtime_error("Cannot open " + opts["output"]);

	return file;
}

}
