//! A `Slab` is a span of memory used for allocations of a specific size class.
//!
//! Each `Slab` is backed by a single `Span` and stores metadata required for
//! page meshing and allocator book-keeping. Each `Slab` has one or more pages
//! of metadata, stored at the start of the allocation, followed by pages
//! containing the allocation slots. `Slab`s have maximum size of and are
//! aligned to 64KiB so that it is trivial to retrieve metadata given a pointer
//! to an allocation in a `Slab`.
//!
//! The metadata pages consist of a header, followed by two arrays of per-page
//! metadata, (i.e. each of length `page_count`); these are:
//!
//!     1. an array of BitSets, indicating which slots of the corresponding data
//!     page are occupied
//!
//!     2. an array of ShuffleVectors useds to randomise slot choice for
//!     allocation in the the corresponding data page
//!
//! Depending on the number of pages in the `Slab`, and the size class of the
//! `Slab` there may be more than one page of metadata, so a pointer to the
//! start of the first data page is stored.
//!
//! The slot size is always a multiple of 16, though it need not be a power of
//! 2.

const std = @import("std");
const BitSet = std.DynamicBitSetUnmanaged;

const params = @import("params.zig");

const Pool = @import("MeshingPool.zig");
const Span = @import("Span.zig");

const PagePtr = [*]align(page_size) u8;

const page_size = std.mem.page_size;
pub const PageIndex = u16;
pub const SlotIndex = std.math.IntFittingRange(0, params.max_slot_count - 1);
const ShuffleVector = @import("shuffle_vector.zig").ShuffleVectorUnmanaged(SlotIndex);

const assert = @import("mesh.zig").assert;

/// `Slab` cannot be copied (and so should be passed by pointer), as this would detach the metadata from allocations
const Slab = @This();

page_mark: u16,
slot_size: u16,
page_count: u16,
data_start: u16, // number of metadata pages/page offset to first data page
fd: std.os.fd_t,
empty_pages: PageList,
partial_pages: PageList,
current_index: ?PageIndex,

// a PageList.Node for a empty_pages or partial_pages is always stored in a free slot in the associated page
// so the page index can be gotten by using indexOf(node_ptr), the page index could be stored in the node
// though indexOf should reduce cache pollution, as it only loads from the Slab header
const PageList = std.SinglyLinkedList(void);
comptime {
    assert(@sizeOf(PageList.Node) <= params.slot_size_min);
}

const bitset_offset = std.mem.alignForward(@sizeOf(Slab), @alignOf(BitSet));

fn bitsetDataOffset(data_page_count: usize) usize {
    return std.mem.alignForward(
        bitset_offset + @sizeOf(BitSet) * data_page_count,
        @alignOf(BitSet.MaskInt),
    );
}

fn shuffleOffset(slots_per_page: usize, data_page_count: usize) usize {
    const bitset_data_offset = bitsetDataOffset(data_page_count);

    const bitset_masks_per_page = (slots_per_page + @bitSizeOf(BitSet.MaskInt) - 1) / @bitSizeOf(BitSet.MaskInt) + 1;
    const bitset_data_bytes_total = bitset_masks_per_page * @sizeOf(BitSet.MaskInt) * data_page_count;

    return std.mem.alignForward(
        bitset_data_offset + bitset_data_bytes_total,
        @alignOf(ShuffleVector),
    );
}

fn shuffleDataOffset(shuffle_offset: usize, data_page_count: usize) usize {
    return std.mem.alignForward(
        shuffle_offset + @sizeOf(ShuffleVector) * data_page_count,
        @alignOf(ShuffleVector.IndexType),
    );
}

fn metadataPageCount(slots_per_page: usize, data_page_count: usize) usize {
    const shuffle_offset = shuffleOffset(slots_per_page, data_page_count);
    const shuffle_data_offset = shuffleDataOffset(shuffle_offset, data_page_count);
    const shuffle_data_bytes_total = slots_per_page * data_page_count * @sizeOf(ShuffleVector.IndexType);

    const one_past_metadata_end = shuffle_data_offset + shuffle_data_bytes_total;

    return std.mem.alignForward(one_past_metadata_end, page_size) / page_size;
}

pub fn init(random: std.rand.Random, slot_size: usize, max_pages: usize) !*align(params.slab_alignment) Slab {
    params.assertSlotSizeValid(slot_size);
    params.assertMaxPagesValid(max_pages);

    const slots_per_page = page_size / slot_size;

    var data_pages: usize = max_pages;
    var meta_pages: usize = 1;
    while (data_pages + meta_pages > max_pages) : (data_pages -= 1) {
        meta_pages = metadataPageCount(slots_per_page, data_pages);
    }
    assert(meta_pages <= std.math.maxInt(u16));
    const page_count = data_pages + meta_pages;
    // const data_pages = (min_slots + slots_per_page - 1) / slots_per_page;
    // const metadata_pages = metadataPageCount(slots_per_page, data_pages);
    // const page_count = data_pages + metadata_pages;

    const span = try Span.init(params.slab_alignment, page_count);
    const slab = @ptrCast(*Slab, @alignCast(params.slab_alignment, span.ptr));

    slab.* = Slab{
        .slot_size = @intCast(u16, slot_size),
        .page_mark = 0,
        .page_count = span.page_count,
        .data_start = @intCast(u16, meta_pages),
        .fd = span.fd,
        .partial_pages = .{},
        .empty_pages = .{},
        .current_index = null,
    };

    // TODO: consider lazy initialisation (i.e. an initPage(index) function that sets up a bitset/shuffle pair)
    initBitSets(slab, slots_per_page, data_pages);
    initShuffles(slab, random, slots_per_page, data_pages);
    return slab;
}

fn initBitSets(pool: *Slab, slots_per_page: usize, data_pages: usize) void {
    const base_addr = @ptrToInt(pool);
    const bitset_ptr = @intToPtr([*]BitSet, base_addr + bitset_offset);

    // use a FixedBufferAllocator that allocates from the memory immediately following the pool struct
    const bitset_data_ptr = @intToPtr([*]BitSet.MaskInt, base_addr + bitsetDataOffset(data_pages));
    // add one for mask len (see implementation of DynamicBitSet)
    const bitset_masks_per_page = (slots_per_page + @bitSizeOf(BitSet.MaskInt) - 1) / @bitSizeOf(BitSet.MaskInt) + 1;
    const bitset_buf_len = (bitset_masks_per_page * data_pages);
    const bitset_data_buf = std.mem.sliceAsBytes(bitset_data_ptr[0..bitset_buf_len]);

    var fba = std.heap.FixedBufferAllocator.init(bitset_data_buf);
    const allocator = fba.allocator();

    var i: usize = 0;
    while (i < data_pages) : (i += 1) {
        bitset_ptr[i] = BitSet.initEmpty(allocator, slots_per_page) catch unreachable;
    }
}

fn initShuffles(pool: *Slab, random: std.rand.Random, slots_per_page: usize, data_pages: usize) void {
    const base_addr = @ptrToInt(pool);
    const shuffle_offset = shuffleOffset(slots_per_page, data_pages);
    const shuffle_ptr = @intToPtr([*]ShuffleVector, base_addr + shuffle_offset);

    const shuffle_data_ptr = @intToPtr([*]ShuffleVector.IndexType, base_addr + shuffleDataOffset(shuffle_offset, data_pages));
    const shuffle_buf_len = slots_per_page * data_pages;
    const shuffle_data_buf = shuffle_data_ptr[0..shuffle_buf_len];

    var i: usize = 0;
    while (i < data_pages) : (i += 1) {
        shuffle_ptr[i] = ShuffleVector.init(random, shuffle_data_buf[i * slots_per_page .. (i + 1) * slots_per_page]);
    }
}

/// unmap the memory backing a `Slab`
pub fn deinit(self: *align(params.slab_alignment) Slab) void {
    var span = Span{
        .page_count = self.page_count,
        .ptr = @ptrCast(PagePtr, self),
        .fd = self.fd,
    };
    span.deinit();
}

pub fn dataPage(self: *const Slab, page_index: usize) PagePtr {
    return @intToPtr(PagePtr, @ptrToInt(self) + (self.data_start + page_index) * page_size);
}

pub fn ownsPtr(self: *const Slab, ptr: *anyopaque) bool {
    // WARNING: does not check ptr is within the page range given by page_count and data_start
    return @ptrToInt(self) == slabAddress(ptr);
}

pub fn slabAddress(ptr: *anyopaque) usize {
    return std.mem.alignBackward(@ptrToInt(ptr), params.slab_alignment);
}

pub fn allocSlot(self: *Slab) ?[]u8 {
    const page_index = self.current_index orelse return self.allocSlotSlow();

    const page_shuffle = self.shuffle(page_index);
    const page_bitset = self.bitset(page_index);

    assert(page_shuffle.count() > 0);

    if (page_shuffle.count() == 1) {
        self.current_index = if (self.partial_pages.popFirst()) |node| self.indexOf(node).page else null;
    }

    const slot_index = page_shuffle.pop();
    assert(!page_bitset.isSet(slot_index));

    page_bitset.set(slot_index);

    return self.slot(page_index, slot_index);
}

// allocation slow path, need to grab never used page (if there is one) or initialise new slab
// Returns the slice of the allocatted slot, unless the `Slab` is full, in which case `null` is
// returned.
fn allocSlotSlow(self: *Slab) ?[]u8 {
    if (self.partial_pages.popFirst() orelse self.empty_pages.popFirst()) |node| {
        self.current_index = self.indexOf(node).page;
        return self.allocSlot();
    }

    if (self.page_mark < self.page_count - self.data_start) {
        // there are pages that have never been used
        const page_index = self.page_mark;
        self.page_mark += 1;

        self.current_index = page_index;
        return self.allocSlot();
    }

    return null;
}

pub fn freeSlot(self: *Slab, random: std.rand.Random, index: Index) void {
    const page_bitset = self.bitset(index.page);
    const page_shuffle = self.shuffle(index.page);

    page_bitset.unset(index.slot);
    page_shuffle.pushAssumeCapacity(random, @intCast(ShuffleVector.IndexType, index.slot));

    const count = page_bitset.count();
    if (count == page_bitset.bit_length - 1) {
        // was a full page, need to add to partial list
        const freed_slot = self.slot(index.page, index.slot);
        const node = @ptrCast(*PageList.Node, @alignCast(@alignOf(PageList.Node), freed_slot.ptr));
        node.* = PageList.Node{ .data = {} };
        self.partial_pages.prepend(node);
    } else if (count > 0) {
        // do we want partial list to be ordered?
    } else {
        self.freePage(index.page);
    }
}

pub fn freePage(self: *Slab, page_index: usize) void {
    if (self.current_index) |index| {
        if (page_index == index) self.current_index = null;
    }

    var iter = self.partial_pages.first;
    if (iter != null and self.indexOf(iter.?).page == page_index) {
        self.partial_pages.first = iter.?.next;
    } else {
        while (iter) |node| : (iter = node.next) {
            if (node.next != null and self.indexOf(node.next.?).page == page_index) {
                node.next = node.next.?.next;
            }
        }
    }
    const page = self.dataPage(page_index);
    const node = @ptrCast(*PageList.Node, page);
    node.* = PageList.Node{ .data = {} };
    self.empty_pages.prepend(node);
    std.os.madvise(@ptrCast([*]u8, page), page_size, std.os.MADV.DONTNEED) catch @panic("couldn't madvise");
}

pub fn bitset(self: *const Slab, page_index: usize) *BitSet {
    const offset = bitset_offset + @sizeOf(BitSet) * page_index;
    return @intToPtr(*BitSet, @ptrToInt(self) + offset);
}

pub fn shuffle(self: *const Slab, page_index: usize) *ShuffleVector {
    const slots_per_page = page_size / self.slot_size;
    const self_shuffle_offset = shuffleOffset(slots_per_page, self.page_count - self.data_start);
    const offset = self_shuffle_offset + @sizeOf(ShuffleVector) * page_index;
    return @intToPtr(*ShuffleVector, @ptrToInt(self) + offset);
}

pub fn slot(self: *const Slab, page_index: usize, slot_index: usize) []u8 {
    const ptr = @ptrCast([*]u8, self.dataPage(page_index)) + slot_index * self.slot_size;
    return ptr[0..self.slot_size];
}

const Index = struct { page: PageIndex, slot: SlotIndex };
pub fn indexOf(self: *const Slab, ptr: *anyopaque) Index {
    assert(self.ownsPtr(ptr));
    const addr = @ptrToInt(ptr);
    const offset = addr - @ptrToInt(self);
    const page_index = offset / page_size - self.data_start;
    const intra_page_offset = offset % page_size;
    const intra_page_index = intra_page_offset / self.slot_size;
    return Index{
        .page = @intCast(PageIndex, page_index),
        .slot = @intCast(SlotIndex, intra_page_index),
    };
}

test {
    var rng = std.rand.DefaultPrng.init(0);
    var pool = try Slab.init(rng.random(), 16, 16);
    defer pool.deinit();
}
