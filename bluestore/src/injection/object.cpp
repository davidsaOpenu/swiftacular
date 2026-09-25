#include <algorithm>
#include <cstdint>
#include <future>
#include <mutex>
#include <string>
#include <vector>

#include "common/errno.h"

#include "internal.h"
#include "backend.h"
#include "object.h"

namespace bluestore {

StateError::StateError(const char *op, const std::string& name, const char *state):
	std::logic_error(std::string(op) + ": " + name + " is " + state) {}

ChangedError::ChangedError(const char *op, const std::string& name, uint64_t ts):
	std::runtime_error(std::string(op) + ": " + name + " " +
		std::to_string(ts) + " has changed") {}

Object::Object(std::shared_ptr<Backend::impl> back, const std::string& name, uint64_t ts):
	Stat{name, ts, false, STATE::PRE_WRITE}, back(std::move(back)) {}

Object::Object(std::shared_ptr<Backend::impl> back, const std::string& name):
	Stat{name, 0, false, STATE::PRE_SEARCH}, back(std::move(back)) {}

Object::Object(Object&& other):
	Stat(other), back(other.back), done(std::move(other.done)), written(other.written) {
	static_cast<Stat&>(other) = Stat{other.name, 0, false, STATE::PRE_SEARCH};
	other.written = 0;
}

Object::~Object() {
	if (state != STATE::IN_WRITE && state != STATE::OLD)
		return;

	try {
		auto& ch = back->collection(name);
		ObjectStore::Transaction t;
		t.remove(ch->cid, back->address(*this));
		back->prepare(ch, std::move(t));
	} catch (...) {}
}

void Object::require(const char *op, std::initializer_list<STATE> allowed) const {
	if (std::find(allowed.begin(), allowed.end(), state) == allowed.end())
		throw StateError(op, name, state_name(state));
}

void Object::open() {
	require("open", {STATE::PRE_SEARCH});
	state = STATE::IN_SEARCH;

	Stat stored;
	int r = back->load(back->address(*this), stored);

	if (r == -ENOENT) {
		state = STATE::MISSING;
		return;
	}

	if (r < 0)
		throw std::runtime_error("open: " + name + ": " + cpp_strerror(r));

	static_cast<Stat&>(*this) = stored;
}

size_t Object::read(uint64_t offset, void *data, size_t size) {
	require("read", {STATE::ACTIVE, STATE::OLD});

	// BlueStore reads the whole object when asked for 0 bytes.
	if (size == 0)
		return 0;

	auto& ch = back->collection(name);
	ghobject_t oid = back->address(*this);
	ceph::buffer::list bl;
	int r = back->store->read(ch, oid, offset, size, bl);
	back->check("read", oid, *this, r);

	if (bl.length())
		bl.begin().copy(bl.length(), static_cast<char*>(data));

	return bl.length();
}

size_t Object::read_metadata(uint64_t offset, void *data, size_t size) {
	require("read_metadata", {STATE::ACTIVE, STATE::OLD});

	auto& ch = back->collection(name);
	ghobject_t oid = back->address(*this);
	ceph::buffer::list bl;
	int r = back->store->omap_get_header(ch, oid, &bl);
	back->check("read_metadata", oid, *this, r);

	if (offset >= bl.length())
		return 0;

	size_t length = std::min<uint64_t>(size, bl.length() - offset);
	bl.begin(offset).copy(length, static_cast<char*>(data));
	return length;
}

void Object::write(const void *data, size_t size) {
	require("write", {STATE::PRE_WRITE, STATE::IN_WRITE});

	ceph::buffer::list bl;
	bl.append(static_cast<const char*>(data), size);

	ghobject_t oid = back->address(*this);
	auto& ch = back->collection(name);
	ObjectStore::Transaction t;

	if (state == STATE::PRE_WRITE) {
		state = STATE::IN_WRITE;
		t.touch(ch->cid, oid);
		back->save(t, *this);
	}

	t.write(ch->cid, oid, written, size, bl);
	written += size;

	back->prepare(ch, std::move(t), &done);
}

void Object::write_metadata(const void *data, size_t size) {
	require("write_metadata", {STATE::PRE_WRITE, STATE::IN_WRITE, STATE::ACTIVE});

	ghobject_t oid = back->address(*this);
	auto& ch = back->collection(name);
	ObjectStore::Transaction t;

	if (state == STATE::PRE_WRITE) {
		state = STATE::IN_WRITE;
		t.touch(ch->cid, oid);
	}

	ceph::buffer::list bl;
	bl.append(static_cast<const char*>(data), size);

	t.omap_setheader(ch->cid, oid, bl);
	back->save(t, *this);

	back->prepare(ch, std::move(t), &done);
}

void Object::tombstone(const void *data, size_t size) {
	require("tombstone", {STATE::PRE_WRITE});

	deleted = true;
	write_metadata(data, size);
}

void Object::sync() {
	back->submit();

	std::shared_future<void> local;
	{
		std::lock_guard l(back->queue_lock);
		local = done;
	}

	if (local.valid())
		local.wait();
}

}
