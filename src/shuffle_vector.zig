const std = @import("std");
const Random = std.rand.Random;

pub fn StaticShuffleVector(comptime max_size: comptime_int) type {
    const IndexType = std.math.IntFittingRange(0, max_size);
    return ShuffleVectorGeneric(IndexType, max_size);
}

pub fn ShuffleVector(comptime T: type) type {
    return ShuffleVectorGeneric(T, null);
}

pub fn ShuffleVectorGeneric(comptime T: type, comptime static: ?comptime_int) type {
    comptime {
        if (@typeInfo(T) != .Int and @typeInfo(T).Int.signedness != .unsigned) {
            @compileError("T must be an unsigned integer, got " ++ @typeName(T));
        }
    }
    return struct {
        const Self = @This();

        indices: Buffer,
        random: Random,

        const Buffer = if (static) |max_size| std.BoundedArray(IndexType, max_size) else FixedBuffer(IndexType);

        pub const IndexType = T;

        pub usingnamespace if (static) |_|
            struct {
                pub fn init(random: Random) Self {
                    var self = Self{
                        .indices = Buffer{ .len = static.? },
                        .random = random,
                    };
                    var buf = self.indices.slice();
                    for (buf) |*index, i| {
                        index.* = @intCast(IndexType, i);
                    }
                    random.shuffle(IndexType, buf);
                    return self;
                }
            }
        else
            struct {
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
            };

        pub fn push(self: *Self, index: IndexType) !void {
            try self.indices.append(index);
            self.pushSwap();
        }

        pub fn pushAssumeCapacity(self: *Self, index: IndexType) void {
            self.indices.appendAssumeCapacity(index);
            self.pushSwap();
        }

        pub fn pushSwap(self: *Self) void {
            const len = self.indices.buffer.len;
            const swap_offset = self.random.uintLessThan(usize, len);
            std.mem.swap(IndexType, &self.indices.buffer[swap_offset], &self.indices.buffer[len - 1]);
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

        buffer: []T,
        capacity: usize,

        pub fn init(buffer: []T) Self {
            return initLen(buffer, 0);
        }

        pub fn initLen(buffer: []T, len: usize) Self {
            return Self{
                .buffer = buffer[0..len],
                .capacity = buffer.len,
            };
        }

        pub fn hasUnusedCapacity(self: *Self, additional_count: usize) bool {
            return self.capacity >= self.buffer.len + additional_count;
        }

        pub fn append(self: *Self, item: T) error{Overflow}!void {
            if (!self.hasUnusedCapacity(1)) return error.Overflow;
            self.appendAssumeCapacity(item);
        }

        pub fn appendAssumeCapacity(self: *Self, item: T) void {
            std.debug.assert(self.buffer.len < self.capacity);
            self.buffer.len += 1;
            self.buffer[self.buffer.len - 1] = item;
        }

        pub fn pop(self: *Self) T {
            const val = self.buffer[self.buffer.len - 1];
            self.buffer.len -= 1;
            return val;
        }

        pub fn popOrNull(self: *Self) ?T {
            if (self.buffer.len == 0) return null;
            return self.pop();
        }
    };
}

test {
    std.testing.refAllDecls(ShuffleVector(u8));
}
