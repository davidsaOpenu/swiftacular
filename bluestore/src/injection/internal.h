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

// How entries are laid out in BlueStore. A name hashes (rjenkins, as Ceph's
// own pools do) to one of 1 << BLUESTORE_BITS collections of pool
// BLUESTORE_POOL, each opened or created once at mount and held until unmount;
// BlueStore aborts on creating a collection twice. All versions of a name share
// that collection: the ACTIVE one at generation 0 in the pool, versions being
// written or retired at generation data_ts in the pool's temp pool. Temp
// entries sort first, so clean() can stop at a collection's first ACTIVE
// entry, and sharing a collection is what lets put() move versions by
// renaming, since BlueStore aborts on a rename between collections.
//
// data_ts, meta_ts and deleted are stored as attributes, with old telling a
// retired version from one still being written; the state is recovered from
// the pool and old rather than stored. Swift's metadata is the omap header,
// kept as opaque bytes.
// see ARCHITECTURE.md#TODO
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
