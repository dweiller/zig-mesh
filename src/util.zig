const std = @import("std");

pub const assert = std.debug.assert;

pub fn waitForInput() void {
    const stdin = std.io.getStdIn().reader();
    var buf: [64]u8 = undefined;
    _ = stdin.readUntilDelimiter(&buf, '\n') catch return;
}

