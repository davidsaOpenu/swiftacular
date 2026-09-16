#include <nanobind/nanobind.h>
#include <nanobind/stl/string.h>

#include "backend.h"

using namespace bluestore;
namespace nb = nanobind;

// The binding: convert the arguments, call the engine, convert the result.
// Decisions belong on one side or the other, not here.
// see ARCHITECTURE.md#binding

NB_MODULE(_raw, m) {
	// The engine is an object with a lifetime, not a set of functions.
	// Python holds a handle; letting go of it closes the engine.
	// see ARCHITECTURE.md#binding
	nb::class_<Backend>(m, "Backend")
		.def(nb::init<const std::string&, uint64_t>());
}
