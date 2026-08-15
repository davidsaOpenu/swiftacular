#include <nanobind/nanobind.h>
#include <nanobind/stl/string.h>
#include <nanobind/stl/optional.h>
#include <unistd.h>
#include <cstdint>
#include <vector>
#include <thread>
#include <chrono>

#include "store.h"

namespace nb = nanobind;

nb::bytearray fake_read(std::string& object) {
	nb::bytearray out;
	out.resize(512);
	void *p = out.data();
	
	{
		nb::gil_scoped_release rel;
		std::this_thread::sleep_for(std::chrono::microseconds(150));

		memset(p, 'A', 512);
	}

	return out;
}

size_t fake_write(std::string& object, std::optional<nb::bytes> data) {
	if (!data)
		return 0;

	size_t n = data->size();
	const void *p = data->data();
	
	{
		nb::gil_scoped_release rel;
		std::this_thread::sleep_for(std::chrono::milliseconds(2));

		std::vector<uint8_t> file(n, '0');
		memcpy(file.data(), p, n);
	}

	return n;
}

NB_MODULE(_raw, m) {
	m.def("fake_read", &fake_read, nb::arg("object"));
	m.def("fake_write", &fake_write, nb::arg("object"), nb::arg("data") = nb::none());
}
