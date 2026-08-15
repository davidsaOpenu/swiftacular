#include <cstring>
#include <thread>
#include <chrono>

#include "backend.h"

size_t fake_read(std::string& object, void *data, size_t size) {
	std::this_thread::sleep_for(std::chrono::microseconds(150));

	memset(data, 'A', size);
	return size;
}

size_t fake_write(std::string& object, const void *data, size_t size) {
	std::this_thread::sleep_for(std::chrono::milliseconds(2));

	std::vector<uint8_t> file(size, '0');
	memcpy(file.data(), data, size);
	return size;
}
