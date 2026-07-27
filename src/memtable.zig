//! src/memtable.zig — In-memory sorted write buffer for LSM.
//! O(1) insert/lookup via HashMap + sorted iteration for compaction.
const std = @import("std");

const MemEntry = struct {
    key: []u8, // owned
    value: []u8, // owned
    tombstone: bool,
};

/// Memtable — in-memory write buffer.
/// put: O(1) amortized, get: O(1) average, iter: O(n log n) sorted.
/// threshold: when size_bytes >= threshold, shouldFlush() returns true.
pub const Memtable = struct {
    allocator: std.mem.Allocator,
    /// key -> index into entries
    index: std.StringHashMap(usize),
    entries: std.ArrayList(MemEntry),
    size_bytes: usize,
    threshold: usize,

    pub fn init(allocator: std.mem.Allocator, threshold: usize) Memtable {
        return .{
            .allocator = allocator,
            .index = std.StringHashMap(usize).init(allocator),
            .entries = std.ArrayList(MemEntry).empty,
            .size_bytes = 0,
            .threshold = threshold,
        };
    }

    pub fn deinit(self: *Memtable) void {
        for (self.entries.items) |*e| {
            self.allocator.free(e.key);
            self.allocator.free(e.value);
        }
        self.entries.deinit(self.allocator);
        self.index.deinit();
    }

    /// Insert or update a key. Regardless of tombstone, the value is stored.
    /// Returns true if this was a new key (not an update).
    pub fn put(self: *Memtable, key: []const u8, value: []const u8) !bool {
        if (self.index.get(key)) |idx| {
            // Update existing entry
            const entry = &self.entries.items[idx];
            // Adjust size: subtract old value, add new value
            if (!entry.tombstone) {
                self.size_bytes -|= entry.value.len;
            }
            self.allocator.free(entry.value);
            entry.value = try self.allocator.dupe(u8, value);
            entry.tombstone = false;
            self.size_bytes += value.len;
            return false;
        }

        // New entry
        const owned_key = try self.allocator.dupe(u8, key);
        const owned_value = try self.allocator.dupe(u8, value);
        const idx = self.entries.items.len;
        try self.entries.append(self.allocator, .{
            .key = owned_key,
            .value = owned_value,
            .tombstone = false,
        });
        try self.index.put(owned_key, idx);
        self.size_bytes += key.len + value.len;
        return true;
    }

    /// Get value for key. Returns null if not found or tombstoned.
    /// The returned slice is borrowed from the memtable (valid until next mutation).
    pub fn get(self: *Memtable, key: []const u8) ?[]const u8 {
        const idx = self.index.get(key) orelse return null;
        const entry = &self.entries.items[idx];
        if (entry.tombstone) return null;
        return entry.value;
    }

    /// Mark key as deleted. Returns true if the key existed in memtable.
    pub fn delete(self: *Memtable, key: []const u8) !bool {
        if (self.index.get(key)) |idx| {
            const entry = &self.entries.items[idx];
            if (!entry.tombstone) {
                entry.tombstone = true;
                self.size_bytes -|= entry.value.len;
                // Keep key in index to shadow B-tree values
            }
            return true;
        }
        // Insert tombstone entry to shadow B-tree
        const owned_key = try self.allocator.dupe(u8, key);
        const idx = self.entries.items.len;
        try self.entries.append(self.allocator, .{
            .key = owned_key,
            .value = "",
            .tombstone = true,
        });
        try self.index.put(owned_key, idx);
        // Tombstone entry itself has minimal size cost
        self.size_bytes += key.len;
        return false;
    }

    /// Returns true if size_bytes >= threshold.
    pub fn shouldFlush(self: *Memtable) bool {
        return self.size_bytes >= self.threshold;
    }

    /// Number of entries (including tombstones).
    pub fn count(self: *Memtable) usize {
        return self.entries.items.len;
    }

    /// Clear all entries. Frees all owned memory.
    pub fn clear(self: *Memtable) void {
        for (self.entries.items) |*e| {
            self.allocator.free(e.key);
            self.allocator.free(e.value);
        }
        self.entries.clearAndFree(self.allocator);
        self.index.clearAndFree();
        self.size_bytes = 0;
    }

    /// Iterator for sorted walk (used by compaction).
    /// Returns entries in key-sorted order. Caller must free the returned slice.
    pub const SortedEntry = struct {
        key: []const u8,
        value: []const u8,
        tombstone: bool,
    };

    pub fn sortedEntries(self: *Memtable, allocator: std.mem.Allocator) ![]SortedEntry {
        const n = self.entries.items.len;
        var result = try allocator.alloc(SortedEntry, n);
        for (self.entries.items, 0..) |*e, i| {
            result[i] = .{
                .key = e.key,
                .value = e.value,
                .tombstone = e.tombstone,
            };
        }
        // Sort by key
        std.mem.sort(SortedEntry, result, {}, struct {
            fn lessThan(_: void, a: SortedEntry, b: SortedEntry) bool {
                return std.mem.lessThan(u8, a.key, b.key);
            }
        }.lessThan);
        return result;
    }

    /// Snapshot interface for compaction: creates an immutable snapshot.
    /// The snapshot is a copy of all entries (sorted). Caller must free.
    pub fn snapshot(self: *Memtable) ![]SortedEntry {
        return self.sortedEntries(self.allocator);
    }

    pub fn sizeBytes(self: *Memtable) usize {
        return self.size_bytes;
    }

    pub fn setThreshold(self: *Memtable, threshold: usize) void {
        self.threshold = threshold;
    }
};

test "memtable: put and get" {
    var mt = Memtable.init(std.testing.allocator, 1024);
    defer mt.deinit();

    try std.testing.expectEqual(@as(usize, 0), mt.count());
    _ = try mt.put("hello", "world");
    try std.testing.expectEqual(@as(usize, 1), mt.count());
    try std.testing.expectEqualStrings("world", mt.get("hello").?);
}

test "memtable: update existing key" {
    var mt = Memtable.init(std.testing.allocator, 1024);
    defer mt.deinit();

    _ = try mt.put("key", "value1");
    _ = try mt.put("key", "value2");
    try std.testing.expectEqual(@as(usize, 1), mt.count());
    try std.testing.expectEqualStrings("value2", mt.get("key").?);
}

test "memtable: get returns null for missing key" {
    var mt = Memtable.init(std.testing.allocator, 1024);
    defer mt.deinit();
    try std.testing.expectEqual(@as(?[]const u8, null), mt.get("nonexistent"));
}

test "memtable: delete tombstone" {
    var mt = Memtable.init(std.testing.allocator, 1024);
    defer mt.deinit();

    _ = try mt.put("key", "value");
    try std.testing.expectEqualStrings("value", mt.get("key").?);
    _ = try mt.delete("key");
    try std.testing.expectEqual(@as(?[]const u8, null), mt.get("key"));
}

test "memtable: delete non-existent key" {
    var mt = Memtable.init(std.testing.allocator, 1024);
    defer mt.deinit();

    // Deleting a non-existent key inserts a tombstone
    _ = try mt.delete("ghost");
    try std.testing.expectEqual(@as(usize, 1), mt.count());
    try std.testing.expectEqual(@as(?[]const u8, null), mt.get("ghost"));
}

test "memtable: shouldFlush on threshold" {
    var mt = Memtable.init(std.testing.allocator, 100);
    defer mt.deinit();

    try std.testing.expect(!mt.shouldFlush());
    // Insert enough data to exceed threshold
    var big_key: [50]u8 = undefined;
    @memset(&big_key, 'x');
    _ = try mt.put(&big_key, "hello");
    try std.testing.expect(!mt.shouldFlush()); // 50+5=55 < 100
    _ = try mt.put("another", &big_key);
    try std.testing.expect(mt.shouldFlush()); // 55+7+50=112 >= 100
}

test "memtable: sorted entries" {
    var mt = Memtable.init(std.testing.allocator, 1024);
    defer mt.deinit();

    _ = try mt.put("z", "last");
    _ = try mt.put("a", "first");
    _ = try mt.put("m", "middle");

    const sorted = try mt.sortedEntries(std.testing.allocator);
    defer std.testing.allocator.free(sorted);

    try std.testing.expectEqual(@as(usize, 3), sorted.len);
    try std.testing.expectEqualStrings("a", sorted[0].key);
    try std.testing.expectEqualStrings("m", sorted[1].key);
    try std.testing.expectEqualStrings("z", sorted[2].key);
}

test "memtable: clear frees memory" {
    var mt = Memtable.init(std.testing.allocator, 1024);
    defer mt.deinit();

    _ = try mt.put("key", "value");
    try std.testing.expectEqual(@as(usize, 1), mt.count());
    mt.clear();
    try std.testing.expectEqual(@as(usize, 0), mt.count());
    try std.testing.expectEqual(@as(?[]const u8, null), mt.get("key"));
}

test "memtable: size tracking" {
    var mt = Memtable.init(std.testing.allocator, 1024);
    defer mt.deinit();

    try std.testing.expectEqual(@as(usize, 0), mt.sizeBytes());
    _ = try mt.put("hello", "world"); // 5 + 5 = 10
    try std.testing.expectEqual(@as(usize, 10), mt.sizeBytes());
    _ = try mt.put("hello", "new"); // update: 5 + 3 = 8 (was 10, now 8)
    try std.testing.expectEqual(@as(usize, 8), mt.sizeBytes());
    _ = try mt.delete("hello"); // tombstone: subtract value (3)
    try std.testing.expectEqual(@as(usize, 5), mt.sizeBytes()); // just key
}