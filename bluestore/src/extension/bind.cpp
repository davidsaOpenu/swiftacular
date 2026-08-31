#include <nanobind/nanobind.h>
#include <nanobind/stl/string.h>
#include <nanobind/stl/optional.h>

#include "backend.h"

namespace nb = nanobind;

namespace {

// The binding: convert the arguments, call the engine, convert the result.
// Decisions belong on one side or the other, not here.
// see ARCHITECTURE.md#binding

nb::bytearray fake_read(Backend& self, std::string& object, size_t size) {
	nb::bytearray out;
	out.resize(size);
	void *data = out.data();

	{
		// Half of the rule. The caller owns the other half.
		// see ARCHITECTURE.md#concurrency
		nb::gil_scoped_release rel;
		self.fake_read(object, data, size);
	}

	return out;
}

size_t fake_write(Backend& self, std::string& object, std::optional<nb::bytes> bytes) {
	if (!bytes)
		return 0;

	const void *data = bytes->data();
	size_t out, size = bytes->size();

	{
		// see ARCHITECTURE.md#concurrency
		nb::gil_scoped_release rel;
		out = self.fake_write(object, data, size);
	}

	return out;
}

}

NB_MODULE(_raw, m) {
	// The engine is an object with a lifetime, not a set of functions.
	// Python holds a handle; letting go of it closes the engine.
	// see ARCHITECTURE.md#binding
	nb::class_<Backend>(m, "Backend")
		.def(nb::init<const std::string&>())
		.def("fake_read", &fake_read, nb::arg("object"), nb::arg("size"))
		.def("fake_write", &fake_write, nb::arg("object"), nb::arg("data") = nb::none());
}
