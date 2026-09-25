#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <future>
#include <mutex>
#include <stdexcept>
#include <string>
#include <vector>
#include <map>

#include "global/global_context.h"
#include "global/global_init.h"
#include "include/ceph_hash.h"
#include "include/Context.h"
#include "common/errno.h"

#include "internal.h"

namespace bluestore {

namespace {

const std::map<std::string, std::string> defaults = {
	{"bluestore_fsck_on_mkfs",   "false"},
	{"bluestore_fsck_on_mount",  "false"},
	{"bluestore_fsck_on_umount", "false"},
	{"bluestore_cache_autotune",        "false"},
	{"bluestore_cache_meta_ratio",      "0.5"},
	{"bluestore_cache_kv_ratio",        "0.45"},
	{"bluestore_cache_kv_onode_ratio",  "0.04"},
	{"bluestore_default_buffered_read", "false"},
	{"admin_socket", ""}
};

const std::map<std::string, std::string> debug = {
	{"bluestore_fsck_on_mkfs",   "false"},
	{"bluestore_fsck_on_mount",  "false"},
	{"bluestore_fsck_on_umount", "false"},
	{"bluestore_cache_autotune",        "false"},
	{"bluestore_cache_meta_ratio",      "0.5"},
	{"bluestore_cache_kv_ratio",        "0.45"},
	{"bluestore_cache_kv_onode_ratio",  "0.04"},
	{"bluestore_default_buffered_read", "false"},
	{"admin_socket", ""},
	{"log_to_stderr",   "true"},
	{"err_to_stderr",   "true"},
	{"debug_bluestore", "20/20"},
	{"debug_bluefs",    "20/20"},
	{"debug_bdev",      "20/20"}
};

const uint32_t COLLECTION_MASK = (1u << BLUESTORE_BITS) - 1;
const uint64_t TICKS_PER_SECOND = 100000;

uint32_t name_hash(const std::string& name) {
	return ceph_str_hash(CEPH_STR_HASH_RJENKINS, name.data(), name.size());
}

}

// Made on first use, and held by Ceph's own g_ceph_context.
// see ARCHITECTURE.md#engine
CephContext *context() {
	static std::once_flag once;

	std::call_once(once, [] {
		std::vector<const char*> args;
		auto opts = &defaults;

		if (std::getenv("BLUESTORE_DEBUG"))
			opts = &debug;

		global_pre_init(opts, args,
			CEPH_ENTITY_TYPE_OSD, CODE_ENVIRONMENT_LIBRARY,
			CINIT_FLAG_NO_DEFAULT_CONFIG_FILE);

		common_init_finish(g_ceph_context);
	});

	return g_ceph_context;
}

uint64_t estimate() {
	static std::mutex lock;
	static uint64_t last = 0;

	auto now = std::chrono::system_clock::now().time_since_epoch();
	auto us = std::chrono::duration_cast<std::chrono::microseconds>(now).count();

	std::lock_guard l(lock);
	last = std::max<uint64_t>(us / (1000000 / TICKS_PER_SECOND), last + 1);
	return last;
}

// Never freed: after a fast shutdown, deleting a store frees its caches out
// from under its collections.
// see ARCHITECTURE.md#object-model
void retire(std::unique_ptr<ObjectStore> store) {
	static std::mutex lock;
	static auto *retired = new std::vector<std::unique_ptr<ObjectStore>>();

	store->prepare_for_fast_shutdown();
	store->umount();

	std::lock_guard l(lock);
	retired->push_back(std::move(store));
}

Backend::impl::~impl() {
	submit();

	// Collections have to be released before BlueStore unmounts.
	collections.clear();

	if (store)
		retire(std::move(store));
}

ObjectStore::CollectionHandle& Backend::impl::collection(const std::string& name) {
	return collections[name_hash(name) & COLLECTION_MASK];
}

ghobject_t Backend::impl::address(const Stat& stat) {
	bool temp = stat.state == STATE::PRE_WRITE || stat.state == STATE::IN_WRITE || stat.state == STATE::OLD;
	int64_t pool = temp ? hobject_t::get_temp_pool(BLUESTORE_POOL) : BLUESTORE_POOL;

	return ghobject_t(
		hobject_t(object_t(stat.name), "", CEPH_NOSNAP, name_hash(stat.name), pool, ""),
		temp ? stat.ts : 0, shard_id_t::NO_SHARD);
}

void Backend::impl::save(ObjectStore::Transaction& t, const Stat& stat) {
	using ceph::encode;

	Attrs attrs;
	encode(stat.ts, attrs["ts"]);
	encode(stat.deleted, attrs["deleted"]);
	encode(stat.state == STATE::OLD, attrs["old"]);

	t.setattrs(collection(stat.name)->cid, address(stat), attrs);
}

int Backend::impl::load(const ghobject_t& oid, Stat& stat) {
	using ceph::decode;

	auto& ch = collections[oid.hobj.get_hash() & COLLECTION_MASK];

	Attrs attrs;
	int r = store->getattrs(ch, oid, attrs);
	if (r < 0)
		return r;

	bool old;
	stat.name = oid.hobj.oid.name;
	decode(stat.ts, attrs["ts"]);
	decode(stat.deleted, attrs["deleted"]);
	decode(old, attrs["old"]);
	stat.state = !oid.hobj.is_temp() ? STATE::ACTIVE : old ? STATE::OLD : STATE::IN_WRITE;

	return 0;
}

void Backend::impl::check(const char *op, const ghobject_t& oid, const Stat& stat, int r) {
	Stat stored;
	if (r >= 0)
		r = load(oid, stored);

	if (r == -ENOENT || (r >= 0 && stored.ts != stat.ts))
		throw ChangedError(op, stat.name, stat.ts);

	if (r < 0)
		throw std::runtime_error(std::string(op) + ": " + stat.name + ": " + cpp_strerror(r));
}

void Backend::impl::prepare(ObjectStore::CollectionHandle& ch, ObjectStore::Transaction&& t, std::shared_future<void> *done) {
	std::shared_future<void> future;
	if (done) {
		std::promise<void> committed;
		future = committed.get_future().share();

		t.register_on_commit(make_lambda_context([committed = std::move(committed)](int) mutable {
			committed.set_value();
		}));
	}

	std::lock_guard l(queue_lock);
	queue.emplace_back(ch, std::move(t));

	if (done)
		*done = std::move(future);
}

void Backend::impl::submit() {
	std::unique_lock s(submit_lock, std::try_to_lock);
	if (!s.owns_lock())
		return;

	for (;;) {
		Queue batch;
		{
			std::lock_guard l(queue_lock);
			if (queue.empty()) {
				s.unlock();
				return;
			}

			batch.swap(queue);
		}

		for (auto& [ch, t] : batch) {
			int r = store->queue_transaction(ch, std::move(t));
			if (r < 0)
				throw std::runtime_error("queue_transaction: " + cpp_strerror(r));
		}
	}
}

}
