#include <cstddef>
#include <cstdint>
#include <initializer_list>
#include <stdexcept>
#include <string>
#include <vector>

#include "backend.h"

#ifndef BLUESTORE_OBJECT_H
#define BLUESTORE_OBJECT_H

namespace bluestore {

// An Object is one version of a name, and its state says what may be done with
// it. Backend::find() gives one in PRE_SEARCH, which open() resolves to the
// ACTIVE version or to MISSING. Backend::create() gives one in PRE_WRITE; the
// first write() or write_metadata() creates it on disk as IN_WRITE (a
// tombstone or an empty object never calls write()), and Backend::put() makes
// it ACTIVE in the same transaction that retires the previous version to OLD,
// so a name never has two active versions or loses the one it had. An OLD
// version stays readable to whoever already holds it; IN_WRITE and OLD
// versions are removed when their Object is destroyed, since nothing else can
// reach them.
//
// Reads are checked after the fact: if the stored data_ts no longer matches,
// the version moved or was replaced, and ChangedError is thrown instead of
// returning another version's bytes. Metadata is the exception: it is
// rewritten in place on an ACTIVE version, so a caller reading it in several
// calls can see parts of different updates. StateError means the caller broke
// these rules; ConflictError is put() refusing a version that is not newer.
// see ARCHITECTURE.md#TODO

struct StateError : std::logic_error {
	StateError(const char *op, const Object& obj);
};

struct ChangedError : std::runtime_error {
	ChangedError(const char *op, const Object& obj);
};

struct ConflictError : std::runtime_error {
	ConflictError(const Object& next, const Object& prev);
};

class Object : public Stat {
	std::shared_ptr<Backend::impl> back;
	uint64_t written = 0;

	Object(std::shared_ptr<Backend::impl> back, const std::string& name, uint64_t ts);
	Object(std::shared_ptr<Backend::impl> back, const std::string& name);

	void check(const char *op, int r) const;

	friend class Backend;
public:
	Object(const Object&) = delete;
	Object& operator=(const Object&) = delete;
	~Object();

	void require(const char *op, std::initializer_list<STATE> allowed) const;

	void open();
	void write(const void *data, size_t size);
	size_t read(uint64_t offset, void *data, size_t size);
	void write_metadata(const void *data, size_t size);
	size_t read_metadata(uint64_t offset, void *data, size_t size);
};

}

#endif
