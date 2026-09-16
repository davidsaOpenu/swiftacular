// The command line tool: each command is one Swift-style request against its
// own mount of the store.
// see ARCHITECTURE.md#binding

#include <algorithm>
#include <iostream>
#include <cstdint>
#include <stdexcept>
#include <string>
#include <vector>

#include <bluestore.h>

#include "args.h"
#include "options.h"
#include "cli.h"

int main(int argc, char**argv) {
	return bluestore::run(argc, argv);
}

namespace bluestore {

namespace {

const size_t CHUNK = 1024 * 1024;

// The states an entry that is not active can be in on disk.
const char *state_name(STATE state) {
	switch (state) {
	case STATE::IN_WRITE: return "IN_WRITE";
	case STATE::OLD:      return "OLD";
	default:       return "UNKNOWN";
	}
}

void open_existing(Object& obj) {
	obj.open();
	if (obj.state == STATE::MISSING)
		throw std::runtime_error("Missing " + obj.name);
}

// put and delete: write a new object, then hand it the name.
int replace(bool deleted) {
	std::string name = object();
	std::string meta = metadata();
	uint64_t limit = size();
	std::istream& in = deleted ? std::cin : input();

	Backend back = backend();
	Object prev = back.find(name);
	prev.open();

	Object next = back.create(name, timestamp());

	std::vector<char> buf(CHUNK);
	for (uint64_t offset = 0; !deleted && offset < limit;) {
		size_t want = std::min<uint64_t>(CHUNK, limit - offset);
		in.read(buf.data(), want);
		size_t got = in.gcount();

		if (got > 0)
			next.write(buf.data(), got);
		offset += got;

		if (got < want)
			break;
	}

	if (deleted)
		next.tombstone(meta.data(), meta.size());
	else
		next.write_metadata(meta.data(), meta.size());

	back.put(next, prev, timestamp());
	return 0;
}

}

int run(int argc, char** argv) {
	parse_args(argc, argv);

	if (opts["show_help"] == "true") {
		log_help();
		return 0;
	} else if (opts["parse_error"] == "true") {
		log_help();
		return 1;
	}

	try {
		const std::string& command = opts["command"];

		if (command == "list") {
			return list();
		} else if (command == "clean") {
			return clean();
		} else if (command == "get") {
			return get();
		} else if (command == "head") {
			return head();
		} else if (command == "put") {
			return put();
		} else if (command == "post") {
			return post();
		} else if (command == "delete") {
			return remove();
		}
	} catch (const std::exception& e) {
		log(e.what());
		return 1;
	}

	return 2;
}

int list() {
	std::ostream& out = output();

	backend().scan([&](const Stat& stat) {
		if (stat.state != STATE::ACTIVE)
			out << state_name(stat.state) << ' ';

		out << stat.name;

		if (stat.state != STATE::ACTIVE)
			out << " ts=" << stat.ts;

		if (stat.state == STATE::IN_WRITE)
			out << " (estimated)";

		if (stat.deleted)
			out << " (deleted)";

		out << '\n';
		return SCAN::NEXT_ENTRY;
	});

	return 0;
}

int clean() {
	backend().clean();
	return 0;
}

int get() {
	std::string name = object();
	uint64_t limit = size();
	std::ostream& out = output();

	Backend back = backend();
	Object obj = back.find(name);
	open_existing(obj);

	if (obj.deleted)
		log(name + " is deleted");

	std::vector<char> buf(CHUNK);
	for (uint64_t offset = 0; offset < limit;) {
		size_t want = std::min<uint64_t>(CHUNK, limit - offset);
		size_t got = obj.read(offset, buf.data(), want);

		out.write(buf.data(), got);
		offset += got;

		if (got < want)
			break;
	}

	return 0;
}

int head() {
	std::string name = object();
	std::ostream& out = output();

	Backend back = backend();
	Object obj = back.find(name);
	open_existing(obj);

	log("Timestamp: " + std::to_string(obj.ts));
	log(std::string("Deleted: ") + (obj.deleted ? "true" : "false"));

	std::vector<char> buf(CHUNK);
	uint64_t offset = 0;
	for (;;) {
		size_t got = obj.read_metadata(offset, buf.data(), buf.size());
		out.write(buf.data(), got);
		offset += got;

		if (got < buf.size())
			break;
	}

	if (offset == 0)
		log(name + " has no metadata");
	else
		log("");

	return 0;
}

int put() {
	return replace(false);
}

int post() {
	std::string name = object();
	std::string meta = metadata();

	Backend back = backend();
	Object obj = back.find(name);
	open_existing(obj);

	obj.write_metadata(meta.data(), meta.size());
	return 0;
}

int remove() {
	return replace(true);
}

}
