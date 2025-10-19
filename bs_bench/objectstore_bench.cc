#include <iostream>
#include <vector>
#include <string>
#include <chrono>
#include <numeric>
#include <algorithm>
#include <iomanip>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <memory>

#include "common/ceph_context.h"
#include "global/global_init.h"
#include "common/ceph_argparse.h"
#include "common/errno.h"
#include "os/bluestore/BlueStore.h"
#include "os/ObjectStore.h"
#include "osd/osd_types.h"

using namespace std;
using namespace std::chrono;

// Helper function to calculate percentiles
double percentile(vector<double>& data, double p) {
    if (data.empty()) return 0.0;

    vector<double> sorted = data;
    sort(sorted.begin(), sorted.end());

    size_t idx = static_cast<size_t>((p / 100.0) * sorted.size());
    if (idx >= sorted.size()) idx = sorted.size() - 1;

    return sorted[idx];
}

// Helper function to format size in human-readable format
string format_size(size_t bytes) {
    if (bytes < 1024) return to_string(bytes) + " B";
    if (bytes < 1024 * 1024) return to_string(bytes / 1024) + " KB";
    return to_string(bytes / (1024 * 1024)) + " MB";
}

int main(int argc, char** argv) {
    map<string,string> defaults = {
        {"bluestore_block_size", "2147483648"},  // 2GB
        {"bluestore_fsck_on_mount", "false"},
        {"bluestore_fsck_on_umount", "false"},
        {"debug_rocksdb", "0/0"},        // Suppress RocksDB output
        {"debug_bluefs", "0/0"},         // Suppress BlueFS output
        {"debug_bdev", "0/0"},           // Suppress block device output
        {"debug_bluestore", "0/0"}       // Suppress BlueStore output
    };

    vector<const char*> args(argv, argv + argc);
    auto cct = global_init(&defaults, args, CEPH_ENTITY_TYPE_OSD,
                           CODE_ENVIRONMENT_UTILITY,
                           CINIT_FLAG_NO_DEFAULT_CONFIG_FILE);
    common_init_finish(g_ceph_context);

    string base_path = "/home/vagrant/bs_cli/bs_test";
    system(("rm -rf " + base_path).c_str());
    system(("mkdir -p " + base_path).c_str());

    // Create BlueStore
    auto store = std::make_unique<BlueStore>(cct.get(), base_path);

    // Create block device (4GB for larger objects)
    string block_path = base_path + "/block";
    int fd = ::open(block_path.c_str(), O_CREAT|O_RDWR|O_TRUNC, 0644);
    ::ftruncate(fd, 4LL*1024*1024*1024);  // 4GB
    ::close(fd);

    // Initialize store
    int r = store->mkfs();
    if (r < 0) {
        cerr << "mkfs failed: " << r << std::endl;
        return 1;
    }

    r = store->mount();
    if (r < 0) {
        cerr << "mount failed: " << r << std::endl;
        return 1;
    }

    // Create collection using spg_t (placement group)
    spg_t pgid(pg_t(0, 0), shard_id_t::NO_SHARD);
    coll_t cid(pgid);
    ObjectStore::CollectionHandle ch = store->create_new_collection(cid);

    {
        ObjectStore::Transaction t;
        t.create_collection(cid, 0);
        r = store->queue_transaction(ch, std::move(t));
        if (r < 0) {
            cerr << "create_collection failed: " << r << std::endl;
            return 1;
        }
    }

    // Benchmark parameters - expanded object sizes
    vector<size_t> object_sizes = {
        4*1024,      // 4 KB
        16*1024,     // 16 KB
        64*1024,     // 64 KB
        256*1024,    // 256 KB
        1024*1024,   // 1 MB
        2*1024*1024, // 2 MB
        4*1024*1024, // 4 MB
        8*1024*1024  // 8 MB
    };
    size_t iterations = 100;

    cout << "\n" << string(90, '=') << "\n";
    cout << "           BlueStore Performance Benchmark\n";
    cout << string(90, '=') << "\n\n";
    cout << "Iterations per size: " << iterations << "\n\n";

    // Table header
    cout << left << setw(12) << "Size"
         << right << setw(12) << "Write (us)"
        //  << setw(12) << "P50"
        //  << setw(12) << "P95"
        //  << setw(12) << "P99"
         << setw(15) << "Write (MB/s)"
         << setw(12) << "Read (us)"
        //  << setw(12) << "P50"
        //  << setw(12) << "P95"
        //  << setw(12) << "P99"
         << setw(15) << "Read (MB/s)" << "\n";
    cout << string(142, '-') << "\n";

    for (auto size : object_sizes) {
        vector<double> write_times, read_times;

        for (size_t i = 0; i < iterations; ++i) {
            ghobject_t oid(hobject_t(
                "obj_" + to_string(size) + "_" + to_string(i),
                "", CEPH_NOSNAP, 0, 0, ""));

            bufferlist write_bl;
            write_bl.append(string(size, 'x'));

            // Write benchmark
            auto start_write = high_resolution_clock::now();
            {
                ObjectStore::Transaction t;
                t.write(cid, oid, 0, size, write_bl);
                r = store->queue_transaction(ch, std::move(t));
            }
            auto end_write = high_resolution_clock::now();

            if (r < 0) {
                cerr << "\nWrite failed for object size " << size
                     << ", iteration " << i << ": " << cpp_strerror(r) << std::endl;
                break;
            }

            write_times.push_back(
                duration<double, std::micro>(end_write - start_write).count());

            // Read benchmark
            auto start_read = high_resolution_clock::now();
            bufferlist read_bl;
            r = store->read(ch, oid, 0, size, read_bl);
            auto end_read = high_resolution_clock::now();

            if (r < 0) {
                cerr << "\nRead failed for object size " << size
                     << ", iteration " << i << ": " << cpp_strerror(r) << std::endl;
                break;
            }

            read_times.push_back(
                duration<double, std::micro>(end_read - start_read).count());
        }

        if (!write_times.empty() && !read_times.empty()) {
            // Calculate statistics
            double avg_write = accumulate(write_times.begin(), write_times.end(), 0.0) / write_times.size();
            double avg_read = accumulate(read_times.begin(), read_times.end(), 0.0) / read_times.size();

            double write_p50 = percentile(write_times, 50);
            double write_p95 = percentile(write_times, 95);
            double write_p99 = percentile(write_times, 99);

            double read_p50 = percentile(read_times, 50);
            double read_p95 = percentile(read_times, 95);
            double read_p99 = percentile(read_times, 99);

            double write_mbps = (size / (1024.0 * 1024.0)) / (avg_write / 1e6);
            double read_mbps = (size / (1024.0 * 1024.0)) / (avg_read / 1e6);

            cout << left << setw(12) << format_size(size)
                 << right << fixed << setprecision(2)
                 << setw(12) << avg_write
                //  << setw(12) << write_p50
                //  << setw(12) << write_p95
                //  << setw(12) << write_p99
                 << setw(15) << write_mbps
                 << setw(12) << avg_read
                //  << setw(12) << read_p50
                //  << setw(12) << read_p95
                //  << setw(12) << read_p99
                 << setw(15) << read_mbps << "\n";
        } else {
            cout << left << setw(12) << format_size(size)
                 << " FAILED - no successful operations\n";
        }
    }

    cout << string(142, '-') << "\n";
    cout << "\nBenchmarks completed successfully.\n\n";

    // Cleanup
    ch.reset();
    store->umount();

    return 0;
}
