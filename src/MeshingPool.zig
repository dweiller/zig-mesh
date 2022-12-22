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

const MeshingPool = @This();

// TODO: use multiple slabs
slab: *align(params.slab_alignment) Slab,
slot_size: u16,
rng: std.rand.DefaultPrng,

pub fn init(slot_size: usize) !MeshingPool {
    return initSeeded(slot_size, 0);
}

pub fn initSeeded(slot_size: usize, seed: u64) !MeshingPool {
    params.assertSlotSizeValid(slot_size);
    var rng = std.rand.DefaultPrng.init(seed);
    var slab = try Slab.init(rng.random(), slot_size, params.slab_alignment / page_size);
    return MeshingPool{
        .slab = slab,
        .slot_size = @intCast(u16, slot_size),
        .rng = rng,
    };
}

pub fn deinit(self: *MeshingPool) void {
    self.slab.deinit();
    self.* = undefined;
}

pub fn allocSlot(self: *MeshingPool) ?[]u8 {
    const slab = self.slab;
    return slab.allocSlot();
}

pub fn freeSlot(self: *MeshingPool, ptr: *anyopaque) void {
    std.debug.assert(self.ownsPtr(ptr));
    const slab = self.slab;
    slab.freeSlot(self.rng.random(), slab.indexOf(ptr));
}

pub fn ownsPtr(self: MeshingPool, ptr: *anyopaque) bool {
    return self.slab.ownsPtr(ptr);
}

fn canMesh(self: MeshingPool, page1_index: usize, page2_index: usize) bool {
    const page1_bitset = self.slab.bitset(page1_index);
    const page2_bitset = self.slab.bitset(page2_index);
    const bitsize = @bitSizeOf(std.DynamicBitSet.MaskInt);
    const num_masks = (page1_bitset.bit_length + (bitsize - 1)) / bitsize;
    for (page1_bitset.masks[0..num_masks]) |mask, i| {
        if (mask & page2_bitset.masks[i] != 0)
            return false;
    }
    return true;
}

/// This function changes the Page pointed to by page2, by doing a swap removal on the PageList
fn meshPages(
    self: MeshingPool,
    page1_index: usize,
    page2_index: usize,
) void {
    // std.debug.assert(canMesh(page1_bitset, page2_bitset));
    const page1 = self.slab.dataPage(page1_index);
    const page2 = self.slab.dataPage(page2_index);
    log.debug("meshPages: {*} and {*}\n", .{ page1, page2 });

    const page2_bitset = self.slab.bitset(page2_index);

    // TODO: it would be better to intersect the complement of page1_bitset
    // with page2_bitset and iterate over that. The issue with this is that
    // this would require copying the bitset.
    var iter = page2_bitset.iterator(.{});
    while (iter.next()) |slot_index| {
        const dest = self.slab.slot(page1_index, slot_index);
        const src = self.slab.slot(page2_index, slot_index);
        std.mem.copy(u8, dest, src);
    }

    self.slab.freePage(page2_index);

    const page_offset = @ptrToInt(page1) - @ptrToInt(self.slab);

    log.debug("remaping {*} to {*}\n", .{ page2, page1 });
    _ = std.os.mmap(
        page2,
        page_size,
        std.os.PROT.READ | std.os.PROT.WRITE,
        std.os.MAP.FIXED | std.os.MAP.SHARED,
        self.slab.fd,
        page_offset,
    ) catch @panic("failed to mesh pages");
}

fn meshAll(self: *MeshingPool, buf: []u8) void {
    const slab = self.slab;
    if (slab.partial_pages.first == null or (slab.partial_pages.first.?.next == null and slab.current_index == null)) return;

    const num_pages = slab.partial_pages.len() + if (slab.current_index != null) @as(usize, 1) else 0;
    std.debug.assert(num_pages > 1);

    std.debug.assert(num_pages <= std.math.maxInt(Slab.SlotIndex));
    // TODO: cache this in Self so we don't need to do it all the time
    const random = self.rng.random();
    const rand_idx = @ptrCast([*]Slab.SlotIndex, buf.ptr);
    const rand_len = buf.len / @sizeOf(Slab.SlotIndex);
    std.debug.assert(rand_len >= 2 * num_pages);
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
            if (self.canMesh(page1_index, page2_index)) {
                log.debug("Merging pages {d} and {d}\n", .{ page1_index, page2_index });
                self.meshPages(page1_index, page2_index);
                return;
            }
        }
    }
}

fn usedSlots(self: MeshingPool) usize {
    var count: usize = if (self.slab.current_index) |index| self.slab.bitset(index).count() else 0;
    var num_partial: usize = 0;
    var iter = self.slab.partial_pages.first;
    while (iter) |node| : (iter = node.next) {
        num_partial += 1;
        const bs = self.slab.bitset(self.slab.indexOf(node).page);
        count += bs.count();
    }
    const slots_per_page = page_size / self.slot_size;
    const num_empty = self.slab.empty_pages.len();
    const num_full = self.slab.page_mark - num_empty - num_partial - if (self.slab.current_index != null) @as(usize, 1) else 0;
    return num_full * slots_per_page + count;
}

fn nonEmptyPages(self: MeshingPool) usize {
    return self.slab.page_mark - self.slab.empty_pages.len();
}

test "MeshingPool" {
    var pool = try MeshingPool.init(16);
    defer pool.deinit();

    const p1 = pool.allocSlot() orelse return error.FailedAlloc;
    try std.testing.expectEqual(@as(usize, 1), pool.nonEmptyPages());
    try std.testing.expectEqual(@as(usize, 1), pool.usedSlots());

    const p2 = pool.allocSlot() orelse return error.FailedAlloc;
    try std.testing.expectEqual(@as(usize, 1), pool.nonEmptyPages());
    try std.testing.expectEqual(@as(usize, 2), pool.usedSlots());

    pool.freeSlot(p1.ptr);
    try std.testing.expectEqual(@as(usize, 1), pool.usedSlots());

    const p3 = pool.allocSlot() orelse return error.FailedAlloc;
    try std.testing.expectEqual(@as(usize, 1), pool.nonEmptyPages());
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
    try std.testing.expectEqual(@as(usize, 1), pool.nonEmptyPages());
    try std.testing.expectEqual(@as(usize, 256), pool.usedSlots());
    const p4 = pool.allocSlot() orelse return error.FailedAlloc;
    try std.testing.expectEqual(@as(usize, 2), pool.nonEmptyPages());
    pool.freeSlot(p4.ptr);
    try std.testing.expectEqual(@as(usize, 1), pool.nonEmptyPages());
}

test "mesh even and odd" {
    var pool = try MeshingPool.init(16);
    defer pool.deinit();

    var pointers: [2 * page_size / 16]?*[16]u8 = .{null} ** (2 * page_size / 16);
    var i: usize = 0;
    while (i < 2 * page_size / 16) : (i += 1) {
        report(pool, &pointers, .before_alloc, i);

        const bytes = pool.allocSlot() orelse return error.FailedAlloc;
        const second_page = i > 255;
        const index = pool.slab.indexOf(bytes.ptr).slot;
        const pointer_index = if (second_page) @as(usize, index) + 256 else index;
        std.debug.assert(pointers[pointer_index] == null);
        pointers[pointer_index] = @ptrCast(*[16]u8, bytes.ptr);

        report(pool, &pointers, .after_alloc, i);

        pointers[pointer_index].?.* = @bitCast([16]u8, @as(u128, pointer_index));

        report(pool, &pointers, .after_write, i);
    }

    log.debug("after writes: first page {d}; second page {d}; pointer[0] ({*}) {d}; pointer[256] ({*}) {d}\n", .{
        @bitCast(u128, @ptrCast(*[16]u8, pool.slab.slot(0, 0).ptr).*),
        @bitCast(u128, @ptrCast(*[16]u8, pool.slab.slot(1, 0).ptr).*),
        pointers[0],
        @bitCast(u128, pointers[0].?.*),
        pointers[256],
        @bitCast(u128, pointers[256].?.*),
    });

    try std.testing.expectEqual(@as(usize, 2), pool.nonEmptyPages());

    try std.testing.expectEqual(@as(u128, 0), @bitCast(u128, pointers[0].?.*));
    try std.testing.expectEqual(@as(u128, 1), @bitCast(u128, pointers[1].?.*));
    try std.testing.expectEqual(@as(u128, 256), @bitCast(u128, pointers[256].?.*));
    try std.testing.expectEqual(@as(u128, 257), @bitCast(u128, pointers[257].?.*));

    i = 0;
    const page1_index = pool.slab.indexOf(pool.slab.dataPage(0)).page;
    const page2_index = pool.slab.indexOf(pool.slab.dataPage(1)).page;
    while (i < page_size / 16) : (i += 2) {
        pool.freeSlot(pool.slab.slot(page1_index, i + 1).ptr);
        pool.freeSlot(pool.slab.slot(page2_index, i).ptr);
    }
    try std.testing.expectEqual(@as(usize, 2), pool.nonEmptyPages());
    try std.testing.expectEqual(@as(usize, 256), pool.usedSlots());

    try std.testing.expect(pool.canMesh(page1_index, page2_index));

    try std.testing.expectEqual(@as(u128, 0), @bitCast(u128, pointers[0].?.*));
    // try std.testing.expectEqual(@as(u128, 1), @bitCast(u128, pointers[1].?.*));
    try std.testing.expectEqual(@as(u128, 2), @bitCast(u128, pointers[2].?.*));
    // try std.testing.expectEqual(@as(u128, 3), @bitCast(u128, pointers[3].?.*));
    try std.testing.expectEqual(@as(u128, 4), @bitCast(u128, pointers[4].?.*));
    // try std.testing.expectEqual(@as(u128, 5), @bitCast(u128, pointers[5].?.*));

    // try std.testing.expectEqual(@as(u128, 256), @bitCast(u128, pointers[256].?.*));
    try std.testing.expectEqual(@as(u128, 257), @bitCast(u128, pointers[257].?.*));
    // try std.testing.expectEqual(@as(u128, 258), @bitCast(u128, pointers[258].?.*));
    try std.testing.expectEqual(@as(u128, 259), @bitCast(u128, pointers[259].?.*));
    // try std.testing.expectEqual(@as(u128, 260), @bitCast(u128, pointers[260].?.*));
    try std.testing.expectEqual(@as(u128, 261), @bitCast(u128, pointers[261].?.*));

    // waitForInput();
    var buf: [16]u8 = undefined;
    pool.meshAll(&buf);
    // waitForInput();

    try std.testing.expectEqual(@as(u128, 0), @bitCast(u128, pointers[0].?.*));
    try std.testing.expectEqual(@as(u128, 257), @bitCast(u128, pointers[1].?.*));
    try std.testing.expectEqual(@as(u128, 2), @bitCast(u128, pointers[2].?.*));
    try std.testing.expectEqual(@as(u128, 259), @bitCast(u128, pointers[3].?.*));
    try std.testing.expectEqual(@as(u128, 4), @bitCast(u128, pointers[4].?.*));
    try std.testing.expectEqual(@as(u128, 261), @bitCast(u128, pointers[5].?.*));

    try std.testing.expectEqual(@as(u128, 0), @bitCast(u128, pointers[256].?.*));
    try std.testing.expectEqual(@as(u128, 257), @bitCast(u128, pointers[257].?.*));
    try std.testing.expectEqual(@as(u128, 2), @bitCast(u128, pointers[258].?.*));
    try std.testing.expectEqual(@as(u128, 259), @bitCast(u128, pointers[259].?.*));
    try std.testing.expectEqual(@as(u128, 4), @bitCast(u128, pointers[260].?.*));
    try std.testing.expectEqual(@as(u128, 261), @bitCast(u128, pointers[261].?.*));
}

fn report(
    pool: MeshingPool,
    pointers: []?*[16]u8,
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
        if (pool.slab.current_index) |page_index| {
            inline for (.{ 0, 1, 2 }) |index| {
                if (pointers[index]) |ptr| {
                    log.debug("\tindex {d} (on page {d}) has value {d} (by pointer {d})\n", .{
                        index,
                        page_index,
                        @bitCast(u128, @ptrCast(*[16]u8, pool.slab.slot(page_index, index).ptr).*),
                        @bitCast(u128, ptr.*),
                    });
                }
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
