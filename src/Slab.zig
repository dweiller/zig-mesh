//! A `Slab` is a span of memory used for allocations of a specific size class.
//!
//! Each `Slab` is backed by a single `Span` and stores metadata required for
//! page meshing and allocator book-keeping. Each `Slab` has one or more pages
//! of metadata, stored at the start of the allocation, followed by pages
//! containing the allocation slots. `Slab`s have maximum size are aligned to
//! (and have maximum size of) 64KiB so that it is trivial to retrieve metadata
//! given a pointer to an allocation in a `Slab`.
//!
//! The primary metadata stored in a `Slab` is a bitset of active slots (i.e.
//! allocated but not freed), along with the size class and slot count.
//! The metadata is stored on the first page of the `Span`, with slots starting
//! on the second page (the size of all metadata is checked at compile-time to
//! ensure is it less than 1 page in size).
//!
//! The slot size is always a multiple of 16, though it need not be a power of
//! 2.

const std = @import("std");
const BitSet = std.StaticBitSet(params.slots_per_slab_max);

const params = @import("params.zig");

const Pool = @import("MeshingPool.zig");
const Span = @import("Span.zig");

const PagePtr = [*]align(page_size) u8;

const page_size = std.mem.page_size;
pub const SlotIndex = std.math.IntFittingRange(0, params.slots_per_slab_max - 1);

const assert = @import("util.zig").assert;

/// `Slab` cannot be copied (and so should be passed by pointer), as this would detach the metadata from allocations
const Slab = @This();
pub const Ptr = *align(params.slab_alignment) Slab;
pub const ConstPtr = *align(params.slab_alignment) const Slab;

pub const List = struct {
    head: ?Ptr = null,
    len: usize = 0,

    pub fn remove(self: *List, slab: Ptr) void {
        assert(self.len > 0);
        self.head = if (slab.next == slab) null else slab.next;
        slab.next.prev = slab.prev;
        slab.prev.next = slab.next;
        slab.next = slab;
        slab.prev = slab;
        self.len -= 1;
    }

    pub fn append(self: *List, slab: Ptr) void {
        assert(slab.next == slab and slab.prev == slab);
        if (self.head) |head| {
            head.prev.next = slab;
            slab.prev = head.prev;
            slab.next = head;
            head.prev = slab;
            self.len += 1;
        } else {
            self.head = slab;
            self.len = 1;
        }
    }
};

slot_size: usize,
page_count: usize,
slot_count: usize,
fd: std.os.fd_t,
bitset: BitSet,
next: Ptr,
prev: Ptr,

comptime {
    assert(@sizeOf(Slab) <= page_size);
}

pub fn init(slot_size: usize, page_count: usize) !Ptr {
    params.assertSlotSizeValid(slot_size);
    params.assertPageCountValid(page_count);

    const span = try Span.init(params.slab_alignment, page_count);
    const slab = @ptrCast(Ptr, @alignCast(params.slab_alignment, span.ptr));

    slab.* = Slab{
        .slot_size = slot_size,
        .page_count = span.page_count,
        .slot_count = ((span.page_count - 1) * page_size) / slot_size,
        .fd = span.fd,
        .bitset = BitSet.initEmpty(),
        .next = slab,
        .prev = slab,
    };

    return slab;
}

/// unmap the memory backing a `Slab`
pub fn deinit(self: Ptr) void {
    var span = Span{
        .page_count = self.page_count,
        .ptr = @ptrCast(PagePtr, self),
        .fd = self.fd,
    };
    span.deinit();
}

pub fn markUnused(self: Ptr) !void {
    try std.os.madvise(
        @ptrCast([*]align(page_size) u8, self) + page_size,
        (self.page_count - 1) * page_size,
        std.os.MADV.DONTNEED,
    );
}

pub fn ownsPtr(self: ConstPtr, ptr: *anyopaque) bool {
    // WARNING: does not check ptr is within the page range given by page_count and data_start
    return @ptrToInt(self) == slabAddress(ptr);
}

pub fn slabAddress(ptr: *anyopaque) usize {
    return std.mem.alignBackward(@ptrToInt(ptr), params.slab_alignment);
}

pub fn allocSlot(self: Ptr, slot_index: usize) []u8 {
    assert(!self.bitset.isSet(slot_index));
    self.bitset.set(slot_index);
    return self.slot(slot_index);
}

pub fn freeSlot(self: Ptr, slot_index: usize) void {
    assert(self.bitset.isSet(slot_index));
    self.bitset.unset(slot_index);
}

pub fn slot(self: Ptr, slot_index: usize) []u8 {
    const ptr = @ptrCast([*]u8, self) + (page_size + slot_index * self.slot_size);
    return ptr[0..self.slot_size];
}

fn slotOffset(self: ConstPtr, ptr: *anyopaque) usize {
    const addr = @ptrToInt(ptr);
    const offset = addr - (@ptrToInt(self) + page_size);
    return offset;
}
pub fn indexOf(self: ConstPtr, ptr: *anyopaque) usize {
    assert(self.ownsPtr(ptr));
    return self.slotOffset(ptr) / self.slot_size;
}

pub fn isInSlot(self: ConstPtr, ptr: *anyopaque, slot_index: usize) bool {
    assert(slot_index < self.slot_count);
    return self.slotOffset(ptr) / self.slot_size == slot_index;
}

pub fn usedSlots(self: ConstPtr) usize {
    return self.bitset.count();
}

test {
    var pool = try Slab.init(16, 16);
    defer pool.deinit();
}
