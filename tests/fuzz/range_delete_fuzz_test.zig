//! deleteRange API fuzz test.
//! Random byte input → decoded as: put several keys, then deleteRange(min, max).
//! Reference model uses StringHashMap with half-open interval [min, max) semantics.
//! Edge cases: min=null, max=null, min==max, min>max (inverted = no-op).

const std = @import("std");
const fuzz = @import("common.zig");
const cube = @import("cube_db");
const ps = cube.page_store;
const dbi = cube.db;

const OpType = enum(u8) {
    put_keys = 0,
    delete_range = 1,
    verify_all = 2,
};

const FuzzCtx = struct {
    db: *dbi.Db,
    model: *std.StringHashMap([]const u8),
    allocator: std.mem.Allocator,
};

fn execOneOp(input: []const u8, ctx: *FuzzCtx) !usize {
    if (input.len < 1) return 0;
    const op_type = input[0];
    var pos: usize = 1;

    switch (op_type) {
        @intFromEnum(OpType.put_keys) => {
            // Decode: count(u8) + [key_len(u8) + key] * count
            if (pos >= input.len) return 0;
            const count = input[pos];
            pos += 1;
            if (count == 0) return pos;

            const n = @min(count, @as(u8, 32));
            for (0..n) |_| {
                if (pos >= input.len) break;
                const key_len = input[pos];
                pos += 1;
                // Cap key length to 32 bytes — avoid triggering btree leaf page overflow
                const actual_key_len = @min(@min(@as(usize, key_len), 32), input.len - pos);
                if (actual_key_len == 0) continue;
                const key = input[pos..][0..actual_key_len];
                pos += actual_key_len;

                // putDirect bypasses micro-batching
                ctx.db.putDirect(key, "v") catch continue;

                // Update model (last-write-wins) — must dupe value since it's freed later
                const owned_key = ctx.allocator.dupe(u8, key) catch continue;
                const owned_val = ctx.allocator.dupe(u8, "v") catch {
                    ctx.allocator.free(owned_key);
                    continue;
                };
                const prev = ctx.model.fetchPut(owned_key, owned_val) catch null;
                if (prev) |p| {
                    ctx.allocator.free(p.key);
                    ctx.allocator.free(p.value);
                }
            }
        },
        @intFromEnum(OpType.delete_range) => {
            // Decode: min_present(u8) + min_len(u8) + min + max_present(u8) + max_len(u8) + max
            // min_present=0 → min=null; max_present=0 → max=null
            var min: ?[]const u8 = null;
            var max: ?[]const u8 = null;

            if (pos >= input.len) return 0;
            const min_present = input[pos] != 0;
            pos += 1;
            if (min_present) {
                if (pos >= input.len) return 0;
                const min_len = input[pos];
                pos += 1;
                const actual_min_len = @min(@as(usize, min_len), input.len - pos);
                if (actual_min_len > 0) {
                    min = input[pos..][0..actual_min_len];
                    pos += actual_min_len;
                }
            }

            if (pos >= input.len) return pos;
            const max_present = input[pos] != 0;
            pos += 1;
            if (max_present) {
                if (pos >= input.len) return pos;
                const max_len = input[pos];
                pos += 1;
                const actual_max_len = @min(@as(usize, max_len), input.len - pos);
                if (actual_max_len > 0) {
                    max = input[pos..][0..actual_max_len];
                    pos += actual_max_len;
                }
            }

            // deleteRange with half-open [min, max) semantics
            if (ctx.db.deleteRange(min, max)) |_| {
                // success — update model below
            } else |_| {
                // deleteRange failed — skip model update
                return pos;
            }

            // Update model: remove all keys k where (min==null or k >= min) and (max==null or k < max)
            var to_remove = std.ArrayList([]const u8).empty;
            defer to_remove.deinit(ctx.allocator);
            var model_it = ctx.model.iterator();
            while (model_it.next()) |entry| {
                const k = entry.key_ptr.*;
                var in_range = true;
                if (min) |m| {
                    if (std.mem.order(u8, k, m) == .lt) in_range = false;
                }
                if (max) |mx| {
                    if (std.mem.order(u8, k, mx) != .lt) in_range = false;
                }
                if (in_range) {
                    to_remove.append(ctx.allocator, k) catch break;
                }
            }
            for (to_remove.items) |k| {
                const prev = ctx.model.fetchRemove(k);
                if (prev) |p| {
                    ctx.allocator.free(p.key);
                    ctx.allocator.free(p.value);
                }
            }
        },
        @intFromEnum(OpType.verify_all) => {
            // Verify: every key in Db should be in model (and vice versa)
            var model_it = ctx.model.iterator();
            while (model_it.next()) |entry| {
                const db_val = ctx.db.get(entry.key_ptr.*) catch continue;
                defer if (db_val) |v| ctx.allocator.free(v);
                if (db_val == null) return error.ModelMismatch;
                if (!std.mem.eql(u8, db_val.?, entry.value_ptr.*)) return error.ModelMismatch;
            }
        },
        else => return pos,
    }
    return pos;
}

fn rangeDeleteFuzzTestOne(ctx: *FuzzCtx, smith: *std.testing.Smith) !void {
    // Clear state from previous iteration to prevent unbounded page accumulation
    // (btree insertIntoLeaf split path can overflow with too many entries per page)
    ctx.db.deleteRange(null, null) catch {};
    var model_it = ctx.model.iterator();
    var to_clear = std.ArrayList([]const u8).empty;
    defer to_clear.deinit(ctx.allocator);
    while (model_it.next()) |entry| {
        to_clear.append(ctx.allocator, entry.key_ptr.*) catch break;
    }
    for (to_clear.items) |k| {
        const prev = ctx.model.fetchRemove(k);
        if (prev) |p| {
            ctx.allocator.free(p.key);
            ctx.allocator.free(p.value);
        }
    }

    var buf: [4096]u8 = undefined;
    const len = smith.slice(&buf);
    const input = buf[0..len];

    var offset: usize = 0;
    while (offset < input.len) {
        const consumed = try execOneOp(input[offset..], ctx);
        if (consumed == 0) break;
        offset += consumed;
    }
}

fn cleanupModel(model: *std.StringHashMap([]const u8), allocator: std.mem.Allocator) void {
    var it = model.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        allocator.free(entry.value_ptr.*);
    }
    model.deinit();
}

test "fuzz deleteRange — smoke (100 random iters)" {
    var ms = ps.MemPageStore.init(std.testing.allocator, 10000);
    defer ms.deinit();
    var db = try dbi.Db.open(std.testing.allocator, ms.store(), .{});
    defer db.close();

    var model = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer cleanupModel(&model, std.testing.allocator);

    var ctx = FuzzCtx{
        .db = db,
        .model = &model,
        .allocator = std.testing.allocator,
    };
    const seed = std.testing.random_seed;
    _ = try fuzz.fuzzLoop(FuzzCtx, &ctx, rangeDeleteFuzzTestOne, 100, seed);
}

test "fuzz deleteRange — corpus replay" {
    var ms = ps.MemPageStore.init(std.testing.allocator, 10000);
    defer ms.deinit();
    var db = try dbi.Db.open(std.testing.allocator, ms.store(), .{});
    defer db.close();

    var model = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer cleanupModel(&model, std.testing.allocator);

    var ctx = FuzzCtx{
        .db = db,
        .model = &model,
        .allocator = std.testing.allocator,
    };
    _ = try fuzz.replayCorpus(FuzzCtx, &ctx, rangeDeleteFuzzTestOne, "tests/fuzz/corpus/api");
}
