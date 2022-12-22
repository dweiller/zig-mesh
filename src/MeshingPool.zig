//! A `MeshingPool` is a pool of memory for allocations of a specific size class
//! that utilises memory mapping techniques to compact memory by merging pages
//! with allocations in non-overlapping slots. Each `MeshingPool` contains a
//! number of `Slab`s and page merging is done only within a a single pool.
//!
//! The slot size is always a multiple of 16, though it need not be a power of
//! 2; if a slot size that is not a multiple of 16 is passed to `init`, it will
//! be rounded up.

const std = @import("std");

const params = @import("params.zig");

const Slab = @import("Slab.zig");
const Span = @import("Span.zig");

const PagePtr = [*]align(page_size) u8;

const page_size = std.mem.page_size;

const log = std.log.scoped(.MeshingPool);

const assert = @import("mesh.zig").assert;

const MeshingPool = @This();

first_slab: Slab.Ptr,
slot_size: u16,
rng: std.rand.DefaultPrng,

pub fn init(slot_size: usize) !MeshingPool {
    return initSeeded(slot_size, 0);
}

pub fn initSeeded(slot_size: usize, seed: u64) !MeshingPool {
    params.assertSlotSizeValid(slot_size);
    var rng = std.rand.DefaultPrng.init(seed);
    var slab = try Slab.init(rng.random(), slot_size, params.page_count_max);
    return MeshingPool{
        .first_slab = slab,
        .slot_size = @intCast(u16, slot_size),
        .rng = rng,
    };
}

pub fn deinit(self: *MeshingPool) void {
    const first_slab = self.first_slab;
    var slab = self.first_slab;
    while (true) {
        const next = slab.next;
        slab.deinit();
        if (next == first_slab) break;
        slab = next;
    }
    self.* = undefined;
}

pub fn allocSlot(self: *MeshingPool) ?[]u8 {
    const slab = self.first_slab;
    if (slab.allocSlot()) |slot| return slot;
    log.debug("Current slab at {*} is full, finding alternate slab", .{slab});
    // need to find a new Slab to allocate from
    var next = slab.next;
    while (next != slab) : (next = next.next) {
        log.debug("checking slab at {*}\n", .{next});
        if (next.allocSlot()) |slot| {
            self.first_slab = next;
            return slot;
        }
    }
    log.debug("All slabs full, allocating new slab", .{});
    // no existing slab has space, allocate a new one
    var new_slab = Slab.init(self.rng.random(), self.slot_size, params.page_count_max) catch return null;
    new_slab.next = slab;
    new_slab.prev = slab.prev;

    new_slab.prev.next = new_slab;
    slab.prev = new_slab;

    self.first_slab = new_slab;
    return new_slab.allocSlot() orelse unreachable; // not possible for fresh slab to fail allocating
}

pub fn freeSlot(self: *MeshingPool, ptr: *anyopaque) void {
    assert(self.ownsPtr(ptr));
    const slab = self.owningSlab(ptr) orelse unreachable;
    slab.freeSlot(self.rng.random(), slab.indexOf(ptr));
}

pub fn owningSlab(self: MeshingPool, ptr: *anyopaque) ?Slab.Ptr {
    const first = self.first_slab;
    if (first.ownsPtr(ptr)) return first;

    var slab = first.next;
    while (slab != first) : (slab = slab.next) {
        if (slab.ownsPtr(ptr)) return slab;
    }

    return null;
}

pub fn ownsPtr(self: MeshingPool, ptr: *anyopaque) bool {
    const first = self.first_slab;
    if (first.ownsPtr(ptr)) return true;

    var slab = first.next;
    while (slab != first) : (slab = slab.next) {
        if (slab.ownsPtr(ptr)) return true;
    }

    return false;
}

const SlabPage = struct {
    slab: Slab.Ptr,
    page: Slab.PageIndex,
};

fn canMesh(slab_page1: SlabPage, slab_page2: SlabPage) bool {
    const page1_bitset = slab_page1.slab.bitset(slab_page1.page);
    const page2_bitset = slab_page2.slab.bitset(slab_page2.page);
    const bitsize = @bitSizeOf(std.DynamicBitSet.MaskInt);
    const num_masks = (page1_bitset.bit_length + (bitsize - 1)) / bitsize;
    for (page1_bitset.masks[0..num_masks]) |mask, i| {
        if (mask & page2_bitset.masks[i] != 0)
            return false;
    }
    return true;
}

/// This function changes the page pointed to by page2 to be page1
fn meshPages(slab_page1: SlabPage, slab_page2: SlabPage) void {
    assert(canMesh(slab_page1, slab_page2));

    const slab1 = slab_page1.slab;
    const slab2 = slab_page2.slab;

    const page1_index = slab_page1.page;
    const page2_index = slab_page2.page;

    const page1 = slab1.dataPage(page1_index);
    const page2 = slab2.dataPage(page2_index);
    log.debug("meshPages: {*} and {*}\n", .{ page1, page2 });

    const page1_bitset = slab1.bitset(page1_index);
    const page2_bitset = slab2.bitset(page2_index);

    var iter = page2_bitset.iterator(.{});
    while (iter.next()) |slot_index| {
        const dest = slab1.slot(page1_index, slot_index);
        const src = slab2.slot(page2_index, slot_index);
        page1_bitset.set(slot_index);
        std.mem.copy(u8, dest, src);
    }

    slab2.freePage(page2_index);

    const page_offset = @ptrToInt(page1) - @ptrToInt(slab1);

    log.debug("remaping {*} to {*}\n", .{ page2, page1 });
    _ = std.os.mmap(
        page2,
        page_size,
        std.os.PROT.READ | std.os.PROT.WRITE,
        std.os.MAP.FIXED | std.os.MAP.SHARED,
        slab1.fd,
        page_offset,
    ) catch @panic("failed to mesh pages");
}

fn meshAll(self: *MeshingPool, slab: Slab.Ptr, buf: []u8) void {
    const num_pages = slab.partial_pages.len() + if (slab.current_index != null) @as(usize, 1) else 0;
    if (num_pages <= 1) return;

    assert(num_pages <= std.math.maxInt(Slab.SlotIndex));
    // TODO: cache this in Self so we don't need to do it all the time
    const random = self.rng.random();
    const rand_idx = @ptrCast([*]Slab.SlotIndex, buf.ptr);
    const rand_len = buf.len / @sizeOf(Slab.SlotIndex);
    assert(rand_len >= 2 * num_pages);
    var rand_index1 = rand_idx[0..num_pages];
    var rand_index2 = rand_idx[num_pages .. 2 * num_pages];
    for (rand_index1[0..num_pages]) |*r, i| {
        r.* = @intCast(Slab.SlotIndex, i);
    }
    random.shuffle(Slab.SlotIndex, rand_index1[0..num_pages]);
    for (rand_index2[0..num_pages]) |*r, i| {
        r.* = @intCast(Slab.SlotIndex, i);
    }
    random.shuffle(Slab.SlotIndex, rand_index2[0..num_pages]);

    const max_offset = @min(num_pages, 20);
    var offset_to_random: usize = 0;
    while (offset_to_random < max_offset) : (offset_to_random += 1) {
        for (rand_index1[0..num_pages]) |page1_index, i| {
            const page2_index = rand_index2[(i + offset_to_random) % num_pages];
            const handle1 = SlabPage{ .slab = slab, .page = page1_index };
            const handle2 = SlabPage{ .slab = slab, .page = page2_index };
            if (canMesh(handle1, handle2)) {
                log.debug("Merging pages {d} and {d}\n", .{ page1_index, page2_index });
                meshPages(handle1, handle2);
                return;
            }
        }
    }
}

fn usedSlots(self: MeshingPool) usize {
    return self.first_slab.usedSlots();
}

fn nonEmptyPageCount(self: MeshingPool) usize {
    return self.first_slab.nonEmptyPageCount();
}

test "MeshingPool" {
    var pool = try MeshingPool.init(16);
    defer pool.deinit();

    const p1 = pool.allocSlot() orelse return error.FailedAlloc;
    try std.testing.expectEqual(@as(usize, 1), pool.nonEmptyPageCount());
    try std.testing.expectEqual(@as(usize, 1), pool.usedSlots());

    const p2 = pool.allocSlot() orelse return error.FailedAlloc;
    try std.testing.expectEqual(@as(usize, 1), pool.nonEmptyPageCount());
    try std.testing.expectEqual(@as(usize, 2), pool.usedSlots());

    pool.freeSlot(p1.ptr);
    try std.testing.expectEqual(@as(usize, 1), pool.usedSlots());

    const p3 = pool.allocSlot() orelse return error.FailedAlloc;
    try std.testing.expectEqual(@as(usize, 1), pool.nonEmptyPageCount());
    try std.testing.expectEqual(@as(usize, 2), pool.usedSlots());

    pool.freeSlot(p3.ptr);
    pool.freeSlot(p2.ptr);
    try std.testing.expectEqual(@as(usize, 0), pool.usedSlots());
}

test "MeshingPool page reclamation" {
    var pool = try MeshingPool.init(16);
    defer pool.deinit();

    var i: usize = 0;
    while (i < page_size / 16) : (i += 1) {
        _ = pool.allocSlot() orelse return error.FailedAlloc;
    }
    try std.testing.expectEqual(@as(usize, 1), pool.nonEmptyPageCount());
    try std.testing.expectEqual(@as(usize, 256), pool.usedSlots());
    const p4 = pool.allocSlot() orelse return error.FailedAlloc;
    try std.testing.expectEqual(@as(usize, 2), pool.nonEmptyPageCount());
    pool.freeSlot(p4.ptr);
    try std.testing.expectEqual(@as(usize, 1), pool.nonEmptyPageCount());
}

test "mesh even and odd" {
    var pool = try MeshingPool.init(16);
    defer pool.deinit();

    var pointers: [2 * page_size / 16]?*u128 = .{null} ** (2 * page_size / 16);
    var i: usize = 0;
    while (i < 2 * page_size / 16) : (i += 1) {
        report(pool, &pointers, .before_alloc, i);

        const bytes = pool.allocSlot() orelse return error.FailedAlloc;
        const second_page = i > 255;
        const index = pool.first_slab.indexOf(bytes.ptr).slot;
        const pointer_index = if (second_page) @as(usize, index) + 256 else index;
        assert(pointers[pointer_index] == null);
        pointers[pointer_index] = @ptrCast(*u128, @alignCast(16, bytes.ptr));

        report(pool, &pointers, .after_alloc, i);

        pointers[pointer_index].?.* = @as(u128, pointer_index);

        report(pool, &pointers, .after_write, i);
    }

    log.debug("after writes: first page {d}; second page {d}; pointer[0] ({*}) {d}; pointer[256] ({*}) {d}\n", .{
        @ptrCast(*u128, @alignCast(16, pool.first_slab.slot(0, 0).ptr)).*,
        @ptrCast(*u128, @alignCast(16, pool.first_slab.slot(1, 0).ptr)).*,
        pointers[0],
        pointers[0].?.*,
        pointers[256],
        pointers[256].?.*,
    });

    try std.testing.expectEqual(@as(usize, 2), pool.nonEmptyPageCount());

    try std.testing.expectEqual(@as(u128, 0), pointers[0].?.*);
    try std.testing.expectEqual(@as(u128, 1), pointers[1].?.*);
    try std.testing.expectEqual(@as(u128, 256), pointers[256].?.*);
    try std.testing.expectEqual(@as(u128, 257), pointers[257].?.*);

    i = 0;
    while (i < page_size / 16) : (i += 2) {
        pool.freeSlot(pool.first_slab.slot(0, i + 1).ptr);
        pool.freeSlot(pool.first_slab.slot(1, i).ptr);
    }
    try std.testing.expectEqual(@as(usize, 2), pool.nonEmptyPageCount());
    try std.testing.expectEqual(@as(usize, 256), pool.usedSlots());

    try std.testing.expect(canMesh(
        .{ .slab = pool.first_slab, .page = 0 },
        .{ .slab = pool.first_slab, .page = 1 },
    ));

    try std.testing.expectEqual(@as(u128, 0), pointers[0].?.*);
    try std.testing.expectEqual(@as(u128, 2), pointers[2].?.*);
    try std.testing.expectEqual(@as(u128, 4), pointers[4].?.*);

    try std.testing.expectEqual(@as(u128, 257), pointers[257].?.*);
    try std.testing.expectEqual(@as(u128, 259), pointers[259].?.*);
    try std.testing.expectEqual(@as(u128, 261), pointers[261].?.*);

    // waitForInput();
    var buf: [16]u8 = undefined;
    pool.meshAll(pool.first_slab, &buf);
    // waitForInput();

    try std.testing.expectEqual(@as(usize, 1), pool.nonEmptyPageCount());
    try std.testing.expectEqual(@as(usize, 256), pool.usedSlots());

    i = 0;
    while (i < page_size / 16) : (i += 2) {
        try std.testing.expectEqual(@as(u128, i), pointers[i].?.*);
        try std.testing.expectEqual(@as(u128, i), pointers[i + 256].?.*);
        try std.testing.expectEqual(@as(u128, i + 1 + 256), pointers[i + 1].?.*);
        try std.testing.expectEqual(@as(u128, i + 1 + 256), pointers[i + 1 + 256].?.*);
    }
}

fn report(
    pool: MeshingPool,
    pointers: []?*u128,
    comptime which: enum { before_alloc, after_alloc, after_write },
    i: usize,
) void {
    const report_at = [_]usize{ 85, 86, 87, 255 };
    if (std.mem.indexOfScalar(usize, &report_at, i) != null) {
        log.debug(switch (which) {
            .before_alloc => "before allocating index {d}\n",
            .after_alloc => "after allocating index {d}\n",
            .after_write => "after writing index {d}\n",
        }, .{i});
        inline for (.{ 0, 1, 2 }) |index| {
            if (pointers[index]) |ptr| {
                log.debug("\tindex {d} (on page {d}) has value {d} (by pointer {d})\n", .{
                    index,
                    0,
                    @ptrCast(*u128, @alignCast(16, pool.first_slab.slot(0, index).ptr)).*,
                    ptr.*,
                });
            }
        }
    }
}

fn waitForInput() void {
    const stdin = std.io.getStdIn().reader();
    var buf: [64]u8 = undefined;
    _ = stdin.readUntilDelimiter(&buf, '\n') catch return;
}

// fills a single page, then deinits it `count` times
pub fn benchmarkMeshingPoolAllocSlot(pool: anytype, count: usize) !void {
    var j: usize = 0;
    while (j < count) : (j += 1) {
        var i: usize = 0;
        while (i < std.meta.Child(@TypeOf(pool)).slot_count) : (i += 1) {
            _ = pool.allocSlot() orelse return error.FailedAlloc;
        }
        pool.deinitPage(pool.all_pages.pop());
    }
}
