#include <cstddef>
#include <cstdint>
#include <functional>
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

struct Stat {
	std::string name;
	uint64_t data_ts = 0;
	uint64_t meta_ts = 0;
	bool deleted = false;
	STATE state;
};

class Object;

class Backend {
	struct impl;
	std::shared_ptr<impl> p;

	friend class Object;
public:
	Backend(const std::string& path, uint64_t size);
	~Backend();

	Object find(const std::string& name);
	Object create(const std::string& name, uint64_t ts);

	void scan(const std::function<SCAN(const Stat&)>& fn);

	void clean();
	void put(Object& next, Object& prev);
};

}

#endif
