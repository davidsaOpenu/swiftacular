// bs_xattr.cc - RocksDB-based extended attribute storage for BlueStore backend
#include <rocksdb/db.h>
#include <rocksdb/options.h>
#include <iostream>
#include <string>
#include <cstring>
#include <errno.h>

using namespace std;

// Usage: bs_xattr get|set|list <filepath> [key] [value]
int main(int argc, char* argv[]) {
    if (argc < 3) {
        cerr << "Usage: " << argv[0] << " get|set|list <filepath> [key] [value]\n";
        cerr << "Commands:\n";
        cerr << "  get <filepath> <key>        - Get xattr value\n";
        cerr << "  set <filepath> <key> <value> - Set xattr value\n";
        cerr << "  list <filepath>             - List all xattr keys\n";
        return 1;
    }

    string operation = argv[1];
    string filepath = argv[2];

    // Create unique DB path per object file
    // Store xattr DB in same directory as the file
    string db_path = filepath + ".xattr.db";

    rocksdb::Options options;
    options.create_if_missing = true;
    options.use_fsync = true;
    options.OptimizeLevelStyleCompaction();

    rocksdb::DB* db;
    rocksdb::Status status = rocksdb::DB::Open(options, db_path, &db);
    if (!status.ok()) {
        cerr << "Failed to open xattr DB for " << filepath << ": "
             << status.ToString() << std::endl;
        return 1;
    }

    if (operation == "get") {
        if (argc < 4) {
            cerr << "Usage: " << argv[0] << " get <filepath> <key>\n";
            delete db;
            return 1;
        }
        string key = argv[3];
        string value;

        status = db->Get(rocksdb::ReadOptions(), key, &value);
        if (status.ok()) {
            // Output raw value to stdout (binary-safe)
            cout.write(value.data(), value.size());
            delete db;
            return 0;
        } else if (status.IsNotFound()) {
            // Key not found - return ENODATA errno
            delete db;
            return ENODATA;  // errno 61 on Linux
        } else {
            cerr << "Get failed: " << status.ToString() << std::endl;
            delete db;
            return EIO;  // I/O error
        }
    }
    else if (operation == "set") {
        if (argc < 4) {
            cerr << "Usage: " << argv[0] << " set <filepath> <key> [value]\n";
            cerr << "  If value is omitted, reads binary value from stdin\n";
            delete db;
            return 1;
        }
        string key = argv[3];
        string value;

        // Read value from stdin if not provided as argument (for binary data)
        if (argc >= 5) {
            value = argv[4];
        } else {
            // Read binary data from stdin
            char buffer[4096];
            while (cin.read(buffer, sizeof(buffer)) || cin.gcount() > 0) {
                value.append(buffer, cin.gcount());
            }
        }

        rocksdb::WriteOptions write_opts;
        write_opts.sync = true;  // Ensure durability

        status = db->Put(write_opts, key, value);
        if (status.ok()) {
            delete db;
            return 0;
        } else {
            cerr << "Set failed: " << status.ToString() << std::endl;
            delete db;
            return EIO;
        }
    }
    else if (operation == "list") {
        // List all keys for debugging
        rocksdb::Iterator* it = db->NewIterator(rocksdb::ReadOptions());
        for (it->SeekToFirst(); it->Valid(); it->Next()) {
            cout << it->key().ToString() << "\n";
        }
        delete it;
        delete db;
        return 0;
    }
    else {
        cerr << "Unknown operation: " << operation << std::endl;
        cerr << "Valid operations: get, set, list\n";
        delete db;
        return 1;
    }

    delete db;
    return 1;
}
