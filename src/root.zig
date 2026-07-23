//! cube_db — 嵌入式 KV 引擎库入口
const std = @import("std");

pub const format = @import("format.zig");
pub const store = @import("store.zig");
pub const btree = @import("btree.zig");
pub const btree_batch = @import("btree_batch.zig");
pub const file_store = @import("file_store.zig");
pub const writer = @import("writer.zig");
pub const db = @import("db.zig");
pub const fault_store = @import("fault_store.zig");

pub const Header = format.Header;
pub const Options = db.Options;
pub const Db = db.Db;

// ponytail: add 保留导出，后续 db.zig 落地后替换
pub fn add(a: i32, b: i32) i32 {
    return a + b;
}

test {
    std.testing.refAllDecls(@This());
}
