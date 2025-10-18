#include <iostream>
#include <string>
#include <vector>
#include <memory>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <pwd.h>

#include "common/ceph_context.h"
#include "global/global_init.h"
#include "common/ceph_argparse.h"
#include "common/errno.h"
#include "os/bluestore/BlueStore.h"
#include "os/ObjectStore.h"
#include "osd/osd_types.h"

using namespace std;

string get_home_directory() {
    const char* home = getenv("HOME");
    if (home) return string(home);
    struct passwd* pw = getpwuid(getuid());
    if (pw && pw->pw_dir) return string(pw->pw_dir);
    return "/tmp";
}

string resolve_bluestore_path(const string& bs_name) {
    return get_home_directory() + "/bluestore_images/" + bs_name;
}

bool ensure_base_directory() {
    string base_dir = get_home_directory() + "/bluestore_images";
    struct stat st;
    if (stat(base_dir.c_str(), &st) != 0) {
        if (mkdir(base_dir.c_str(), 0755) != 0) {
            cerr << "Failed to create " << base_dir << ": " << cpp_strerror(errno) << std::endl;
            return false;
        }
    }
    return true;
}

class BlueStoreUtil {
private:
    boost::intrusive_ptr<CephContext> cct;
    BlueStore* store;
    ObjectStore::CollectionHandle ch;
    coll_t cid;
    string base_path;
    bool mounted;

public:
    BlueStoreUtil(const string& path) : base_path(path), mounted(false), store(nullptr) {
        map<string,string> defaults = {
            {"bluestore_block_size", "10737418240"},
            {"bluestore_fsck_on_mount", "false"},
            {"bluestore_fsck_on_umount", "false"},
            {"debug_rocksdb", "0/0"},
            {"debug_bluefs", "0/0"},
            {"debug_bdev", "0/0"},
            {"debug_bluestore", "0/0"}
        };
        vector<const char*> args;
        cct = global_init(&defaults, args, CEPH_ENTITY_TYPE_OSD,
                          CODE_ENVIRONMENT_UTILITY, 
                          CINIT_FLAG_NO_DEFAULT_CONFIG_FILE);
        common_init_finish(cct.get());
        spg_t pgid(pg_t(0, 0), shard_id_t::NO_SHARD);
        cid = coll_t(pgid);
    }

    ~BlueStoreUtil() {
        try {
            if (mounted && store) {
                ch.reset();
                store->umount();
            }
            if (store) {
                delete store;
                store = nullptr;
            }
        } catch (...) {}
    }

    int create() {
        struct stat st;
        if (stat(base_path.c_str(), &st) == 0) {
            cerr << "BlueStore exists at " << base_path << std::endl;
            return -1;
        }
        if (mkdir(base_path.c_str(), 0755) != 0) {
            cerr << "Failed to create " << base_path << std::endl;
            return -1;
        }
        string block_path = base_path + "/block";
        int fd = ::open(block_path.c_str(), O_CREAT|O_RDWR|O_TRUNC, 0644);
        if (fd < 0) return -1;
        ::ftruncate(fd, 10LL*1024*1024*1024); # 2 GB
        ::close(fd);
        
        store = new BlueStore(cct.get(), base_path);
        if (store->mkfs() < 0) return -1;
        if (store->mount() < 0) return -1;
        mounted = true;
        
        ch = store->create_new_collection(cid);
        ObjectStore::Transaction t;
        t.create_collection(cid, 0);
        return store->queue_transaction(ch, std::move(t));
    }

    int mount_existing() {
        if (mounted) return 0;
        if (!store) {
            struct stat st;
            if (stat((base_path + "/block").c_str(), &st) != 0) return -1;
            store = new BlueStore(cct.get(), base_path);
        }
        if (store->mount() < 0) return -1;
        mounted = true;
        ch = store->open_collection(cid);
        return ch ? 0 : -1;
    }

    int write_object(const string& obj_name, const string& data) {
        if (!mounted && mount_existing() < 0) return -1;
        ghobject_t oid(hobject_t(obj_name, "", CEPH_NOSNAP, 0, 0, ""));
        bufferlist bl;
        bl.append(data);
        ObjectStore::Transaction t;
        t.write(cid, oid, 0, data.size(), bl);
        return store->queue_transaction(ch, std::move(t));
    }

    int read_object(const string& obj_name) {
        if (!mounted && mount_existing() < 0) return -1;
        ghobject_t oid(hobject_t(obj_name, "", CEPH_NOSNAP, 0, 0, ""));
        bufferlist bl;
        int r = store->read(ch, oid, 0, 1024*1024*1024, bl);
        if (r < 0) return r;
        cout.write(bl.c_str(), bl.length());
        cout.flush();
        return 0;
    }

    int delete_object(const string& obj_name) {
        if (!mounted && mount_existing() < 0) return -1;
        ghobject_t oid(hobject_t(obj_name, "", CEPH_NOSNAP, 0, 0, ""));
        ObjectStore::Transaction t;
        t.remove(cid, oid);
        return store->queue_transaction(ch, std::move(t));
    }
};

int main(int argc, char** argv) {
    if (argc < 3) {
        cerr << "Usage: " << argv[0] << " <command> <bs_name> [args]" << std::endl;
        return 1;
    }
    
    string command = argv[1];
    string bs_name = argv[2];
    
    if (!ensure_base_directory()) return 1;
    string bluestore_path = resolve_bluestore_path(bs_name);
    
    try {
        BlueStoreUtil util(bluestore_path);
        
        if (command == "create") {
            return util.create() == 0 ? 0 : 1;
        } else if (command == "write") {
            if (argc < 4) return 1;
            string data;
            char buffer[4096];
            while (cin.read(buffer, sizeof(buffer)) || cin.gcount() > 0) {
                data.append(buffer, cin.gcount());
            }
            return util.write_object(argv[3], data) == 0 ? 0 : 1;
        } else if (command == "read") {
            if (argc < 4) return 1;
            return util.read_object(argv[3]) == 0 ? 0 : 1;
        } else if (command == "delete") {
            if (argc < 4) return 1;
            return util.delete_object(argv[3]) == 0 ? 0 : 1;
        }
    } catch (...) {
        return 1;
    }
    return 0;
}
