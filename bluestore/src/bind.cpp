#include <nanobind/nanobind.h>
#include <nanobind/stl/string.h>
#include <nanobind/stl/optional.h>

#include "backend.h"
#include "bind.h"

namespace nb = nanobind;

nb::bytearray py_fake_read(std::string& object, size_t size) {
	nb::bytearray out;
	out.resize(size);
	void *data = out.data();

	{
		nb::gil_scoped_release rel;
		fake_read(object, data, size);
	}

	return out;
}

size_t py_fake_write(std::string& object, std::optional<nb::bytes> bytes) {
	if (!bytes)
		return 0;

	const void *data = bytes->data();
	size_t out, size = bytes->size();

	{
		nb::gil_scoped_release rel;
		out = fake_write(object, data, size);
	}

	return out;
}

NB_MODULE(_raw, m) {
	m.def("fake_read", &py_fake_read, nb::arg("object"), nb::arg("size"));
	m.def("fake_write", &py_fake_write, nb::arg("object"), nb::arg("data") = nb::none());
}
