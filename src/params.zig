const std = @import("std");

const page_size = std.mem.page_size;
// TODO: allow slot sizes larger than the page_size; this would require
// refactoring to mesh `Blocks` that are of arbitrary size. Along with bigger
// slot sizes, this change would allow tuning the slot size vs the block size
// for optimal performance or memory overhead (bigger blocks means larger
// bitsets/shuffle vectors).
pub const slot_size_max = page_size / 2;
pub const slot_size_min = 16;
pub const max_slot_count = page_size / slot_size_min;
pub const slab_alignment = 1 << 16; // 64KiB

comptime {
    std.debug.assert(slot_size_max <= std.math.maxInt(u16));
}

pub fn assertSlotSizeValid(slot_size: usize) void {
    std.debug.assert(slot_size != 0);
    std.debug.assert(slot_size <= slot_size_max);
    std.debug.assert(slot_size % slot_size_min == 0);
}

pub fn assertMaxPagesValid(max_pages: usize) void {
    std.debug.assert(max_pages <= slab_alignment / page_size);
}
