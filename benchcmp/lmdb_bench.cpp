// lmdb_bench.cpp — LMDB benchmark aligned with cube_db workload.
// 10k keys, 100B & 10KB values, sequential put, random get, sequential delete.
// MDB_NOSYNC + MDB_WRITEMAP = no fsync, same as cube_db MemPageStore (no fsync).
// build:
//   clang++ -O3 -std=c++17 lmdb_bench.cpp -I/opt/homebrew/opt/lmdb/include \
//     /opt/homebrew/opt/lmdb/lib/liblmdb.a -lpthread -o lmdb_bench
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <string>
#include <vector>
#include <random>
#include <unistd.h>
#include "lmdb.h"

static int64_t monoNs() {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

static void fmtKey(char buf[12], size_t i) {
    snprintf(buf, 12, "%010zu", i);
}

static void printRow(const char* engine, const char* op, const char* vname, size_t ops, int64_t ns) {
    double ms = ns / 1000000.0;
    double sec = ns / 1000000000.0;
    double ops_s = (double)ops / sec;
    double avg_us = (ns / 1000.0) / ops;
    printf("%-8s %-5s %-5s %12zu %12.1f %12.0f %12.2f\n",
        engine, op, vname, ops, ms, ops_s, avg_us);
    fflush(stdout);
}

// Seed for random get (same as cube_db bench: 0x42)
static std::mt19937 rng(0x42);

static void benchLMDB_put(const char* op, size_t n, const char* value, size_t vlen, bool batch) {
    MDB_env* env;
    MDB_txn* txn;
    MDB_dbi dbi;

    // Create env in a temp directory
    char dbpath[] = "/tmp/lmdb_bench_XXXXXX";
    mkdtemp(dbpath);

    mdb_env_create(&env);
    // 1TB map size (like cube_db's 1TB reserved mmap)
    mdb_env_set_mapsize(env, (size_t)1 << 40);
    // MDB_NOSYNC = no fsync, MDB_WRITEMAP = writemap mode
    unsigned int flags = MDB_NOSYNC | MDB_WRITEMAP;
    mdb_env_open(env, dbpath, flags, 0664);

    mdb_txn_begin(env, nullptr, 0, &txn);
    mdb_dbi_open(txn, nullptr, MDB_CREATE, &dbi);
    mdb_txn_commit(txn);

    char kbuf[12];

    int64_t start = monoNs();

    if (batch) {
        // Single transaction for all puts (equivalent to putBatch)
        mdb_txn_begin(env, nullptr, 0, &txn);
        for (size_t i = 0; i < n; i++) {
            fmtKey(kbuf, i);
            MDB_val key = { 10, kbuf };
            MDB_val val = { vlen, (void*)value };
            mdb_put(txn, dbi, &key, &val, 0);
        }
        mdb_txn_commit(txn);
    } else {
        // One transaction per put (equivalent to cube_db single put)
        for (size_t i = 0; i < n; i++) {
            fmtKey(kbuf, i);
            MDB_val key = { 10, kbuf };
            MDB_val val = { vlen, (void*)value };
            mdb_txn_begin(env, nullptr, 0, &txn);
            mdb_put(txn, dbi, &key, &val, 0);
            mdb_txn_commit(txn);
        }
    }

    int64_t elapsed = monoNs() - start;
    printRow("LMDB", op, vlen == 100 ? "100B" : "10KB", n, elapsed);

    // Cleanup
    mdb_dbi_close(env, dbi);
    mdb_env_close(env);
    // Remove temp dir
    rmdir(dbpath);
}

static void benchLMDB_get(size_t n, const char* value, size_t vlen) {
    MDB_env* env;
    MDB_txn* txn;
    MDB_dbi dbi;

    char dbpath[] = "/tmp/lmdb_bench_XXXXXX";
    mkdtemp(dbpath);

    mdb_env_create(&env);
    mdb_env_set_mapsize(env, (size_t)1 << 40);
    mdb_env_open(env, dbpath, MDB_NOSYNC | MDB_WRITEMAP, 0664);

    mdb_txn_begin(env, nullptr, 0, &txn);
    mdb_dbi_open(txn, nullptr, MDB_CREATE, &dbi);

    // Insert data first
    char kbuf[12];
    for (size_t i = 0; i < n; i++) {
        fmtKey(kbuf, i);
        MDB_val key = { 10, kbuf };
        MDB_val val = { vlen, (void*)value };
        mdb_put(txn, dbi, &key, &val, 0);
    }
    mdb_txn_commit(txn);

    // Random get (read-only transaction)
    mdb_txn_begin(env, nullptr, MDB_RDONLY, &txn);

    std::uniform_int_distribution<size_t> dist(0, n - 1);

    int64_t start = monoNs();
    for (size_t i = 0; i < n; i++) {
        size_t idx = dist(rng);
        fmtKey(kbuf, idx);
        MDB_val key = { 10, kbuf };
        MDB_val val;
        int rc = mdb_get(txn, dbi, &key, &val);
        (void)rc;
    }
    int64_t elapsed = monoNs() - start;
    printRow("LMDB", "get", vlen == 100 ? "100B" : "10KB", n, elapsed);

    mdb_txn_abort(txn);
    mdb_dbi_close(env, dbi);
    mdb_env_close(env);
    rmdir(dbpath);
}

static void benchLMDB_delete(size_t n, const char* value, size_t vlen) {
    MDB_env* env;
    MDB_txn* txn;
    MDB_dbi dbi;

    char dbpath[] = "/tmp/lmdb_bench_XXXXXX";
    mkdtemp(dbpath);

    mdb_env_create(&env);
    mdb_env_set_mapsize(env, (size_t)1 << 40);
    mdb_env_open(env, dbpath, MDB_NOSYNC | MDB_WRITEMAP, 0664);

    mdb_txn_begin(env, nullptr, 0, &txn);
    mdb_dbi_open(txn, nullptr, MDB_CREATE, &dbi);

    // Insert data first
    char kbuf[12];
    for (size_t i = 0; i < n; i++) {
        fmtKey(kbuf, i);
        MDB_val key = { 10, kbuf };
        MDB_val val = { vlen, (void*)value };
        mdb_put(txn, dbi, &key, &val, 0);
    }
    mdb_txn_commit(txn);

    // Delete sequentially (one txn per delete, equivalent to cube_db delete)
    int64_t start = monoNs();
    for (size_t i = 0; i < n; i++) {
        fmtKey(kbuf, i);
        MDB_val key = { 10, kbuf };
        mdb_txn_begin(env, nullptr, 0, &txn);
        mdb_del(txn, dbi, &key, nullptr);
        mdb_txn_commit(txn);
    }
    int64_t elapsed = monoNs() - start;
    printRow("LMDB", "delete", vlen == 100 ? "100B" : "10KB", n, elapsed);

    mdb_dbi_close(env, dbi);
    mdb_env_close(env);
    rmdir(dbpath);
}

int main() {
    const size_t N = 10000;

    // Prepare values
    std::vector<char> val100(100, 'x');
    std::vector<char> val10k(10240, 'x');

    printf("%-8s %-5s %-5s %12s %12s %12s %12s\n",
        "engine", "op", "value", "ops", "time_ms", "ops/s", "avg_us/op");
    printf("----------------------------------------------------------------------\n");

    // put (single)
    benchLMDB_put("put", N, val100.data(), 100, false);
    benchLMDB_put("put", N, val10k.data(), 10240, false);

    // putBatch (single transaction)
    benchLMDB_put("putbatch", N, val100.data(), 100, true);
    benchLMDB_put("putbatch", N, val10k.data(), 10240, true);

    // get (random)
    benchLMDB_get(N, val100.data(), 100);
    benchLMDB_get(N, val10k.data(), 10240);

    // delete (sequential)
    benchLMDB_delete(N, val100.data(), 100);
    benchLMDB_delete(N, val10k.data(), 10240);

    return 0;
}
