#ifndef __BLUESTORE_BACKEND_H
#define __BLUESTORE_BACKEND_H

size_t fake_read(std::string& object, void *data, size_t size);
size_t fake_write(std::string& object, const void *data, size_t size);

#endif
