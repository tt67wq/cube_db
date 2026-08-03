// lmdb_bench_scattered.cpp — LMDB benchmark with SCATTERED keys.
// v2: verify malloc scatter + stability. Print address samples.
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <unistd.h>
#include "lmdb.h"

static int64_t monoNs() {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

int main() {
    char v100[100]; memset(v100, 'x', 100);
    size_t n = 1000000;
    const char* dbpath = "/tmp/lmdb_scattered_test.db";
    unlink(dbpath); unlink("/tmp/lmdb_scattered_test.db.lock");
    
    MDB_env* env; mdb_env_create(&env);
    mdb_env_set_mapsize(env, 1ULL << 30);
    mdb_env_set_maxdbs(env, 8);
    mdb_env_set_maxreaders(env, 126);
    int rc = mdb_env_open(env, dbpath, MDB_NOSUBDIR | MDB_WRITEMAP, 0664);
    if (rc) { printf("env_open: %d (%s)\n", rc, mdb_strerror(rc)); return 1; }
    MDB_txn* txn; rc = mdb_txn_begin(env, nullptr, 0, &txn);
    MDB_dbi dbi; rc = mdb_dbi_open(txn, nullptr, 0, &dbi);
    
    // Scattered keys
    char** keys = (char**)malloc(n * sizeof(char*));
    for (size_t i = 0; i < n; i++) { keys[i] = (char*)malloc(12); snprintf(keys[i], 12, "%010zu", i); }
    
    // Print address scatter samples
    printf("addr samples: first=%p mid=%p last=%p\n", keys[0], keys[n/2], keys[n-1]);
    size_t distinct_pages = 0; uintptr_t last_page = 0;
    for (size_t i = 0; i < n; i += 1000) {
        uintptr_t p = (uintptr_t)keys[i] >> 12;
        if (p != last_page) { distinct_pages++; last_page = p; }
    }
    printf("distinct 4K pages in samples: %zu / %zu\n", distinct_pages, n/1000);
    
    int64_t start = monoNs();
    for (size_t i = 0; i < n; i++) {
        MDB_val key = {10, keys[i]};
        MDB_val val = {100, v100};
        mdb_put(txn, dbi, &key, &val, 0);
    }
    rc = mdb_txn_commit(txn);
    int64_t ns = monoNs() - start;
    printf("LMDB-scattered putBatch %zu keys: %.2fms total, %.2f us/op\n", n, ns/1e6, (double)ns/1000.0/n);
    
    for (size_t i = 0; i < n; i++) free(keys[i]);
    free(keys);
    mdb_env_close(env);
    unlink(dbpath); unlink("/tmp/lmdb_scattered_test.db.lock");
    return 0;
}
