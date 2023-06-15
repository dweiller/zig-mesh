const std = @import("std");
const Allocator = std.mem.Allocator;
const MeshAllocator = @import("mesh.zig").Allocator;

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

    switch (comptime benchmark.allocator) {
        .gpa => {
            var gpa = std.heap.GeneralPurposeAllocator(.{}){};
            try callBenchmark(benchmark.name, benchmark.subname, gpa.allocator());
        },
        .mesh => {
            var mesher = MeshAllocator.init(.{});
            try callBenchmark(benchmark.name, benchmark.subname, mesher.allocator());
        },
    }
}

fn callBenchmark(comptime field: []const u8, comptime sub_field: []const u8, allocator: Allocator) !void {
    try @field(@field(benchmarks, field), sub_field)(allocator);
}

const KiB = 1024;
const MiB = 1024 * KiB;
const GiB = 1024 * MiB;
pub const benchmarks = .{
    .many = .{
        .@"u32-16KiB" = benchmarkSize(@sizeOf(u32), 16 * KiB),
        .@"u32-32KiB" = benchmarkSize(@sizeOf(u32), 32 * KiB),
        .@"u32-64KiB" = benchmarkSize(@sizeOf(u32), 64 * KiB),
        .@"u32-128KiB" = benchmarkSize(@sizeOf(u32), 128 * KiB),
        .@"u32-256KiB" = benchmarkSize(@sizeOf(u32), 256 * KiB),
        .@"u32-512KiB" = benchmarkSize(@sizeOf(u32), 512 * KiB),
    },
    .@"many-transposed" = .{
        .@"u32-16KiB" = benchmarkSizeTransposedDestroy(@sizeOf(u32), 16 * KiB),
        .@"u32-32KiB" = benchmarkSizeTransposedDestroy(@sizeOf(u32), 32 * KiB),
        .@"u32-64KiB" = benchmarkSizeTransposedDestroy(@sizeOf(u32), 64 * KiB),
        .@"u32-128KiB" = benchmarkSizeTransposedDestroy(@sizeOf(u32), 128 * KiB),
        .@"u32-256KiB" = benchmarkSizeTransposedDestroy(@sizeOf(u32), 256 * KiB),
        .@"u32-512KiB" = benchmarkSizeTransposedDestroy(@sizeOf(u32), 512 * KiB),
    },
    .@"large-block" = .{
        .@"16KiB" = benchmarkLargeBlock(u8, 16 * KiB),
        .@"512KiB" = benchmarkLargeBlock(u8, 512 * KiB),
    },
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
            for (0..iterations) |i| {
                inline for (&pointers[i], sizes) |*p, size| {
                    p.* = try allocator.create([size]u8);
                }
            }
            for (0..iterations) |i| {
                inline for (pointers[i], sizes) |p, size| {
                    allocator.destroy(@ptrCast(*[size]u8, p));
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
) Benchmark {
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
            for (0..iterations) |i| {
                inline for (&pointers[i], sizes) |*p, size| {
                    p.* = try allocator.create([size]u8);
                }
            }
            inline for (sizes, 0..) |size, sz| {
                for (pointers) |p| {
                    allocator.destroy(@ptrCast(*[size]u8, p[sz]));
                }
            }
        }
    };
    return s.f;
}
