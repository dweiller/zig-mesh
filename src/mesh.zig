// TODO: first make a mesh allocator for a fixed slot size, i.e. a pool/object allocator that does meshing
//       Then reuse that code to make a GPA that has mesh allocators for different sizes
const std = @import("std");
const Allocator = std.mem.Allocator;

const MeshingPool = @import("page_pool.zig").MeshingPool;

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
            const T = MeshingPool(size_classes[i]);
            t.* = T;
            max_size = @max(max_size, @sizeOf(T));
        }
        break :map map;
    };

    const Pools = Pools: {
        var fields: [size_classes.len]std.builtin.Type.StructField = undefined;
        for (fields) |*field, i| {
            const T = MeshingPool(size_classes[i]);
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
        large_allocations: LargeAllocTable = .{},

        const LargeAlloc = struct {
            bytes: []u8,
        };

        const LargeAllocTable = std.AutoHashMapUnmanaged(usize, LargeAlloc);

        pub fn init() !Self {
            var pools: Pools = undefined;
            inline for (pools) |*pool, i| {
                pool.* = try @TypeOf(pool.*).init(i, config.pool_page_count);
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
            return .{
                .ptr = self,
                .vtable = &.{
                    .alloc = alloc,
                    .resize = resize,
                    .free = free,
                },
            };
        }

        inline fn maxOffset(size: usize, alignment: usize) usize {
            const gcd = std.math.gcd(size, alignment);
            return alignment - gcd;
        }

        fn alloc(
            ctx: *anyopaque,
            len: usize,
            log2_ptr_align: u8,
            ret_addr: usize,
        ) ?[*]u8 {
            const self = @ptrCast(*Self, @alignCast(@alignOf(Self), ctx));
            // TODO: handle requested pointer and length alignment
            const alignment = @as(usize, 1) << @intCast(std.mem.Allocator.Log2Align, log2_ptr_align);
            inline for (size_classes) |size, index| {
                if (len <= size and alignment <= size) {
                    const max_offset = maxOffset(size, alignment);
                    if (max_offset + len <= size) {
                        const pool = @ptrCast(*pool_type_map[index], &self.pools[index]);
                        const slot = pool.allocSlot() catch return null;
                        log.debug("allocation of size {d} in pool {d} created in slot at {*}", .{ len, pool.slot_size, slot });
                        return std.mem.alignPointer(@as([*]u8, slot), alignment) orelse unreachable;
                    }
                }
            }

            self.large_allocations.ensureUnusedCapacity(std.heap.page_allocator, 1) catch return null;
            if (std.heap.page_allocator.rawAlloc(len, log2_ptr_align, ret_addr)) |ptr| {
                log.debug("creating large allocation of size {d} at {*}", .{ len, ptr });
                self.large_allocations.putAssumeCapacity(@ptrToInt(ptr), .{ .bytes = ptr[0..len] });
                return ptr;
            } else {
                return null;
            }
        }

        fn resize(
            ctx: *anyopaque,
            buf: []u8,
            log2_buf_align: u8,
            new_len: usize,
            ret_addr: usize,
        ) bool {
            const self = @ptrCast(*Self, @alignCast(@alignOf(Self), ctx));
            inline for (self.pools) |*pool| {
                if (pool.ownsPtr(buf.ptr)) {
                    log.debug("pool {d} owns the allocation to be resized", .{pool.slot_size});
                    const page_offset = @ptrToInt(buf.ptr) % std.mem.page_size;
                    const slot_index = page_offset / pool.slot_size;
                    const new_end_index = (page_offset + new_len - 1) / pool.slot_size;

                    return if (new_end_index != slot_index)
                        false
                    else
                        true;
                }
            }
            // must be a large allocation
            log.debug("resizing large allocation at {*}", .{buf.ptr});
            const entry = self.large_allocations.getEntry(@ptrToInt(buf.ptr)) orelse unreachable;
            if (std.heap.page_allocator.rawResize(
                buf,
                log2_buf_align,
                new_len,
                ret_addr,
            )) {
                entry.value_ptr.bytes = buf.ptr[0..new_len];
                return true;
            } else return false;
        }

        fn free(ctx: *anyopaque, buf: []u8, log2_buf_align: u8, ret_addr: usize) void {
            const self = @ptrCast(*Self, @alignCast(@alignOf(Self), ctx));
            inline for (self.pools) |*pool| {
                if (pool.ownsPtr(buf.ptr)) {
                    log.debug("pool {d} owns the pointer to be freed", .{pool.slot_size});
                    const slot = @ptrCast(*[pool.slot_size]u8, buf.ptr);
                    pool.freeSlot(slot);
                    return;
                }
            }
            // must be a large allocation
            log.debug("freeing large allocation at {*}", .{buf.ptr});
            std.heap.page_allocator.rawFree(buf, log2_buf_align, ret_addr);
            std.debug.assert(self.large_allocations.remove(@ptrToInt(buf.ptr)));
        }
    };
}

test "each allocation type" {
    const config = Config{};
    var mesher = try MeshAllocator(config).init();
    defer mesher.deinit();
    const allocator = mesher.allocator();
    for (config.size_classes) |size| {
        {
            var buf = try allocator.alloc(u8, size - 14);
            std.testing.expect(allocator.resize(buf, size)) catch |err| {
                std.debug.print("\nfailed to resize up for size class {d}\n", .{size});
                return err;
            };
            buf.len = size;
            std.testing.expect(allocator.resize(buf, size / 4)) catch |err| {
                std.debug.print("\nfailed to resize down for size class {d}\n", .{size});
                return err;
            };
            buf.len = size / 4;
            std.testing.expect(!allocator.resize(buf, size + 1)) catch |err| {
                std.debug.print("\nerroneously resized to size {d} for size class {d}\n", .{ size + 1, size });
                return err;
            };
            allocator.free(buf);
        }
    }
    // large allocation
    const page_size = std.mem.page_size;
    const inital_size = (3 * page_size) / 2;
    const max_size = 2 * page_size;
    const small_size = page_size / 2;
    var buf = try allocator.alloc(u8, inital_size);
    std.testing.expect(allocator.resize(buf, max_size)) catch |err| {
        std.debug.print("\nfailed to resize large allocation up to {d}\n", .{max_size});
        return err;
    };
    buf.len = max_size;
    std.testing.expect(allocator.resize(buf, small_size)) catch |err| {
        std.debug.print("\nfailed to resize large allocation down to {d}\n", .{small_size});
        return err;
    };
    buf.len = small_size;
    std.testing.expect(!allocator.resize(buf, max_size + 1)) catch |err| {
        std.debug.print("\nerroneously resized large allocation to size {d} (max should be {d})\n", .{ max_size + 1, max_size });
        return err;
    };
    allocator.free(buf);
}

test "create/destroy loop" {
    const config = Config{};
    var mesher = try MeshAllocator(config).init();
    defer mesher.deinit();
    const allocator = mesher.allocator();

    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        log.debug("iteration {d}", .{i});
        var ptr = try allocator.create(u32);
        allocator.destroy(ptr);
    }
}

// test "MeshAllocator: validate len_align" {
//     var mesher = MeshAllocator(.{}).init(std.testing.allocator);
//     var validator = std.mem.validationWrap(mesher);
//     const allocator = validator.allocator();
//     var slice = try allocator.alloc(u64, 3);
//     allocator.free(slice);
// }
