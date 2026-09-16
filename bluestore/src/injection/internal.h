#include <cstdint>
#include <memory>
#include <string>
#include <vector>
#include <map>

#include "common/ceph_context.h"
#include "os/ObjectStore.h"

#include "backend.h"
#include "object.h"

#ifndef BLUESTORE_INTERNAL_H
#define BLUESTORE_INTERNAL_H

// The engine's Ceph-facing internals.
// see ARCHITECTURE.md#building

#define BLUESTORE_POOL 10
#define BLUESTORE_BITS 8

namespace bluestore {

using Attrs = std::map<std::string, ceph::buffer::list, std::less<>>;

CephContext *context();
uint64_t estimate();

// How entries are laid out: which collection a name hashes to, the address
// that separates what holds a name from what does not, and which facts are
// attributes rather than the map header.
// see ARCHITECTURE.md#object_model
struct Backend::impl {
	// Every Object holds impl too, so the store stays mounted until the last
	// of them is gone, not just the Backend.
	// see ARCHITECTURE.md#binding
	std::unique_ptr<ObjectStore> store;
	std::vector<ObjectStore::CollectionHandle> collections;

	~impl();

	ObjectStore::CollectionHandle& collection(const std::string& name);

	ghobject_t address(const Stat& stat);

	void save(ObjectStore::Transaction& t, const Stat& stat);
	int load(const ghobject_t& oid, Stat& stat);

	// Blocks until the transaction is durable, so a call from Python has to
	// follow the rule.
	// see ARCHITECTURE.md#concurrency
	void commit(ObjectStore::CollectionHandle& ch, ObjectStore::Transaction&& t);
};

}

#endif
