const std = @import("std");
const Random = std.rand.Random;

const assert = @import("util.zig").assert;

pub fn StaticShuffleVector(comptime max_size: comptime_int) type {
    const IndexType = std.math.IntFittingRange(0, max_size);
    return ShuffleVectorGeneric(IndexType, max_size);
}

pub fn ShuffleVector(comptime T: type) type {
    return ShuffleVectorGeneric(T, null);
}

pub fn StaticShuffleVectorUnmanaged(comptime max_size: comptime_int) type {
    const IndexType = std.math.IntFittingRange(0, max_size);
    return ShuffleVectorUnmanagedGeneric(IndexType, max_size);
}

pub fn ShuffleVectorUnmanaged(comptime T: type) type {
    return ShuffleVectorUnmanagedGeneric(T, null);
}

pub fn ShuffleVectorGeneric(comptime T: type, comptime static: ?comptime_int) type {
    return struct {
        random: Random,
        unmanaged: Unmanaged,

        const Self = @This();
        const Unmanaged = ShuffleVectorUnmanagedGeneric(T, static);
        pub const IndexType = Unmanaged.IndexType;

        pub usingnamespace if (static) |_|
            struct {
                pub fn init(random: Random) Self {
                    return Self{
                        .random = random,
                        .unmanaged = Unmanaged.init(random),
                    };
                }
            }
        else
            struct {
                pub fn init(random: Random, buffer: []IndexType) Self {
                    return Self{
                        .random = random,
                        .unmanaged = Unmanaged.init(random, buffer),
                    };
                }
            };

        pub fn push(self: *Self, index: IndexType) !void {
            return self.unmanaged.push(self.random, index);
        }

        pub fn pushAssumeCapacity(self: *Self, index: IndexType) void {
            return self.unmanaged.pushAssumeCapacity(self.random, index);
        }

        pub fn pushSwap(self: *Self) void {
            return self.unmanaged.pushSwap(self.random);
        }

        pub fn popOrNull(self: *Self) ?IndexType {
            return self.unmanaged.popOrNull();
        }

        pub fn pop(self: *Self) IndexType {
            return self.unmanaged.pop();
        }

        pub fn peek(self: Self) ?T {
            return self.unmanaged.peek();
        }

        pub fn count(self: Self) usize {
            return self.unmanaged.count();
        }
    };
}

pub fn ShuffleVectorUnmanagedGeneric(comptime T: type, comptime static: ?comptime_int) type {
    comptime {
        if (@typeInfo(T) != .Int and @typeInfo(T).Int.signedness != .unsigned) {
            @compileError("T must be an unsigned integer, got " ++ @typeName(T));
        }
    }
    return struct {
        const Self = @This();

        indices: Buffer,

        const Buffer = if (static) |max_size| std.BoundedArray(IndexType, max_size) else FixedBuffer(IndexType);

        pub const IndexType = T;

        pub usingnamespace if (static) |_|
            struct {
                pub fn init(random: Random) Self {
                    var self = Self{
                        .indices = Buffer{ .len = static.? },
                    };
                    var buf = self.indices.slice();
                    for (buf, 0..) |*index, i| {
                        index.* = @intCast(IndexType, i);
                    }
                    random.shuffle(IndexType, buf);
                    return self;
                }
            }
        else
            struct {
                pub fn init(random: Random, buffer: []IndexType) Self {
                    assert(buffer.len - 1 <= std.math.maxInt(IndexType));
                    for (buffer, 0..) |*index, i| {
                        index.* = @intCast(IndexType, i);
                    }
                    random.shuffle(IndexType, buffer);

                    return Self{
                        .indices = FixedBuffer(IndexType).initLen(buffer, buffer.len),
                    };
                }
            };

        pub fn clear(self: *Self) void {
            self.indices.resize(0) catch unreachable;
        }

        pub fn push(self: *Self, random: Random, index: IndexType) !void {
            try self.indices.append(index);
            self.pushSwap(random);
        }

        pub fn pushAssumeCapacity(self: *Self, random: Random, index: IndexType) void {
            self.indices.appendAssumeCapacity(index);
            self.pushSwap(random);
        }

        pub fn pushSwap(self: *Self, random: Random) void {
            const len = self.count();
            const swap_offset = random.uintLessThan(usize, len);
            std.mem.swap(IndexType, &self.indices.buffer[swap_offset], &self.indices.buffer[len - 1]);
        }

        pub inline fn popOrNull(self: *Self) ?IndexType {
            return self.indices.popOrNull();
        }

        pub inline fn pop(self: *Self) IndexType {
            return self.indices.pop();
        }

        pub fn peek(self: Self) ?T {
            if (self.count() == 0) return null;
            return self.indices.buffer[self.count() - 1];
        }

        pub inline fn count(self: Self) usize {
            return if (static == null) self.indices.buffer.len else self.indices.len;
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

        pub fn resize(self: *Self, new_len: usize) !void {
            if (new_len > self.capacity) return error.Overflow;
            self.buffer.len = new_len;
        }

        pub fn hasUnusedCapacity(self: *Self, additional_count: usize) bool {
            return self.capacity >= self.buffer.len + additional_count;
        }

        pub fn append(self: *Self, item: T) error{Overflow}!void {
            if (!self.hasUnusedCapacity(1)) return error.Overflow;
            self.appendAssumeCapacity(item);
        }

        pub fn appendAssumeCapacity(self: *Self, item: T) void {
            assert(self.buffer.len < self.capacity);
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
