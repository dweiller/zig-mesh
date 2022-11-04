// TODO: first make a mesh allocator for a fixed slot size, i.e. a pool/object allocator that does meshing
//       Then reuse that code to make a GPA that has mesh allocators for different sizes
const std = @import("std");
const Allocator = std.mem.Allocator;

const ShuffleVector = @import("shuffle_vector.zig").ShuffleVector;

const page_allocator = std.heap.page_allocator;
const page_size = std.mem.page_size;

const PagePtr = [*]align(page_size) u8;

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

        // non-full pages, sorted from high to low occupancy
        pages: std.TailQueue(Page) = .{},
        full_pages: std.TailQueue(Page) = .{},
        rng: std.rand.DefaultPrng,
        node_allocator: Allocator,

        pub const slot_count = page_size / slot_size;
        const BitSet = std.StaticBitSet(slot_count);
        const PageNode = std.TailQueue(Page).Node;

        pub fn init(node_allocator: Allocator, seed: u64) Self {
            return .{
                .rng = std.rand.DefaultPrng.init(seed),
                .node_allocator = node_allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            inline for (.{ self.full_pages, self.pages }) |*pages| {
                while (pages.pop()) |node| {
                    self.deinitPage(node);
                }
            }
        }

        fn initPage(self: *Self) !*Page {
            const ptr = try getPage();
            errdefer releasePage(ptr);
            const page = try self.node_allocator.create(PageNode);
            page.* = .{ .data = Page.init(ptr, self.rng.random()) };
            self.pages.append(page);
            return &page.data;
        }

        fn deinitPage(self: *Self, page: *PageNode) void {
            if (page.data.isFull())
                self.full_pages.remove(page)
            else
                self.pages.remove(page);
            releasePage(@ptrCast(PagePtr, page.data.slots));
            self.node_allocator.destroy(page);
        }

        fn allocSlot(self: *Self) ?*Page.Slot {
            var found_page: ?*Page = null;
            var it = self.pages.first;
            while (it) |node| : (it = node.next) {
                if (!node.data.isFull()) {
                    found_page = &node.data;
                    break;
                }
            }

            var page: *Page = if (found_page) |page| page else self.initPage() catch return null;
            const ptr = page.allocSlotUnsafe();
            if (page.isFull()) {
                self.pages.remove(it.?);
                self.full_pages.prepend(it.?);
            }
            return ptr;
        }

        fn freeSlot(self: *Self, ptr: *Page.Slot) void {
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

        const Page = struct {
            slots: [*]align(page_size) Slot,
            occupied: BitSet,
            shuffle: Shuffle,

            const Shuffle = ShuffleVector(slot_count);

            const Slot = [slot_size]u8;

            fn init(ptr: PagePtr, random: std.rand.Random) Page {
                return .{
                    .slots = @ptrCast([*]Slot, ptr),
                    .occupied = BitSet.initEmpty(),
                    .shuffle = Shuffle.init(random),
                };
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

            inline fn ownsPtr(page: Page, ptr: *const Slot) bool {
                return @ptrToInt(page.slots) == std.mem.alignBackward(@ptrToInt(ptr), page_size);
            }
        };
    };
}

inline fn getPage() !PagePtr {
    const slice = std.os.mmap(
        null,
        page_size,
        std.os.PROT.READ | std.os.PROT.WRITE,
        std.os.MAP.PRIVATE | std.os.MAP.ANONYMOUS,
        -1,
        0,
    ) catch return error.OutOfMemory;
    return slice.ptr;
}

inline fn releasePage(ptr: PagePtr) void {
    std.os.munmap(ptr[0..page_size]);
}

test "PoolAllocator" {
    var pool = PoolAllocator(16).init(std.testing.allocator, 0);
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
    var pool = PoolAllocator(16).init(std.testing.allocator, 0);
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

test "even and odd meshable" {
    const Pool = PoolAllocator(16);
    var pool = Pool.init(std.testing.allocator, 0);
    defer pool.deinit();
    var i: usize = 0;
    while (i < 2 * page_size / 16) : (i += 1) {
        _ = pool.allocSlot().?;
    }
    try std.testing.expectEqual(@as(usize, 2), pool.pageCount());
    try std.testing.expectEqual(@as(usize, 2), pool.full_pages.len);
    try std.testing.expectEqual(@as(usize, 0), pool.pages.len);

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
