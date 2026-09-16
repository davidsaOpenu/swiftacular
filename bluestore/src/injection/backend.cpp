#include <cstdint>
#include <vector>

#include <filesystem>
#include <fstream>
#include <sstream>
#include <stdexcept>
#include <memory>

#include "os/bluestore/BlueStore.h"
#include "common/errno.h"

#include "internal.h"
#include "backend.h"
#include "object.h"

namespace bluestore {

namespace {

constexpr uint64_t DEFAULT_CAPACITY = 1024ull * 1024 * 1024;

}

ConflictError::ConflictError(const char *op, const std::string& name, uint64_t next, uint64_t prev):
	std::runtime_error(std::string(op) + ": " + name + " " + std::to_string(next) +
		" is not newer than " + std::to_string(prev)) {}

// A new store's file is made at the requested capacity, or at a small
// default, and an existing store is only ever grown. expand_devices() needs
// it unmounted and kills the process if another has it open, so a mount is
// tried first to turn that into an ordinary error.
// see ARCHITECTURE.md#object_model
Backend::Backend(const std::string& path, std::optional<uint64_t> capacity): p(std::make_shared<impl>()) {
	// An empty block file would fall back to BlueStore's own default size.
	if (capacity && *capacity == 0)
		throw std::invalid_argument("bluestore " + path + ": capacity must not be 0");

	std::error_code ec;
	std::filesystem::create_directories(path, ec);
	if (ec)
		throw std::runtime_error("bluestore " + path + ": " + ec.message());

	try {
		std::string block = path + "/block";
		bool fresh = !std::filesystem::exists(block) || std::filesystem::file_size(block) == 0;
		std::ofstream(block, std::ios::app);

		if (fresh)
			std::filesystem::resize_file(block, capacity.value_or(DEFAULT_CAPACITY));
		else if (capacity && std::filesystem::file_size(block) < *capacity)
			std::filesystem::resize_file(block, *capacity);

		auto store = std::make_unique<BlueStore>(bluestore::context(), path);
		int r = store->mkfs();
		if (r < 0)
			throw std::runtime_error("mkfs: " + cpp_strerror(r));

		bluestore_bdev_label_t label;
		r = BlueStore::read_bdev_label(bluestore::context(), block, &label);
		if (r < 0)
			throw std::runtime_error("read_bdev_label: " + cpp_strerror(r));

		if (label.size < std::filesystem::file_size(block)) {
			r = store->mount();
			if (r < 0)
				throw std::runtime_error("mount: " + cpp_strerror(r));

			store->umount();

			std::ostringstream out;
			r = store->expand_devices(out);
			if (r < 0)
				throw std::runtime_error("expand_devices: " + cpp_strerror(r));
		}

		r = store->mount();
		if (r < 0)
			throw std::runtime_error("mount: " + cpp_strerror(r));

		// Mounted from here on, so impl unmounts it however construction ends.
		p->store = std::move(store);

		for (uint32_t ps = 0; ps < (1u << BLUESTORE_BITS); ++ps) {
			coll_t cid(spg_t(pg_t(ps, BLUESTORE_POOL)));
			if (p->store->collection_exists(cid)) {
				p->collections.push_back(p->store->open_collection(cid));
				continue;
			}

			auto ch = p->store->create_new_collection(cid);
			ObjectStore::Transaction t;
			t.create_collection(cid, BLUESTORE_BITS);
			p->commit(ch, std::move(t));
			p->collections.push_back(ch);
		}
	} catch (const std::exception& e) {
		throw std::runtime_error("bluestore " + path + ": " + e.what());
	} catch (...) {
		throw std::runtime_error("bluestore " + path + ": unknown failure");
	}
}

Backend::~Backend() = default;

Object Backend::create(const std::string& name, std::optional<uint64_t> ts) {
	return Object(p, name, ts.value_or(estimate()));
}

Object Backend::find(const std::string& name) {
	return Object(p, name);
}

void Backend::scan(const std::function<SCAN(const Stat&)>& fn) {
	for (auto& ch : p->collections) {
		bool next_collection = false;
		ghobject_t next;

		while (!next_collection && !next.is_max()) {
			std::vector<ghobject_t> batch;
			int r = p->store->collection_list(ch, next, ghobject_t::get_max(),
				1024, &batch, &next);
			if (r < 0)
				throw std::runtime_error("collection_list: " + cpp_strerror(r));

			for (const auto& oid : batch) {
				Stat stat;
				r = p->load(oid, stat);
				if (r < 0)
					throw std::runtime_error("getattrs: " + cpp_strerror(r));

				if (fn(stat) == SCAN::NEXT_COLLECTION) {
					next_collection = true;
					break;
				}
			}
		}
	}
}

void Backend::clean() {
	scan([&](const Stat& stat) {
		if (stat.state == STATE::ACTIVE)
			return SCAN::NEXT_COLLECTION;

		auto& ch = p->collection(stat.name);
		ObjectStore::Transaction t;
		t.remove(ch->cid, p->address(stat));
		p->commit(ch, std::move(t));
		return SCAN::NEXT_ENTRY;
	});
}

void Backend::put(Object& next, Object& prev, std::optional<uint64_t> ts) {
	next.require("put", {STATE::IN_WRITE});
	prev.require("put", {STATE::ACTIVE, STATE::MISSING});

	// A rename between collections aborts BlueStore.
	if (next.name != prev.name || next.back != p || prev.back != p)
		throw std::invalid_argument("put: " + next.name + " cannot replace " + prev.name);

	uint64_t settled = ts.value_or(next.ts);
	if (settled <= prev.ts)
		throw ConflictError("put", next.name, settled, prev.ts);

	auto& ch = p->collection(next.name);
	const coll_t& cid = ch->cid;
	ObjectStore::Transaction t;

	if (prev.state == STATE::ACTIVE) {
		ghobject_t from = p->address(prev);
		prev.state = STATE::OLD;
		t.collection_move_rename(cid, from, cid, p->address(prev));
		p->save(t, prev);
	}

	ghobject_t from = p->address(next);
	next.state = STATE::ACTIVE;
	next.ts = settled;
	t.collection_move_rename(cid, from, cid, p->address(next));
	p->save(t, next);

	p->commit(ch, std::move(t));
}

}
