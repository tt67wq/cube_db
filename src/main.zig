const std = @import("std");
const Io = std.Io;

const cube_db = @import("cube_db");

pub fn main(init: std.process.Init) !void {
    std.debug.print("cube_db — embedded KV engine. See docs/DESIGN.md.\n", .{});

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;
    try stdout_writer.writeAll("build ok\n");
    try stdout_writer.flush();
}

test "main: sanity" {
    _ = cube_db;
}
