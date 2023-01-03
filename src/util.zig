const std = @import("std");

pub const assert = std.debug.assert;

pub fn waitForInput() void {
    const stdin = std.io.getStdIn().reader();
    var buf: [64]u8 = undefined;
    _ = stdin.readUntilDelimiter(&buf, '\n') catch return;
}

pub fn fileDescriptorCount() !usize {
    var dir = try std.fs.openIterableDirAbsolute("/proc/self/fd", .{});
    defer dir.close();
    var iter = dir.iterateAssumeFirstIteration();
    var count: usize = 0;
    while (try iter.next()) |_| {
        count += 1;
    }
    return count;
}
