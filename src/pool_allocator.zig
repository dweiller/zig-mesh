// TODO: first make a mesh allocator for a fixed slot size, i.e. a pool/object allocator that does meshing
//       Then reuse that code to make a GPA that has mesh allocators for different sizes
const std = @import("std");
const Allocator = std.mem.Allocator;

const ShuffleVector = @import("shuffle_vector.zig").ShuffleVector;

const page_allocator = std.heap.page_allocator;
const page_size = std.mem.page_size;

const PagePtr = [*]align(page_size) u8;

const log = std.log.scoped(.PoolAllocator);

pub fn PoolAllocator(comptime slot_size: comptime_int) type {
    comptime {
        if (slot_size > page_size)
            @compileError(std.fmt.comptimePrint(
                "Slot size ({d}) cannot be larger than the page size ({d})",
                .{ slot_size, page_size },
            ));
    }

    return struct {
        const Self = @This();

        // TODO: change pages to be an array, so it can be indexed quickly
        // non-full pages, sorted from high to low occupancy
        pages: std.TailQueue(Page) = .{},
        full_pages: std.TailQueue(Page) = .{},
        rng: std.rand.DefaultPrng,
        node_allocator: Allocator,
        comptime slot_size: usize = slot_size,
        fd: std.os.fd_t,
        start: PagePtr,
        end: PagePtr,

        const Shuffle = ShuffleVector(slot_count);

        pub const slot_count = page_size / slot_size;
        const BitSet = std.StaticBitSet(slot_count);
        const PageNode = std.TailQueue(Page).Node;

        const MMAP_PROT_FLAGS = std.os.PROT.READ | std.os.PROT.WRITE;
        const MMAP_MAP_FLAGS = std.os.MAP.SHARED;

        pub fn init(node_allocator: Allocator, seed: u64, max_page_count: usize) !Self {
            const fd = try std.os.memfd_create(std.fmt.comptimePrint("pool{d}", .{slot_size}), 0);
            errdefer std.os.close(fd);

            const size = max_page_count * page_size;
            try std.os.ftruncate(fd, size);

            const start = try std.os.mmap(
                null,
                size,
                MMAP_PROT_FLAGS,
                MMAP_MAP_FLAGS,
                fd,
                0,
            );

            return .{
                .rng = std.rand.DefaultPrng.init(seed),
                .node_allocator = node_allocator,
                // TODO: FD_CLOEXEC for multithreading
                .fd = fd,
                .start = start.ptr,
                .end = @alignCast(page_size, start.ptr + size),
            };
        }

        pub fn deinit(self: *Self) void {
            inline for (.{ self.full_pages, self.pages }) |*pages| {
                while (pages.pop()) |node| {
                    self.deinitPage(node);
                }
            }
            std.os.close(self.fd);
        }

        fn initPage(self: *Self) !*PageNode {
            const offset = self.pageCount() * page_size;
            const ptr = @alignCast(page_size, self.start + offset);
            if (@ptrToInt(ptr) >= @ptrToInt(self.end)) return error.NoMorePages;
            log.debug("initPage: offset {d}; ptr {*}", .{ offset, ptr });
            errdefer releasePage(ptr);
            const page = try self.node_allocator.create(PageNode);
            page.* = .{ .data = Page.init(ptr, self.rng.random()) };
            self.pages.append(page);
            return page;
        }

        fn deinitPage(self: *Self, page: *PageNode) void {
            if (page.data.isFull())
                self.full_pages.remove(page)
            else
                self.pages.remove(page);
            releasePage(page.data.startPtr());
            self.node_allocator.destroy(page);
        }

        inline fn page_offset(self: Self, page: Page) usize {
            const ptr = page.startPtr();
            return @ptrToInt(ptr) - @ptrToInt(self.start);
        }

        fn expand(self: *Self, page_count: usize) !void {
            var i: usize = 0;
            while (i < page_count) : (i += 1) {
                _ = try self.initPage();
            }
        }

        inline fn releasePage(ptr: PagePtr) void {
            // MADV.REMOVE is meant to work the same as fallocate with FL_PUNCH_HOLE
            std.os.madvise(ptr, page_size, std.os.MADV.REMOVE) catch @panic("couldn't madvise");
        }

        pub fn allocSlot(self: *Self) ?*Page.Slot {
            if (self.pages.first == null) {
                self.expand(1) catch @panic("could not expand pool");
            }
            const page_node = self.pages.first orelse return null;

            const ptr = page_node.data.allocSlotUnsafe();
            if (page_node.data.isFull()) {
                self.pages.remove(page_node);
                self.full_pages.prepend(page_node);
            }
            return ptr;
        }

        pub fn freeSlot(self: *Self, ptr: *Page.Slot) void {
            inline for (.{ self.pages, self.full_pages }) |pages, i| {
                var it = pages.first;
                while (it) |node| : (it = node.next) {
                    if (node.data.ownsPtr(ptr)) {
                        const index = node.data.slotIndex(ptr);
                        self.freePageIndex(node, index, i == 1);
                        return;
                    }
                }
            }
        }

        fn freePageIndex(self: *Self, node: *PageNode, index: usize, comptime full_page: bool) void {
            if (!full_page) {
                node.data.freeIndex(index);
                if (node.data.isEmpty()) {
                    self.deinitPage(node);
                } else if (node.next) |next_node| {
                    if (node.data.occupied.count() < next_node.data.occupied.count()) {
                        self.pages.remove(node);
                        self.pages.insertAfter(next_node, node);
                    }
                }
            } else {
                node.data.freeIndex(index);
                self.full_pages.remove(node);
                self.pages.prepend(node);
            }
        }

        fn canMesh(page1: Page, page2: Page) bool {
            var meshed_bitset = page1.occupied;
            meshed_bitset.setIntersection(page2.occupied);
            return meshed_bitset.count() == 0;
        }

        fn meshPages(self: *Self, node1: *PageNode, node2: *PageNode) void {
            const page1 = node1.data;
            const page2 = node2.data;
            std.debug.assert(canMesh(page1, page2));
            log.debug("meshPages: {*} and {*}\n", .{ page1.slots, page2.slots });

            // copy data from page2 to page1
            var copy_mask = page1.occupied;
            copy_mask.toggleAll();

            var slots_to_copy = page2.occupied;
            slots_to_copy.setIntersection(copy_mask);

            var iter = slots_to_copy.iterator(.{});
            while (iter.next()) |slot_index| {
                var dest = page1.slotPtr(slot_index);
                const src = page2.slotPtr(slot_index);
                // std.debug.print("copying {d} into index {d}\n", .{ @bitCast(u128, src.*), slot_index });
                std.mem.copy(u8, dest, src);
            }

            self.deinitPage(node2);

            log.debug("remaping {*} to {*}\n", .{ page2.slots, page1.slots });
            _ = std.os.mmap(
                page2.startPtr(),
                page_size,
                MMAP_PROT_FLAGS,
                std.os.MAP.FIXED | MMAP_MAP_FLAGS,
                self.fd,
                self.page_offset(page1),
            ) catch @panic("failed to mesh pages");
        }

        fn meshAll(self: *Self) void {
            std.debug.assert(self.pages.first != null);
            std.debug.assert(self.pages.last != null);
            std.debug.assert(self.pages.len != 0); // this should be overly-cautious given the prior asserts
            const num_pages = self.pages.len;

            // NOTE: This means we cannot handle more than 256GiB worth of 4KiB pages in a pool
            std.debug.assert(num_pages <= std.math.maxInt(u16));
            // TODO: cache this in Self so we don't need to do it all the time
            // TODO: find a way to never panic (probably by allocating this slice on page alloc)
            var random_index = self.node_allocator.alloc(u16, num_pages) catch
                @panic("could not allocate random vector index");
            defer self.node_allocator.free(random_index);

            const random = self.rng.random();
            for (random_index) |*index, i| {
                index.* = @intCast(u16, i);
            }
            random.shuffle(u16, random_index);

            const max_offset = @min(self.pages.len, 20);
            var offset_to_random: usize = 0;
            while (offset_to_random < max_offset) : (offset_to_random += 1) {
                var page1_iter = self.pages.first;
                var page1_index: usize = 0;
                while (page1_iter) |page1| : ({
                    page1_iter = page1.next;
                    page1_index += 1;
                }) {
                    const i = (page1_index + offset_to_random) % num_pages;
                    const page2_index = random_index[i];
                    const page2 = self.getNthPage(page2_index);
                    if (canMesh(page1.data, page2.data)) {
                        log.debug("Merging pages {d} and {d}\n", .{ page1_index, page2_index });
                        self.meshPages(page1, page2);
                        return;
                    }
                }
            }
        }

        fn getNthPage(self: Self, index: usize) *PageNode {
            const num_pages = self.pages.len;
            if (index <= num_pages / 2) {
                var page = self.pages.first.?;
                var i: usize = 0;
                while (i < index) : (i += 1) {
                    page = page.next.?;
                }
                return page;
            } else {
                var page = self.pages.last.?;
                var i: usize = num_pages - 1;
                while (i > index) : (i -= 1) {
                    page = page.prev.?;
                }
                return page;
            }
        }

        fn pageCount(self: Self) usize {
            return self.pages.len + self.full_pages.len;
        }

        fn usedSlots(self: Self) usize {
            var slots: usize = 0;
            var it = self.pages.first;
            while (it) |node| : (it = node.next) {
                slots += node.data.occupied.count();
            }
            return self.full_pages.len * slot_count + slots;
        }

        pub fn ownsPtr(self: Self, ptr: *const anyopaque) bool {
            inline for (.{ self.full_pages, self.pages }) |*pages| {
                var it = pages.first;
                while (it) |node| : (it = node.next) {
                    if (node.data.ownsPtr(ptr)) return true;
                }
            }
            return false;
        }

        const Page = struct {
            slots: [*]align(page_size) Slot,
            occupied: BitSet,
            shuffle: Shuffle,

            const Slot = [slot_size]u8;

            fn init(ptr: PagePtr, random: std.rand.Random) Page {
                return .{
                    .slots = @ptrCast([*]Slot, ptr),
                    .occupied = BitSet.initEmpty(),
                    .shuffle = Shuffle.init(random),
                };
            }

            fn startPtr(page: Page) PagePtr {
                return @ptrCast(PagePtr, page.slots);
            }

            fn slotPtr(page: Page, index: usize) *Slot {
                const slot_ptr = page.slots + index;
                return @ptrCast(*Slot, slot_ptr);
            }

            fn slotIndex(page: Page, ptr: *Slot) usize {
                std.debug.assert(page.ownsPtr(ptr));
                const offset = @ptrToInt(ptr) - @ptrToInt(page.slots);
                return offset / slot_size;
            }

            fn nextIndexUnsafe(page: *Page) usize {
                return page.shuffle.pop();
            }

            fn allocSlot(page: *Page) ?*Slot {
                if (page.isFull()) return null;
                return allocSlotUnsafe();
            }

            fn allocSlotUnsafe(page: *Page) *Slot {
                const index = page.nextIndexUnsafe();
                page.occupied.set(index);
                return page.slotPtr(index);
            }

            inline fn freeIndex(page: *Page, index: usize) void {
                page.occupied.unset(index);
                page.shuffle.pushRaw(@intCast(ShuffleVector(slot_count).IndexType, index));
            }

            inline fn isFull(page: Page) bool {
                return page.occupied.count() == slot_count;
            }

            inline fn isEmpty(page: Page) bool {
                return page.occupied.count() == 0;
            }

            inline fn ownsPtr(page: Page, ptr: *const anyopaque) bool {
                return @ptrToInt(page.slots) == std.mem.alignBackward(@ptrToInt(ptr), page_size);
            }
        };
    };
}

test "PoolAllocator" {
    var pool = try PoolAllocator(16).init(std.testing.allocator, 0, 3);
    defer pool.deinit();

    try std.testing.expectEqual(256, PoolAllocator(16).slot_count);

    const p1 = pool.allocSlot().?;
    try std.testing.expectEqual(@as(usize, 1), pool.pageCount());
    try std.testing.expectEqual(@as(usize, 1), pool.usedSlots());

    const p2 = pool.allocSlot().?;
    try std.testing.expectEqual(@as(usize, 1), pool.pageCount());
    try std.testing.expectEqual(@as(usize, 2), pool.usedSlots());

    pool.freeSlot(p1);
    try std.testing.expectEqual(@as(usize, 1), pool.usedSlots());

    const p3 = pool.allocSlot().?;
    try std.testing.expectEqual(@as(usize, 1), pool.pageCount());
    try std.testing.expectEqual(@as(usize, 2), pool.usedSlots());

    pool.freeSlot(p3);
    pool.freeSlot(p2);
    try std.testing.expectEqual(@as(usize, 0), pool.usedSlots());
}

test "PoolAllocator page reclamation" {
    var pool = try PoolAllocator(16).init(std.testing.allocator, 0, 3);
    defer pool.deinit();

    var i: usize = 0;
    while (i < page_size / 16) : (i += 1) {
        _ = pool.allocSlot().?;
    }
    try std.testing.expectEqual(@as(usize, 1), pool.pageCount());
    try std.testing.expectEqual(@as(usize, 256), pool.usedSlots());
    const p4 = pool.allocSlot().?;
    try std.testing.expectEqual(@as(usize, 2), pool.pageCount());
    pool.freeSlot(p4);
    try std.testing.expectEqual(@as(usize, 1), pool.pageCount());
}

fn report(
    pool: PoolAllocator(16),
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
        const page = pool.full_pages.last orelse pool.pages.first.?;
        inline for (.{ 0, 1, 2 }) |index| {
            if (pointers[index]) |ptr| {
                log.debug("\tindex {d} has value {d} (by pointer {d})\n", .{
                    index,
                    @bitCast(u128, page.data.slotPtr(index).*),
                    @bitCast(u128, ptr.*),
                });
            }
        }
    }
}

test "mesh even and odd" {
    const Pool = PoolAllocator(16);
    var pool = try Pool.init(std.testing.allocator, 0, 2);
    defer pool.deinit();

    var pointers: [2 * page_size / 16]?*[16]u8 = .{null} ** (2 * page_size / 16);
    var i: usize = 0;
    while (i < 2 * page_size / 16) : (i += 1) {
        report(pool, &pointers, .before_alloc, i);

        const ptr = pool.allocSlot().?;
        const second_page = i > 255;
        const index = if (pool.pages.first) |page| page.data.slotIndex(ptr) else pool.full_pages.first.?.data.slotIndex(ptr);
        const pointer_index = if (second_page) index + 256 else index;
        std.debug.assert(pointers[pointer_index] == null);
        pointers[pointer_index] = ptr;

        report(pool, &pointers, .after_alloc, i);

        if (i == 256) {
            log.debug("writing to second page\n", .{});
            if (pointers[0]) |p|
                log.debug("\tindex {d} has value {d} (by pointer {d})\n", .{ 0, @bitCast(u128, pool.pages.first.?.data.slotPtr(0).*), @bitCast(u128, p.*) });
        }

        pointers[pointer_index].?.* = @bitCast([16]u8, @as(u128, pointer_index));

        report(pool, &pointers, .after_write, i);
    }
    log.debug("after writes: first page {d}; second page {d}; pointer[0] ({*}) {d}; pointer[256] ({*}) {d}\n", .{
        @bitCast(u128, pool.full_pages.first.?.data.slotPtr(0).*),
        @bitCast(u128, pool.full_pages.first.?.next.?.data.slotPtr(0).*),
        pointers[0],
        @bitCast(u128, pointers[0].?.*),
        pointers[256],
        @bitCast(u128, pointers[256].?.*),
    });

    try std.testing.expectEqual(@as(usize, 2), pool.pageCount());
    try std.testing.expectEqual(@as(usize, 2), pool.full_pages.len);
    try std.testing.expectEqual(@as(usize, 0), pool.pages.len);

    try std.testing.expectEqual(@as(u128, 0), @bitCast(u128, pointers[0].?.*));
    try std.testing.expectEqual(@as(u128, 1), @bitCast(u128, pointers[1].?.*));
    try std.testing.expectEqual(@as(u128, 256), @bitCast(u128, pointers[256].?.*));
    try std.testing.expectEqual(@as(u128, 257), @bitCast(u128, pointers[257].?.*));

    i = 2;
    var page1 = pool.full_pages.first.?;
    var page2 = page1.next.?;
    pool.freePageIndex(page1, 0, true);
    pool.freePageIndex(page2, 1, true);
    while (i < page_size / 16) : (i += 2) {
        pool.freePageIndex(page1, i, false);
        pool.freePageIndex(page2, i + 1, false);
    }
    try std.testing.expectEqual(@as(usize, 2), pool.pageCount());
    try std.testing.expectEqual(@as(usize, 0), pool.full_pages.len);
    try std.testing.expectEqual(@as(usize, 2), pool.pages.len);

    try std.testing.expect(Pool.canMesh(page1.data, page2.data));

    try std.testing.expectEqual(@as(u128, 0), @bitCast(u128, pointers[0].?.*));
    try std.testing.expectEqual(@as(u128, 1), @bitCast(u128, pointers[1].?.*));
    try std.testing.expectEqual(@as(u128, 2), @bitCast(u128, pointers[2].?.*));
    try std.testing.expectEqual(@as(u128, 3), @bitCast(u128, pointers[3].?.*));
    try std.testing.expectEqual(@as(u128, 4), @bitCast(u128, pointers[4].?.*));
    try std.testing.expectEqual(@as(u128, 5), @bitCast(u128, pointers[5].?.*));

    try std.testing.expectEqual(@as(u128, 256), @bitCast(u128, pointers[256].?.*));
    try std.testing.expectEqual(@as(u128, 257), @bitCast(u128, pointers[257].?.*));
    try std.testing.expectEqual(@as(u128, 258), @bitCast(u128, pointers[258].?.*));
    try std.testing.expectEqual(@as(u128, 259), @bitCast(u128, pointers[259].?.*));
    try std.testing.expectEqual(@as(u128, 260), @bitCast(u128, pointers[260].?.*));
    try std.testing.expectEqual(@as(u128, 261), @bitCast(u128, pointers[261].?.*));

    waitForInput();
    pool.meshAll();
    waitForInput();

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

fn waitForInput() void {
    const stdin = std.io.getStdIn().reader();
    var buf: [64]u8 = undefined;
    _ = stdin.readUntilDelimiter(&buf, '\n') catch return;
}

// fills a single page, then deinits it `count` times
pub fn benchmarkPoolAllocatorAllocSlot(pool: anytype, count: usize) void {
    var j: usize = 0;
    while (j < count) : (j += 1) {
        var i: usize = 0;
        while (i < std.meta.Child(@TypeOf(pool)).slot_count) : (i += 1) {
            _ = pool.allocSlot().?;
        }
        pool.deinitPage(pool.full_pages.first.?);
    }
}
