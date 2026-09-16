#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <mutex>
#include <stdexcept>
#include <string>
#include <vector>
#include <map>

#include "global/global_context.h"
#include "global/global_init.h"
#include "include/ceph_hash.h"
#include "common/Cond.h"
#include "common/errno.h"

#include "internal.h"

namespace bluestore {

namespace {

const std::map<std::string, std::string> defaults = {
	{"bluestore_fsck_on_mkfs",   "false"},
	{"bluestore_fsck_on_mount",  "false"},
	{"bluestore_fsck_on_umount", "false"},
	{"admin_socket", ""}
};

const std::map<std::string, std::string> debug = {
	{"bluestore_fsck_on_mkfs",   "false"},
	{"bluestore_fsck_on_mount",  "false"},
	{"bluestore_fsck_on_umount", "false"},
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

// Made on first use rather than at load: the log thread it starts does not
// survive a fork, so it has to start in the worker that uses it, and Ceph's
// own g_ceph_context holds it rather than a pointer of ours. BLUESTORE_DEBUG
// switches to verbose BlueStore logging on stderr.
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
	auto now = std::chrono::system_clock::now().time_since_epoch();
	auto us = std::chrono::duration_cast<std::chrono::microseconds>(now).count();

	return us / (1000000 / TICKS_PER_SECOND);
}

Backend::impl::~impl() {
	// Collections have to be released before BlueStore unmounts.
	collections.clear();

	if (store)
		store->umount();
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

	// The address already carries the name's hash.
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

void Backend::impl::commit(ObjectStore::CollectionHandle& ch, ObjectStore::Transaction&& t) {
	C_SaferCond done;
	t.register_on_commit(&done);

	int r = store->queue_transaction(ch, std::move(t));
	if (r < 0)
		throw std::runtime_error("queue_transaction: " + cpp_strerror(r));

	done.wait();
}

}
