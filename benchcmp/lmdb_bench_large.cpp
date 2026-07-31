#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <unistd.h>
#include <sys/stat.h>
#include "lmdb.h"

static int64_t monoNs() {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

int main() {
    char v100[100]; memset(v100, 'x', 100);
    
    size_t sizes[] = {10000, 100000, 1000000};
    
    for (int s = 0; s < 3; s++) {
        size_t n = sizes[s];
        const char* dbpath = "/tmp/lmdb_large_test.db";
        unlink(dbpath);
        unlink("/tmp/lmdb_large_test.db.lock");
        
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
        if (rc) { printf("dbi: %d\n", rc); return 1; }
        
        char kbuf[12];
        int64_t start = monoNs();
        for (size_t i = 0; i < n; i++) {
            snprintf(kbuf, 12, "%010zu", i);
            MDB_val key = {strlen(kbuf), kbuf};
            MDB_val val = {100, v100};
            mdb_put(txn, dbi, &key, &val, 0);
        }
        rc = mdb_txn_commit(txn);
        if (rc) { printf("commit: %d\n", rc); }
        int64_t ns = monoNs() - start;
        
        struct stat st;
        stat(dbpath, &st);
        
        printf("LMDB-default putBatch %7zu keys: %.2fms total, %.2f us/op, filesize=%ld bytes (%.1fMB)\n",
               n, ns/1e6, (double)ns/1000.0/n, (long)st.st_size, (double)st.st_size/1e6);
        
        // Get test
        MDB_txn* rtxn;
        mdb_txn_begin(env, nullptr, MDB_RDONLY, &rtxn);
        unsigned int nkeys;
        
        
        // Cold get
        int64_t cstart = monoNs();
        for (int i = 0; i < 100; i++) {
            size_t idx = (size_t)rand() % n;
            snprintf(kbuf, 12, "%010zu", idx);
            MDB_val key = {strlen(kbuf), kbuf};
            MDB_val val;
            mdb_get(rtxn, dbi, &key, &val);
        }
        int64_t cns = monoNs() - cstart;
        
        // Warm get
        int wn = n < 10000 ? n : 10000;
        int64_t wstart = monoNs();
        for (int i = 0; i < wn; i++) {
            size_t idx = (size_t)rand() % n;
            snprintf(kbuf, 12, "%010zu", idx);
            MDB_val key = {strlen(kbuf), kbuf};
            MDB_val val;
            mdb_get(rtxn, dbi, &key, &val);
        }
        int64_t wns = monoNs() - wstart;
        printf("LMDB-default get %7zu keys: cold-100=%.2fus, warm-%d=%.2f us/op\n\n",
               n, (double)cns/1000.0, wn, (double)wns/1000.0/wn);
        
        mdb_txn_abort(rtxn);
        mdb_env_close(env);
        unlink(dbpath);
        unlink("/tmp/lmdb_large_test.db.lock");
    }
    return 0;
}
