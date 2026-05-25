// bs_ondisk.cc - BlueStore-backed object file operations for Swift
#include <iostream>
#include <vector>
#include <string>
#include <chrono>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <memory>
#include <sstream>

#include "common/ceph_context.h"
#include "global/global_init.h"
#include "common/ceph_argparse.h"
#include "common/errno.h"
#include "os/bluestore/BlueStore.h"
#include "os/ObjectStore.h"
#include "osd/osd_types.h"

using namespace std;

// Usage: bs_ondisk list|verify|read|write|stat <bluestore_path> [object_name] [options]

void print_usage(const char* prog) {
    cerr << "Usage: " << prog << " <command> <bluestore_path> [options]\n";
    cerr << "\nCommands:\n";
    cerr << "  list <bluestore_path>                      - List all objects\n";
    cerr << "  stat <bluestore_path> <object_name>        - Get object size/info\n";
    cerr << "  verify <bluestore_path> <object_name>      - Verify object exists\n";
    cerr << "  read <bluestore_path> <object_name> [offset] [length]\n";
    cerr << "  write <bluestore_path> <object_name> <size> - Write from stdin\n";
    cerr << "  remove <bluestore_path> <object_name>      - Remove object\n";
    cerr << "\nExamples:\n";
    cerr << "  " << prog << " list /srv/node/sdb1/bluestore\n";
    cerr << "  " << prog << " stat /srv/node/sdb1/bluestore obj_12345.data\n";
    cerr << "  " << prog << " read /srv/node/sdb1/bluestore obj_12345.data 0 1024\n";
    cerr << "  cat data.bin | " << prog << " write /srv/node/sdb1/bluestore obj_12345.data\n";
}

int main(int argc, char** argv) {
    if (argc < 3) {
        print_usage(argv[0]);
        return 1;
    }

    string operation = argv[1];
    string bluestore_path = argv[2];

    // Initialize Ceph context with minimal logging
    map<string,string> defaults = {
        {"bluestore_fsck_on_mount", "false"},
        {"bluestore_fsck_on_umount", "false"},
        {"debug_rocksdb", "0/0"},
        {"debug_bluefs", "0/0"},
        {"debug_bdev", "0/0"},
        {"debug_bluestore", "0/0"}
    };

    vector<const char*> args(argv, argv + argc);
    auto cct = global_init(&defaults, args, CEPH_ENTITY_TYPE_OSD,
                           CODE_ENVIRONMENT_UTILITY,
                           CINIT_FLAG_NO_DEFAULT_CONFIG_FILE);
    common_init_finish(g_ceph_context);

    // Create and mount BlueStore
    auto store = std::make_unique<BlueStore>(cct.get(), bluestore_path);

    int r = store->mount();
    if (r < 0) {
        cerr << "Failed to mount BlueStore at " << bluestore_path
             << ": " << cpp_strerror(r) << std::endl;
        return 1;
    }

    // Use a default collection for Swift objects
    spg_t pgid(pg_t(0, 0), shard_id_t::NO_SHARD);
    coll_t cid(pgid);
    ObjectStore::CollectionHandle ch;

    if (operation == "list") {
        // List all objects in the collection
        ch = store->open_collection(cid);
        if (!ch) {
            // Collection doesn't exist yet - return empty list
            store->umount();
            return 0;
        }

        vector<ghobject_t> objects;
        ghobject_t next;
        while (true) {
            vector<ghobject_t> batch;
            r = store->collection_list(ch, next, ghobject_t::get_max(),
                                       1000, &batch, &next);
            if (r < 0) {
                cerr << "collection_list failed: " << cpp_strerror(r) << std::endl;
                break;
            }

            for (const auto& obj : batch) {
                // Output object name (one per line)
                cout << obj.hobj.oid.name << "\n";
            }

            if (batch.size() < 1000) {
                break;  // No more objects
            }
        }

        store->umount();
        return 0;
    }
    else if (operation == "stat") {
        if (argc < 4) {
            cerr << "Usage: " << argv[0] << " stat <bluestore_path> <object_name>\n";
            store->umount();
            return 1;
        }
        string obj_name = argv[3];

        ch = store->open_collection(cid);
        if (!ch) {
            store->umount();
            return ENOENT;
        }

        ghobject_t oid(hobject_t(obj_name, "", CEPH_NOSNAP, 0, 0, ""));

        struct stat st;
        r = store->stat(ch, oid, &st);
        if (r == 0) {
            // Output: size mtime
            cout << st.st_size << " " << st.st_mtime << "\n";
            store->umount();
            return 0;
        } else {
            store->umount();
            return ENOENT;
        }
    }
    else if (operation == "verify") {
        if (argc < 4) {
            cerr << "Usage: " << argv[0] << " verify <bluestore_path> <object_name>\n";
            store->umount();
            return 1;
        }
        string obj_name = argv[3];

        ch = store->open_collection(cid);
        if (!ch) {
            store->umount();
            return ENOENT;
        }

        ghobject_t oid(hobject_t(obj_name, "", CEPH_NOSNAP, 0, 0, ""));

        struct stat st;
        r = store->stat(ch, oid, &st);

        store->umount();
        return (r == 0) ? 0 : ENOENT;
    }
    else if (operation == "read") {
        if (argc < 4) {
            cerr << "Usage: " << argv[0] << " read <bluestore_path> <object_name> [offset] [length]\n";
            store->umount();
            return 1;
        }
        string obj_name = argv[3];
        size_t offset = (argc > 4) ? stoull(argv[4]) : 0;
        size_t length = (argc > 5) ? stoull(argv[5]) : 0;

        ch = store->open_collection(cid);
        if (!ch) {
            store->umount();
            return ENOENT;
        }

        ghobject_t oid(hobject_t(obj_name, "", CEPH_NOSNAP, 0, 0, ""));

        // If length not specified, get object size
        if (length == 0) {
            struct stat st;
            r = store->stat(ch, oid, &st);
            if (r < 0) {
                store->umount();
                return ENOENT;
            }
            length = st.st_size - offset;
        }

        bufferlist bl;
        r = store->read(ch, oid, offset, length, bl);
        if (r >= 0) {
            // Output raw binary data to stdout
            cout.write(bl.c_str(), bl.length());
            store->umount();
            return 0;
        } else {
            cerr << "Read failed: " << cpp_strerror(r) << std::endl;
            store->umount();
            return EIO;
        }
    }
    else if (operation == "write") {
        if (argc < 4) {
            cerr << "Usage: " << argv[0] << " write <bluestore_path> <object_name> < data\n";
            store->umount();
            return 1;
        }
        string obj_name = argv[3];

        ch = store->open_collection(cid);
        if (!ch) {
            // Create collection if it doesn't exist
            ch = store->create_new_collection(cid);
            ObjectStore::Transaction t;
            t.create_collection(cid, 0);
            r = store->queue_transaction(ch, std::move(t));
            if (r < 0) {
                cerr << "Failed to create collection: " << cpp_strerror(r) << std::endl;
                store->umount();
                return 1;
            }
        }

        ghobject_t oid(hobject_t(obj_name, "", CEPH_NOSNAP, 0, 0, ""));

        // Read data from stdin
        ostringstream oss;
        oss << cin.rdbuf();
        string data = oss.str();

        bufferlist bl;
        bl.append(data);

        ObjectStore::Transaction t;
        t.write(cid, oid, 0, bl.length(), bl);
        r = store->queue_transaction(ch, std::move(t));

        if (r == 0) {
            store->umount();
            return 0;
        } else {
            cerr << "Write failed: " << cpp_strerror(r) << std::endl;
            store->umount();
            return EIO;
        }
    }
    else if (operation == "remove") {
        if (argc < 4) {
            cerr << "Usage: " << argv[0] << " remove <bluestore_path> <object_name>\n";
            store->umount();
            return 1;
        }
        string obj_name = argv[3];

        ch = store->open_collection(cid);
        if (!ch) {
            store->umount();
            return ENOENT;
        }

        ghobject_t oid(hobject_t(obj_name, "", CEPH_NOSNAP, 0, 0, ""));

        ObjectStore::Transaction t;
        t.remove(cid, oid);
        r = store->queue_transaction(ch, std::move(t));

        if (r == 0) {
            store->umount();
            return 0;
        } else {
            cerr << "Remove failed: " << cpp_strerror(r) << std::endl;
            store->umount();
            return EIO;
        }
    }
    else {
        cerr << "Unknown operation: " << operation << std::endl;
        print_usage(argv[0]);
        store->umount();
        return 1;
    }

    store->umount();
    return 1;
}
