# 02 — B-tree

B-tree 是 cube_db 的索引引擎。所有 key→value 的映射都存在 B-tree 节点中。

## 叶子 vs 分支

B-tree 有两种节点：

- **叶子（Leaf）**：存实际的 key-value 条目。上限 32 条目（`LEAF_MAX_ENTRIES=32`）。
- **分支（Branch）**：存分隔 key 和 u32 子页号，用于路由。上限 64 子指针（`BRANCH_MAX_CHILDREN=64`）。

叶子节点 payload 布局 (big-endian)：

```
+ kind: u8 (=2) + count: u16 + entries[]
  每个 entry: tombstone(1) + klen(4) + key(klen) + vlen(4) + flags(1) + value(vlen)
```

分支节点 payload 布局：

```
+ kind: u8 (=1) + count: u16 + keys[] + children[]
  keys: 每个 klen(4) + key(klen)
  children: count(2) 个 u32，比 keys 多一个（额外最右子指针）
```

### 寻址

子指针是 **u32 页号**（不是指针或偏移）。BST 查找时读子页号，然后通过 `PageStore.readPage(page_no)` 获取新页数据。这使 B-tree 层完全不知数据在内存还是磁盘——由 PageStore 抽象。

### COW 特性

每次写入都会产生一条从根到叶的新路径。旧根页不立即释放——进入 pending_free，等读者释放后才回收。所以每次 insert 返回 `WriteResult.new_root`，调用方用这个新 root 替换旧 meta 中的 root。

### 查询路径

```
点查 get(key):
  1. 从 root 页开始
  2. 读页 payload，看 kind
  3. 如果是 branch：findInBranchPayload 找应走哪个子页号，跳到 2
  4. 如果是 leaf：findInLeaf 线性扫描条目找 key
  5. 返回 value（或 null）
```

## 核心源码讲解

### key 比较

```zig
pub fn cmpKey(a: []const u8, b: []const u8) std.math.Order {
    return std.mem.order(u8, a, b);
}
```

直接用 Zig stdlib 的 `std.mem.order`——按字节序逐字节比较。`Order` 返回 `.lt` / `.eq` / `.gt`，用于二分查找。

### Branch.findChild

分支节点路由的核心——二分查找 key 应走哪个子指针：

```zig
pub fn findChild(self: *const Branch, key: []const u8) usize {
    var lo: usize = 0;
    var hi: usize = self.keys.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        switch (cmpKey(self.keys[mid], key)) {
            .lt, .eq => lo = mid + 1,
            .gt => hi = mid,
        }
    }
    return lo;
}
```

**逐段讲解：**

1. 在 `keys` 数组（分隔 key）中二分查找，找到第一个大于 target 的 key。
2. `.lt, .eq` 都往右走——等于也应向右，因为分隔 key 是右子树的最小值。
3. 返回的 `lo` 是 child index：0 到 `children.len-1`。
4. 如果 target 比所有分隔 key 都大，返回 `self.keys.len`，即最右子指针。

### get — 点查

```zig
pub fn get(allocator: std.mem.Allocator, store: PageStore, root: u32, key: []const u8) !?[]u8 {
    if (root == NULL_ROOT) return null;
    var cur = root;
    var depth: u32 = 0;
    while (depth < 1000) : (depth += 1) {
        const payload = try readNodePayload(store, cur);
        if (payload.len == 0) return error.Truncated;
        if (payload[0] == LEAF_KIND) {
            return findInLeaf(allocator, store, payload, key);
        } else {
            cur = try findInBranchPayload(payload, key);
        }
    }
    return error.Truncated;
}
```

**逐段讲解：**

1. root = 0（`NULL_ROOT`）→ 空库，直接返回 null。
2. `depth < 1000` 是防无限循环的安全阀——B-tree 深度不可能超过几百。
3. 循环地：读当前页 payload → 看第一个字节判 kind。
4. leaf → `findInLeaf` 线性扫描；branch → `findInBranchPayload` 找子页号继续。
5. `findInLeaf` 内部逐条扫描 entry，遇到 key 相等且 non-tombstone 就拷贝返回 value。如果溢出页标记，调用 `readOverflowValue` 读溢出链。

### insert — 插入

insert 是递归的：`insert`（入口）→ 判 root 是 leaf 还是 branch → 调用 `insertIntoLeaf` 或 `insertIntoBranch` → 后者递归调用子节点的 insert 函数 → 返回 `InsertSub`（新子页、分裂信息、delta）。

```zig
pub fn insert(
    allocator: std.mem.Allocator,
    store: PageStore,
    root: u32,
    key: []const u8,
    value: []const u8,
    tombstone: bool,
    dirty: *std.ArrayList(u32),
) !WriteResult {
    if (root == NULL_ROOT) {
        // 空树：分配一个新 leaf 页，写第一个 entry
        ...
    }
    ...
    if (sub.split_key) |sk| {
        // root 分裂：建新 root branch
        // 新 root 是 branch，含一个 key 和两个子指针
        ...
    }
    return .{ .new_root = sub.new_child, .live_delta = sub.live_delta, .count_delta = sub.count_delta };
}
```

**关键设计：**

1. **COW 路径**：每次 insert 都走 allocPage → writeNodePage，写的是新页。旧页（`page_no`）加入 `dirty` 列表，最终进 pending_free。不原地修改页。
2. **分裂冒泡**：叶子满了（>32）→ 分裂成两个叶子，分裂 key 上提到父 branch；branch 满了（>64 子指针）→ 同样分裂冒泡。如果 root 也分裂，就建新 root branch，树深 +1。
3. **delta 记账**：`WriteResult.live_delta` 和 `count_delta` 让调用方（writer）能精确追踪存储空间和条目数变化，不重复扫描。

**插入流程举例（put "zi"）**：

```
初始: 单 leaf [alice, bob, charlie...]
插入 zi: leaf 未满 → 写入新 leaf 页 → 返回新 root 页号
        （旧 leaf 页进 dirty → pending_free）

如果 leaf 满了:
leaf 分裂 → 左右两个 leaf + 上提 split key
       → 如果 root 是 leaf，建新 root branch（含 split key + 两个子指针）
       → 返回新 root 页号
```

## 可运行片段

把以下代码保存到 `tests/btree_tutorial_test.zig`，用 `zig build test` 执行：

```zig
const std = @import("std");
const cube = @import("cube_db");
const MemPageStore = cube.page_store.MemPageStore;
const btree = cube.btree;

test "B-tree 插入和查询" {
    const allocator = std.testing.allocator;
    var ms = MemPageStore.init(allocator, 1 << 10);
    defer ms.deinit();
    const store = ms.store();

    var dirty = std.ArrayList(u32).empty;
    defer dirty.deinit(allocator);

    var root: u32 = 0;

    // 插入三个 key
    for ([_][]const u8{"alice", "bob", "carol"}, 0..) |k, i| {
        var buf: [8]u8 = undefined;
        const v = try std.fmt.bufPrint(&buf, "val_{d}", .{i});
        const result = try btree.insert(allocator, store, root, k, v, false, &dirty);
        root = result.new_root;
    }

    // 查询
    const v = try btree.get(allocator, store, root, "bob");
    defer if (v) |val| allocator.free(val);
    try std.testing.expect(v != null);
    try std.testing.expectEqualStrings("val_1", v.?);

    // 不存在的 key
    const nv = try btree.get(allocator, store, root, "zoe");
    try std.testing.expect(nv == null);
}
```

## 要点回顾

- 叶子节点存 key-value，上限 32 条目。分支节点存路由 key + u32 子页号，上限 64。
- 子指针是页号，非偏移——B-tree 层不感知存储后端。
- 每次 insert 写新路径（COW），旧页加入 pending_free。
- 二分查找用于分支路由和叶子内的位置定位。
- 分裂从叶子冒泡到根；根分裂则树深 +1。
- get 从根到叶逐层下降，O(log n) 页 I/O。
