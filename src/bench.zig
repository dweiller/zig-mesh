const std = @import("std");
const PoolAllocator = @import("mesh.zig").PoolAllocator;

pub fn main() !void {
    var args = std.process.args();
    _ = args.next();
    var count: usize = 100;
    if (args.next()) |arg| {
        count = try std.fmt.parseInt(usize, arg, 10);
    }

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const Pool = PoolAllocator(16);
    var pool = Pool.init(arena.allocator(), 0);
    defer pool.deinit();

    @import("mesh.zig").benchmarkPoolAllocatorAllocSlot(&pool, count);
}

