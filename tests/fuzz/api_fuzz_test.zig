//! DB API operation sequence fuzz test.
//! Random byte input → decoded as put/get/delete operations.
//! Each op executed against both Db (MemPageStore, COW path) and
//! a reference std.StringHashMap. Results must match.

const std = @import("std");
const fuzz = @import("common.zig");
const cube = @import("cube_db");
const ps = cube.page_store;
const dbi = cube.db;

const OpType = enum(u8) {
    put = 0,
    get = 1,
    delete = 2,
};

/// Context for the fuzz target: Db + reference model.
const FuzzCtx = struct {
    db: *dbi.Db,
    model: *std.StringHashMap([]const u8),
    allocator: std.mem.Allocator,
};

/// Decode and execute a single op from input bytes.
/// Returns bytes consumed, or 0 if input is too short.
fn execOneOp(input: []const u8, ctx: *FuzzCtx) !usize {
    if (input.len < 5) return 0;
    const op_type = input[0];
    const key_len = std.mem.readInt(u32, input[1..5], .little);
    const actual_key_len = @min(@as(usize, key_len), input.len - 5);
    if (actual_key_len == 0) return 5;
    const key = input[5..][0..actual_key_len];
    var consumed: usize = 5 + actual_key_len;

    switch (op_type) {
        @intFromEnum(OpType.put) => {
            if (consumed + 4 > input.len) return 0;
            const val_len = std.mem.readInt(u32, input[consumed..][0..4], .little);
            consumed += 4;
            const actual_val_len = @min(@as(usize, val_len), input.len - consumed);
            const value = input[consumed..][0..actual_val_len];
            consumed += actual_val_len;

            ctx.db.put(key, value) catch return consumed;
            const owned_key = try ctx.allocator.dupe(u8, key);
            const owned_val = try ctx.allocator.dupe(u8, value);
            const prev = try ctx.model.fetchPut(owned_key, owned_val);
            if (prev) |p| {
                ctx.allocator.free(p.key);
                ctx.allocator.free(p.value);
            }
        },
        @intFromEnum(OpType.get) => {
            const db_val = try ctx.db.get(key);
            defer if (db_val) |v| ctx.allocator.free(v);
            const model_val = ctx.model.get(key);
            if (db_val) |dv| {
                if (model_val == null) return error.ModelMismatch;
                if (!std.mem.eql(u8, dv, model_val.?)) return error.ModelMismatch;
            } else {
                if (model_val != null) return error.ModelMismatch;
            }
        },
        @intFromEnum(OpType.delete) => {
            ctx.db.delete(key) catch return consumed;
            const prev = ctx.model.fetchRemove(key);
            if (prev) |p| {
                ctx.allocator.free(p.key);
                ctx.allocator.free(p.value);
            }
            const db_got = try ctx.db.get(key);
            if (db_got) |v| {
                ctx.allocator.free(v);
                return error.ModelMismatch;
            }
        },
        else => return consumed,
    }
    return consumed;
}

fn apiFuzzTestOne(ctx: *FuzzCtx, smith: *std.testing.Smith) !void {
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

test "fuzz DB API — smoke (100 random iters)" {
    var ms = ps.MemPageStore.init(std.testing.allocator, 10000);
    defer ms.deinit();
    var db = try dbi.Db.open(std.testing.allocator, ms.store(), .{});
    defer db.close();

    var model = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer {
        var it = model.iterator();
        while (it.next()) |entry| {
            std.testing.allocator.free(entry.key_ptr.*);
            std.testing.allocator.free(entry.value_ptr.*);
        }
        model.deinit();
    }

    var ctx = FuzzCtx{
        .db = db,
        .model = &model,
        .allocator = std.testing.allocator,
    };
    const seed = std.testing.random_seed;
    _ = try fuzz.fuzzLoop(FuzzCtx, &ctx, apiFuzzTestOne, 100, seed);
}

test "fuzz DB API — corpus replay" {
    var ms = ps.MemPageStore.init(std.testing.allocator, 10000);
    defer ms.deinit();
    var db = try dbi.Db.open(std.testing.allocator, ms.store(), .{});
    defer db.close();

    var model = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer {
        var it = model.iterator();
        while (it.next()) |entry| {
            std.testing.allocator.free(entry.key_ptr.*);
            std.testing.allocator.free(entry.value_ptr.*);
        }
        model.deinit();
    }

    var ctx = FuzzCtx{
        .db = db,
        .model = &model,
        .allocator = std.testing.allocator,
    };
    _ = try fuzz.replayCorpus(FuzzCtx, &ctx, apiFuzzTestOne, "tests/fuzz/corpus/api");
}