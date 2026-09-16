#include <nanobind/nanobind.h>
#include <nanobind/stl/optional.h>
#include <nanobind/stl/string.h>

#include <bluestore.h>

using namespace bluestore;
namespace nb = nanobind;

// The binding: convert the arguments, call the engine, convert the result.
// Decisions belong on one side or the other, not here.
// see ARCHITECTURE.md#binding

namespace {

constexpr uint64_t MiB = 1024 * 1024;

void backend_put(Backend& self, Object& next, Object& prev, std::optional<uint64_t> ts) {
	self.put(next, prev, ts);
}

void backend_clean(Backend &self) {
	self.clean();
}

void object_open(Object& self) {
	nb::gil_scoped_release rel;
	self.open();
}

nb::bytearray object_read(Object& self, uint64_t offset, uint64_t size) {
	nb::bytearray out;

	if (size == 0)
		return out;

	size_t prog;
	out.resize(size);
	void *data = out.data();

	{
		nb::gil_scoped_release rel;
		prog = self.read(offset, data, size);
	}

	out.resize(prog);
	return out;
}

nb::bytearray object_read_metadata(Object& self, uint64_t offset, uint64_t size) {
	nb::bytearray out;

	if (size == 0)
		return out;

	size_t prog;
	out.resize(size);
	void *data = out.data();

	{
		nb::gil_scoped_release rel;
		prog = self.read_metadata(offset, data, size);
	}

	out.resize(prog);
	return out;
}

void object_write(Object& self, const nb::bytes& bytes) {
	const void *data = bytes.data();
	size_t size = bytes.size();

	self.write(data, size);
}

void object_write_metadata(Object& self, const nb::bytes& bytes) {
	const void *data = bytes.data();
	size_t size = bytes.size();

	self.write_metadata(data, size);
}

void object_tombstone(Object& self, const nb::bytes& bytes) {
	const void *data = bytes.data();
	size_t size = bytes.size();

	self.tombstone(data, size);
}

}

NB_MODULE(_raw, m) {
	// The engine is an object with a lifetime, not a set of functions.
	// Python holds a handle; letting go of it closes the engine.
	// see ARCHITECTURE.md#binding

	nb::enum_<STATE>(m, "STATE")
		.value("PRE_SEARCH", STATE::PRE_SEARCH)
		.value("IN_SEARCH", STATE::IN_SEARCH)
		.value("MISSING", STATE::MISSING)
		.value("PRE_WRITE", STATE::PRE_WRITE)
		.value("IN_WRITE", STATE::IN_WRITE)
		.value("ACTIVE", STATE::ACTIVE)
		.value("OLD", STATE::OLD);

	nb::exception<StateError>(m, "StateError");
	nb::exception<ChangedError>(m, "ChangedError");
	nb::exception<ConflictError>(m, "ConflictError");

	nb::class_<Object>(m, "Object")
		.def_ro("name", &Object::name)
		.def_ro("ts", &Object::ts)
		.def_ro("deleted", &Object::deleted)
		.def_ro("state", &Object::state)
		.def("open", &object_open)
		.def("read", &object_read, nb::arg("offset") = 0, nb::arg("size") = MiB)
		.def("read_metadata", &object_read_metadata, nb::arg("offset") = 0, nb::arg("size") = MiB)
		.def("write", &object_write, nb::arg("data"))
		.def("write_metadata", &object_write_metadata, nb::arg("data"))
		.def("tombstone", &object_tombstone, nb::arg("data"));

	nb::class_<Backend>(m, "Backend")
		.def(nb::init<const std::string&, std::optional<uint64_t>>(), nb::arg("path"), nb::arg("capacity") = nb::none())
		.def("create", &Backend::create, nb::arg("name"), nb::arg("timestamp") = nb::none())
		.def("find", &Backend::find, nb::arg("name"))
		.def("put", &backend_put, nb::arg("next"), nb::arg("prev"), nb::arg("timestamp") = nb::none())
		.def("clean", &backend_clean);
}
