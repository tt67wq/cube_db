# cube_db Usage Manual

cube_db is an embedded key-value store written in Zig 0.16.0. Fixed pages (4KB) + freelist page
reuse + COW B-tree:

- **O(1) compact**: only writes the meta page, no data rewrite
- **~1× write amplification**: old pages go to the freelist and are reused in place
- **O(1) recovery**: reads two meta pages
- **MVCC reader safety**: dirty pages are held until readers drain
- **Overflow pages**: large values automatically go through overflow page chains

Pure synchronous API; no runtime setup required.

---

## Table of contents

1. [Installation & build](#1-installation--build)
2. [Quick start](#2-quick-start)
3. [API](#3-api)
4. [Error handling](#4-error-handling)
5. [Concurrency & MVCC](#5-concurrency--mvcc)
6. [Common recipes](#6-common-recipes)
7. [API quick reference](#7-api-quick-reference)

---

## 1. Installation & build

Dependencies:
- Zig 0.16.0
- A local `../zio` repo (`build.zig.zon` path dependency)

```bash
zig build test          # run all tests
zig build -Doptimize=ReleaseFast   # compile the library
zig build bench -Doptimize=ReleaseFast   # run benchmarks
```

Use as a dependency:

```zig
// build.zig
const cube_dep = b.dependency("cube_db", .{ .target = target, .optimize = optimize });
const cube_mod = cube_dep.module("cube_db");
exe.root_module.addImport("cube_db", cube_mod);
```

Import in code:

```zig
const cube = @import("cube_db");
const Db = cube.Db;
const Entry = cube.Entry;
const Options = cube.Options;
```

---

## 2. Quick start

cube_db uses fixed-size pages (4KB) and freelist page reuse, no full rewrite needed.

### In-memory mode (testing / prototyping)

```zig
const std = @import("std");
const zio = @import("zio");
const cube = @import("cube_db");
const Db = cube.Db;
const MemPageStore = cube.page_store.MemPageStore;

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var ms = MemPageStore.init(allocator, 1 << 20); // 1M pages
    defer ms.deinit();

    var db = try Db.open(allocator, ms.store(), .{});
    defer db.close();

    try db.put("hello", "world");
    const v = try db.get("hello");
    defer allocator.free(v.?);
    std.debug.print("got: {s}\n", .{v.?});
}
```

### File mode (persistent)

```zig
var fps = try cube.file_page_store.FilePageStore.init(allocator, "my.db"); // LMDB-style 1TB reserved mmap
defer fps.deinit();
var db = try Db.open(allocator, fps.store(), .{});
defer db.close();

try db.put("hello", "world");
```

`open` restores state from the meta pages (page 1/2): root, sequence, entry_count, byte_size.
Recovery needs no full-file scan; it is O(1).

**FilePageStore features:**
- **mmap 1TB reserved region**: plenty of virtual address space on 64-bit systems; the file grows
  on demand via `ftruncate`
- **Zero-copy reads**: readers read directly through mmap pointers, no `read()` syscalls
- **Dual alternating meta pages**: meta writes alternate between page 1 and page 2; after a crash
  the one with the larger sequence is recovered
- **fsync on commit**: `commit` is followed by an automatic `fsync` for crash safety

---

## 3. API

### 3.1 Open & close

```zig
// In-memory mode
var ms = MemPageStore.init(allocator, mapsize_pages);
defer ms.deinit();
var db = try Db.open(allocator, ms.store(), .{});
defer db.close();
```

```zig
// File mode (mmap)
var fps = try cube.file_page_store.FilePageStore.init(allocator, "path.db");
defer fps.deinit();
var db = try Db.open(allocator, fps.store(), .{});
defer db.close();
```

### 3.2 Read: get

```zig
const v = try db.get("hello");
if (v) |value| {
    defer allocator.free(value); // ⚠️ return value is allocator-owned; caller must free
    std.debug.print("hello = {s}\n", .{value});
} else {
    std.debug.print("(missing)\n", .{});
}
```

- Returns `!?[]u8`: `null` = key does not exist (or was deleted).
- A non-null value is a freshly allocated copy; you must `free` it.
- `get` is lock-free and fsync-free; it reads an atomic root snapshot.
- **Read-path optimization**: CRC is skipped; get 100B ~2.7µs (near LMDB level).
- **High-frequency reads**: per-call alloc/free has cost; on hot paths (cache/index layers)
  use `getInto` (see 3.2.1).

#### 3.2.1 Zero-copy read: getInto (T-29)

```zig
var buf: [4096]u8 = undefined; // caller-owned buffer, reusable
const n = (try db.getInto("hello", &buf)) orelse return; // null = key does not exist
std.debug.print("hello = {s}\n", .{buf[0..n]});
```

- `getInto(key, buffer) !?usize`: copies the value into `buffer` and returns the number of bytes
  written; `ReadTxn.getInto` is identical (snapshot pinned at the txn root).
- `null` is reserved **exclusively for a missing key** (including tombstones) — this fully decouples
  from the null-ambiguity of the old borrowed API removed in T-23 (copy semantics, no borrow-invalidation
  source).
- A buffer that is too small returns `error.BufferTooSmall` and **the buffer is neither written nor
  cleared** (no partial writes; safe to retry with a larger buffer).
- Exact boundary: a buffer of exactly the right length succeeds; overflow values (>3800B) are copied
  page-by-page through the overflow page chain, byte-identical to `get()`.
- Fully zero-allocation end to end: allocation ownership stays with the caller; hot-path reads avoid
  per-call alloc/free.

> **Migration note**: the zero-copy borrowed read APIs (Db and ReadTxn layers) were removed in T-23 —
> their `null` return was ambiguous (overflow / tombstone / missing were indistinguishable). T-29 solves
> the same problem with `getInto` (copies into a caller buffer + explicit `BufferTooSmall` error): `null`
> semantics are now unambiguous, and allocation ownership belongs to the caller. For reads you can use
> either `get()` or `getInto()`; they are semantically equivalent with different performance profiles.

### 3.3 Write: put / putBatch / delete / flush

```zig
try db.put("hello", "world");   // single entry, 1 commit
try db.delete("hello");         // tombstone
```

Batch writes (recommended):

```zig
const entries = [_]Entry{
    .{ .key = "a", .value = "1" },
    .{ .key = "b", .value = "2" },
    .{ .key = "c", .value = "3" },
};
try db.putBatch(&entries); // whole batch, 1 commit
```

**Micro-batching (automatic batch commit):**

```zig
var db = try Db.open(allocator, store, .{
    .micro_batch = .{ .batch_threshold = 100 },
});
// the first 99 puts are staged; the 100th is flushed automatically
try db.put("k1", "v1");
try db.put("k2", "v2");
// ... the 100th put triggers the batch commit

// force-commit the staged data
try db.flush();

// skip batching; commit immediately
try db.putDirect("urgent", "now");
```

- `batch_threshold = 0` (default): batching disabled; `put`/`delete` commit immediately
- `batch_threshold > 0`: entries are staged in pending and auto-`flush()`ed at the threshold
- `flush()`: force-commits all pending entries
- `putDirect()`/`deleteDirect()`: skip batching, commit immediately
- `close()`: automatically flushes any residual entries

Entry structure:

```zig
pub const Entry = struct {
    key: []const u8,
    value: []const u8,
    tombstone: bool = false, // true means delete this key
};
```

- Same key, last wins: for multiple identical keys within a batch, the last one takes effect.
- key/value are borrowed slices; they must stay valid until `putBatch` returns.

Batch delete:

```zig
const dels = [_]Entry{
    .{ .key = "a", .value = "", .tombstone = true },
    .{ .key = "b", .value = "", .tombstone = true },
};
try db.putBatch(&dels);
```

Range delete (`deleteRange`): batch-deletes keys in the half-open interval `[min, max)`, with boundary
semantics identical to `select` — `null` min/max means unbounded on that side, and `(null, null)` clears
the entire database. It is implemented internally on the `select` iterator + tombstone batch commit;
under micro-batching it flushes staged entries first so pending keys are also within the deleted range.

```zig
// delete [b, d): removes b, c; keeps a, d, e
try db.deleteRange("b", "d");

// null boundaries = unbounded
try db.deleteRange(null, "c");  // delete all keys < c
try db.deleteRange("m", null);  // delete all keys >= m
try db.deleteRange(null, null); // clear the whole database
```

- Half-open interval `[min, max)`: `max` itself is not deleted (same as `select`).
- Reversed/empty interval (`min >= max`, both non-null): successful no-op, no error.
- Idempotent on missing keys: deleting the same range again still succeeds.
- After deletion `entryCount()` decreases accordingly (consistent with single `delete` accounting).

### 3.4 Explicit transactions (LMDB-style)

`put`/`putBatch`/`delete` are convenience APIs (they wrap an implicit WriteTxn committed immediately).
Use explicit transactions for multi-step atomicity or abort:

```zig
// Write txn: single-writer mutex; commit = applyBatch + meta switch + fsync; abort discards without flushing
var w = try db.beginWriteTxn();
defer w.deinit(); // if not committed/aborted, deinit auto-aborts
try w.put("k", "v");
try w.delete("old");
try w.commit(); // atomic commit

// Read txn: MVCC snapshot (holds the root at open time), does not block writers
var r = try db.beginReadTxn();
defer r.end();
const v = try r.get("k");
defer if (v) |val| allocator.free(val);
```

- WriteTxn: single-writer mutex (only one active at a time); after `commit` changes are atomically
  visible; `abort` discards them.
- ReadTxn: snapshot isolation; after a writer commits a new version, readers still see the old snapshot
  until `end`.
- key/value used across `beginWriteTxn`/`commit` must stay valid (borrowed slices).

### 3.5 Range query: select

```zig
var it = try db.select("b", "d"); // [min, max)
defer it.deinit();

while (try it.next()) |entry| {
    std.debug.print("{s} = {s}\n", .{ entry.key, entry.value });
}
```

- The interval is **[min, max)**: min inclusive, max exclusive.
- `null` means unbounded: `db.select(null, null)` iterates everything.
- Tombstones are skipped automatically.
- **Borrow contract (T-29 Phase B)**: `entry.key`/`entry.value` are borrowed slices, valid **only until
  the next `next()` or `deinit()`**. Inline value/key are borrowed directly from the mmap page
  (zero-copy); overflow values (>3800B) are assembled through the iterator's internal reusable buffer —
  when iterating consecutive overflow entries, a previous entry's value is overwritten by the new one
  (the observable face of the borrow contract).
- **Snapshot pin (T-29 Phase B)**: the iterator holds an MVCC reader slot for its lifetime — a writer
  committing mid-iteration (COW) does not affect borrowed pages; the iterator always sees the snapshot
  from `select` time; dirty pages are not reclaimed until `deinit()` (last reader exits). **Forgetting
  `deinit` leaks a reader slot** (dirty pages not reclaimed, `dirt` count not decremented); always
  `defer it.deinit()`. A `ReadTxn.select` iterator holds an independent pin (stackable with the txn's
  pin) and must likewise be deinit'ed.
- Using `btree.select` directly (raw page-store layer) has no pin; the caller must guarantee Store
  stability on its own.
- Scan performance (T-29 Phase B borrowing): descent stack O(depth) (no per-node dup copies), inline
  value scans allocate zero, overflow values lazily allocate one reusable buffer per iterator.

Retaining entry contents:

```zig
var keys = std.ArrayList([]u8).empty;
defer {
    for (keys.items) |k| allocator.free(k);
    keys.deinit(allocator);
}
var it = try db.select(null, null);
defer it.deinit();
while (try it.next()) |e| {
    try keys.append(allocator, try allocator.dupe(u8, e.key));
}
```

### 3.6 Compact

`compact` is **O(1)** — it only writes the meta page, no data rewrite.

```zig
try db.compact(); // immediately reclaims all dirty pages (requires no active reader)
```

- With active readers, dirty pages stay in `pending_free` until the readers finish.
- `compact` automatically flushes all flushable `pending_free`.

### 3.7 Options

```zig
var db = try Db.open(allocator, store, .{
    .fsync = true,   // fsync after every write
});
```

| Field | Type | Default | Meaning |
|---|---|---|---|
| `fsync` | `bool` | `true` | Whether write operations fsync to disk. `false` = faster but data is lost on crash |

`compact` is O(1) (meta page switch, no data rewrite).

---

## 4. Error handling

All read/write operations return `!T` (error union). Common errors:

| Error | Meaning |
|---|---|
| `OutOfMemory` | allocation failed |
| `PageNotFound` | invalid page number (corrupt file) |
| `MapFull` | page space exhausted (insufficient mapsize) |
| `FileLocked` | the file is already locked by another opener (T-34 multi-process guard, see below) |

```zig
db.put("k", "v") catch |err| switch (err) {
    error.PageNotFound => { /* storage corrupt */ },
    else => return err,
};
```

---

## 5. Concurrency & MVCC

- **Multi-threaded reads**: safe. `get`/`select` read an atomic root snapshot, lock-free and fsync-free.
- **MVCC reader**: writers defer reclaiming dirty pages while readers are active:

```zig
const reader = db.beginRead(); // begin read, returns an explicit Reader handle (carrying the snapshot)
const v = try db.get("k");     // read a consistent snapshot
db.endRead(reader);            // end read (pass the handle to unregister), release dirty pages
```

> `beginRead` returns a **Reader handle** (not a sequence number); `endRead` must be given the same handle to pair the unregister.

- **With no active readers**: dirty pages are reclaimed automatically after each commit.
- **Do not share a single iterator across threads**; each thread opens its own `select`.

### Multi-process semantics (T-34)

- **One opener per database file at a time**: `FilePageStore.init` takes an advisory exclusive
  lock (`flock(fd, LOCK_EX | LOCK_NB)`) right after open. A second process (or another fd in the
  same process) opening the same path gets `error.FileLocked`.
- The lock releases when the holder's fd closes: a normal `deinit()`/process exit, or the holder
  crashing/being killed — the kernel closes the fd and the lock evaporates; no stale locks. A fork'd
  child inherits the parent's fd (sharing the same open file description) and never self-conflicts
  with it; if the child opens the same path itself, it is rejected as a second opener.
- **flock semantics are not guaranteed on NFS and other network filesystems** — local filesystems only.

---

## 6. Common recipes

### 6.1 Counter (read-modify-write)

```zig
fn incr(db: *Db, key: []const u8) !void {
    const cur = try db.get(key);
    const n: u64 = if (cur) |c| blk: { defer allocator.free(c); break :blk std.fmt.parseInt(u64, c, 10) catch 0; } else 0;
    var buf: [20]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, "{d}", .{n + 1});
    try db.put(key, s);
}
```

> Note: a single-key read-modify-write is **not atomic** (there is a window between `get` and `put`).

### 6.2 Batch import

```zig
fn import(db: *Db, items: []const struct { k: []const u8, v: []const u8 }) !void {
    var entries = try allocator.alloc(Entry, items.len);
    defer allocator.free(entries);
    for (items, 0..) |it, i| entries[i] = .{ .key = it.k, .value = it.v };
    try db.putBatch(entries);
}
```

### 6.3 Full traversal

```zig
var it = try db.select(null, null);
defer it.deinit();
var count: usize = 0;
while (try it.next()) |_| count += 1;
std.debug.print("total entries: {d}\n", .{count});
```

### 6.4 Delete a batch of keys

```zig
fn deleteKeys(db: *Db, keys: []const []const u8) !void {
    var entries = try allocator.alloc(Entry, keys.len);
    defer allocator.free(entries);
    for (keys, 0..) |k, i| entries[i] = .{ .key = k, .value = "", .tombstone = true };
    try db.putBatch(entries);
}
```

---

## 7. API quick reference

```zig
const cube = @import("cube_db");
const Db = cube.Db;
const Entry = cube.Entry;
const Options = cube.Options;

// Open
var ms = cube.page_store.MemPageStore.init(allocator, 1 << 20);
defer ms.deinit();
var db = try Db.open(allocator, ms.store(), .{});
defer db.close();

// Read
const v = try db.get(key);            // !?[]u8, caller frees
const n = (try db.getInto(key, &buf)) orelse 0; // !?usize zero-copy into buf; null = key missing

// Write
try db.put(key, value);               // single entry
try db.putBatch(&entries);            // batch (recommended)
try db.delete(key);                   // tombstone

// Range [min, max)
var it = try db.select(min, max);     // min/max can be null
defer it.deinit();
while (try it.next()) |e| { /* e.key, e.value borrowed, invalid after next(); it pins snapshot, don't forget deinit */ }

// Compact
try db.compact();                     // O(1) meta switch

// MVCC reader (explicit handle pairing)
const reader = db.beginRead();
db.endRead(reader);

// Explicit transactions (LMDB-style)
var w = try db.beginWriteTxn();          // single-writer mutex
defer w.deinit();                       // auto-aborts if not committed/aborted
try w.put(key, value);                  // stage
try w.commit();                         // applyBatch + meta switch + fsync
// w.abort();                          // discard

var r = try db.beginReadTxn();          // MVCC snapshot, does not block writers
defer r.end();
const rv = try r.get(key);              // borrowed snapshot
// try r.select(min, max);

try db.sync();                          // explicit flush in async mode
```

### Types

| Type | Definition |
|---|---|
| `Db` | database handle, entry point for all operations |
| `Entry` | `struct { key: []const u8, value: []const u8, tombstone: bool = false }` |
| `Options` | `struct { fsync: bool = true }` (`fsync=false` enables async mode) |
| `WriteTxn` | `db.beginWriteTxn()`, single-writer mutex, `commit`/`abort`/`deinit` |
| `ReadTxn` | `db.beginReadTxn()`, MVCC snapshot, `get`/`select`/`end`/`deinit` |
| `Iterator` | returned by `select`, has `.next() !?LeafEntry` and `.deinit()` |

### Ownership rules at a glance

- `[]u8` returned by `get`: **caller frees**.
- key/value for `put`/`putBatch`/`delete`: **borrowed**, valid until the call returns.
- min/max for `select`: **borrowed**, valid for the lifetime of the iterator.
- iterator `entry.key`/`entry.value`: **borrowed from the iterator**, valid until the next `next()`.
- `db`: allocated by `open`, freed by `close`.
