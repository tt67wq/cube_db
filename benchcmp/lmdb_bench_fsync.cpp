// LMDB benchmark with DEFAULT fsync (no MDB_NOSYNC)
// Same workload as lmdb_bench.cpp but without MDB_NOSYNC flag
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

int main() {
    const size_t n = 10000;
    const char* dbpath = "/tmp/lmdb_bench_fsync.db";
    char v100[100]; memset(v100, 'x', 100);
    
    // put
    {
        unlink(dbpath);
        MDB_env* env; mdb_env_create(&env);
        mdb_env_set_mapsize(env, 1ULL << 30);
        // DEFAULT flags = fsync on every commit (LMDB default)
        mdb_env_open(env, dbpath, MDB_WRITEMAP, 0664);
        MDB_txn* txn; mdb_txn_begin(env, nullptr, 0, &txn);
        MDB_dbi dbi; mdb_dbi_open(txn, nullptr, 0, &dbi);
        char kbuf[12];
        int64_t start = monoNs();
        for (size_t i = 0; i < n; i++) {
            fmtKey(kbuf, i);
            MDB_val key = {strlen(kbuf), kbuf};
            MDB_val val = {100, v100};
            mdb_put(txn, dbi, &key, &val, 0);
        }
        mdb_txn_commit(txn);
        int64_t ns = monoNs() - start;
        double avg_us = (double)ns / 1000.0 / n;
        printf("LMDB-default put 100B (single txn): total=%.2fms avg=%.2fus/op\n", ns/1e6, avg_us);
        mdb_env_close(env);
    }
    
    // putBatch (same as above — LMDB single txn = batch)
    {
        unlink(dbpath);
        MDB_env* env; mdb_env_create(&env);
        mdb_env_set_mapsize(env, 1ULL << 30);
        mdb_env_open(env, dbpath, MDB_WRITEMAP, 0664);
        MDB_txn* txn; mdb_txn_begin(env, nullptr, 0, &txn);
        MDB_dbi dbi; mdb_dbi_open(txn, nullptr, 0, &dbi);
        char kbuf[12];
        int64_t start = monoNs();
        for (size_t i = 0; i < n; i++) {
            fmtKey(kbuf, i);
            MDB_val key = {strlen(kbuf), kbuf};
            MDB_val val = {100, v100};
            mdb_put(txn, dbi, &key, &val, 0);
        }
        mdb_txn_commit(txn);
        int64_t ns = monoNs() - start;
        double avg_us = (double)ns / 1000.0 / n;
        printf("LMDB-default putBatch 100B (single txn): total=%.2fms avg=%.2fus/op\n", ns/1e6, avg_us);
        mdb_env_close(env);
    }
    
    // Per-commit put (each put = separate txn, like cube_db single put)
    {
        unlink(dbpath);
        MDB_env* env; mdb_env_create(&env);
        mdb_env_set_mapsize(env, 1ULL << 30);
        mdb_env_open(env, dbpath, MDB_WRITEMAP, 0664);
        MDB_dbi dbi;
        { MDB_txn* txn; mdb_txn_begin(env, nullptr, 0, &txn); mdb_dbi_open(txn, nullptr, 0, &dbi); mdb_txn_commit(txn); }
        char kbuf[12];
        int64_t start = monoNs();
        for (size_t i = 0; i < n; i++) {
            fmtKey(kbuf, i);
            MDB_txn* txn; mdb_txn_begin(env, nullptr, 0, &txn);
            MDB_val key = {strlen(kbuf), kbuf};
            MDB_val val = {100, v100};
            mdb_put(txn, dbi, &key, &val, 0);
            mdb_txn_commit(txn);
        }
        int64_t ns = monoNs() - start;
        double avg_us = (double)ns / 1000.0 / n;
        printf("LMDB-default put-per-commit 100B: total=%.2fms avg=%.2fus/op\n", ns/1e6, avg_us);
        mdb_env_close(env);
    }
    
    unlink(dbpath);
    return 0;
}
