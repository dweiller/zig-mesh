const std = @import("std");
const Random = std.rand.Random;

pub fn StaticShuffleVector(comptime max_size: comptime_int) type {
    return struct {
        const Self = @This();

        buffer: [max_size]IndexType,
        vec: ShuffleVector(IndexType),

        pub const IndexType = std.math.IntFittingRange(0, max_size);

        pub fn init(random: std.rand.Random) Self {
            var self = Self{
                .buffer = undefined,
                .vec = undefined,
            };
            self.vec = ShuffleVector(IndexType).init(random, self.buffer[0..max_size]);
            return self;
        }

        pub inline fn push(self: *Self, index: IndexType) !void {
            try self.vec.push(index);
        }

        pub inline fn pushAssumeCapacity(self: *Self, index: IndexType) void {
            self.vec.pushAssumeCapacity(index);
        }

        pub inline fn popOrNull(self: *Self) ?IndexType {
            return self.vec.popOrNull();
        }

        pub inline fn pop(self: *Self) IndexType {
            return self.vec.pop();
        }
    };
}

pub fn ShuffleVector(comptime T: type) type {
    comptime {
        if (@typeInfo(T) != .Int and @typeInfo(T).Int.signedness != .unsigned) {
            @compileError("T must be an unsigned integer, got " ++ @typeName(T));
        }
    }
    return struct {
        const Self = @This();

        indices: FixedBuffer(IndexType),
        random: Random,

        pub const IndexType = T;

        pub fn init(random: Random, buffer: []IndexType) Self {
            std.debug.assert(buffer.len - 1 <= std.math.maxInt(IndexType));
            for (buffer) |*index, i| {
                index.* = @intCast(IndexType, i);
            }
            random.shuffle(IndexType, buffer);

            return Self{
                .indices = FixedBuffer(IndexType).initLen(buffer, buffer.len),
                .random = random,
            };
        }

        pub fn push(self: *Self, index: IndexType) !void {
            try self.indices.append(index);
            self.pushSwap();
        }

        pub fn pushAssumeCapacity(self: *Self, index: IndexType) void {
            self.indices.appendAssumeCapacity(index);
            self.pushSwap();
        }

        pub fn pushSwap(self: *Self) void {
            const len = self.indices.items.len;
            const swap_offset = self.random.uintLessThan(usize, len);
            std.mem.swap(IndexType, &self.indices.items[swap_offset], &self.indices.items[len - 1]);
        }

        pub inline fn popOrNull(self: *Self) ?IndexType {
            return self.indices.popOrNull();
        }

        pub inline fn pop(self: *Self) IndexType {
            return self.indices.pop();
        }
    };
}

pub fn FixedBuffer(comptime T: type) type {
    return struct {
        const Self = @This();

        items: []T,
        capacity: usize,

        pub fn init(buffer: []T) Self {
            return initLen(buffer, 0);
        }

        pub fn initLen(buffer: []T, len: usize) Self {
            return Self{
                .items = buffer[0..len],
                .capacity = buffer.len,
            };
        }

        pub fn hasUnusedCapacity(self: *Self, additional_count: usize) bool {
            return self.capacity >= self.items.len + additional_count;
        }

        pub fn append(self: *Self, item: T) error{OutOfMemory}!void {
            if (!self.hasUnusedCapacity(1)) return error.OutOfMemory;
            self.appendAssumeCapacity(item);
        }

        pub fn appendAssumeCapacity(self: *Self, item: T) void {
            std.debug.assert(self.items.len < self.capacity);
            self.items.len += 1;
            self.items[self.items.len - 1] = item;
        }

        pub fn pop(self: *Self) T {
            const val = self.items[self.items.len - 1];
            self.items.len -= 1;
            return val;
        }

        pub fn popOrNull(self: *Self) ?T {
            if (self.items.len == 0) return null;
            return self.pop();
        }
    };
}

test {
    std.testing.refAllDecls(ShuffleVector(u8));
}
