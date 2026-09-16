#include <stdexcept>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <optional>
#include <vector>
#include <string>
#include <memory>

#ifndef BLUESTORE_BACKEND_H
#define BLUESTORE_BACKEND_H

namespace bluestore {
// This header and object.h are the engine's surface; anything that needs a
// Ceph type lives behind Backend::impl in internal.h.
// see ARCHITECTURE.md#building

enum class SCAN {
	NEXT_ENTRY,
	NEXT_COLLECTION
};

enum class STATE {
	PRE_SEARCH,
	IN_SEARCH,
	MISSING,
	PRE_WRITE,
	IN_WRITE,
	ACTIVE,
	OLD
};

const char *state_name(STATE state);

struct Stat {
	std::string name;
	uint64_t ts = 0;
	bool deleted = false;
	STATE state;
};

struct ConflictError : std::runtime_error {
	ConflictError(const char *op, const std::string& name, uint64_t next, uint64_t prev);
};

class Object;

class Backend {
	struct impl;
	std::shared_ptr<impl> p;

	friend class Object;
public:
	Backend(const std::string& path, std::optional<uint64_t> capacity = {});
	~Backend();

	Object create(const std::string& name, std::optional<uint64_t> ts = {});
	Object find(const std::string& name);

	void scan(const std::function<SCAN(const Stat&)>& fn);

	void clean();
	void put(Object& next, Object& prev, std::optional<uint64_t> ts = {});
};

}

#endif
