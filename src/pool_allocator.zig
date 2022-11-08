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

        all_pages: PageList = .{},
        growing_page: ?usize = null,
        rng: std.rand.DefaultPrng,
        node_allocator: Allocator,
        comptime slot_size: usize = slot_size,
        fd: std.os.fd_t,
        start: PagePtr,
        end: PagePtr,

        const Shuffle = ShuffleVector(slot_count);

        const PageList = struct {
            list: std.SegmentedList(Page, 8) = .{},

            inline fn len(self: PageList) usize {
                return self.list.len;
            }

            fn GetType(comptime SelfType: type) type {
                if (@typeInfo(SelfType).Pointer.is_const) {
                    return *const Page;
                } else {
                    return *Page;
                }
            }

            inline fn get(self: anytype, index: usize) GetType(@TypeOf(self)) {
                return self.list.at(index);
            }

            inline fn append(self: *PageList, allocator: Allocator, page: Page) !void {
                try self.list.append(allocator, page);
            }

            inline fn pop(self: *PageList) Page {
                return self.list.pop().?;
            }

            inline fn deinit(self: *PageList, allocator: Allocator) void {
                self.list.deinit(allocator);
            }
        };

        pub const slot_count = page_size / slot_size;
        const BitSet = std.StaticBitSet(slot_count);

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
            var iter = self.all_pages.list.constIterator(0);
            while (iter.next()) |page| {
                releasePage(page.startPtr());
            }
            self.all_pages.deinit(self.node_allocator);
            std.os.close(self.fd);
        }

        fn initPage(self: *Self) !void {
            const offset = self.pageCount() * page_size;
            const ptr = @alignCast(page_size, self.start + offset);
            if (@ptrToInt(ptr) >= @ptrToInt(self.end)) return error.NoMorePages;
            log.debug("initPage: offset {d}; ptr {*}", .{ offset, ptr });
            errdefer releasePage(ptr);
            try self.all_pages.append(self.node_allocator, Page.init(ptr, self.rng.random()));
        }

        /// This function changes the Page pointed to by doing a swap removal on the PageList
        fn deinitPage(self: *Self, page: *Page) void {
            log.debug("deiniting page {}", .{page.*});
            std.debug.assert(self.all_pages.len() > 0);

            const change_growing = if (self.growing_page) |index| change_growing: {
                const growing = self.all_pages.get(index);
                if (growing == page) {
                    log.debug("deinited page was the current growing page", .{});
                    break :change_growing true;
                }
                break :change_growing false;
            } else false;

            const start_ptr = page.startPtr();
            if (self.all_pages.get(self.all_pages.len() - 1) == page) {
                _ = self.all_pages.pop();
            } else {
                page.* = self.all_pages.pop();
            }
            releasePage(start_ptr);

            if (change_growing) {
                self.growing_page = self.findNonFullPageIndex();
                log.debug("new growing page index: {?d}", .{self.growing_page});
            }
        }

        fn findNonFullPageIndex(self: *Self) ?usize {
            var iter = self.all_pages.list.constIterator(0);
            while (iter.next()) |page| {
                if (!page.isFull()) {
                    return iter.index - 1;
                }
            }
            return null;
        }

        inline fn page_offset(self: Self, page: anytype) usize {
            const ptr = page.startPtr();
            return @ptrToInt(ptr) - @ptrToInt(self.start);
        }

        fn expand(self: *Self, page_count: usize) !void {
            log.debug("expanding pool", .{});
            var i: usize = 0;
            while (i < page_count) : (i += 1) {
                try self.initPage();
            }
            if (self.growing_page == null) {
                self.growing_page = self.all_pages.len() - page_count;
            }
        }

        inline fn releasePage(ptr: PagePtr) void {
            // MADV.REMOVE is meant to work the same as fallocate with FL_PUNCH_HOLE
            std.os.madvise(ptr, page_size, std.os.MADV.REMOVE) catch @panic("couldn't madvise");
        }

        pub fn allocSlot(self: *Self) !*Page.Slot {
            const page_index = self.growing_page orelse index: {
                self.expand(1) catch return error.OutOfMemory;
                break :index self.growing_page.?;
            };

            const page = self.all_pages.get(page_index);

            const ptr = page.allocSlotUnsafe();
            if (page.isFull()) {
                const next_index = page_index + 1;
                self.growing_page = if (next_index >= self.all_pages.len())
                    null
                else
                    next_index;
            }
            return ptr;
        }

        pub fn freeSlot(self: *Self, ptr: *Page.Slot) void {
            comptime std.debug.assert(slot_count > 1);

            var iter = self.all_pages.list.iterator(0);
            while (iter.next()) |page| {
                if (page.ownsPtr(ptr)) {
                    const index = page.slotIndex(ptr);
                    page.freeIndex(index);
                    if (page.isEmpty()) {
                        self.deinitPage(page);
                    }
                    return;
                }
            }
        }

        fn canMesh(page1: BitSet, page2: BitSet) bool {
            var meshed_bitset = page1;
            meshed_bitset.setIntersection(page2);
            return meshed_bitset.count() == 0;
        }

        /// This function changes the Page pointed to by page2, by doing a swap removal on the PageList
        fn meshPages(self: *Self, page1: *const Page, page2: *Page) void {
            std.debug.assert(canMesh(page1.occupied, page2.occupied));
            log.debug("meshPages: {*} and {*}\n", .{ page1.slots, page2.slots });

            // copy data from page2 to page1
            var copy_mask = page1.occupied;
            copy_mask.toggleAll();

            var slots_to_copy = page2.occupied;
            slots_to_copy.setIntersection(copy_mask);

            var iter = slots_to_copy.iterator(.{});
            while (iter.next()) |slot_index| {
                const dest = page1.slotPtr(slot_index);
                const src = page2.slotPtr(slot_index);
                // std.debug.print("copying {d} into index {d}\n", .{ @bitCast(u128, src.*), slot_index });
                std.mem.copy(u8, dest, src);
            }

            self.deinitPage(page2);

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
            // TODO(perf): don't scan over full pages...
            const num_pages = self.all_pages.len();
            std.debug.assert(num_pages > 1);

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

            const max_offset = @min(num_pages, 20);
            var offset_to_random: usize = 0;
            while (offset_to_random < max_offset) : (offset_to_random += 1) {
                var iter = self.all_pages.list.constIterator(0);
                while (iter.next()) |page1| {
                    const page1_index = iter.index - 1;
                    const i = (page1_index + offset_to_random) % num_pages;
                    const page2_index = random_index[i];
                    const page2 = self.all_pages.get(page2_index);
                    if (canMesh(page1.occupied, page2.occupied)) {
                        log.debug("Merging pages {d} and {d}\n", .{ page1_index, page2_index });
                        self.meshPages(page1, page2);
                        return;
                    }
                }
            }
        }

        inline fn pageCount(self: Self) usize {
            return self.all_pages.len();
        }

        fn usedSlots(self: Self) usize {
            var slots: usize = 0;
            var iter = self.all_pages.list.constIterator(0);
            while (iter.next()) |page| {
                slots += page.occupied.count();
            }
            return slots;
        }

        pub fn ownsPtr(self: Self, ptr: *const anyopaque) bool {
            var iter = self.all_pages.list.constIterator(0);
            while (iter.next()) |page| {
                if (page.ownsPtr(ptr)) return true;
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

    const p1 = try pool.allocSlot();
    try std.testing.expectEqual(@as(usize, 1), pool.pageCount());
    try std.testing.expectEqual(@as(usize, 1), pool.usedSlots());

    const p2 = try pool.allocSlot();
    try std.testing.expectEqual(@as(usize, 1), pool.pageCount());
    try std.testing.expectEqual(@as(usize, 2), pool.usedSlots());

    pool.freeSlot(p1);
    try std.testing.expectEqual(@as(usize, 1), pool.usedSlots());

    const p3 = try pool.allocSlot();
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
        _ = try pool.allocSlot();
    }
    try std.testing.expectEqual(@as(usize, 1), pool.pageCount());
    try std.testing.expectEqual(@as(usize, 256), pool.usedSlots());
    const p4 = try pool.allocSlot();
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
        const page = pool.all_pages.get(0);
        inline for (.{ 0, 1, 2 }) |index| {
            if (pointers[index]) |ptr| {
                log.debug("\tindex {d} has value {d} (by pointer {d})\n", .{
                    index,
                    @bitCast(u128, page.slotPtr(index).*),
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

        const ptr = try pool.allocSlot();
        const second_page = i > 255;
        const index = pool.all_pages.get(pool.all_pages.len() - 1).slotIndex(ptr);
        const pointer_index = if (second_page) index + 256 else index;
        std.debug.assert(pointers[pointer_index] == null);
        pointers[pointer_index] = ptr;

        report(pool, &pointers, .after_alloc, i);

        pointers[pointer_index].?.* = @bitCast([16]u8, @as(u128, pointer_index));

        report(pool, &pointers, .after_write, i);
    }

    log.debug("after writes: first page {d}; second page {d}; pointer[0] ({*}) {d}; pointer[256] ({*}) {d}\n", .{
        @bitCast(u128, pool.all_pages.get(0).slotPtr(0).*),
        @bitCast(u128, pool.all_pages.get(1).slotPtr(0).*),
        pointers[0],
        @bitCast(u128, pointers[0].?.*),
        pointers[256],
        @bitCast(u128, pointers[256].?.*),
    });

    try std.testing.expectEqual(@as(usize, 2), pool.pageCount());
    try std.testing.expectEqual(@as(usize, 2), pool.all_pages.len());

    try std.testing.expectEqual(@as(u128, 0), @bitCast(u128, pointers[0].?.*));
    try std.testing.expectEqual(@as(u128, 1), @bitCast(u128, pointers[1].?.*));
    try std.testing.expectEqual(@as(u128, 256), @bitCast(u128, pointers[256].?.*));
    try std.testing.expectEqual(@as(u128, 257), @bitCast(u128, pointers[257].?.*));

    i = 0;
    const page1 = pool.all_pages.get(0);
    const page2 = pool.all_pages.get(1);
    while (i < page_size / 16) : (i += 2) {
        pool.freeSlot(page1.slotPtr(i + 1));
        pool.freeSlot(page2.slotPtr(i));
    }
    try std.testing.expectEqual(@as(usize, 2), pool.pageCount());

    try std.testing.expect(Pool.canMesh(page1.occupied, page2.occupied));

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
pub fn benchmarkPoolAllocatorAllocSlot(pool: anytype, count: usize) !void {
    var j: usize = 0;
    while (j < count) : (j += 1) {
        var i: usize = 0;
        while (i < std.meta.Child(@TypeOf(pool)).slot_count) : (i += 1) {
            _ = try pool.allocSlot();
        }
        pool.deinitPage(pool.all_pages.pop());
    }
}
