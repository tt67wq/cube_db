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
    const char* dbpath = "/tmp/lmdb_fsync_test.db";
    char v100[100]; memset(v100, 'x', 100);
    
    // Per-commit put (each put = separate txn, like cube_db single put with fsync)
    unlink(dbpath);
    unlink("/tmp/lmdb_fsync_test.db.lock");
    MDB_env* env; 
    int rc = mdb_env_create(&env);
    if (rc) { printf("env_create: %d\n", rc); return 1; }
    mdb_env_set_mapsize(env, 1ULL << 30);
    rc = mdb_env_open(env, dbpath, MDB_NOSUBDIR | MDB_WRITEMAP, 0664);
    if (rc) { printf("env_open: %d (%s)\n", rc, mdb_strerror(rc)); return 1; }
    
    MDB_dbi dbi;
    { MDB_txn* txn; rc = mdb_txn_begin(env, nullptr, 0, &txn); if (rc) { printf("begin: %d\n", rc); return 1; }
      rc = mdb_dbi_open(txn, nullptr, 0, &dbi); if (rc) { printf("dbi_open: %d\n", rc); return 1; }
      mdb_txn_commit(txn); }
    
    char kbuf[12];
    int64_t start = monoNs();
    for (size_t i = 0; i < n; i++) {
        snprintf(kbuf, 12, "%010zu", i);
        MDB_txn* txn; rc = mdb_txn_begin(env, nullptr, 0, &txn); if (rc) { printf("begin2: %d\n", rc); break; }
        MDB_val key = {strlen(kbuf), kbuf};
        MDB_val val = {100, v100};
        rc = mdb_put(txn, dbi, &key, &val, 0);
        if (rc) { printf("put: %d\n", rc); mdb_txn_abort(txn); break; }
        rc = mdb_txn_commit(txn);
        if (rc) { printf("commit: %d\n", rc); break; }
    }
    int64_t ns = monoNs() - start;
    printf("LMDB-default (fsync) put-per-commit 100B: %.2fms total, %.2f us/op\n", ns/1e6, (double)ns/1000.0/n);
    mdb_env_close(env);
    unlink(dbpath);
    unlink("/tmp/lmdb_fsync_test.db.lock");
    return 0;
}
