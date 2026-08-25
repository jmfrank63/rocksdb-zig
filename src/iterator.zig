const std = @import("std");
const rdb = @import("rocksdb");
const lib = @import("lib.zig");

const Allocator = std.mem.Allocator;

const Data = lib.Data;

pub const Direction = enum { forward, reverse };

pub const Iterator = struct {
    raw: RawIterator,
    direction: Direction,
    done: bool,
    is_first: bool = true,

    const Self = @This();

    pub fn deinit(self: Self) void {
        self.raw.deinit();
    }

    pub fn next(self: *Self, err_str: *?Data) error{RocksDBIterator}!?[2]Data {
        return self.nextGeneric([2]Data, RawIterator.entry, err_str);
    }

    pub fn nextKey(self: *Self, err_str: *?Data) error{RocksDBIterator}!?Data {
        return self.nextGeneric(Data, RawIterator.key, err_str);
    }

    pub fn nextValue(self: *Self, err_str: *?Data) error{RocksDBIterator}!?Data {
        return self.nextGeneric(Data, RawIterator.value, err_str);
    }

    fn nextGeneric(
        self: *Self,
        comptime T: type,
        getNext: fn (RawIterator) ?T,
        err_str: *?Data,
    ) error{RocksDBIterator}!?T {
        if (self.done) {
            return null;
        } else {
            // NOTE: we call next before getting the value (instead of after)
            // because rocksdb uses pointers
            if (!self.is_first) {
                switch (self.direction) {
                    .forward => self.raw.next(),
                    .reverse => self.raw.prev(),
                }
            }

            if (getNext(self.raw)) |item| {
                self.is_first = false;
                return item;
            } else {
                self.done = true;
                try self.raw.status(err_str);
                return null;
            }
        }
    }
};

pub const RawIterator = struct {
    inner: *rdb.rocksdb_iterator_t,
    read_options: ?*rdb.rocksdb_readoptions_t,

    const Self = @This();

    pub fn deinit(self: Self) void {
        rdb.rocksdb_iter_destroy(self.inner);
        if (self.read_options) |opts| {
            rdb.rocksdb_readoptions_destroy(opts);
        }
    }

    pub fn seek(self: Self, key_: []const u8) void {
        rdb.rocksdb_iter_seek(self.inner, @ptrCast(key_.ptr), key_.len);
    }

    pub fn seekForPrev(self: Self, key_: []const u8) void {
        rdb.rocksdb_iter_seek_for_prev(self.inner, @ptrCast(key_.ptr), key_.len);
    }

    pub fn seekToFirst(self: Self) void {
        rdb.rocksdb_iter_seek_to_first(self.inner);
    }

    pub fn seekToLast(self: Self) void {
        rdb.rocksdb_iter_seek_to_last(self.inner);
    }

    pub fn valid(self: Self) bool {
        return rdb.rocksdb_iter_valid(self.inner) != 0;
    }

    pub fn entry(self: Self) ?[2]Data {
        if (self.valid()) {
            return .{ self.keyImpl(), self.valueImpl() };
        } else {
            return null;
        }
    }

    pub fn key(self: Self) ?Data {
        if (self.valid()) {
            return self.keyImpl();
        } else {
            return null;
        }
    }

    pub fn value(self: Self) ?Data {
        if (self.valid()) {
            return self.valueImpl();
        } else {
            return null;
        }
    }

    fn borrowedByTheIterator(_: ?*anyopaque) callconv(.c) void {}

    fn keyImpl(self: Self) Data {
        var len: usize = undefined;
        const ret = rdb.rocksdb_iter_key(self.inner, &len);
        return .{
            .data = ret[0..len],
            .free = borrowedByTheIterator,
        };
    }

    fn valueImpl(self: Self) Data {
        var len: usize = undefined;
        const ret = rdb.rocksdb_iter_value(self.inner, &len);
        return .{
            .data = ret[0..len],
            .free = borrowedByTheIterator,
        };
    }

    pub fn next(self: Self) void {
        rdb.rocksdb_iter_next(self.inner);
    }

    pub fn prev(self: Self) void {
        rdb.rocksdb_iter_prev(self.inner);
    }

    pub fn status(self: Self, err_str: *?Data) error{RocksDBIterator}!void {
        var err_str_in: ?[*:0]u8 = null;
        rdb.rocksdb_iter_get_error(self.inner, @ptrCast(&err_str_in));
        if (err_str_in) |s| {
            err_str.* = .{
                .data = std.mem.span(s),
                .free = rdb.rocksdb_free,
            };
            return error.RocksDBIterator;
        }
    }
};

test "RawIterator seek and bounds" {
    const database = @import("database.zig");
    const allocator = std.testing.allocator;

    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const path = try dir.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(path);

    var err_str: ?lib.Data = null;
    defer if (err_str) |e| e.deinit();

    var db, const families = try database.DB.open(
        allocator,
        std.testing.io,
        path,
        .{ .create_if_missing = true, .create_missing_column_families = true },
        &.{.{ .name = "default" }},
        false,
        &err_str,
    );
    defer db.deinit();
    defer database.DB.freeColumnFamilies(allocator, families);

    const cf = families[0].handle;
    db = db.withDefaultColumnFamily(cf);

    try db.put(null, "a", "1", .{}, &err_str);
    try db.put(null, "b", "2", .{}, &err_str);
    try db.put(null, "c", "3", .{}, &err_str);

    var raw = db.rawIterator(null, .{});
    defer raw.deinit();

    raw.seekToFirst();
    var key = raw.key().?;
    try std.testing.expectEqualSlices(u8, "a", key.data);

    raw.seekToLast();
    key = raw.key().?;
    try std.testing.expectEqualSlices(u8, "c", key.data);

    raw.seek("b");
    key = raw.key().?;
    try std.testing.expectEqualSlices(u8, "b", key.data);
}

test "Iterator on empty database returns no entries" {
    const database = @import("database.zig");
    const allocator = std.testing.allocator;

    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const path = try dir.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(path);

    var err_str: ?lib.Data = null;
    defer if (err_str) |e| e.deinit();

    var db, const families = try database.DB.open(
        allocator,
        std.testing.io,
        path,
        .{ .create_if_missing = true },
        null,
        false,
        &err_str,
    );
    defer db.deinit();
    defer database.DB.freeColumnFamilies(allocator, families);

    const cf = families[0].handle;
    db = db.withDefaultColumnFamily(cf);

    var iter = db.iterator(null, .forward, null, .{});
    defer iter.deinit();

    const entry = try iter.next(&err_str);
    try std.testing.expect(entry == null);
}

test "RawIterator seek to non-existent key" {
    const database = @import("database.zig");
    const allocator = std.testing.allocator;

    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const path = try dir.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(path);

    var err_str: ?lib.Data = null;
    defer if (err_str) |e| e.deinit();

    var db, const families = try database.DB.open(
        allocator,
        std.testing.io,
        path,
        .{ .create_if_missing = true },
        null,
        false,
        &err_str,
    );
    defer db.deinit();
    defer database.DB.freeColumnFamilies(allocator, families);

    const cf = families[0].handle;
    db = db.withDefaultColumnFamily(cf);

    try db.put(null, "a", "1", .{}, &err_str);
    try db.put(null, "c", "3", .{}, &err_str);

    var raw = db.rawIterator(null, .{});
    defer raw.deinit();

    // Seek to nonexistent key between existing keys
    raw.seek("b");
    // Should position at next valid key or become invalid
    if (raw.valid()) {
        const key = raw.key();
        if (key) |k| {
            // If valid, it should be at 'c' (next key after 'b')
            try std.testing.expectEqualSlices(u8, "c", k.data);
        }
    }
}

test "Iterator reverse direction" {
    const database = @import("database.zig");
    const allocator = std.testing.allocator;

    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const path = try dir.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(path);

    var err_str: ?lib.Data = null;
    defer if (err_str) |e| e.deinit();

    var db, const families = try database.DB.open(
        allocator,
        std.testing.io,
        path,
        .{ .create_if_missing = true },
        null,
        false,
        &err_str,
    );
    defer db.deinit();
    defer database.DB.freeColumnFamilies(allocator, families);

    const cf = families[0].handle;
    db = db.withDefaultColumnFamily(cf);

    try db.put(null, "a", "1", .{}, &err_str);
    try db.put(null, "b", "2", .{}, &err_str);
    try db.put(null, "c", "3", .{}, &err_str);

    var iter = db.iterator(null, .reverse, null, .{});
    defer iter.deinit();

    // First item in reverse should be 'c'
    const entry1 = try iter.nextValue(&err_str);
    try std.testing.expect(entry1 != null);
    try std.testing.expectEqualSlices(u8, "3", entry1.?.data);

    const entry2 = try iter.nextValue(&err_str);
    try std.testing.expect(entry2 != null);
    try std.testing.expectEqualSlices(u8, "2", entry2.?.data);
}

test "Iterator with seek position" {
    const database = @import("database.zig");
    const allocator = std.testing.allocator;

    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const path = try dir.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(path);

    var err_str: ?lib.Data = null;
    defer if (err_str) |e| e.deinit();

    var db, const families = try database.DB.open(
        allocator,
        std.testing.io,
        path,
        .{ .create_if_missing = true },
        null,
        false,
        &err_str,
    );
    defer db.deinit();
    defer database.DB.freeColumnFamilies(allocator, families);

    const cf = families[0].handle;
    db = db.withDefaultColumnFamily(cf);

    try db.put(null, "a", "1", .{}, &err_str);
    try db.put(null, "b", "2", .{}, &err_str);
    try db.put(null, "c", "3", .{}, &err_str);

    var iter = db.iterator(null, .forward, "b", .{});
    defer iter.deinit();

    const entry1 = try iter.nextKey(&err_str);
    try std.testing.expect(entry1 != null);
    try std.testing.expectEqualSlices(u8, "b", entry1.?.data);
}

test "Iterator cleanup after exhaustion" {
    const database = @import("database.zig");
    const allocator = std.testing.allocator;

    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const path = try dir.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(path);

    var err_str: ?lib.Data = null;
    defer if (err_str) |e| e.deinit();

    var db, const families = try database.DB.open(
        allocator,
        std.testing.io,
        path,
        .{ .create_if_missing = true },
        null,
        false,
        &err_str,
    );
    defer db.deinit();
    defer database.DB.freeColumnFamilies(allocator, families);

    const cf = families[0].handle;
    db = db.withDefaultColumnFamily(cf);

    try db.put(null, "a", "1", .{}, &err_str);

    var iter = db.iterator(null, .forward, null, .{});
    defer iter.deinit();

    // Exhaust the iterator
    _ = try iter.next(&err_str);
    const second = try iter.next(&err_str);
    try std.testing.expect(second == null);

    // Call next again after exhaustion
    const third = try iter.next(&err_str);
    try std.testing.expect(third == null);
}

test "RawIterator multiple operations" {
    const database = @import("database.zig");
    const allocator = std.testing.allocator;

    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const path = try dir.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(path);

    var err_str: ?lib.Data = null;
    defer if (err_str) |e| e.deinit();

    var db, const families = try database.DB.open(
        allocator,
        std.testing.io,
        path,
        .{ .create_if_missing = true },
        null,
        false,
        &err_str,
    );
    defer db.deinit();
    defer database.DB.freeColumnFamilies(allocator, families);

    const cf = families[0].handle;
    db = db.withDefaultColumnFamily(cf);

    try db.put(null, "a", "1", .{}, &err_str);
    try db.put(null, "b", "2", .{}, &err_str);
    try db.put(null, "c", "3", .{}, &err_str);

    var raw = db.rawIterator(null, .{});
    defer raw.deinit();

    // Multiple seeks
    raw.seekToFirst();
    try std.testing.expect(raw.valid());

    raw.seekToLast();
    try std.testing.expect(raw.valid());

    raw.seek("b");
    try std.testing.expect(raw.valid());

    // Test status doesn't error on valid iterator
    try raw.status(&err_str);
    try std.testing.expect(err_str == null);
}

test "an iterator entry does not carry rocksdb_free: those bytes belong to the iterator" {
    const database = @import("database.zig");
    const allocator = std.testing.allocator;

    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const path = try dir.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(path);

    var err_str: ?Data = null;
    const opened, const cfs = try database.DB.open(
        allocator,
        std.testing.io,
        path,
        .{ .create_if_missing = true, .create_missing_column_families = true },
        null,
        false,
        &err_str,
    );
    defer {
        opened.deinit();
        database.DB.freeColumnFamilies(allocator, cfs);
    }

    const db = opened.withDefaultColumnFamily(cfs[0].handle);
    try db.put(null, "k1", "v1", .{}, &err_str);
    try db.put(null, "k2", "v2", .{}, &err_str);

    var it = db.iterator(null, .forward, null, .{});
    defer it.deinit();

    const first = (try it.next(&err_str)) orelse return error.IteratorYieldedNothing;

    if (first[0].free == rdb.rocksdb_free) {
        std.debug.print(
            \\
            \\rocksdb_iter_key and rocksdb_iter_value return memory owned by the
            \\iterator. It is invalidated by the next seek or next() and it was
            \\never allocated for the caller. Data.deinit calls Data.free, and
            \\Data documents itself as "allocated by rocksdb and must be freed by
            \\rocksdb" - so a caller who honours that contract on an iterator
            \\entry hands the C heap a pointer it never gave out.
            \\
        , .{});
        return error.IteratorEntryClaimsToOwnBorrowedBytes;
    }

    first[0].deinit();
    first[1].deinit();

    const second = (try it.next(&err_str)) orelse return error.IteratorStoppedAfterDeinit;
    try std.testing.expect(second[0].data.len > 0);
}
