const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [256]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    try stdout_writer.interface.writeAll("zig-pkl 0.0.0\nmessage codes 0x20-0x32\npkl-binary values\n");
    try stdout_writer.interface.flush();
}
