#include <cstddef>
#include <string>
#include <memory>

#ifndef BLUESTORE_BACKEND_H
#define BLUESTORE_BACKEND_H

// The engine's surface. Deliberately mentions nothing of Ceph: the state
// lives behind the pointer, so the extension can be compiled against this
// header without Ceph's headers being present at all.
// see ARCHITECTURE.md#engine

class Backend {
	struct impl;
	std::unique_ptr<impl> p;

public:
	Backend(const std::string& _filename);
	~Backend();

	size_t fake_read(std::string& object, void *data, size_t size);
	size_t fake_write(std::string& object, const void *data, size_t size);
};

#endif
