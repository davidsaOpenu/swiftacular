// An Object is one entry in the store, and its state says what may be done
// with it. The states, the calls that move between them, and why a read
// checks afterwards rather than locking are all in the document.
// see ARCHITECTURE.md#object-model

#include <cstddef>
#include <cstdint>
#include <future>
#include <initializer_list>
#include <optional>
#include <string>
#include <vector>

#include "backend.h"

#ifndef BLUESTORE_OBJECT_H
#define BLUESTORE_OBJECT_H

namespace bluestore {

struct StateError : std::logic_error {
	StateError(const char *op, const std::string& name, const char *state);
};

struct ChangedError : std::runtime_error {
	ChangedError(const char *op, const std::string& name, uint64_t ts);
};

class Object : public Stat {
	std::shared_ptr<Backend::impl> back;
	std::shared_future<void> done;
	uint64_t written = 0;

	Object(std::shared_ptr<Backend::impl> back, const std::string& name, uint64_t ts);
	Object(std::shared_ptr<Backend::impl> back, const std::string& name);

	friend class Backend;
public:
	Object(const Object&) = delete;
	Object& operator=(const Object&) = delete;
	Object(Object&& other);
	~Object();

	void require(const char *op, std::initializer_list<STATE> allowed) const;

	void open();
	size_t read(uint64_t offset, void *data, size_t size);
	size_t read_metadata(uint64_t offset, void *data, size_t size);
	void write(const void *data, size_t size);
	void write_metadata(const void *data, size_t size);
	void tombstone(const void *data, size_t size);
	void sync();
};

}

#endif
