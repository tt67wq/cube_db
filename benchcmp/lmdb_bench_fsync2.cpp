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
    const size_t n = 10000;
    const char* dbpath = "/tmp/lmdb_fsync2.db";
    char v100[100]; memset(v100, 'x', 100);
    
    // putBatch: single txn with 10K entries, default fsync
    unlink(dbpath);
    unlink("/tmp/lmdb_fsync2.db.lock");
    MDB_env* env;
    mdb_env_create(&env);
    mdb_env_set_mapsize(env, 1ULL << 30);
    mdb_env_set_maxdbs(env, 8);
    mdb_env_set_maxreaders(env, 126);
    int rc = mdb_env_open(env, dbpath, MDB_NOSUBDIR | MDB_WRITEMAP, 0664);
    if (rc) { printf("env_open: %d (%s)\n", rc, mdb_strerror(rc)); return 1; }
    
    MDB_txn* txn;
    rc = mdb_txn_begin(env, nullptr, 0, &txn);
    if (rc) { printf("begin: %d\n", rc); return 1; }
    MDB_dbi dbi;
    rc = mdb_dbi_open(txn, nullptr, 0, &dbi);
    if (rc) { printf("dbi_open: %d (%s)\n", rc, mdb_strerror(rc)); mdb_txn_abort(txn); return 1; }
    
    char kbuf[12];
    int64_t start = monoNs();
    for (size_t i = 0; i < n; i++) {
        snprintf(kbuf, 12, "%010zu", i);
        MDB_val key = {strlen(kbuf), kbuf};
        MDB_val val = {100, v100};
        rc = mdb_put(txn, dbi, &key, &val, 0);
        if (rc) { printf("put: %d (%s)\n", rc, mdb_strerror(rc)); mdb_txn_abort(txn); break; }
    }
    rc = mdb_txn_commit(txn);
    if (rc) printf("commit: %d\n", rc);
    int64_t ns = monoNs() - start;
    printf("LMDB-default (fsync) putBatch 100B (single txn 10K): %.2fms total, %.2f us/op\n", ns/1e6, (double)ns/1000.0/n);
    mdb_env_close(env);
    unlink(dbpath);
    unlink("/tmp/lmdb_fsync2.db.lock");
    return 0;
}
