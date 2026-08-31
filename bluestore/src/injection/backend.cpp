#include <cstring>
#include <vector>
#include <thread>
#include <chrono>

#include <iostream>
#include <memory>

#include "common/ceph_argparse.h"
#include "common/ceph_context.h"
#include "common/common_init.h"
#include "common/config.h"

#include "backend.h"

struct Backend::impl {
	CephContext *cct = nullptr;
	std::string filename;
};

Backend::Backend(const std::string& _filename):
	p(std::make_unique<impl>()) {
	p->filename = _filename;

	CephInitParameters iparams(CEPH_ENTITY_TYPE_OSD);
	p->cct = common_preinit(iparams, CODE_ENVIRONMENT_LIBRARY, 0);
	p->cct->_conf.set_val("bluestore_block_path", p->filename);
	p->cct->_conf.set_val("bluestore_fsck_on_mount",  "false");
	p->cct->_conf.set_val("bluestore_fsck_on_umount", "false");
}

Backend::~Backend() {
	if (p && p->cct)
		p->cct->put();
}

size_t Backend::fake_read(std::string& object, void *data, size_t size) {
	std::this_thread::sleep_for(std::chrono::microseconds(150));

	memset(data, 'A', size);
	return size;
}

size_t Backend::fake_write(std::string& object, const void *data, size_t size) {
	std::this_thread::sleep_for(std::chrono::milliseconds(2));

	std::vector<uint8_t> file(size, '0');
	memcpy(file.data(), data, size);
	return size;
}
