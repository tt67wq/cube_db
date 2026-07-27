# 06 — LSM 层：Memtable、WAL、Compactor

前五章讲的都是 B-tree/COW 持久化路径。在此基础上，cube_db 还有一条 **LSM 写路径**：写操作先进入内存缓冲区（memtable）和预写日志（WAL），后台 compactor 线程异步刷入 B-tree。

## 整体架构

```
put → Memtable (O(1) HashMap) ─→ WAL (追加持久化)
                                  ↓ crash? → replay 恢复
                                  ↓ ready? → Compactor 后台线程
                                              ↓ RwLock 独占 B-tree
                                              ↓ applyBatch → B-tree
                                              ↓ WAL truncate + Memtable clear
```

## 数据流

```
Db.put(key, value):
  1. 有 memtable？ → 写 WAL append → 写 memtable put
     → memtable 满了？ → signal compactor
  2. 无 memtable？ → 直接走 COW 路径 (applyBatch)

Db.get(key):
  1. 有 memtable？ → 查 memtable（有值直接返回）
  2. 无匹配？ → 查 B-tree

Db.delete(key):
  1. 有 memtable？ → 写 WAL → 写 memtable delete（tombstone）
  2. 无 memtable？ → 直接走 COW 路径
```

## 为什么需要 LSM 层

B-tree 写入是 COW 的——每次产生新页，有写放大。如果每次小写入都走 B-tree，IO 效率低。LSM 思路：

- **小写入聚合成批**：memtable 攒了一批写入后，compactor 一次性 applyBatch 刷入 B-tree（batch 效率 ~9× 优于单条 put）。
- **WAL 保证不丢数据**：memtable 是内存的，crash 后会丢失；WAL 在磁盘上，replay 就能恢复。
- **读路径两层**：最新数据在 memtable 中，B-tree 存已刷盘的旧数据。

## 核心源码讲解

### Memtable — 内存写入缓冲区

```zig
pub const Memtable = struct {
    allocator: std.mem.Allocator,
    index: std.StringHashMap(usize),       // key → entries 索引
    entries: std.ArrayList(MemEntry),      // 实际条目存储
    size_bytes: usize,                     // 当前数据大小（用于阈值判断）
    threshold: usize,                      // 触发 flush 的阈值

    pub fn put(self: *Memtable, key: []const u8, value: []const u8) !bool {
        if (self.index.get(key)) |idx| {
            // 更新已有 entry
            const entry = &self.entries.items[idx];
            // 调整 size：减旧值，加新值
            if (!entry.tombstone) self.size_bytes -|= entry.value.len;
            self.allocator.free(entry.value);
            entry.value = try self.allocator.dupe(u8, value);
            entry.tombstone = false;
            self.size_bytes += value.len;
            return false;  // 更新，非新增
        }
        // 新 entry
        ...
        self.size_bytes += key.len + value.len;
        return true;  // 新增
    }

    pub fn get(self: *Memtable, key: []const u8) ?[]const u8 {
        const idx = self.index.get(key) orelse return null;
        const entry = &self.entries.items[idx];
        if (entry.tombstone) return null;
        return entry.value;
    }

    pub fn shouldFlush(self: *Memtable) bool {
        return self.size_bytes >= self.threshold;
    }
};
```

**要点：**

- `StringHashMap` 存 key → index 映射，O(1) 平均查找。
- `entries` 用 ArrayList 存实际条目，HashMap 只存索引号——更新时只改 entries 不重建 HashMap。
- `size_bytes` 精确跟踪数据量，用于阈值判断。更新时减旧值加新值，delete 时减 value 留 key。
- `shouldFlush()` 返回 true 时，Db.put 会调用 `compactor.signal(memtable)` 唤醒后台线程。

### WAL — 预写日志

```zig
pub const Wal = struct {
    fd: i32,
    append_pos: u64,       // 当前写入位置
    checkpoint_pos: u64,   // 已确认持久化的位置

    pub fn append(self: *Wal, entry_type: EntryType, key: []const u8, value: []const u8) !u64 {
        const pos = self.append_pos;
        // 写 9 字节头：type(1) + key_len(4) + val_len(4)
        var hdr: [9]u8 = undefined;
        hdr[0] = @intFromEnum(entry_type);
        std.mem.writeInt(u32, hdr[1..][0..4], @as(u32, @intCast(key.len)), .little);
        std.mem.writeInt(u32, hdr[5..][0..4], @as(u32, @intCast(value.len)), .little);
        // 计算 CRC32（覆盖头+key+value）
        var crc = std.hash.Crc32.init();
        crc.update(hdr[0..9]);
        crc.update(key);
        crc.update(value);
        const crc_val = crc.final();
        // 写入：头 → key → value → CRC
        _ = c.pwrite(self.fd, &hdr, 9, tot(pos));
        _ = c.pwrite(self.fd, key.ptr, key.len, tot(pos + 9));
        _ = c.pwrite(self.fd, value.ptr, value.len, tot(pos + 9 + key.len));
        _ = c.pwrite(self.fd, &crc_buf, 4, tot(pos + 9 + key.len + value.len));
        self.append_pos = pos + 9 + key.len + value.len + 4;
        return pos;
    }

    pub fn replay(self: *Wal) ![]Entry {
        // 读出所有 WAL 条目，逐条验证 CRC，跳过损坏条目
        // 返回 Entry 数组，调用方可用这些条目重建 memtable
    }

    pub fn truncate(self: *Wal) !void {
        // 关闭文件，删除，重新创建——清空已刷盘的 WAL
    }
};
```

**要点：**

- 每条记录格式：`type(1) + key_len(4) + val_len(4) + key(N) + val(M) + CRC32(4)`。
- 使用 `pwrite` 直接写文件偏移（无缓冲），不怕 crash 时丢失已 write 未 fsync 的数据。
- `replay` 在启动时调用，读出所有合法条目重建 memtable。
- `truncate` 在 compactor 刷盘完成后调用——B-tree 已持久化，WAL 可以删了。

### Compactor — 后台刷盘线程

```zig
pub const Compactor = struct {
    state: *wrt.State,       // B-tree 写入目标
    wal: *wal_mod.Wal,       // 刷盘后 truncate WAL
    rwlock: *RwLock,         // B-tree 并发保护
    thread: ?std.Thread,     // 后台线程
    cond: Condition,         // 信号唤醒
    pending_memtable: ?*Memtable,  // 待刷的 memtable

    pub fn signal(self: *Compactor, mt: *memtable_mod.Memtable) void {
        self.mutex.lock() catch {};
        defer self.mutex.unlock();
        self.pending_memtable = mt;
        self.cond.signal();  // 唤醒后台线程
    }

    fn threadLoop(self: *Compactor) void {
        while (self.running) {
            self.mutex.lock() catch {};
            while (self.pending_memtable == null and self.running) {
                self.cond.wait(&self.mutex) catch continue;  // 等待信号
            }
            // 取 memtable，解锁
            self.mutex.unlock();
            // 刷盘
            self.flush(mt) catch {};
        }
    }

    fn flush(self: *Compactor, mt: *memtable_mod.Memtable) !void {
        const entries = try mt.snapshot();  // 排好序的快照
        // 构造 applyBatch 需要的 Request 数组
        ...
        try self.rwlock.lock();       // 独占 B-tree
        defer self.rwlock.unlock();
        try self.state.applyBatch(reqs);  // 批量写入 B-tree
        try self.wal.truncate();      // 清空 WAL
        mt.clear();                   // 清空 memtable
    }
};
```

**要点：**

- `signal` 由 Db.put 在 memtable 满时调用，设置 `pending_memtable` 并唤醒后台线程。
- `threadLoop` 等待 signal，取 memtable 后立刻释放锁（避免阻塞新的 put）。
- `flush` 先 `snapshot` 获取排序快照，然后加 RwLock 独占 B-tree，调用 `applyBatch` 批量写入，最后 truncate WAL + clear memtable。
- RwLock 保证 flush 时其他线程不能同时写 B-tree，但不阻塞读 memtable。

### Db 中的 LSM 双路径

```zig
pub fn put(self: *Db, key: []const u8, value: []const u8) !void {
    if (self.mt) |mt| {
        if (self.wal) |w| _ = try w.append(.put, key, value);
        _ = try mt.put(key, value);
        if (mt.shouldFlush()) {
            if (self.compactor) |c| c.signal(mt);
        }
        return;
    }
    // Fallback to original COW path
    var future: zio.Future(wrt.OpResult) = .{};
    try self.state.applyBatch(&.{.{...}});
    _ = try future.wait();
}

pub fn get(self: *Db, key: []const u8) !?[]u8 {
    if (self.mt) |mt| {
        if (self.rwlock) |rw| try rw.lockShared();
        defer if (self.rwlock) |rw| rw.unlockShared();
        if (mt.get(key)) |val| {
            return try self.allocator.dupe(u8, val);
        }
    }
    // Fallback to B-tree
    const root = self.state.getRoot();
    return try btree.get(self.allocator, self.store, root, key);
}
```

**要点：**

- `put` 有 memtable 时走 LSM 路径：WAL append → memtable put → 满则 signal compactor。无 memtable 时走原始 COW 路径。
- `get` 先查 memtable（需读锁，防止 compactor 同时写），命中则返回；miss 则查 B-tree。
- `delete` 在 LSM 路径中只写 tombstone 到 memtable + WAL，不立即刷 B-tree——compactor 刷盘时一并处理。

## 可运行片段

把以下代码保存到 `tests/lsm_tutorial_test.zig`，用 `zig build test` 执行：

```zig
const std = @import("std");
const cube = @import("cube_db");
const memtable = cube.memtable;

test "Memtable 基本操作" {
    var mt = memtable.Memtable.init(std.testing.allocator, 1024);
    defer mt.deinit();

    _ = try mt.put("hello", "world");
    try std.testing.expectEqualStrings("world", mt.get("hello").?);

    // 更新已有 key
    _ = try mt.put("hello", "new");
    try std.testing.expectEqualStrings("new", mt.get("hello").?);

    // 删除
    _ = try mt.delete("hello");
    try std.testing.expectEqual(@as(?[]const u8, null), mt.get("hello"));
}

test "Memtable 阈值触发 flush" {
    var mt = memtable.Memtable.init(std.testing.allocator, 100);
    defer mt.deinit();

    try std.testing.expect(!mt.shouldFlush());
    var big: [60]u8 = undefined;
    @memset(&big, 'x');
    _ = try mt.put(&big, "hello");
    try std.testing.expect(!mt.shouldFlush()); // 60+5=65 < 100
    _ = try mt.put("another", &big);
    try std.testing.expect(mt.shouldFlush()); // 65+7+60=132 >= 100 ✓
}
```

## 要点回顾

- cube_db 是 **LSM + COW B-tree 混合架构**：小写走 memtable，批量刷入 B-tree。
- **Memtable**：HashMap O(1) put/get，`size_bytes` 跟踪数据量，阈值触发 flush。
- **WAL**：append-only 日志，CRC32 校验，crash 时 replay 恢复，flush 后 truncate。
- **Compactor**：后台线程，signal/condition 唤醒，RwLock 保证 B-tree 并发安全，`applyBatch` 批量写入。
- **Db.put/get/delete**：先查/写 memtable，再 fallback 到 B-tree——双路径无缝切换。