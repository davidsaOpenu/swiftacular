#include <algorithm>
#include <cstdint>
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

void Object::check(const char *op, int r) const {
	Stat stored;
	if (r >= 0)
		r = back->load(back->address(*this), stored);

	if (r == -ENOENT || (r >= 0 && stored.ts != ts))
		throw ChangedError(op, name, ts);

	if (r < 0)
		throw std::runtime_error(std::string(op) + ": " + name + ": " + cpp_strerror(r));
}

Object::Object(Object&& other):
	Stat(other), back(other.back), written(other.written) {
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
		back->commit(ch, std::move(t));
	} catch (...) {}
}

void Object::require(const char *op, std::initializer_list<STATE> allowed) const {
	if (std::find(allowed.begin(), allowed.end(), state) == allowed.end())
		throw StateError(op, name, state_name(state));
}

void Object::open() {
	require("open", {STATE::PRE_SEARCH, STATE::ACTIVE, STATE::OLD});
	if (state == STATE::PRE_SEARCH)
		state = STATE::IN_SEARCH;

	Stat stored;
	int r = back->load(back->address(*this), stored);

	if (r == -ENOENT && state == STATE::IN_SEARCH) {
		state = STATE::MISSING;
		return;
	}

	if (r == -ENOENT || (r >= 0 && state != STATE::IN_SEARCH && stored.ts != ts))
		throw ChangedError("open", name, ts);

	if (r < 0)
		throw std::runtime_error("open: " + name + ": " + cpp_strerror(r));

	// A search takes whatever version it found, and becomes ACTIVE with it.
	static_cast<Stat&>(*this) = stored;
}

size_t Object::read(uint64_t offset, void *data, size_t size) {
	require("read", {STATE::ACTIVE, STATE::OLD});

	// BlueStore reads the whole object when asked for 0 bytes.
	if (size == 0)
		return 0;

	auto& ch = back->collection(name);
	ceph::buffer::list bl;
	int r = back->store->read(ch, back->address(*this), offset, size, bl);
	check("read", r);

	if (bl.length())
		bl.begin().copy(bl.length(), static_cast<char*>(data));

	return bl.length();
}

size_t Object::read_metadata(uint64_t offset, void *data, size_t size) {
	require("read_metadata", {STATE::ACTIVE, STATE::OLD});

	auto& ch = back->collection(name);
	ceph::buffer::list bl;
	int r = back->store->omap_get_header(ch, back->address(*this), &bl);
	check("read_metadata", r);

	if (offset >= bl.length())
		return 0;

	size_t length = std::min<uint64_t>(size, bl.length() - offset);
	bl.begin(offset).copy(length, static_cast<char*>(data));
	return length;
}

void Object::write(const void *data, size_t size) {
	if (state == STATE::PRE_WRITE)
		write_metadata(nullptr, 0);

	require("write", {STATE::IN_WRITE});

	auto& ch = back->collection(name);
	ceph::buffer::list bl;
	bl.append(static_cast<const char*>(data), size);

	ObjectStore::Transaction t;
	t.write(ch->cid, back->address(*this), written, size, bl);
	back->commit(ch, std::move(t));

	written += size;
}

void Object::write_metadata(const void *data, size_t size) {
	require("write_metadata", {STATE::PRE_WRITE, STATE::IN_WRITE, STATE::ACTIVE});

	auto& ch = back->collection(name);
	ghobject_t oid = back->address(*this);
	ObjectStore::Transaction t;

	if (state == STATE::PRE_WRITE) {
		t.touch(ch->cid, oid);
		state = STATE::IN_WRITE;
	}

	ceph::buffer::list bl;
	bl.append(static_cast<const char*>(data), size);

	back->save(t, *this);
	t.omap_setheader(ch->cid, oid, bl);
	back->commit(ch, std::move(t));
}

void Object::tombstone(const void *data, size_t size) {
	require("tombstone", {STATE::PRE_WRITE});

	deleted = true;
	write_metadata(data, size);
}

}
