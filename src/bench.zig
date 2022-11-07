const std = @import("std");
const Allocator = std.mem.Allocator;
const MeshAllocator = @import("mesh.zig").MeshAllocator;

const benchmark = @import("@benchmark");

pub const Alloc = enum {
    gpa,
    mesh,
};

pub fn main() !void {
    var args = std.process.args();
    _ = args.next();
    var count: ?usize = null;
    if (args.next()) |arg| {
        count = try std.fmt.parseInt(usize, arg, 10);
    }

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    switch (comptime benchmark.allocator) {
        .gpa => try @field(benchmarks, benchmark.name)(gpa.allocator()),
        .mesh => {
            var mesher = try MeshAllocator(.{}).init(gpa.allocator());
            try @field(benchmarks, benchmark.name)(mesher.allocator());
        },
    }
}

const KiB = 1024;
const MiB = 1024 * KiB;
const GiB = 1024 * MiB;
pub const benchmarks = .{
    .@"many-u32-16KiB" = benchmarkSize(@sizeOf(u32), 16 * KiB),
    .@"many-u32-32KiB" = benchmarkSize(@sizeOf(u32), 32 * KiB),
    .@"many-u32-64KiB" = benchmarkSize(@sizeOf(u32), 64 * KiB),
    .@"many-u32-128KiB" = benchmarkSize(@sizeOf(u32), 128 * KiB),
    .@"many-u32-256KiB" = benchmarkSize(@sizeOf(u32), 256 * KiB),
    .@"many-u32-512KiB" = benchmarkSize(@sizeOf(u32), 512 * KiB),
};

pub const Benchmark = fn (Allocator) Allocator.Error!void;

pub fn benchmarkLargeBlock(comptime T: type, comptime max_size: usize) Benchmark {
    const count = max_size / @sizeOf(T);
    const s = struct {
        fn f(allocator: Allocator) Allocator.Error!void {
            var buf = try allocator.alloc(T, count);
            allocator.free(buf);
        }
    };
    return s.f;
}

pub fn benchmarkSize(comptime size: usize, comptime max_size: usize) Benchmark {
    return benchmarkMultiSize(&[1]usize{size}, max_size);
}

pub fn benchmarkMultiSize(comptime sizes: []const usize, comptime max_size: usize) Benchmark {
    const sizes_sum = comptime sizes_sum: {
        var sum = 0;
        for (sizes) |size| {
            sum += size;
        }
        break :sizes_sum sum;
    };

    const iterations = max_size / sizes_sum;
    const s = struct {
        fn f(allocator: Allocator) Allocator.Error!void {
            var pointers: [iterations][sizes.len]*anyopaque = undefined;
            var i: usize = 0;
            while (i < iterations) : (i += 1) {
                inline for (sizes) |size, sz| {
                    pointers[i][sz] = try allocator.create([size]u8);
                }
            }
            i = 0;
            while (i < iterations) : (i += 1) {
                inline for (sizes) |size, sz| {
                    allocator.destroy(@ptrCast(*[size]u8, pointers[i][sz]));
                }
            }
        }
    };
    return s.f;
}

pub fn benchmarkSizeTransposedDestroy(comptime size: usize, comptime max_size: usize) Benchmark {
    return benchmarkMultiSizeTransposedDestroy(&[1]usize{size}, max_size);
}

pub fn benchmarkMultiSizeTransposedDestroy(
    comptime sizes: []const usize,
    comptime max_size: usize,
) !Benchmark {
    const sizes_sum = comptime sizes_sum: {
        var sum = 0;
        for (sizes) |size| {
            sum += size;
        }
        break :sizes_sum sum;
    };

    const iterations = max_size / sizes_sum;
    const s = struct {
        fn f(allocator: Allocator) Allocator.Error!void {
            var pointers: [iterations][sizes.len]*anyopaque = undefined;
            var i: usize = 0;
            while (i < iterations) : (i += 1) {
                inline for (sizes) |size, sz| {
                    pointers[i][sz] = try allocator.create([size]u8);
                }
            }
            i = 0;
            inline for (sizes) |size, sz| {
                while (i < iterations) : (i += 1) {
                    allocator.destroy(@ptrCast(*[size]u8, pointers[i][sz]));
                }
            }
        }
    };
    return s.f;
}
