// TODO: first make a mesh allocator for a fixed slot size, i.e. a pool/object allocator that does meshing
//       Then reuse that code to make a GPA that has mesh allocators for different sizes
const std = @import("std");
const Allocator = std.mem.Allocator;

const PoolAllocator = @import("pool_allocator.zig").PoolAllocator;

pub const Config = struct {
    size_classes: []const usize = &.{
        16,
        32,
        48,
        64,
        90,
        106,
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

        pub fn init(node_allocator: Allocator) Self {
            var pools: Pools = undefined;
            inline for (pools) |*pool, i| {
                pool.* = @TypeOf(pool.*).init(node_allocator, i);
            }

            return Self{
                .pools = pools,
            };
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
            std.debug.assert(ptr_align == 0);
            std.debug.assert(len_align == 0);
            std.debug.assert(ret_addr == 0);
            inline for (size_classes) |size, index| {
                if (len <= size) {
                    const pool = @ptrCast(*pool_type_map[index], &self.pools[index]);
                    const slot = pool.allocSlot() orelse return error.OutOfMemory;
                    return std.mem.span(slot);
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
            std.debug.assert(buf_align == 0);
            std.debug.assert(ret_addr == 0);

            inline for (self.pools) |*pool| {
                if (pool.ownsPtr(buf.ptr)) {
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
            std.debug.assert(buf_align == 0);
            std.debug.assert(ret_addr == 0);

            inline for (self.pools) |*pool| {
                if (pool.ownsPtr(buf.ptr)) {
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
    var a = MeshAllocator(.{}).init(std.testing.allocator);
    var buf = try a.alloc(8, 0, 0, 0);
    try std.testing.expectEqual(@as(?usize, 16), a.resize(buf, 0, 16, 0, 0));
    try std.testing.expectEqual(@as(?usize, null), a.resize(buf, 0, 17, 0, 0));
    a.free(buf, 0, 0);
}
