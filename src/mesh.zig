// TODO: first make a mesh allocator for a fixed slot size, i.e. a pool/object allocator that does meshing
//       Then reuse that code to make a GPA that has mesh allocators for different sizes
const std = @import("std");

const MeshingPool = @import("MeshingPool.zig").MeshingPool(.{ .debug_checks = false });

const log = std.log.scoped(.MeshAllocator);

const assert = @import("util.zig").assert;

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
};

const max_num_size_classes = 32;

pub const Allocator = @This();

num_size_classes: usize,
size_classes: [max_num_size_classes]u16,
pools: [max_num_size_classes]MeshingPool,
large_allocations: LargeAllocTable = .{},

const LargeAlloc = struct {
    bytes: []u8,
};

const LargeAllocTable = std.AutoHashMapUnmanaged(usize, LargeAlloc);

pub fn init(config: Config) Allocator {
    assert(std.sort.isSorted(usize, config.size_classes, {}, std.sort.asc(usize)));
    assert(config.size_classes.len < max_num_size_classes);

    var size_classes: [max_num_size_classes]u16 = undefined;
    for (size_classes[0..config.size_classes.len], config.size_classes) |*sc, size| {
        sc.* = @intCast(size);
    }

    var pools: [max_num_size_classes]MeshingPool = undefined;
    for (pools[0..config.size_classes.len], config.size_classes) |*p, size| {
        p.* = MeshingPool.init(size);
    }

    return Allocator{
        .num_size_classes = config.size_classes.len,
        .size_classes = size_classes,
        .pools = pools,
    };
}

pub fn deinit(self: *Allocator) void {
    for (self.pools[0..self.num_size_classes]) |*pool| {
        pool.deinit();
    }
}

fn sizeClassIndex(self: Allocator, size: usize) usize {
    for (self.size_classes[0..self.num_size_classes], 0..) |s, i| {
        if (size <= s) return i;
    }
}

pub fn allocator(self: *Allocator) std.mem.Allocator {
    return .{
        .ptr = self,
        .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .free = free,
        },
    };
}

fn maxOffset(size: usize, alignment: usize) usize {
    const gcd = std.math.gcd(size, alignment);
    return alignment - gcd;
}

fn alloc(ctx: *anyopaque, len: usize, log2_ptr_align: u8, ret_addr: usize) ?[*]u8 {
    const self: *Allocator = @ptrCast(@alignCast(ctx));
    const alignment = @as(usize, 1) << @as(std.mem.Allocator.Log2Align, @intCast(log2_ptr_align));
    for (self.size_classes[0..self.num_size_classes], 0..) |size, index| {
        if (len <= size and maxOffset(size, alignment) + len <= size) {
            const pool = &self.pools[index];
            const slot = pool.allocSlot() orelse return null;
            log.debug(
                "allocation of size {d} in pool {d} (slot size {d}) created in slot {d} at address {*}",
                .{ len, index, size, pool.owningSlab(slot.ptr).?.indexOf(slot.ptr), slot },
            );
            return std.mem.alignPointer(slot.ptr, alignment) orelse unreachable;
        }
    }

    self.large_allocations.ensureUnusedCapacity(std.heap.page_allocator, 1) catch return null;
    if (std.heap.page_allocator.rawAlloc(len, log2_ptr_align, ret_addr)) |ptr| {
        log.debug("creating large allocation of size {d} at {*}", .{ len, ptr });
        self.large_allocations.putAssumeCapacity(@intFromPtr(ptr), .{ .bytes = ptr[0..len] });
        return ptr;
    } else {
        return null;
    }
}

fn resize(ctx: *anyopaque, buf: []u8, log2_buf_align: u8, new_len: usize, ret_addr: usize) bool {
    const self: *Allocator = @ptrCast(@alignCast(ctx));
    for (self.pools[0..self.num_size_classes], 0..) |*pool, index| {
        if (pool.owningSlab(buf.ptr)) |slab| {
            log.debug("pool {d} (slot size {d}) owns the allocation to be resized", .{ index, pool.slot_size });
            const slot_index = slab.indexOf(buf.ptr);
            const new_last_ptr = buf.ptr + new_len - 1;
            return slab.isInSlot(new_last_ptr, slot_index);
        }
    }
    // must be a large allocation
    log.debug("resizing large allocation at {*}", .{buf.ptr});
    const entry = self.large_allocations.getEntry(@intFromPtr(buf.ptr)) orelse unreachable;
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
    const self: *Allocator = @ptrCast(@alignCast(ctx));
    for (self.pools[0..self.num_size_classes], 0..) |*pool, index| {
        if (pool.owningSlab(buf.ptr)) |slab| {
            log.debug("slab at {*} in pool {d} (slot size {d}) owns the pointer to be freed", .{ slab, index, pool.slot_size });
            pool.freeSlotInSlab(buf.ptr, slab);
            return;
        }
    }
    // must be a large allocation
    log.debug("freeing large allocation at {*}", .{buf.ptr});
    std.heap.page_allocator.rawFree(buf, log2_buf_align, ret_addr);
    assert(self.large_allocations.remove(@intFromPtr(buf.ptr)));
}

test "each allocation type" {
    const config = Config{};
    var mesher = Allocator.init(config);
    defer mesher.deinit();
    const a = mesher.allocator();
    for (config.size_classes) |size| {
        {
            var buf = try a.alloc(u8, size - 14);
            std.testing.expect(a.resize(buf, size)) catch |err| {
                std.debug.print("\nfailed to resize up for size class {d}\n", .{size});
                return err;
            };
            buf.len = size;
            std.testing.expect(a.resize(buf, size / 4)) catch |err| {
                std.debug.print("\nfailed to resize down for size class {d}\n", .{size});
                return err;
            };
            buf.len = size / 4;
            std.testing.expect(!a.resize(buf, size + 1)) catch |err| {
                std.debug.print("\nerroneously resized to size {d} for size class {d}\n", .{ size + 1, size });
                return err;
            };
            a.free(buf);
        }
    }
    // large allocation
    const page_size = std.mem.page_size;
    const inital_size = (3 * page_size) / 2;
    const max_size = 2 * page_size;
    const small_size = page_size / 2;
    var buf = try a.alloc(u8, inital_size);
    std.testing.expect(a.resize(buf, max_size)) catch |err| {
        std.debug.print("\nfailed to resize large allocation up to {d}\n", .{max_size});
        return err;
    };
    buf.len = max_size;
    std.testing.expect(a.resize(buf, small_size)) catch |err| {
        std.debug.print("\nfailed to resize large allocation down to {d}\n", .{small_size});
        return err;
    };
    buf.len = small_size;
    std.testing.expect(!a.resize(buf, max_size + 1)) catch |err| {
        std.debug.print("\nerroneously resized large allocation to size {d} (max should be {d})\n", .{ max_size + 1, max_size });
        return err;
    };
    a.free(buf);
}

test "create/destroy loop" {
    const config = Config{};
    var mesher = Allocator.init(config);
    defer mesher.deinit();
    const a = mesher.allocator();

    for (0..1000) |i| {
        log.debug("iteration {d}", .{i});
        var ptr = try a.create(u32);
        a.destroy(ptr);
    }
}
