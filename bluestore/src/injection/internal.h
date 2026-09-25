// The engine's Ceph-facing internals, which only the build inside Ceph's can see.
// see ARCHITECTURE.md#building

#include <cstdint>
#include <future>
#include <memory>
#include <mutex>
#include <string>
#include <utility>
#include <vector>
#include <map>

#include "common/ceph_context.h"
#include "os/ObjectStore.h"

#include "backend.h"
#include "object.h"

#ifndef BLUESTORE_INTERNAL_H
#define BLUESTORE_INTERNAL_H

#define BLUESTORE_POOL 10
#define BLUESTORE_BITS 8

namespace bluestore {

using Queue = std::vector<std::pair<ObjectStore::CollectionHandle, ObjectStore::Transaction>>;
using Attrs = std::map<std::string, ceph::buffer::list, std::less<>>;

CephContext *context();
uint64_t estimate();
void retire(std::unique_ptr<ObjectStore> store);

// The store, how its entries are laid out, and the queue of prepared transactions.
// see ARCHITECTURE.md#object-model
struct Backend::impl {
	std::vector<ObjectStore::CollectionHandle> collections;
	std::unique_ptr<ObjectStore> store;

	std::mutex submit_lock;
	std::mutex queue_lock;
	Queue queue;

	~impl();

	ObjectStore::CollectionHandle& collection(const std::string& name);

	ghobject_t address(const Stat& stat);

	void save(ObjectStore::Transaction& t, const Stat& stat);
	int load(const ghobject_t& oid, Stat& stat);
	void check(const char *op, const ghobject_t& oid, const Stat& stat, int r);

	void prepare(ObjectStore::CollectionHandle& ch, ObjectStore::Transaction&& t, std::shared_future<void> *done = nullptr);
	void submit();
};

}

#endif
