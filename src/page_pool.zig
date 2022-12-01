const std = @import("std");
const Allocator = std.mem.Allocator;

const ShuffleVector = @import("shuffle_vector.zig").ShuffleVector;

const page_size = std.mem.page_size;

const PagePtr = [*]align(page_size) u8;

const log = std.log.scoped(.MeshingPool);

pub fn MeshingPool(comptime slot_size: comptime_int) type {
    comptime {
        if (slot_size > page_size)
            @compileError(std.fmt.comptimePrint(
                "Slot size ({d}) cannot be larger than the page size ({d})",
                .{ slot_size, page_size },
            ));
    }

    return struct {
        const Self = @This();

        all_pages: PageList,
        rng: std.rand.DefaultPrng,
        comptime slot_size: usize = slot_size,
        fd: std.os.fd_t,
        start: PagePtr,
        end: PagePtr,

        const HeaderIndex = std.math.IntFittingRange(0, headers_per_page);

        const Shuffle = ShuffleVector(slots_per_page);
        const headers_per_page = page_size / @sizeOf(PageHeader);
        pub const slots_per_page = page_size / slot_size;
        const BitSet = std.StaticBitSet(slots_per_page);

        const PageList = struct {
            headers: [*]align(page_size) PageHeader,
            current: ?usize = null,
            len: usize = 0,
            capacity: usize,

            fn get(self: PageList, index: usize) PageHeader {
                return self.headers[index];
            }

            fn getPtr(self: PageList, index: usize) *PageHeader {
                return &self.headers[index];
            }

            fn append(self: *PageList, page: PageHeader) !void {
                if (self.len == self.capacity) return error.ListFull;
                self.headers[self.len] = page;
                self.len += 1;
            }

            fn slice(self: PageList) []PageHeader {
                return self.headers[0..self.len];
            }

            fn swapRemove(self: *PageList, index: usize) PageHeader {
                std.debug.assert(self.len > 0);

                const removed = self.headers[index];
                self.headers[index] = self.headers[self.len - 1];

                if (self.len == 1) {
                    self.current = null;
                } else if (self.len == index) {
                    self.current = self.findNonFullPageIndex();
                }

                self.len -= 1;
                return removed;
            }

            fn findNonFullPageIndex(self: PageList) ?usize {
                if (self.current) |index| {
                    if (!self.get(index).isFull()) return index;
                }

                var i = self.current orelse 0;
                const len = self.len;
                const last = (i + len - 1) % len;
                while (i != last) : (i = (i + 1) % len) {
                    if (!self.get(i).isFull()) {
                        return i;
                    }
                } else if (!self.get(i).isFull()) {
                    return i;
                }
                return null;
            }
        };

        const MMAP_PROT_FLAGS = std.os.PROT.READ | std.os.PROT.WRITE;
        const MMAP_MAP_FLAGS = std.os.MAP.SHARED;

        pub fn init(seed: u64, max_page_count: usize) !Self {
            const fd = try std.os.memfd_create(std.fmt.comptimePrint("pool{d}", .{slot_size}), 0);
            errdefer std.os.close(fd);

            // data_page_count = header_page_count * headers_per_page
            //                 = (max_page_count - data_page_count) * headers_per_page
            const data_page_count = (max_page_count * headers_per_page) / (headers_per_page + 1);
            const header_page_count = (data_page_count + headers_per_page - 1) / headers_per_page;

            log.debug("creating pool with max_page_count = {d}; data_page_count = {d}; header_page_count = {d}", .{
                max_page_count,
                data_page_count,
                header_page_count,
            });

            const header_bytes = try std.os.mmap(
                null,
                data_page_count * @sizeOf(PageHeader),
                MMAP_PROT_FLAGS,
                std.os.MAP.PRIVATE | std.os.MAP.ANONYMOUS,
                -1,
                0,
            );
            errdefer std.os.munmap(header_bytes);

            const size = data_page_count * page_size;
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
                .all_pages = .{ .headers = @ptrCast([*]PageHeader, header_bytes.ptr), .capacity = data_page_count },
                .rng = std.rand.DefaultPrng.init(seed),
                // TODO: FD_CLOEXEC for multithreading
                .fd = fd,
                .start = start.ptr,
                .end = @alignCast(page_size, start.ptr + size),
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.all_pages.slice()) |*page| {
                releasePage(page.pagePtr());
            }
            const size = self.all_pages.capacity * @sizeOf(PageHeader);
            std.os.munmap(@ptrCast([*]u8, self.all_pages.headers)[0..size]);
            std.os.close(self.fd);
            self.* = undefined;
        }

        fn initPage(self: *Self) !void {
            const offset = self.pageCount() * page_size;
            const ptr = @alignCast(page_size, self.start + offset);
            if (@ptrToInt(ptr) >= @ptrToInt(self.end)) return error.NoMorePages;
            log.debug("initPage: offset {d}; ptr {*}", .{ offset, ptr });
            errdefer releasePage(ptr);
            try self.all_pages.append(PageHeader.init(ptr, self.rng.random()));
        }

        fn deinitPage(self: *Self, page_index: usize) void {
            log.debug("deiniting page {}", .{self.all_pages.headers[page_index]});
            std.debug.assert(self.all_pages.len > 0);

            const header = self.all_pages.swapRemove(page_index);
            const start_ptr = header.pagePtr();
            releasePage(start_ptr);
        }

        inline fn page_offset(self: Self, page: anytype) usize {
            const ptr = page.pagePtr();
            return @ptrToInt(ptr) - @ptrToInt(self.start);
        }

        fn expand(self: *Self, page_count: usize) !void {
            log.debug("expanding pool", .{});
            const len = self.all_pages.len;
            var i: usize = 0;
            while (i < page_count) : (i += 1) {
                try self.initPage();
            }
            if (self.all_pages.current == null) {
                self.all_pages.current = len;
            }
        }

        inline fn releasePage(ptr: PagePtr) void {
            // MADV.REMOVE is meant to work the same as fallocate with FL_PUNCH_HOLE
            std.os.madvise(ptr, page_size, std.os.MADV.REMOVE) catch @panic("couldn't madvise");
        }

        pub fn allocSlot(self: *Self) !*PageHeader.Slot {
            const page_index = self.all_pages.current orelse current: {
                self.expand(1) catch return error.OutOfMemory;
                break :current self.all_pages.current.?;
            };

            const page = self.all_pages.getPtr(page_index);
            const ptr = page.allocSlotUnsafe();
            if (page.isFull()) {
                self.all_pages.current = self.all_pages.findNonFullPageIndex();
            }
            return ptr;
        }

        pub fn freeSlot(self: *Self, ptr: *PageHeader.Slot) void {
            comptime std.debug.assert(slots_per_page > 1);

            for (self.all_pages.slice()) |*page, i| {
                if (page.ownsPtr(ptr)) {
                    const index = page.slotIndex(ptr);
                    page.freeIndex(index);
                    if (page.isEmpty()) {
                        self.deinitPage(i);
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
        fn meshPages(self: *Self, page1: PageHeader, page2: PageHeader, page2_index: usize) void {
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

            self.deinitPage(page2_index);

            log.debug("remaping {*} to {*}\n", .{ page2.slots, page1.slots });
            _ = std.os.mmap(
                page2.pagePtr(),
                page_size,
                MMAP_PROT_FLAGS,
                std.os.MAP.FIXED | MMAP_MAP_FLAGS,
                self.fd,
                self.page_offset(page1),
            ) catch @panic("failed to mesh pages");
        }

        fn meshAll(self: *Self, buf: []u8) void {
            // TODO(perf): don't scan over full pages...
            const num_pages = self.all_pages.len;
            std.debug.assert(num_pages > 1);

            std.debug.assert(num_pages <= std.math.maxInt(HeaderIndex));
            // TODO: cache this in Self so we don't need to do it all the time
            // TODO: find a way to never panic (probably by allocating this slice on page alloc)
            const random = self.rng.random();
            const rand_idx = @ptrCast([*]HeaderIndex, buf.ptr);
            const rand_len = buf.len / @sizeOf(HeaderIndex);
            std.debug.assert(rand_len >= 2 * num_pages);
            var rand_index1 = rand_idx[0..num_pages];
            var rand_index2 = rand_idx[num_pages .. 2 * num_pages];
            for (rand_index1[0..num_pages]) |*r, i| {
                r.* = @intCast(HeaderIndex, i);
            }
            random.shuffle(HeaderIndex, rand_index1[0..num_pages]);
            for (rand_index2[0..num_pages]) |*r, i| {
                r.* = @intCast(HeaderIndex, i);
            }
            random.shuffle(HeaderIndex, rand_index2[0..num_pages]);

            const max_offset = @min(num_pages, 20);
            var offset_to_random: usize = 0;
            while (offset_to_random < max_offset) : (offset_to_random += 1) {
                for (rand_index1[0..num_pages]) |page1_index, i| {
                    const page2_index = rand_index2[(i + offset_to_random) % num_pages];
                    const page1 = self.all_pages.get(page1_index);
                    const page2 = self.all_pages.get(page2_index);
                    if (canMesh(page1.occupied, page2.occupied)) {
                        log.debug("Merging pages {d} and {d}\n", .{ page1_index, page2_index });
                        self.meshPages(page1, page2, page2_index);
                        return;
                    }
                }
            }
        }

        inline fn pageCount(self: Self) usize {
            return self.all_pages.len;
        }

        fn usedSlots(self: Self) usize {
            var slots: usize = 0;
            for (self.all_pages.slice()) |page| {
                slots += page.occupied.count();
            }
            return slots;
        }

        pub fn ownsPtr(self: Self, ptr: *const anyopaque) bool {
            log.debug("ownsPtr({*})", .{ptr});
            const start = @ptrToInt(self.start);
            const end = @ptrToInt(self.end);
            const addr = @ptrToInt(ptr);
            return start <= addr and addr < end;
        }

        const PageHeader = struct {
            slots: [*]align(page_size) Slot,
            occupied: BitSet,
            shuffle: Shuffle,

            const Slot = [slot_size]u8;

            fn init(ptr: PagePtr, random: std.rand.Random) PageHeader {
                return .{
                    .slots = @ptrCast([*]Slot, ptr),
                    .occupied = BitSet.initEmpty(),
                    .shuffle = Shuffle.init(random),
                };
            }

            fn pagePtr(page: PageHeader) PagePtr {
                return @ptrCast(PagePtr, page.slots);
            }

            fn slotPtr(page: PageHeader, index: usize) *Slot {
                return &page.slots[index];
            }

            fn slotIndex(page: PageHeader, ptr: *Slot) usize {
                const offset = @ptrToInt(ptr) - @ptrToInt(page.slots);
                return offset / slot_size;
            }

            fn nextIndexUnsafe(page: *PageHeader) usize {
                return page.shuffle.pop();
            }

            fn allocSlot(page: *PageHeader) ?*Slot {
                if (page.isFull()) return null;
                return page.allocSlotUnsafe();
            }

            fn allocSlotUnsafe(page: *PageHeader) *Slot {
                const index = page.nextIndexUnsafe();
                page.occupied.set(index);
                const ptr = page.slotPtr(index);
                log.debug("pool allocated slot {d} at {*}", .{ index, ptr });
                return ptr;
            }

            inline fn freeIndex(page: *PageHeader, index: usize) void {
                page.occupied.unset(index);
                page.shuffle.pushRaw(@intCast(ShuffleVector(slots_per_page).IndexType, index));
            }

            inline fn isFull(page: PageHeader) bool {
                return page.occupied.count() == slots_per_page;
            }

            inline fn isEmpty(page: PageHeader) bool {
                return page.occupied.count() == 0;
            }

            inline fn ownsPtr(page: PageHeader, ptr: *const anyopaque) bool {
                return @ptrToInt(page.slots) == std.mem.alignBackward(@ptrToInt(ptr), page_size);
            }
        };
    };
}

test "MeshingPool" {
    var pool = try MeshingPool(16).init(0, 3);
    defer pool.deinit();

    try std.testing.expectEqual(256, MeshingPool(16).slots_per_page);

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

test "MeshingPool page reclamation" {
    var pool = try MeshingPool(16).init(0, 4);
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
    pool: MeshingPool(16),
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
        if (pool.all_pages.current) |page_index| {
            const page = pool.all_pages.get(page_index);
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
}

test "mesh even and odd" {
    const Pool = MeshingPool(16);
    var pool = try Pool.init(0, 3);
    defer pool.deinit();

    var pointers: [2 * page_size / 16]?*[16]u8 = .{null} ** (2 * page_size / 16);
    var i: usize = 0;
    while (i < 2 * page_size / 16) : (i += 1) {
        report(pool, &pointers, .before_alloc, i);

        const ptr = try pool.allocSlot();
        const second_page = i > 255;
        const index = pool.all_pages.get(pool.all_pages.len - 1).slotIndex(ptr);
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
    try std.testing.expectEqual(@as(usize, 2), pool.all_pages.len);

    try std.testing.expectEqual(@as(u128, 0), @bitCast(u128, pointers[0].?.*));
    try std.testing.expectEqual(@as(u128, 1), @bitCast(u128, pointers[1].?.*));
    try std.testing.expectEqual(@as(u128, 256), @bitCast(u128, pointers[256].?.*));
    try std.testing.expectEqual(@as(u128, 257), @bitCast(u128, pointers[257].?.*));

    i = 0;
    const page1 = pool.all_pages.getPtr(0);
    const page2 = pool.all_pages.getPtr(1);
    while (i < page_size / 16) : (i += 2) {
        pool.freeSlot(page1.slotPtr(i + 1));
        pool.freeSlot(page2.slotPtr(i));
    }
    try std.testing.expectEqual(@as(usize, 2), pool.pageCount());
    try std.testing.expectEqual(@as(usize, 256), pool.usedSlots());

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
    var buf: [16]u8 = undefined;
    pool.meshAll(&buf);
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
pub fn benchmarkMeshingPoolAllocSlot(pool: anytype, count: usize) !void {
    var j: usize = 0;
    while (j < count) : (j += 1) {
        var i: usize = 0;
        while (i < std.meta.Child(@TypeOf(pool)).slot_count) : (i += 1) {
            _ = try pool.allocSlot();
        }
        pool.deinitPage(pool.all_pages.pop());
    }
}
