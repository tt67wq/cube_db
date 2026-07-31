#include <cstdio>
#include <cstdint>
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
    const char* dbpath = "/tmp/lmdb_warm10k.db";
    
    // Pre-warm: create file and insert+commit once (triggers map growth)
    unlink(dbpath);
    unlink("/tmp/lmdb_warm10k.db.lock");
    {
        MDB_env* env; mdb_env_create(&env);
        mdb_env_set_mapsize(env, 1ULL << 30);
        mdb_env_set_maxdbs(env, 8);
        mdb_env_set_maxreaders(env, 126);
        mdb_env_open(env, dbpath, MDB_NOSUBDIR | MDB_WRITEMAP, 0664);
        MDB_txn* txn; mdb_txn_begin(env, nullptr, 0, &txn);
        MDB_dbi dbi; mdb_dbi_open(txn, nullptr, 0, &dbi);
        char kbuf[12];
        for (int i = 0; i < 100; i++) {
            snprintf(kbuf, 12, "%010d", i);
            MDB_val key = {strlen(kbuf), kbuf};
            MDB_val val = {100, v100};
            mdb_put(txn, dbi, &key, &val, 0);
        }
        mdb_txn_commit(txn);
        mdb_env_close(env);
    }
    
    // Now warm run: reopen and putBatch 10K
    {
        MDB_env* env; mdb_env_create(&env);
        mdb_env_set_mapsize(env, 1ULL << 30);
        mdb_env_set_maxdbs(env, 8);
        mdb_env_set_maxreaders(env, 126);
        mdb_env_open(env, dbpath, MDB_NOSUBDIR | MDB_WRITEMAP, 0664);
        MDB_txn* txn; mdb_txn_begin(env, nullptr, 0, &txn);
        MDB_dbi dbi; mdb_dbi_open(txn, nullptr, 0, &dbi);
        
        char kbuf[12];
        // Delete pre-warm keys first
        for (int i = 0; i < 100; i++) {
            snprintf(kbuf, 12, "%010d", i);
            MDB_val key = {strlen(kbuf), kbuf};
            mdb_del(txn, dbi, &key, nullptr);
        }
        
        int64_t start = monoNs();
        for (int i = 0; i < 10000; i++) {
            snprintf(kbuf, 12, "%010d", i);
            MDB_val key = {strlen(kbuf), kbuf};
            MDB_val val = {100, v100};
            mdb_put(txn, dbi, &key, &val, 0);
        }
        mdb_txn_commit(txn);
        int64_t ns = monoNs() - start;
        printf("LMDB-default (warm) putBatch 10K: %.2fms total, %.2f us/op\n", ns/1e6, (double)ns/1000.0/10000);
        mdb_env_close(env);
    }
    
    unlink(dbpath);
    unlink("/tmp/lmdb_warm10k.db.lock");
    return 0;
}
