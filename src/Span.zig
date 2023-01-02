//! A `Span` is a single contiguous region of virtual memory used to hold
//! allocations for a single size class, along with associated metadata. A
//! `Span` is created with a given alignment and metadata is stored at the start
//! of the memory owned by the `Span` making it trivial to get to the metadata
//! given the pointer for an allocation.
//!
//! A `std.mem.Allocator` is not required to obtain a new `Span`, as the
//! implementation will directly use the OS virtual mapping facilities.

const std = @import("std");
const builtin = @import("builtin");

const log = std.log.scoped(.Core);

const page_size = std.mem.page_size;

const assert = @import("mesh.zig").assert;

const Span = @This();

page_count: usize,
ptr: [*]align(page_size) u8, // pointer to the mapped memory
fd: std.os.fd_t, // a valid file descriptor is required for remapping addresses

/// Initialise a new span. `page_count` must be at most 16.
pub fn init(alignment: usize, page_count: usize) !Span {
    assert(alignment >= page_count * page_size);
    const size = page_count * page_size;
    const oversized = size + alignment - 1;

    const fd = try std.os.memfd_create("mesh-span", 0);
    errdefer (std.os.close(fd));

    try std.os.ftruncate(fd, @as(u64, size));

    const MMAP_PROT_FLAGS = std.os.PROT.READ | std.os.PROT.WRITE;
    const MMAP_MAP_FLAGS = std.os.MAP.SHARED;

    const unaligned = try std.os.mmap(null, oversized, MMAP_PROT_FLAGS, std.os.MAP.ANONYMOUS | MMAP_MAP_FLAGS, -1, 0);
    const unaligned_address = @ptrToInt(unaligned.ptr);

    const aligned_address = std.mem.alignForward(unaligned_address, alignment);
    const aligned = @intToPtr([*]align(page_size) u8, aligned_address);

    const align_offset = aligned_address - unaligned_address;
    const initial_unused_pages = unaligned[0..align_offset];
    const trailing_unused_pages = @alignCast(page_size, aligned[size .. oversized - align_offset]);

    _ = try std.os.mmap(aligned, size, MMAP_PROT_FLAGS, std.os.MAP.FIXED | MMAP_MAP_FLAGS, fd, 0);

    if (align_offset > 0)
        std.os.munmap(initial_unused_pages);

    std.os.munmap(trailing_unused_pages);

    return Span{
        .page_count = @intCast(u16, page_count),
        .ptr = aligned,
        .fd = fd,
    };
}

pub fn deinit(self: *Span) void {
    std.os.munmap(self.ptr[0 .. @as(usize, self.page_count) * page_size]);
    std.os.close(self.fd);
    self.page_count = 0;
    self.ptr = undefined;
    self.fd = undefined;
}

test {
    var span = try init(page_size * 16, 16);
    defer span.deinit();

    span.ptr[0] = 5;
    span.ptr[16 * page_size - 1] = 7;
    try std.testing.expectEqual(@as(u8, 5), span.ptr[0]);
    try std.testing.expectEqual(@as(u8, 7), span.ptr[16 * page_size - 1]);

    try std.testing.expect(std.mem.isAligned(@ptrToInt(span.ptr), 1 << 16));
}
