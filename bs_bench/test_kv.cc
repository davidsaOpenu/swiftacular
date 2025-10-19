// benchmark_rocksdb_latency.cc
#include <rocksdb/db.h>
#include <rocksdb/options.h>
#include <chrono>
#include <iostream>
#include <random>
#include <vector>
#include <string>
#include <iomanip>

using namespace std;
using namespace std::chrono;

string random_value(size_t size) {
  static thread_local std::mt19937 gen{std::random_device{}()};
  static thread_local std::uniform_int_distribution<int> dist(0, 255);
  string s(size, '\0');
  for (size_t i = 0; i < size; i++) s[i] = static_cast<char>(dist(gen));
  return s;
}

int main() {
  const string db_path = "./rocksdb_bench";
  const vector<size_t> value_sizes = {8, 16, 32, 64, 128, 512, 1024, 2048};
  const size_t iterations = 20000;

  rocksdb::Options options;
  options.create_if_missing = true;
  options.use_fsync = true;          // ensure data durability
  options.disable_auto_compactions = true;
  options.OptimizeLevelStyleCompaction();

  // Clean existing DB
  rocksdb::DestroyDB(db_path, options);

  rocksdb::DB* db;
  rocksdb::Status status = rocksdb::DB::Open(options, db_path, &db);
  if (!status.ok()) {
    cerr << "Failed to open RocksDB: " << status.ToString() << endl;
    return 1;
  }

  cout << "\n============================\n";
  cout << "  ROCKSDB BENCHMARKS\n";
  cout << "============================\n\n";

  for (auto size : value_sizes) {
    string value = random_value(size);
    double total_set_us = 0.0;
    double total_get_us = 0.0;

    for (size_t i = 0; i < iterations; ++i) {
      string key = "key_" + to_string(i);

      auto t1 = high_resolution_clock::now();
      status = db->Put(rocksdb::WriteOptions(), key, value);
      auto t2 = high_resolution_clock::now();
      total_set_us += duration_cast<microseconds>(t2 - t1).count();

      string out;
      auto t3 = high_resolution_clock::now();
      status = db->Get(rocksdb::ReadOptions(), key, &out);
      auto t4 = high_resolution_clock::now();
      total_get_us += duration_cast<microseconds>(t4 - t3).count();
    }

    cout << fixed << setprecision(3);
    cout << "value_size=" << setw(5) << size << " B  "
         << "avg_put=" << setw(8) << (total_set_us / iterations)
         << " µs  avg_get=" << setw(8) << (total_get_us / iterations)
         << " µs\n";
  }

  delete db;
  return 0;
}
