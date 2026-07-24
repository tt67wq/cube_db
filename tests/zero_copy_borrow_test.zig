//! T3 RED: Store.readBorrow 借用切片（不 alloc 不 memcpy，指向 mmap/ArrayList）。
//! 旧实现无 readBorrow → 编译错；GREEN 加 vtable + 实现。
const std = @import("std");
const zio = @import("zio");
const cube = @import("cube_db");
const store_mod = cube.store;

test "T3: MemStore.readBorrow returns borrowed slice equal to appended" {
    var ms = store_mod.MemStore.init(std.testing.allocator);
    defer ms.deinit();
    const s = ms.store();
    const data = "borrowed-slice-data";
    const off = try s.append(data);
    const got = try s.readBorrow(off, data.len);
    try std.testing.expectEqualStrings(data, got);
}

test "T3: MemStore.readBorrow bounds — offset==size returns empty" {
    var ms = store_mod.MemStore.init(std.testing.allocator);
    defer ms.deinit();
    const s = ms.store();
    _ = try s.append("abc");
    const size = try s.size();
    const got = try s.readBorrow(size, 10);
    try std.testing.expectEqual(@as(usize, 0), got.len);
}

test "T3: FileStore.readBorrow returns borrowed mmap slice" {
    const path = "t3_borrow_filestore.db";
    const cwd = zio.Dir.cwd();
    cwd.deleteFile(path) catch {};
    defer cwd.deleteFile(path) catch {};
    var fs = try cube.file_store.FileStore.create(std.testing.allocator, path);
    defer fs.close();
    const s = fs.store();
    const data = "file-borrowed-slice";
    const off = try s.append(data);
    const got = try s.readBorrow(off, data.len);
    try std.testing.expectEqualStrings(data, got);
}
