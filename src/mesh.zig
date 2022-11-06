// TODO: first make a mesh allocator for a fixed slot size, i.e. a pool/object allocator that does meshing
//       Then reuse that code to make a GPA that has mesh allocators for different sizes
const std = @import("std");
const Allocator = std.mem.Allocator;

const PoolAllocator = @import("pool_allocator.zig").PoolAllocator;

const log = std.log.scoped(.MeshAllocator);

pub const Config = struct {
    size_classes: []const usize = &.{
        16,
        32,
        48,
        64,
        80,
        96,
        112,
        128,
        160,
        192,
        224,
        256,
        320,
        384,
        448,
        512,
    },
    // use enough pages for 64GiB by default
    pool_page_count: usize = @divExact(64 * 1024 * 1024 * 1024, std.mem.page_size),
};

pub fn MeshAllocator(comptime config: Config) type {
    const size_classes = config.size_classes;

    comptime {
        for (size_classes[0 .. size_classes.len - 2]) |s, i| {
            if (s >= size_classes[i + 1]) @compileError("Size classes must be strictly increasing");
        }
    }

    comptime var max_size = 0;
    const pool_type_map = map: {
        var map: [size_classes.len]type = undefined;
        for (map) |*t, i| {
            const T = PoolAllocator(size_classes[i]);
            t.* = T;
            max_size = @max(max_size, @sizeOf(T));
        }
        break :map map;
    };

    const Pools = Pools: {
        var fields: [size_classes.len]std.builtin.Type.StructField = undefined;
        for (fields) |*field, i| {
            const T = PoolAllocator(size_classes[i]);
            field.* = .{
                .name = std.fmt.comptimePrint("{d}", .{i}),
                .field_type = T,
                .default_value = null,
                .alignment = if (@sizeOf(T) > 0) @alignOf(T) else 0,
                .is_comptime = false,
            };
        }
        break :Pools @Type(.{
            .Struct = .{
                .layout = .Auto,
                .fields = &fields,
                .decls = &[0]std.builtin.Type.Declaration{},
                .is_tuple = true,
            },
        });
    };

    return struct {
        const Self = @This();

        pools: Pools,

        pub fn init(node_allocator: Allocator) !Self {
            var pools: Pools = undefined;
            inline for (pools) |*pool, i| {
                pool.* = try @TypeOf(pool.*).init(node_allocator, i, config.pool_page_count);
            }

            return Self{
                .pools = pools,
            };
        }

        pub fn deinit(self: *Self) void {
            inline for (self.pools) |*pool| {
                pool.deinit();
            }
        }

        fn poolIndexForSize(size: usize) ?usize {
            for (size_classes) |s, i| {
                if (size <= s) return i;
            }
            return null;
        }

        pub fn allocator(self: *Self) Allocator {
            return Allocator.init(self, alloc, resize, free);
        }

        fn alloc(
            self: *Self,
            len: usize,
            ptr_align: u29,
            len_align: u29,
            ret_addr: usize,
        ) Allocator.Error![]u8 {
            // TODO: handle requested pointer and length alignment
            _ = ret_addr;
            inline for (size_classes) |size, index| {
                if (len <= size and ptr_align <= size) {
                    const aligned_len = std.mem.alignAllocLen(size, len, len_align);
                    const pool = @ptrCast(*pool_type_map[index], &self.pools[index]);
                    log.debug("creating allocation of size {d} in pool {d}", .{ len, pool.slot_size });
                    const slot = try pool.allocSlot();
                    return std.mem.span(slot)[0..aligned_len];
                }
            }
            return error.OutOfMemory;
        }

        fn resize(
            self: *Self,
            buf: []u8,
            buf_align: u29,
            new_len: usize,
            len_align: u29,
            ret_addr: usize,
        ) ?usize {
            _ = buf_align;
            _ = ret_addr;

            inline for (self.pools) |*pool| {
                if (pool.ownsPtr(buf.ptr)) {
                    log.debug("pool {d} owns the allocation to be resized", .{pool.slot_size});
                    return if (pool.slot_size < new_len)
                        null
                    else if (len_align == 0)
                        new_len
                    else
                        pool.slot_size;
                }
            }
            unreachable;
        }

        fn free(self: *Self, buf: []u8, buf_align: u29, ret_addr: usize) void {
            _ = buf_align;
            _ = ret_addr;

            inline for (self.pools) |*pool| {
                if (pool.ownsPtr(buf.ptr)) {
                    log.debug("pool {d} owns the pointer to be freed", .{pool.slot_size});
                    const slot = @ptrCast(*[pool.slot_size]u8, buf.ptr);
                    pool.freeSlot(slot);
                    return;
                }
            }
            unreachable;
        }
    };
}

test {
    const config = Config{};
    var mesher = try MeshAllocator(config).init(std.testing.allocator);
    defer mesher.deinit();
    const allocator = mesher.allocator();
    for (config.size_classes) |size| {
        {
            var buf = try allocator.alloc(u8, size - 14);
            std.testing.expect(allocator.resize(buf, size) != null) catch |err| {
                std.debug.print("\nfailed to resize up for size class {d}\n", .{size});
                return err;
            };
            std.testing.expect(allocator.resize(buf, size / 4) != null) catch |err| {
                std.debug.print("\nfailed to resize down for size class {d}\n", .{size});
                return err;
            };
            std.testing.expectEqual(@as(?[]u8, null), allocator.resize(buf, size + 1)) catch |err| {
                std.debug.print("\nerroneously resized to size {d} for size class {d}\n", .{ size + 1, size });
                return err;
            };
            allocator.free(buf);
        }
    }
}

// test "MeshAllocator: validate len_align" {
//     var mesher = MeshAllocator(.{}).init(std.testing.allocator);
//     var validator = std.mem.validationWrap(mesher);
//     const allocator = validator.allocator();
//     var slice = try allocator.alloc(u64, 3);
//     allocator.free(slice);
// }
