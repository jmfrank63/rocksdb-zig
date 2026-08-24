const std = @import("std");
const rdb = @import("rocksdb");
const lib = @import("lib.zig");

const Allocator = std.mem.Allocator;

const ColumnFamilyHandle = lib.ColumnFamilyHandle;

pub const WriteBatch = struct {
    inner: *rdb.rocksdb_writebatch_t,

    const Self = @This();

    pub fn init() WriteBatch {
        return .{ .inner = rdb.rocksdb_writebatch_create().? };
    }

    pub fn deinit(self: WriteBatch) void {
        rdb.rocksdb_writebatch_destroy(self.inner);
    }

    pub fn put(
        self: *const Self,
        column_family: ColumnFamilyHandle,
        key: []const u8,
        value: []const u8,
    ) void {
        rdb.rocksdb_writebatch_put_cf(
            self.inner,
            column_family,
            key.ptr,
            key.len,
            value.ptr,
            value.len,
        );
    }

    pub fn delete(
        self: *const Self,
        column_family: ColumnFamilyHandle,
        key: []const u8,
    ) void {
        rdb.rocksdb_writebatch_delete_cf(
            self.inner,
            column_family,
            key.ptr,
            key.len,
        );
    }

    pub fn deleteRange(
        self: *const Self,
        column_family: ColumnFamilyHandle,
        start_key: []const u8,
        end_key: []const u8,
    ) void {
        rdb.rocksdb_writebatch_delete_range_cf(
            self.inner,
            column_family,
            start_key.ptr,
            start_key.len,
            end_key.ptr,
            end_key.len,
        );
    }
};

test "WriteBatch put/delete" {
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

    var batch = WriteBatch.init();
    defer batch.deinit();
    batch.put(cf, "a", "1");
    batch.put(cf, "b", "2");
    try db.write(batch, .{}, &err_str);

    const val = try db.get(null, "a", .{}, &err_str);
    defer if (val) |v| v.deinit();
    try std.testing.expectEqualSlices(u8, "1", val.?.data);

    var delete_batch = WriteBatch.init();
    defer delete_batch.deinit();
    delete_batch.delete(cf, "a");
    try db.write(delete_batch, .{}, &err_str);

    const after_delete = try db.get(null, "a", .{}, &err_str);
    try std.testing.expect(after_delete == null);
}

test "WriteBatch delete non-existent key" {
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

    var batch = WriteBatch.init();
    defer batch.deinit();
    batch.delete(cf, "nonexistent");
    // Should not fail
    try db.write(batch, .{}, &err_str);
}

test "WriteBatch put empty value" {
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

    var batch = WriteBatch.init();
    defer batch.deinit();
    batch.put(cf, "key", "");
    try db.write(batch, .{}, &err_str);

    const val = try db.get(null, "key", .{}, &err_str);
    defer if (val) |v| v.deinit();
    try std.testing.expect(val != null);
    try std.testing.expect(val.?.data.len == 0);
}

test "WriteBatch delete range" {
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

    // Add some keys
    try db.put(null, "a", "1", .{}, &err_str);
    try db.put(null, "b", "2", .{}, &err_str);
    try db.put(null, "c", "3", .{}, &err_str);

    var batch = WriteBatch.init();
    defer batch.deinit();
    batch.deleteRange(cf, "a", "c");
    try db.write(batch, .{}, &err_str);

    // Key "a" and "b" should be deleted, "c" should remain
    const val_a = try db.get(null, "a", .{}, &err_str);
    const val_b = try db.get(null, "b", .{}, &err_str);
    const val_c = try db.get(null, "c", .{}, &err_str);
    defer if (val_c) |v| v.deinit();

    try std.testing.expect(val_a == null);
    try std.testing.expect(val_b == null);
    try std.testing.expect(val_c != null);
}

test "WriteBatch multiple operations and cleanup" {
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

    // Create multiple batches in sequence and verify cleanup
    for (0..10) |i| {
        var batch = WriteBatch.init();
        defer batch.deinit();

        const key = try std.fmt.allocPrint(allocator, "key_{d}", .{i});
        defer allocator.free(key);
        const value = try std.fmt.allocPrint(allocator, "value_{d}", .{i});
        defer allocator.free(value);

        batch.put(cf, key, value);
        try db.write(batch, .{}, &err_str);
    }

    // Verify all keys were written
    for (0..10) |i| {
        const key = try std.fmt.allocPrint(allocator, "key_{d}", .{i});
        defer allocator.free(key);
        const val = try db.get(null, key, .{}, &err_str);
        defer if (val) |v| v.deinit();
        try std.testing.expect(val != null);
    }
}

test "WriteBatch empty batch write" {
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

    // Write an empty batch - should succeed
    var batch = WriteBatch.init();
    defer batch.deinit();
    try db.write(batch, .{}, &err_str);
}
