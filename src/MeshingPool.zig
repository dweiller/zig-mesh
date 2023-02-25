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
const ShuffleVector = @import("shuffle_vector.zig").StaticShuffleVectorUnmanaged(params.slots_per_slab_max);

const page_size = std.mem.page_size;

const log = std.log.scoped(.MeshingPool);

const assert = @import("util.zig").assert;

const Config = struct {
    debug_checks: bool,
};

pub fn MeshingPool(comptime config: Config) type {
    return struct {
        const Pool = @This();
        partial_slabs: Slab.List = .{},
        empty_slabs: Slab.List = .{},
        full_slabs: Slab.List = .{},
        span_cache: std.BoundedArray(Span, 16) = .{},
        slot_size: usize,
        rng: std.rand.DefaultPrng,
        shuffle: ShuffleVector,

        pub fn init(slot_size: usize) Pool {
            return initSeeded(slot_size, 0);
        }

        pub fn initSeeded(slot_size: usize, seed: u64) Pool {
            params.assertSlotSizeValid(slot_size);
            var rng = std.rand.DefaultPrng.init(seed);
            return Pool{
                .slot_size = slot_size,
                .rng = rng,
                .shuffle = ShuffleVector{ .indices = .{} },
            };
        }

        pub fn deinit(self: *Pool) void {
            inline for (comptime std.meta.tags(List)) |list| {
                const field_name = @tagName(list) ++ "_slabs";
                while (@field(self, field_name).head) |slab| {
                    @field(self, field_name).remove(slab);
                    slab.deinit();
                }
            }
            while (self.span_cache.popOrNull()) |span| {
                var s = span;
                s.deinit();
            }
            self.* = undefined;
        }

        const List = enum { partial, empty, full };
        fn moveSlab(self: *Pool, comptime from: List, comptime to: List, slab: Slab.Ptr) void {
            @field(self, @tagName(from) ++ "_slabs").remove(slab);
            @field(self, @tagName(to) ++ "_slabs").append(slab);
        }

        fn adoptSlab(self: *Pool, slab: Slab.Ptr) void {
            if (slab.isEmpty())
                self.empty_slabs.append(slab)
            else if (slab.isFull())
                self.full_slabs.append(slab)
            else
                self.partial_slabs.append(slab);
        }

        fn adoptSlabAsCurrent(self: *Pool, slab: Slab.Ptr) void {
            log.debug("pool {*} adopting slab {*} as its current slab", .{ self, slab });
            self.partial_slabs.append(slab);
            self.partial_slabs.head = slab;
            self.initShuffleForCurrent();
            // TODO: should we call madvise WILLNEED?
        }

        fn initShuffleForCurrent(self: *Pool) void {
            self.shuffle.clear();
            const random = self.rng.random();
            var iter = self.partial_slabs.head.?.bitset.iterator(.{ .kind = .unset });
            while (iter.next()) |index| {
                if (index >= self.partial_slabs.head.?.slot_count) break;
                self.shuffle.pushAssumeCapacity(random, @intCast(ShuffleVector.IndexType, index));
            }
        }

        pub fn allocSlot(self: *Pool) ?[]u8 {
            var slab = self.partial_slabs.head orelse return self.allocSlotSlow();
            assert(slab.usedSlots() < slab.slot_count);

            const slot_index = self.shuffle.pop();
            log.debug("allocating slot {d} in slab at {*}", .{ slot_index, slab });
            if (config.debug_checks) {
                for (self.shuffle.indices.buffer[0..self.shuffle.indices.len]) |index| {
                    if (slot_index == index) std.debug.panic("shuffle vector still contains popped index {d}\n", .{slot_index});
                }
            }
            const slot = slab.allocSlot(slot_index);

            if (slab.usedSlots() == slab.slot_count) {
                self.moveSlab(.partial, .full, slab);
            }

            return slot;
        }

        // allocation slow path, need to grab empty slab (if there is one) or initialise a new slab
        // Returns the slice of the allocatted slot, unless the `Slab` is full, in which case `null` is
        // returned.
        fn allocSlotSlow(self: *Pool) ?[]u8 {
            assert(self.partial_slabs.head == null);
            if (self.empty_slabs.head) |slab| {
                self.empty_slabs.remove(slab);
                self.adoptSlabAsCurrent(slab);
                return self.allocSlot() orelse unreachable;
            }

            // check span cache
            var new_slab = if (self.span_cache.popOrNull()) |span| new_slab: {
                log.debug("Reusing unmapped span ({} pages, fd {})", .{ span.page_count, span.fd });
                break :new_slab Slab.initSpan(self.slot_size, span) catch {
                    log.warn("could not map unmapped span ({} pages, fd {})", .{ span.page_count, span.fd });
                    return null;
                };
            } else new_slab: {
                log.debug("All slabs full, allocating new slab", .{});
                break :new_slab Slab.init(self.slot_size, params.slab_page_count_max) catch |err| {
                    log.warn("could not allocate new slab: {s}", .{@errorName(err)});
                    return null;
                };
            };

            self.adoptSlabAsCurrent(new_slab);

            return self.allocSlot() orelse unreachable; // not possible for fresh slab to fail allocating
        }

        pub fn freeSlot(self: *Pool, ptr: *anyopaque) void {
            const slab = self.owningSlab(ptr) orelse unreachable;
            self.freeSlotInSlab(ptr, slab);
        }

        pub fn freeSlotInSlab(self: *Pool, ptr: *anyopaque, slab: Slab.Ptr) void {
            const slot_index = slab.indexOf(ptr);
            slab.freeSlot(slot_index);

            if (self.partial_slabs.head) |current| {
                if (current == slab) {
                    self.shuffle.pushAssumeCapacity(self.rng.random(), @intCast(ShuffleVector.IndexType, slot_index));
                }
            }

            const count = slab.usedSlots();
            if (count == slab.slot_count - 1) {
                // was a full slab, need to add to partial list
                log.debug("slab was full", .{});
                self.moveSlab(.full, .partial, slab);
            } else if (count == 0) {
                // going from partial -> empty
                log.debug("slab became empty", .{});
                self.moveSlab(.partial, .empty, slab);
                slab.markUnused() catch |err| log.warn("Could not madvise DONTNEED slab {*}: {s}", .{ slab, @errorName(err) });
            }
        }

        pub fn owningSlab(self: Pool, ptr: *anyopaque) ?Slab.Ptr {
            if (self.partial_slabs.head) |first| {
                if (first.ownsPtr(ptr)) return first;
                var slab = first.next;
                while (slab != first) : (slab = slab.next) {
                    if (slab.ownsPtr(ptr)) return slab;
                }
            }

            if (self.full_slabs.head) |first| {
                if (first.ownsPtr(ptr)) return first;
                var slab = first.next;
                while (slab != first) : (slab = slab.next) {
                    if (slab.ownsPtr(ptr)) return slab;
                }
            }

            return null;
        }

        pub fn ownsPtr(self: Pool, ptr: *anyopaque) bool {
            return self.owningSlab(ptr) != null;
        }

        fn canMesh(slab1: Slab, slab2: Slab) bool {
            // TODO: this performs a copy of slab1.bitset, which isn't required
            return slab1.bitset.intersectWith(slab2.bitset).count() == 0;
        }

        /// This function changes the slab pointed to by page2 to be page1
        fn meshSlabs(self: *Pool, slab1: Slab.Ptr, slab2: Slab.Ptr) void {
            assert(canMesh(slab1.*, slab2.*));

            log.debug("meshing slabs {*} and {*}\n", .{ slab1, slab2 });

            var iter = slab2.bitset.iterator(.{});
            while (iter.next()) |slot_index| {
                const dest = slab1.slot(slot_index);
                const src = slab2.slot(slot_index);
                slab2.bitset.unset(slot_index);
                slab1.bitset.set(slot_index);
                std.mem.copy(u8, dest, src);
            }

            log.debug("remaping address range of size slab_size at {*} to {*}\n", .{ slab2, slab1 });
            const slab_size = page_size * slab2.page_count;
            // slab1 and slab2 are in the partial list
            self.partial_slabs.remove(slab2);
            var slab2_span = slab2.unmap();
            self.span_cache.append(slab2_span) catch slab2_span.deinit();

            if (slab1.usedSlots() == slab1.slot_count) {
                self.moveSlab(.partial, .full, slab1);
            }

            _ = std.os.mmap(
                @ptrCast([*]u8, slab2),
                slab_size,
                std.os.PROT.READ | std.os.PROT.WRITE,
                std.os.MAP.FIXED | std.os.MAP.SHARED,
                slab1.fd,
                0,
            ) catch @panic("failed to mesh pages");
        }

        fn splitMesherInner(self: *Pool, list1: []Slab.Ptr, list2: []Slab.Ptr) void {
            assert(list1.len == list2.len);
            const len = list1.len;
            const max_offset = @min(len, 20);
            for (0..max_offset) |offset| {
                for (list1, 0..) |slab1, i| {
                    const slab2 = list2[(i + offset) % len];
                    if (canMesh(slab1.*, slab2.*)) {
                        self.meshSlabs(slab1, slab2);
                        // BUG/TODO: think about whether we need to remove meshed slabs from the lists,
                        //           or if this will recurisvely mesh pages correctly.
                    }
                }
            }
        }

        fn splitMesher(self: *Pool, buf: []Slab.Ptr) void {
            const num_slabs = self.partial_slabs.len;
            if (num_slabs <= 1) return;

            // TODO: cache this in Self so we don't need to do it all the time
            const random = self.rng.random();
            assert(buf.len >= num_slabs);
            const first = self.partial_slabs.head.?;
            buf[0] = first;

            var slab = first.next;
            var slab_index: usize = 1;
            while (slab != first) {
                buf[slab_index] = slab;
                slab_index += 1;
                slab = slab.next;
            }
            random.shuffle(Slab.Ptr, buf[0..slab_index]);

            var slabs1 = buf[0 .. num_slabs / 2];
            var slabs2 = buf[num_slabs / 2 .. (num_slabs / 2) * 2];

            self.splitMesherInner(slabs1, slabs2);
        }

        fn usedSlots(self: Pool) usize {
            var count: usize = 0;

            if (self.full_slabs.head) |first| {
                var iter = first;
                while (true) : (iter = iter.next) {
                    count += iter.slot_count;
                    if (iter.next == first) break;
                }
            }

            if (self.partial_slabs.head) |first| {
                var iter = first;
                while (true) : (iter = iter.next) {
                    count += iter.usedSlots();
                    if (iter.next == first) break;
                }
            }

            return count;
        }

        fn countSlabs(self: Pool, comptime list: List) usize {
            var count: usize = 0;
            if (@field(self, @tagName(list) ++ "_slabs").head) |first| {
                var iter = first;
                while (true) : (iter = iter.next) {
                    count += 1;
                    if (iter.next == first) break;
                }
            }
            return count;
        }

        fn nonEmptySlabCount(self: Pool) usize {
            return self.countSlabs(.partial) + self.countSlabs(.full);
        }
    };
}

const fileDescriptorCount = @import("util.zig").fileDescriptorCount;
const TestMesher = MeshingPool(.{ .debug_checks = true });

test "MeshingPool" {
    const fd_count = try fileDescriptorCount();
    var pool = TestMesher.init(16);

    const p1 = pool.allocSlot() orelse return error.FailedAlloc;
    try std.testing.expectEqual(@as(usize, 1), pool.nonEmptySlabCount());
    try std.testing.expectEqual(pool.nonEmptySlabCount(), pool.partial_slabs.len + pool.full_slabs.len);
    try std.testing.expectEqual(@as(usize, 1), pool.usedSlots());

    const p2 = pool.allocSlot() orelse return error.FailedAlloc;
    try std.testing.expectEqual(@as(usize, 1), pool.nonEmptySlabCount());
    try std.testing.expectEqual(pool.nonEmptySlabCount(), pool.partial_slabs.len + pool.full_slabs.len);
    try std.testing.expectEqual(@as(usize, 2), pool.usedSlots());

    pool.freeSlot(p1.ptr);
    try std.testing.expectEqual(@as(usize, 1), pool.usedSlots());

    const p3 = pool.allocSlot() orelse return error.FailedAlloc;
    try std.testing.expectEqual(@as(usize, 1), pool.nonEmptySlabCount());
    try std.testing.expectEqual(pool.nonEmptySlabCount(), pool.partial_slabs.len + pool.full_slabs.len);
    try std.testing.expectEqual(@as(usize, 2), pool.usedSlots());

    pool.freeSlot(p3.ptr);
    pool.freeSlot(p2.ptr);
    try std.testing.expectEqual(@as(usize, 0), pool.usedSlots());

    pool.deinit();
    try std.testing.expectEqual(fd_count, try fileDescriptorCount());
}

test "MeshingPool slab reclamation" {
    var pool = TestMesher.init(16);
    defer pool.deinit();

    var i: usize = 0;
    while (i < params.slots_per_slab_max) : (i += 1) {
        _ = pool.allocSlot() orelse return error.FailedAlloc;
    }
    try std.testing.expectEqual(@as(usize, 1), pool.nonEmptySlabCount());
    try std.testing.expectEqual(pool.nonEmptySlabCount(), pool.partial_slabs.len + pool.full_slabs.len);
    try std.testing.expectEqual(@as(usize, params.slots_per_slab_max), pool.usedSlots());
    const p4 = pool.allocSlot() orelse return error.FailedAlloc;
    try std.testing.expectEqual(@as(usize, 2), pool.nonEmptySlabCount());
    try std.testing.expectEqual(pool.nonEmptySlabCount(), pool.partial_slabs.len + pool.full_slabs.len);
    pool.freeSlot(p4.ptr);
    try std.testing.expectEqual(@as(usize, 1), pool.nonEmptySlabCount());
    try std.testing.expectEqual(pool.nonEmptySlabCount(), pool.partial_slabs.len + pool.full_slabs.len);
}

test "mesh even and odd" {
    var pool = TestMesher.init(16);
    defer pool.deinit();

    const slots_per_slab = params.slab_data_size_max / 16;
    var pointers: [2 * slots_per_slab]?*u128 = .{null} ** (2 * slots_per_slab);
    var i: usize = 0;
    while (i < 2 * slots_per_slab) : (i += 1) {
        const bytes = pool.allocSlot() orelse return error.FailedAlloc;
        const second_slab = i >= slots_per_slab;
        const index = pool.owningSlab(bytes.ptr).?.indexOf(bytes.ptr);
        const pointer_index = if (second_slab) index + slots_per_slab else index;
        assert(pointers[pointer_index] == null);

        pointers[pointer_index] = @ptrCast(*u128, @alignCast(16, bytes.ptr));
        pointers[pointer_index].?.* = @as(u128, pointer_index);
    }

    try std.testing.expectEqual(@as(usize, 2), pool.nonEmptySlabCount());
    try std.testing.expectEqual(pool.nonEmptySlabCount(), pool.partial_slabs.len + pool.full_slabs.len);

    try std.testing.expectEqual(@as(u128, 0), pointers[0].?.*);
    try std.testing.expectEqual(@as(u128, 1), pointers[1].?.*);
    try std.testing.expectEqual(@as(u128, 256), pointers[256].?.*);
    try std.testing.expectEqual(@as(u128, 257), pointers[257].?.*);

    try std.testing.expectEqual(@as(?Slab.Ptr, null), pool.partial_slabs.head);
    try std.testing.expectEqual(@as(usize, 2), pool.full_slabs.len);
    try std.testing.expectEqual(pool.full_slabs.len, pool.countSlabs(.full));
    i = 0;
    while (i < slots_per_slab - 1) : (i += 2) {
        pool.freeSlot(pointers[i + 1].?);
        pool.freeSlot(pointers[i + slots_per_slab].?);
    }
    try std.testing.expectEqual(@as(usize, 2), pool.nonEmptySlabCount());
    try std.testing.expectEqual(pool.nonEmptySlabCount(), pool.partial_slabs.len + pool.full_slabs.len);
    try std.testing.expectEqual(@as(usize, slots_per_slab), pool.usedSlots());

    try std.testing.expect(TestMesher.canMesh(pool.partial_slabs.head.?.*, pool.partial_slabs.head.?.next.*));

    try std.testing.expectEqual(@as(u128, 0), pointers[0].?.*);
    try std.testing.expectEqual(@as(u128, 2), pointers[2].?.*);
    try std.testing.expectEqual(@as(u128, 4), pointers[4].?.*);

    try std.testing.expectEqual(@as(u128, 257), pointers[257].?.*);
    try std.testing.expectEqual(@as(u128, 259), pointers[259].?.*);
    try std.testing.expectEqual(@as(u128, 261), pointers[261].?.*);

    // waitForInput();
    assert(TestMesher.canMesh(pool.partial_slabs.head.?.*, pool.partial_slabs.head.?.next.*));
    var buf: [2]Slab.Ptr = undefined;
    pool.splitMesher(&buf);
    // waitForInput();

    try std.testing.expectEqual(@as(usize, 1), pool.nonEmptySlabCount());
    try std.testing.expectEqual(pool.nonEmptySlabCount(), pool.partial_slabs.len + pool.full_slabs.len);
    try std.testing.expectEqual(@as(usize, slots_per_slab), pool.usedSlots());

    i = 0;
    while (i < page_size / 16) : (i += 2) {
        try std.testing.expectEqual(@as(u128, i), pointers[i].?.*);
        try std.testing.expectEqual(@as(u128, i), pointers[i + slots_per_slab].?.*);
        try std.testing.expectEqual(@as(u128, i + 1 + slots_per_slab), pointers[i + 1].?.*);
        try std.testing.expectEqual(@as(u128, i + 1 + slots_per_slab), pointers[i + 1 + slots_per_slab].?.*);
    }
}

const waitForInput = @import("util.zig").waitForInput;

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
