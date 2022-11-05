const std = @import("std");

pub fn ShuffleVector(comptime max_size: comptime_int) type {
    return struct {
        const Self = @This();

        list: std.BoundedArray(IndexType, max_size),
        random: std.rand.Random,

        pub const BitSet = std.StaticBitSet(max_size);
        pub const IndexType = std.math.IntFittingRange(0, max_size);

        pub fn init(random: std.rand.Random) Self {
            var vec = Self{
                .list = .{},
                .random = random,
            };
            vec.refill(BitSet.initEmpty());
            return vec;
        }

        pub fn clearAndRefill(self: *Self, bitset: BitSet) void {
            self.list.resize(0);
            self.fillFrom(bitset);
        }

        pub fn fillFrom(self: *Self, bitset: BitSet) void {
            std.debug.assert(if (self.list.ensureUnusedCapacity(bitset.count())) true else |_| false);
            var iter = bitset.iterator(.{});
            while (iter.next()) |index| {
                self.list.appendAssumeCapacity(@intCast(IndexType, index));
            }
        }

        pub fn refill(self: *Self, current: BitSet) void {
            var bitset = current;
            bitset.toggleAll();
            self.fillFrom(bitset);
            self.random.shuffle(IndexType, self.list.slice());
        }

        pub fn push(self: *Self, index: IndexType) !void {
            try self.list.ensureUnusedCapacity(1);
            self.pushRaw(index);
        }

        pub fn pushRaw(self: *Self, index: IndexType) void {
            self.list.appendAssumeCapacity(index);
            const len = self.list.len;
            const swap_offset = self.random.uintLessThan(usize, len);
            std.mem.swap(IndexType, &self.list.buffer[swap_offset], &self.list.buffer[len - 1]);
        }

        pub inline fn popOrNull(self: *Self) ?IndexType {
            return self.list.popOrNull();
        }

        pub inline fn pop(self: *Self) IndexType {
            return self.list.pop();
        }
    };
}

test {
    std.testing.refAllDecls(@This());
}
