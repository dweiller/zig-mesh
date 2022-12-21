const std = @import("std");
const build_options = @import("build_options");
const MeshAlllocator = @import("mesh").MeshAllocator;

pub fn main() !void {
    var meta_alloc = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = meta_alloc.deinit();
    var mesher = try MeshAlllocator.init(.{});
    defer mesher.deinit();

    const allocator = mesher.allocator();

    inline for (.{ 1, 2, 3, 4 }) |_| {
        var buf: [50000]*[256]u8 = undefined;

        for (buf) |*ptr| {
            const b = try allocator.create([256]u8);
            b.* = std.mem.zeroes([256]u8);
            ptr.* = b;
        }

        if (comptime build_options.pauses) {
            std.debug.print("memory allocated\n", .{});
            std.time.sleep(3 * std.time.ns_per_s);
            std.debug.print("freeing memory\n", .{});
        }

        for (buf) |ptr| {
            allocator.destroy(ptr);
        }
        if (comptime build_options.pauses) {
            std.debug.print("memory freed\n", .{});
            std.time.sleep(3 * std.time.ns_per_s);
        }
    }
}
