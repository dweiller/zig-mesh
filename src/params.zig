const std = @import("std");

const assert = @import("util.zig").assert;

const page_size = std.mem.page_size;
// TODO: allow slot sizes larger than the page_size; this would require
// refactoring to mesh `Blocks` that are of arbitrary size. Along with bigger
// slot sizes, this change would allow tuning the slot size vs the block size
// for optimal performance or memory overhead (bigger blocks means larger
// bitsets/shuffle vectors).
pub const slab_alignment = 1 << 16; // 64KiB
pub const slab_size_max = slab_alignment;
pub const slab_data_size_max = slab_size_max - page_size;

pub const slot_size_max = slab_size_max / 8;
pub const slot_size_min = 16;

pub const slots_per_slab_max = slab_data_size_max / slot_size_min;
pub const slab_page_count_max = slab_size_max / page_size;

comptime {
    assert(slot_size_max <= std.math.maxInt(u16));
}

pub fn assertSlotSizeValid(slot_size: usize) void {
    assert(slot_size != 0);
    assert(slot_size <= slot_size_max);
    assert(slot_size % slot_size_min == 0);
}

pub fn assertPageCountValid(page_count: usize) void {
    assert(page_count <= slab_page_count_max);
}
