//! writer.zig — batch 应用、COW、header 提交、垃圾统计、自动 compaction 触发
//! M4。同步写路径；D4 协程/group commit 押注已关闭（压测验证同步写足够）。
const std = @import("std");
const zio = @import("zio");
const f = @import("format.zig");
const store_mod = @import("store.zig");
const btree = @import("btree.zig");
const btree_batch = @import("btree_batch.zig");
const file_store = @import("file_store.zig");

const Store = store_mod.Store;

pub const Options = struct {
    auto_compact_dirt_ratio: ?f32 = 0.30,
    auto_compact_min_bytes: u64 = 16 * 1024 * 1024,
    fsync: bool = true,
};

/// 写请求结果（Future 值类型）
pub const OpResult = anyerror!void;

/// 写请求。调用方栈分配 future，通过指针传 mailbox。
pub const Request = struct {
    key: []const u8,
    value: []const u8,
    tombstone: bool,
    future: *zio.Future(OpResult),
};

/// writer 内部状态（与 Db 共享）
pub const State = struct {
    allocator: std.mem.Allocator,
    store: Store,
    fs: *file_store.FileStore,
    /// 原子 root（逻辑偏移，0=空树，maxInt=btree.NULL_ROOT 转换）
    root: std.atomic.Value(u64),
    dirt: std.atomic.Value(u64),
    entry_count: std.atomic.Value(u64),
    byte_size: std.atomic.Value(u64),
    opts: Options,
    closed: std.atomic.Value(bool),
    /// 自动 compaction 触发计数（测试用）
    compact_count: std.atomic.Value(u32),
    /// applyBatch 调用次数（group commit 合并度观测）
    apply_count: std.atomic.Value(u64) = .init(0),
};

/// 应用一批写请求，COW 构建新 root，写 header，fsync，更新原子状态。
/// 返回写入的 header 数（1）。
pub fn applyBatch(state: *State, batch: []Request) !void {
    _ = state.apply_count.fetchAdd(1, .monotonic);
    // 快照当前 root（DB 层：0=空，n>0=有效 btree off + 1）
    const cur_root = state.root.load(.acquire);
    const bt_root: u64 = if (cur_root == 0) btree.NULL_ROOT else cur_root - 1;

    // BTreeBatch：所有 op 应用到缓存树，一次 flush（1 header + 1 fsync + COW 摊薄）
    var bt = btree_batch.BTreeBatch.init(state.allocator, state.store, bt_root);
    defer bt.deinit();

    for (batch) |req| {
        bt.apply(req.key, req.value, req.tombstone) catch |err| {
            // apply 失败（如内存）：全批不提交，全部 future set err
            for (batch) |r| r.future.set(err);
            return;
        };
    }
    const wr = bt.commit() catch |err| {
        for (batch) |r| r.future.set(err);
        return;
    };

    // 提交：写 header（root、dirt、count、byte_size）
    // DB 层 root：0=空，n>0=btree off + 1
    const new_db_root: u64 = if (wr.new_root == btree.NULL_ROOT) 0 else wr.new_root + 1;
    const cur_dirt = state.dirt.load(.acquire);
    const cur_count = state.entry_count.load(.acquire);
    const cur_byte = state.byte_size.load(.acquire);
    const new_dirt = cur_dirt + wr.dirt_delta;
    const new_count_signed: i64 = @as(i64, @intCast(cur_count)) + wr.count_delta;
    const new_count: u64 = @intCast(@max(@as(i64, 0), new_count_signed));
    const new_byte_signed: i64 = @as(i64, @intCast(cur_byte)) + wr.live_delta;
    const new_byte: u64 = @intCast(@max(@as(i64, 0), new_byte_signed));

    _ = try file_store.appendHeaderRecord(state.fs, .{
        .btree_root = new_db_root,
        .entry_count = new_count,
        .byte_size = new_byte,
        .dirt = new_dirt,
    });
    if (state.opts.fsync) {
        try state.store.sync();
    }

    // 原子更新状态
    state.root.store(new_db_root, .release);
    state.dirt.store(new_dirt, .release);
    state.entry_count.store(new_count, .release);
    state.byte_size.store(new_byte, .release);

    // 所有请求成功
    for (batch) |req| {
        req.future.set({});
    }

    // 自动 compaction 检查
    if (state.opts.auto_compact_dirt_ratio) |ratio| {
        const live = new_byte;
        const total = new_dirt + live;
        if (total >= state.opts.auto_compact_min_bytes and live > 0) {
            const dirt_ratio = @as(f64, @floatFromInt(new_dirt)) / @as(f64, @floatFromInt(total));
            if (dirt_ratio >= @as(f64, @floatCast(ratio))) {
                // ponytail: MVP 自动 compact 标记计数，实际 compaction 由 compactor.zig 实现（M5）
                _ = state.compact_count.fetchAdd(1, .monotonic);
            }
        }
    }
}

