//! Minimal RFC 8949 CBOR decoder for WebAuthn (COSE keys, attestation
//! objects, authenticator data extensions).
//!
//! Scope: definite-length items only, no tags, no floats, no simple values
//! other than false/true/null, and at most 16 levels of nesting. Byte and text
//! strings are borrowed slices into the caller's input buffer; only arrays and
//! maps are heap allocated. Call `deinit` on a successfully decoded value with
//! the same allocator that was passed to `decode`.
//!
//! Note: the `null` member of `Value` is spelled `@"null"` because `null` is a
//! Zig keyword; its wire/API name is still "null".

const std = @import("std");

/// A decoded CBOR data item.
pub const Value = union(enum) {
    uint: u64,
    nint: i64,
    bytes: []const u8,
    text: []const u8,
    array: []Value,
    map: []Entry,
    boolean: bool,
    null: void,
};

/// One key/value pair of a CBOR map, in wire order.
pub const Entry = struct { key: Value, value: Value };

/// Failures that can occur while decoding.
pub const DecodeError = error{ UnexpectedEof, Unsupported, Invalid, OutOfMemory };

/// Maximum nesting depth of containers (the top-level item is at depth 0).
const max_depth: usize = 16;

const Decoder = struct {
    allocator: std.mem.Allocator,
    input: []const u8,
    pos: usize = 0,

    fn remaining(self: *const Decoder) usize {
        return self.input.len - self.pos;
    }

    fn readByte(self: *Decoder) DecodeError!u8 {
        if (self.pos == self.input.len) return error.UnexpectedEof;
        const byte = self.input[self.pos];
        self.pos += 1;
        return byte;
    }

    /// Read the big-endian unsigned argument payload of `n` bytes.
    fn readUint(self: *Decoder, comptime n: usize) DecodeError!u64 {
        if (self.remaining() < n) return error.UnexpectedEof;
        var value: u64 = 0;
        for (self.input[self.pos..][0..n]) |byte| {
            value = (value << 8) | byte;
        }
        self.pos += n;
        return value;
    }

    /// Decode the additional-information field into its integer argument.
    fn readArg(self: *Decoder, ai: u5) DecodeError!u64 {
        return switch (ai) {
            0...23 => @as(u64, ai),
            24 => self.readUint(1),
            25 => self.readUint(2),
            26 => self.readUint(4),
            27 => self.readUint(8),
            // Reserved additional-information values 28, 29, 30.
            28, 29, 30 => error.Invalid,
            // Indefinite length: explicitly out of scope.
            31 => error.Unsupported,
        };
    }

    /// Read a definite-length byte or text string as a borrowed slice.
    fn readSlice(self: *Decoder, ai: u5) DecodeError![]const u8 {
        const len = try self.readArg(ai);
        if (len > @as(u64, @intCast(self.remaining()))) return error.UnexpectedEof;
        const n = std.math.cast(usize, len) orelse return error.Invalid;
        const start = self.pos;
        self.pos += n;
        return self.input[start..self.pos];
    }

    fn decodeValue(self: *Decoder, depth: usize) DecodeError!Value {
        if (depth > max_depth) return error.Invalid;

        const initial = try self.readByte();
        const major: u3 = @intCast(initial >> 5);
        const ai: u5 = @intCast(initial & 0x1f);

        switch (major) {
            0 => return .{ .uint = try self.readArg(ai) },
            1 => {
                const n = try self.readArg(ai);
                // -(1 + n) must fit in i64; RFC 8949 can represent one more
                // negative value than any two's-complement 64-bit integer.
                if (n > @as(u64, std.math.maxInt(i64))) return error.Invalid;
                return .{ .nint = -1 - @as(i64, @intCast(n)) };
            },
            2 => return .{ .bytes = try self.readSlice(ai) },
            3 => return .{ .text = try self.readSlice(ai) },
            4 => {
                const len = try self.readArg(ai);
                // Every item needs at least one byte, so a larger length can
                // never be satisfied; reject before allocating.
                if (len > @as(u64, @intCast(self.remaining()))) return error.UnexpectedEof;
                const n = std.math.cast(usize, len) orelse return error.Invalid;

                const items = try self.allocator.alloc(Value, n);
                errdefer self.allocator.free(items);
                var i: usize = 0;
                errdefer {
                    for (items[0..i]) |item| deinit(self.allocator, item);
                }
                while (i < n) : (i += 1) {
                    items[i] = try self.decodeValue(depth + 1);
                }
                return .{ .array = items };
            },
            5 => {
                const len = try self.readArg(ai);
                // Every entry needs at least two bytes (key and value).
                if (len > @as(u64, @intCast(self.remaining() / 2))) return error.UnexpectedEof;
                const n = std.math.cast(usize, len) orelse return error.Invalid;

                const entries = try self.allocator.alloc(Entry, n);
                errdefer self.allocator.free(entries);
                var i: usize = 0;
                errdefer {
                    for (entries[0..i]) |entry| {
                        deinit(self.allocator, entry.key);
                        deinit(self.allocator, entry.value);
                    }
                }
                while (i < n) : (i += 1) {
                    const key = try self.decodeValue(depth + 1);
                    errdefer deinit(self.allocator, key);
                    const val = try self.decodeValue(depth + 1);
                    entries[i] = .{ .key = key, .value = val };
                }
                return .{ .map = entries };
            },
            6 => return error.Unsupported, // tags
            7 => return switch (ai) {
                0...19 => error.Unsupported, // unassigned simple values
                20 => .{ .boolean = false },
                21 => .{ .boolean = true },
                22 => .{ .null = {} },
                23 => error.Unsupported, // undefined
                24 => error.Unsupported, // simple value with one-byte payload
                25, 26, 27 => error.Unsupported, // half/single/double precision float
                28, 29, 30 => error.Invalid, // reserved
                31 => error.Unsupported, // break outside an indefinite-length item
            },
        }
    }
};

/// Decode exactly one CBOR data item from `input`.
///
/// Returns `error.Invalid` if any bytes remain after the top-level item.
/// On success the caller owns array/map allocations and must call `deinit`.
pub fn decode(allocator: std.mem.Allocator, input: []const u8) DecodeError!Value {
    var decoder: Decoder = .{ .allocator = allocator, .input = input };
    const value = try decoder.decodeValue(0);
    errdefer deinit(allocator, value);
    if (decoder.pos != input.len) return error.Invalid;
    return value;
}

/// Release every allocation owned by `value` (arrays and maps, recursively).
/// Borrowed byte/text slices are never freed.
pub fn deinit(allocator: std.mem.Allocator, value: Value) void {
    switch (value) {
        .uint, .nint, .bytes, .text, .boolean, .null => {},
        .array => |items| {
            for (items) |item| deinit(allocator, item);
            allocator.free(items);
        },
        .map => |entries| {
            for (entries) |entry| {
                deinit(allocator, entry.key);
                deinit(allocator, entry.value);
            }
            allocator.free(entries);
        },
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn expectUint(value: Value, expected: u64) !void {
    switch (value) {
        .uint => |actual| try testing.expectEqual(expected, actual),
        else => return error.TestExpectedUint,
    }
}

fn expectNint(value: Value, expected: i64) !void {
    switch (value) {
        .nint => |actual| try testing.expectEqual(expected, actual),
        else => return error.TestExpectedNint,
    }
}

fn expectBool(value: Value, expected: bool) !void {
    switch (value) {
        .boolean => |actual| try testing.expectEqual(expected, actual),
        else => return error.TestExpectedBool,
    }
}

fn expectNull(value: Value) !void {
    switch (value) {
        .null => {},
        else => return error.TestExpectedNull,
    }
}

fn expectBytes(value: Value, expected: []const u8) !void {
    switch (value) {
        .bytes => |actual| {
            try testing.expectEqual(expected.len, actual.len);
            try testing.expectEqualSlices(u8, expected, actual);
        },
        else => return error.TestExpectedBytes,
    }
}

fn expectText(value: Value, expected: []const u8) !void {
    switch (value) {
        .text => |actual| {
            try testing.expectEqual(expected.len, actual.len);
            try testing.expectEqualSlices(u8, expected, actual);
        },
        else => return error.TestExpectedText,
    }
}

fn expectArray(value: Value) ![]Value {
    return switch (value) {
        .array => |items| items,
        else => error.TestExpectedArray,
    };
}

fn expectMap(value: Value) ![]Entry {
    return switch (value) {
        .map => |entries| entries,
        else => error.TestExpectedMap,
    };
}

/// COSE_Key as used by WebAuthn: {1: 2, 3: -7, -1: 1, -2: x, -3: y}.
const cose_key_prefix = [_]u8{ 0xa5, 0x01, 0x02, 0x03, 0x26, 0x20, 0x01, 0x21, 0x58, 0x20 };
const cose_key_mid = [_]u8{ 0x22, 0x58, 0x20 };
const x_coord: [32]u8 = @splat(0xaa);
const y_coord: [32]u8 = @splat(0xbb);
const cose_key = cose_key_prefix ++ x_coord ++ cose_key_mid ++ y_coord;

test "decode COSE-key-shaped map" {
    const value = try decode(testing.allocator, &cose_key);
    defer deinit(testing.allocator, value);

    const entries = try expectMap(value);
    try testing.expectEqual(@as(usize, 5), entries.len);

    try expectUint(entries[0].key, 1);
    try expectUint(entries[0].value, 2);

    try expectUint(entries[1].key, 3);
    try expectNint(entries[1].value, -7);

    try expectNint(entries[2].key, -1);
    try expectUint(entries[2].value, 1);

    try expectNint(entries[3].key, -2);
    try expectBytes(entries[3].value, &x_coord);

    try expectNint(entries[4].key, -3);
    try expectBytes(entries[4].value, &y_coord);
}

test "decode nested arrays and maps" {
    // [ {1: [-1]}, [[1, 2], 3] ]
    const input = [_]u8{ 0x82, 0xa1, 0x01, 0x81, 0x20, 0x82, 0x82, 0x01, 0x02, 0x03 };
    const value = try decode(testing.allocator, input[0..]);
    defer deinit(testing.allocator, value);

    const outer = try expectArray(value);
    try testing.expectEqual(@as(usize, 2), outer.len);

    const map_entries = try expectMap(outer[0]);
    try testing.expectEqual(@as(usize, 1), map_entries.len);
    try expectUint(map_entries[0].key, 1);
    const inner_array = try expectArray(map_entries[0].value);
    try testing.expectEqual(@as(usize, 1), inner_array.len);
    try expectNint(inner_array[0], -1);

    const nested = try expectArray(outer[1]);
    try testing.expectEqual(@as(usize, 2), nested.len);
    const pair = try expectArray(nested[0]);
    try testing.expectEqual(@as(usize, 2), pair.len);
    try expectUint(pair[0], 1);
    try expectUint(pair[1], 2);
    try expectUint(nested[1], 3);
}

test "decode negative integers" {
    const cases = [_]struct { input: []const u8, expected: i64 }{
        .{ .input = &[_]u8{0x20}, .expected = -1 },
        .{ .input = &[_]u8{ 0x38, 0x63 }, .expected = -100 },
        .{ .input = &[_]u8{ 0x3b, 0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff }, .expected = std.math.minInt(i64) },
    };
    for (cases) |case| {
        const value = try decode(testing.allocator, case.input);
        defer deinit(testing.allocator, value);
        try expectNint(value, case.expected);
    }

    // -(1 + 2^63) does not fit in i64.
    try testing.expectError(error.Invalid, decode(testing.allocator, &[_]u8{ 0x3b, 0x80, 0, 0, 0, 0, 0, 0, 0 }));
}

test "decode 64-bit unsigned integer" {
    const input = [_]u8{ 0x1b, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff };
    const value = try decode(testing.allocator, &input);
    defer deinit(testing.allocator, value);
    try expectUint(value, std.math.maxInt(u64));
}

test "byte and text slices are borrowed from the input" {
    // [ h'010203', "hi" ]
    var input = [_]u8{ 0x82, 0x43, 0x01, 0x02, 0x03, 0x62, 'h', 'i' };
    const value = try decode(testing.allocator, &input);
    defer deinit(testing.allocator, value);

    const items = try expectArray(value);
    try testing.expectEqual(@as(usize, 2), items.len);

    switch (items[0]) {
        .bytes => |bytes| {
            try testing.expectEqual(@as(usize, 3), bytes.len);
            try testing.expectEqual(@intFromPtr(&input[2]), @intFromPtr(bytes.ptr));
        },
        else => return error.TestExpectedBytes,
    }
    switch (items[1]) {
        .text => |text| {
            try testing.expectEqualStrings("hi", text);
            try testing.expectEqual(@intFromPtr(&input[6]), @intFromPtr(text.ptr));
        },
        else => return error.TestExpectedText,
    }
}

test "truncated input is UnexpectedEof" {
    const cases = [_][]const u8{
        &[_]u8{},
        &[_]u8{0x18}, // uint, missing argument byte
        &[_]u8{ 0x19, 0x01 }, // uint16, missing second byte
        &[_]u8{ 0x43, 0x01 }, // bytes(3), only one byte present
        &[_]u8{ 0x63, 'a' }, // text(3), only one byte present
        &[_]u8{0x82}, // array(2), no items
        &[_]u8{ 0x82, 0x01 }, // array(2), one item
        &[_]u8{0xa1}, // map(1), no entries
        &[_]u8{ 0xa1, 0x01 }, // map(1), missing value
        &[_]u8{ 0x5b, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff }, // absurd byte length
    };
    for (cases) |case| {
        try testing.expectError(error.UnexpectedEof, decode(testing.allocator, case));
    }
}

test "trailing bytes are Invalid" {
    const cases = [_][]const u8{
        &[_]u8{ 0x00, 0x00 },
        &[_]u8{ 0x01, 0xff },
        &[_]u8{ 0x81, 0x00, 0x00 },
        &[_]u8{ 0xa1, 0x01, 0x02, 0x03 },
    };
    for (cases) |case| {
        try testing.expectError(error.Invalid, decode(testing.allocator, case));
    }
}

test "indefinite lengths are Unsupported" {
    const cases = [_][]const u8{
        &[_]u8{0x5f}, // indefinite byte string
        &[_]u8{0x7f}, // indefinite text string
        &[_]u8{0x9f}, // indefinite array
        &[_]u8{0xbf}, // indefinite map
        &[_]u8{ 0x9f, 0x00, 0xff },
    };
    for (cases) |case| {
        try testing.expectError(error.Unsupported, decode(testing.allocator, case));
    }
}

test "unsupported and invalid major types" {
    // Tags (major 6).
    try testing.expectError(error.Unsupported, decode(testing.allocator, &[_]u8{ 0xc0, 0x00 }));
    // Floats (major 7, ai 25/26/27).
    try testing.expectError(error.Unsupported, decode(testing.allocator, &[_]u8{ 0xf9, 0x00, 0x00 }));
    try testing.expectError(error.Unsupported, decode(testing.allocator, &[_]u8{ 0xfa, 0x00, 0x00, 0x00, 0x00 }));
    try testing.expectError(error.Unsupported, decode(testing.allocator, &[_]u8{ 0xfb, 0, 0, 0, 0, 0, 0, 0, 0 }));
    // Simple values other than false/true/null, and undefined.
    try testing.expectError(error.Unsupported, decode(testing.allocator, &[_]u8{0xf0}));
    try testing.expectError(error.Unsupported, decode(testing.allocator, &[_]u8{ 0xf8, 0x20 }));
    try testing.expectError(error.Unsupported, decode(testing.allocator, &[_]u8{0xf7}));
    // Stray break.
    try testing.expectError(error.Unsupported, decode(testing.allocator, &[_]u8{0xff}));
    // Reserved additional-information values 28..30.
    try testing.expectError(error.Invalid, decode(testing.allocator, &[_]u8{0x1c}));
    try testing.expectError(error.Invalid, decode(testing.allocator, &[_]u8{0x3d}));
    try testing.expectError(error.Invalid, decode(testing.allocator, &[_]u8{0x5e}));
    try testing.expectError(error.Invalid, decode(testing.allocator, &[_]u8{0xfc}));
}

test "false, true and null" {
    try decodeBooleanAndNull(0xf4, .false_value);
    try decodeBooleanAndNull(0xf5, .true_value);
    try decodeBooleanAndNull(0xf6, .null_value);
}

const PrimitiveCase = enum { false_value, true_value, null_value };

fn decodeBooleanAndNull(byte: u8, expected: PrimitiveCase) !void {
    const value = try decode(testing.allocator, &[_]u8{byte});
    defer deinit(testing.allocator, value);
    switch (expected) {
        .false_value => try expectBool(value, false),
        .true_value => try expectBool(value, true),
        .null_value => try expectNull(value),
    }
}

test "depth limit of 16 is enforced" {
    // 16 nested arrays around a scalar: the scalar sits at depth 16 -> allowed.
    var allowed: [17]u8 = undefined;
    @memset(allowed[0..16], 0x81);
    allowed[16] = 0x00;
    {
        const value = try decode(testing.allocator, &allowed);
        defer deinit(testing.allocator, value);
    }

    // 17 nested arrays: the scalar would sit at depth 17 -> Invalid.
    var too_deep: [18]u8 = undefined;
    @memset(too_deep[0..17], 0x81);
    too_deep[17] = 0x00;
    try testing.expectError(error.Invalid, decode(testing.allocator, &too_deep));
}

fn decodeWithoutLeak(allocator: std.mem.Allocator, input: []const u8) !void {
    const value = try decode(allocator, input);
    deinit(allocator, value);
}

test "allocation failures do not leak" {
    try testing.checkAllAllocationFailures(testing.allocator, decodeWithoutLeak, .{&cose_key});
}
