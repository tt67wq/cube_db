// benchcmp.cpp — compare SQLite (:memory:) vs RocksDB (no fsync) on cube_db's workload.
// Workload matches bench/bench.zig small scale: 10000 keys, 100B & 10KB values,
// sequential put, random get. No fsync (pure page-cache throughput).
// build:
//   clang++ -O3 -std=c++17 benchcmp.cpp -I/opt/homebrew/opt/rocksdb/include \
//     /opt/homebrew/opt/rocksdb/lib/librocksdb.a /opt/homebrew/opt/sqlite/lib/libsqlite3.a \
//     -lpthread -ldl -lz -lbz2 -lzstd -lsnappy -o benchcmp
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <string>
#include <vector>
#include <random>
#include <unistd.h>

static int64_t monoNs() {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

static void fmtKey(char buf[12], size_t i) {
    snprintf(buf, 12, "%010zu", i);
}

struct Cell { const char* engine; const char* op; const char* vname; size_t vlen; };

static void printRow(const Cell& c, size_t ops, int64_t ns) {
    double ms = ns / 1000000.0;
    double sec = ns / 1000000000.0;
    double ops_s = (double)ops / sec;
    double avg_us = (ns / 1000.0) / ops;
    printf("%-8s %-5s %-5s %12zu %12.1f %12.0f %12.2f\n",
        c.engine, c.op, c.vname, ops, ms, ops_s, avg_us);
    fflush(stdout);
}

// ---------------- SQLite ----------------
#include "sqlite3.h"

static void benchSQLite(const char* op, size_t n, const char* value, size_t vlen) {
    sqlite3* db;
    if (sqlite3_open(":memory:", &db) != SQLITE_OK) { fprintf(stderr, "sqlite open fail\n"); return; }
    sqlite3_exec(db, "PRAGMA journal_mode=OFF; PRAGMA synchronous=OFF; PRAGMA temp_store=MEMORY;", nullptr, nullptr, nullptr);
    sqlite3_exec(db, "CREATE TABLE kv(k TEXT PRIMARY KEY, v BLOB);", nullptr, nullptr, nullptr);
    sqlite3_stmt* ins; sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO kv(k,v) VALUES(?,?)", -1, &ins, nullptr);
    sqlite3_stmt* sel; sqlite3_prepare_v2(db, "SELECT v FROM kv WHERE k=?", -1, &sel, nullptr);
    char kbuf[12];
    // warmup 1%
    size_t wu = n / 100; if (wu > 1000) wu = 1000;
    sqlite3_exec(db, "BEGIN", nullptr, nullptr, nullptr);
    for (size_t i = 0; i < wu; i++) {
        fmtKey(kbuf, i); sqlite3_bind_text(ins, 1, kbuf, 10, SQLITE_STATIC);
        sqlite3_bind_blob(ins, 2, value, (int)vlen, SQLITE_STATIC); sqlite3_step(ins); sqlite3_reset(ins);
    }
    sqlite3_exec(db, "COMMIT", nullptr, nullptr, nullptr);

    if (strcmp(op, "put") == 0) {
        sqlite3_exec(db, "BEGIN", nullptr, nullptr, nullptr);
        int64_t t = monoNs();
        for (size_t i = 0; i < n; i++) {
            fmtKey(kbuf, i); sqlite3_bind_text(ins, 1, kbuf, 10, SQLITE_STATIC);
            sqlite3_bind_blob(ins, 2, value, (int)vlen, SQLITE_STATIC); sqlite3_step(ins); sqlite3_reset(ins);
        }
        sqlite3_exec(db, "COMMIT", nullptr, nullptr, nullptr);
        printRow({"sqlite","put(batch)", vlen==100?"100B":"10KB", vlen}, n, monoNs() - t);
    } else if (strcmp(op, "put1") == 0) {
        // single-op commit per put — matches cube_db single put
        int64_t t = monoNs();
        for (size_t i = 0; i < n; i++) {
            sqlite3_exec(db, "BEGIN", nullptr, nullptr, nullptr);
            fmtKey(kbuf, i); sqlite3_bind_text(ins, 1, kbuf, 10, SQLITE_STATIC);
            sqlite3_bind_blob(ins, 2, value, (int)vlen, SQLITE_STATIC); sqlite3_step(ins); sqlite3_reset(ins);
            sqlite3_exec(db, "COMMIT", nullptr, nullptr, nullptr);
        }
        printRow({"sqlite","put1", vlen==100?"100B":"10KB", vlen}, n, monoNs() - t);
    } else if (strcmp(op, "get") == 0) {
        // preload all
        sqlite3_exec(db, "BEGIN", nullptr, nullptr, nullptr);
        for (size_t i = 0; i < n; i++) {
            fmtKey(kbuf, i); sqlite3_bind_text(ins, 1, kbuf, 10, SQLITE_STATIC);
            sqlite3_bind_blob(ins, 2, value, (int)vlen, SQLITE_STATIC); sqlite3_step(ins); sqlite3_reset(ins);
        }
        sqlite3_exec(db, "COMMIT", nullptr, nullptr, nullptr);
        std::mt19937 rng(0x42);
        for (size_t i = 0; i < wu; i++) {
            size_t idx = rng() % n; fmtKey(kbuf, idx); sqlite3_bind_text(sel, 1, kbuf, 10, SQLITE_STATIC);
            sqlite3_step(sel); sqlite3_reset(sel);
        }
        int64_t t = monoNs();
        for (size_t i = 0; i < n; i++) {
            size_t idx = rng() % n; fmtKey(kbuf, idx); sqlite3_bind_text(sel, 1, kbuf, 10, SQLITE_STATIC);
            sqlite3_step(sel); sqlite3_reset(sel);
        }
        printRow({"sqlite","get", vlen==100?"100B":"10KB", vlen}, n, monoNs() - t);
    }
    sqlite3_finalize(ins); sqlite3_finalize(sel); sqlite3_close(db);
}

// ---------------- RocksDB ----------------
#include "rocksdb/c.h"

static void benchRocksDB(const char* op, size_t n, const char* value, size_t vlen) {
    char* err = nullptr;
    rocksdb_options_t* opts = rocksdb_options_create();
    rocksdb_options_set_create_if_missing(opts, 1);
    rocksdb_options_set_compression(opts, 0);  // no compression, fair
    rocksdb_options_set_write_buffer_size(opts, 64 * 1024 * 1024);
    rocksdb_options_set_max_write_buffer_number(opts, 4);
    rocksdb_options_increase_parallelism(opts, 2);
    // disable flush-to-disk: keep data in OS page cache (no fsync path)
    // fsync avoided via writeoptions_set_sync(0) below.
    // db path inside project dir (sandbox blocks /tmp)
    char dbpath[256];
    snprintf(dbpath, sizeof(dbpath), ".rocksdb_bench_%d", (int)getpid());
    rocksdb_writeoptions_t* wopts = rocksdb_writeoptions_create();
    rocksdb_writeoptions_set_sync(wopts, 0);
    rocksdb_readoptions_t* ropts = rocksdb_readoptions_create();

    rocksdb_t* db = rocksdb_open(opts, dbpath, &err);
    if (err) { fprintf(stderr, "rocksdb open: %s\n", err); free(err); return; }
    char kbuf[12];
    size_t wu = n / 100; if (wu > 1000) wu = 1000;
    rocksdb_writebatch_t* wb = rocksdb_writebatch_create();
    for (size_t i = 0; i < wu; i++) {
        fmtKey(kbuf, i); rocksdb_writebatch_put(wb, kbuf, 10, value, vlen);
    }
    rocksdb_write(db, wopts, wb, &err); rocksdb_writebatch_clear(wb);

    if (strcmp(op, "put") == 0) {
        // batched put (fair vs cube putBatch) — single batch
        for (size_t i = 0; i < n; i++) {
            fmtKey(kbuf, i); rocksdb_writebatch_put(wb, kbuf, 10, value, vlen);
        }
        int64_t t = monoNs();
        rocksdb_write(db, wopts, wb, &err);
        printRow({"rocks","put(batch)", vlen==100?"100B":"10KB", vlen}, n, monoNs() - t);
        rocksdb_writebatch_clear(wb);
    } else if (strcmp(op, "put1") == 0) {
        // single-op write per put — matches cube_db single put
        int64_t t = monoNs();
        for (size_t i = 0; i < n; i++) {
            fmtKey(kbuf, i); rocksdb_put(db, wopts, kbuf, 10, value, vlen, &err);
        }
        printRow({"rocks","put1", vlen==100?"100B":"10KB", vlen}, n, monoNs() - t);
    } else if (strcmp(op, "get") == 0) {
        // preload all via batch
        for (size_t i = 0; i < n; i++) {
            fmtKey(kbuf, i); rocksdb_writebatch_put(wb, kbuf, 10, value, vlen);
        }
        rocksdb_write(db, wopts, wb, &err); rocksdb_writebatch_clear(wb);
        std::mt19937 rng(0x42);
        size_t vlen_out; char* val;
        for (size_t i = 0; i < wu; i++) {
            size_t idx = rng() % n; fmtKey(kbuf, idx);
            val = rocksdb_get(db, ropts, kbuf, 10, &vlen_out, &err);
            if (val) free(val);
        }
        int64_t t = monoNs();
        for (size_t i = 0; i < n; i++) {
            size_t idx = rng() % n; fmtKey(kbuf, idx);
            val = rocksdb_get(db, ropts, kbuf, 10, &vlen_out, &err);
            if (val) free(val);
        }
        printRow({"rocks","get", vlen==100?"100B":"10KB", vlen}, n, monoNs() - t);
    }
    rocksdb_writebatch_destroy(wb);
    rocksdb_close(db);
    rocksdb_options_destroy(opts); rocksdb_writeoptions_destroy(wopts); rocksdb_readoptions_destroy(ropts);
    // cleanup dir
    char rmcmd[256]; snprintf(rmcmd, sizeof(rmcmd), "rm -rf %s", dbpath); system(rmcmd);
}

int main() {
    char v100[100]; char v10k[10000];
    memset(v100, 'x', 100); memset(v10k, 'x', 10000);
    size_t n = 10000;
    printf("engine  op    value  %12s %12s %12s %12s\n","ops","time_ms","ops/s","avg_us/op");
    printf("------- ----- ----- %12s %12s %12s %12s\n","----","------","----","--------");
    // SQLite
    benchSQLite("put", n, v100, 100);
    benchSQLite("put", n, v10k, 10000);
    benchSQLite("put1", n, v100, 100);
    benchSQLite("put1", n, v10k, 10000);
    benchSQLite("get", n, v100, 100);
    benchSQLite("get", n, v10k, 10000);
    // RocksDB
    benchRocksDB("put", n, v100, 100);
    benchRocksDB("put", n, v10k, 10000);
    benchRocksDB("put1", n, v100, 100);
    benchRocksDB("put1", n, v10k, 10000);
    benchRocksDB("get", n, v100, 100);
    benchRocksDB("get", n, v10k, 10000);
    return 0;
}
