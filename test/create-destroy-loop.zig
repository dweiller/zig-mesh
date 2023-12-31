const std = @import("std");
const build_options = @import("build_options");
const mesh = @import("mesh");

pub fn main() !void {
    var mesher = mesh.Allocator.init(.{});
    defer mesher.deinit();

    const allocator = mesher.allocator();

    if (comptime build_options.pauses) {
        std.debug.print("hit [enter] to enter loop\n", .{});
        waitForInput();
    }

    inline for (.{ 1, 2, 3, 4 }) |_| {
        var buf: [50000]*[256]u8 = undefined; // pointers to 12 MiB of data

        for (&buf) |*ptr| {
            const b = try allocator.create([256]u8);
            b.* = [1]u8{1} ** 256;
            ptr.* = b;
        }

        if (comptime build_options.pauses) {
            std.debug.print("memory allocated\n", .{});
            waitForInput();
            std.debug.print("freeing memory\n", .{});
        }

        for (buf) |ptr| {
            allocator.destroy(ptr);
        }
        if (comptime build_options.pauses) {
            std.debug.print("memory freed\n", .{});
            waitForInput();
        }
    }
}

fn waitForInput() void {
    const stdin = std.io.getStdIn().reader();
    var buf: [64]u8 = undefined;
    _ = stdin.readUntilDelimiter(&buf, '\n') catch return;
}
