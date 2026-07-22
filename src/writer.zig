//! writer.zig — writer 协程：batch 应用、COW、header 提交、垃圾统计、自动 compaction 触发
//! M4。D4 单 writer + mailbox；D10 group commit 排空策略。
const std = @import("std");
const zio = @import("zio");
const f = @import("format.zig");
const store_mod = @import("store.zig");
const btree = @import("btree.zig");
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
};

pub const MAX_BATCH_OPS: usize = 64;
pub const MAX_BATCH_BYTES: usize = 1024 * 1024;

/// 应用一批写请求，COW 构建新 root，写 header，fsync，更新原子状态。
/// 返回写入的 header 数（1）。
pub fn applyBatch(state: *State, batch: []Request) !void {
    // 快照当前 root（DB 层：0=空，n>0=有效 btree off + 1）
    const cur_root = state.root.load(.acquire);
    var bt_root: u64 = if (cur_root == 0) btree.NULL_ROOT else cur_root - 1;
    var live_delta: i64 = 0;
    var dirt_delta: u64 = 0;
    var count_delta: i64 = 0;
    var any_err: ?anyerror = null;
    var err_req_index: ?usize = null;

    for (batch, 0..) |req, i| {
        const wr = btree.insert(state.allocator, state.store, bt_root, req.key, req.value, req.tombstone) catch |err| {
            any_err = err;
            err_req_index = i;
            break;
        };
        bt_root = wr.new_root;
        live_delta += wr.live_delta;
        dirt_delta += wr.dirt_delta;
        count_delta += wr.count_delta;
    }

    if (any_err) |err| {
        // 失败：对已处理请求设成功，对失败请求设错误，后续未处理也设错误
        for (batch, 0..) |req, i| {
            if (i < err_req_index.?) {
                req.future.set({});
            } else {
                req.future.set(err);
            }
        }
        return;
    }

    // 提交：写 header（root、dirt、count、byte_size）
    // DB 层 root：0=空，n>0=btree off + 1
    const new_db_root: u64 = if (bt_root == btree.NULL_ROOT) 0 else bt_root + 1;
    const cur_dirt = state.dirt.load(.acquire);
    const cur_count = state.entry_count.load(.acquire);
    const cur_byte = state.byte_size.load(.acquire);
    const new_dirt = cur_dirt + dirt_delta;
    const new_count_signed: i64 = @as(i64, @intCast(cur_count)) + count_delta;
    const new_count: u64 = @intCast(@max(@as(i64, 0), new_count_signed));
    const new_byte_signed: i64 = @as(i64, @intCast(cur_byte)) + live_delta;
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

/// writer 协程主循环。
/// receive 首请求 → yield → tryReceive 排空至上限 → applyBatch → 循环。
/// channel 关闭则退出。
pub fn writerLoop(state: *State, mailbox: *zio.Channel(Request)) anyerror!void {
    var batch_buf: [MAX_BATCH_OPS]Request = undefined;
    while (true) {
        const first = mailbox.receive() catch |err| switch (err) {
            error.ChannelClosed => {
                return;
            },
            else => return err,
        };
        // yield 一次让排队 sender 入队
        try zio.yield();
        // 排空至上限
        var count: usize = 1;
        batch_buf[0] = first;
        var bytes: usize = first.key.len + first.value.len;
        while (count < MAX_BATCH_OPS and bytes < MAX_BATCH_BYTES) {
            const r = mailbox.tryReceive() catch break;
            batch_buf[count] = r;
            count += 1;
            bytes += r.key.len + r.value.len;
        }
        applyBatch(state, batch_buf[0..count]) catch {};
        if (state.closed.load(.acquire)) return;
    }
}
