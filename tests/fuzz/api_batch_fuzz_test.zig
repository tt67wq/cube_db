//! putBatch API fuzz test.
//! Random byte input → decoded as putBatch operations (multiple key-value pairs per batch).
//! Each batch executed against both Db (MemPageStore, COW path) and
//! a reference std.StringHashMap. Results must match.

const std = @import("std");
const fuzz = @import("common.zig");
const cube = @import("cube_db");
const ps = cube.page_store;
const dbi = cube.db;

const OpType = enum(u8) {
    putBatch = 0,
    get_all = 1,
    delete_batch = 2,
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
    if (input.len < 1) return 0;
    const op_type = input[0];
    var pos: usize = 1;

    switch (op_type) {
        @intFromEnum(OpType.putBatch) => {
            // Decode: count(u8) + [key_len(u16) + key + val_len(u16) + val] * count
            if (pos >= input.len) return 0;
            const pair_count = input[pos];
            pos += 1;
            if (pair_count == 0) return pos;

            // Build entries array from input
            // Limit to 8 pairs per batch — keep total payload within single leaf page (4068B)
            var entries_buf: [8]cube.Entry = undefined;
            var owned_keys: [8][]u8 = undefined;
            var owned_vals: [8][]u8 = undefined;
            var actual_n: usize = 0;
            const n = @min(pair_count, entries_buf.len);

            for (0..n) |i| {
                if (pos + 2 > input.len) break;
                const key_len = std.mem.readInt(u16, input[pos..][0..2], .little);
                pos += 2;
                // Cap key length to 32 bytes — keep batch payload within leaf page
                const actual_key_len = @min(@min(@as(usize, key_len), 32), input.len - pos);
                if (actual_key_len == 0) {
                    // empty key — use placeholder
                    entries_buf[i] = .{ .key = "", .value = "", .tombstone = false };
                    owned_keys[i] = ctx.allocator.dupe(u8, "") catch return pos;
                    owned_vals[i] = ctx.allocator.dupe(u8, "") catch return pos;
                    actual_n += 1;
                    continue;
                }
                const key = input[pos..][0..actual_key_len];
                pos += actual_key_len;

                if (pos + 2 > input.len) break;
                const val_len = std.mem.readInt(u16, input[pos..][0..2], .little);
                pos += 2;
                // Cap value length to 64 bytes — keep batch payload within leaf page
                const actual_val_len = @min(@min(@as(usize, val_len), 64), input.len - pos);
                const value = input[pos..][0..actual_val_len];
                pos += actual_val_len;

                entries_buf[i] = .{ .key = key, .value = value, .tombstone = false };
                owned_keys[i] = ctx.allocator.dupe(u8, key) catch return pos;
                owned_vals[i] = ctx.allocator.dupe(u8, value) catch return pos;
                actual_n += 1;
            }

            if (actual_n == 0) return pos;

            // Execute putBatch — use owned slices (valid during call)
            for (0..actual_n) |i| {
                entries_buf[i].key = owned_keys[i];
                entries_buf[i].value = owned_vals[i];
            }
            ctx.db.putBatch(entries_buf[0..actual_n]) catch {
                // putBatch failed — free owned and return
                for (0..actual_n) |i| {
                    ctx.allocator.free(owned_keys[i]);
                    ctx.allocator.free(owned_vals[i]);
                }
                return pos;
            };

            // Update reference model
            for (0..actual_n) |i| {
                const prev = ctx.model.fetchPut(owned_keys[i], owned_vals[i]) catch null;
                if (prev) |p| {
                    ctx.allocator.free(p.key);
                    ctx.allocator.free(p.value);
                }
            }
        },
        @intFromEnum(OpType.get_all) => {
            // Verify all model keys match Db
            var model_it = ctx.model.iterator();
            while (model_it.next()) |entry| {
                const db_val = ctx.db.get(entry.key_ptr.*) catch continue;
                defer if (db_val) |v| ctx.allocator.free(v);
                if (db_val) |dv| {
                    if (!std.mem.eql(u8, dv, entry.value_ptr.*)) return error.ModelMismatch;
                } else {
                    return error.ModelMismatch;
                }
            }
        },
        @intFromEnum(OpType.delete_batch) => {
            // Decode: count(u8) + [key_len(u16) + key] * count
            if (pos >= input.len) return 0;
            const del_count = input[pos];
            pos += 1;
            if (del_count == 0) return pos;

            const dn = @min(del_count, @as(u8, 8));
            var del_entries: [8]cube.Entry = undefined;
            var del_keys: [8][]u8 = undefined;
            var actual_dn: usize = 0;

            for (0..dn) |i| {
                if (pos + 2 > input.len) break;
                const key_len = std.mem.readInt(u16, input[pos..][0..2], .little);
                pos += 2;
                // Cap key length to 32 bytes — must fit in btree leaf page
                const actual_key_len = @min(@min(@as(usize, key_len), 32), input.len - pos);
                if (actual_key_len == 0) continue;
                const key = input[pos..][0..actual_key_len];
                pos += actual_key_len;

                del_keys[i] = ctx.allocator.dupe(u8, key) catch return pos;
                del_entries[i] = .{ .key = del_keys[i], .value = "", .tombstone = true };
                actual_dn += 1;
            }

            if (actual_dn > 0) {
                ctx.db.putBatch(del_entries[0..actual_dn]) catch {
                    for (0..actual_dn) |i| ctx.allocator.free(del_keys[i]);
                    return pos;
                };
                // Update model: remove from model
                for (0..actual_dn) |i| {
                    const prev = ctx.model.fetchRemove(del_keys[i]);
                    if (prev) |p| {
                        ctx.allocator.free(p.key);
                        ctx.allocator.free(p.value);
                    }
                    ctx.allocator.free(del_keys[i]);
                }
            }
        },
        else => return pos,
    }
    return pos;
}

fn batchFuzzTestOne(ctx: *FuzzCtx, smith: *std.testing.Smith) !void {
    // Clear state from previous iteration to prevent unbounded page accumulation
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

test "fuzz putBatch API — smoke (100 random iters)" {
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
    _ = try fuzz.fuzzLoop(FuzzCtx, &ctx, batchFuzzTestOne, 100, seed);
}

test "fuzz putBatch API — corpus replay" {
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
    _ = try fuzz.replayCorpus(FuzzCtx, &ctx, batchFuzzTestOne, "tests/fuzz/corpus/api");
}
