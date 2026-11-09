const std = @import("std");
const sdk = @import("native_sdk");
const core = @import("surface_fixture_core");
const p = sdk.runtime.testing.blob_policy;
const reference = sdk.runtime.testing.blob_reference_store;
const stores = sdk.runtime.session_blobs;
const exact = @import("surface_layout_e2e_tests.zig").expectComplete;
var modes: [13]usize = @splat(0);
fn observed(input: []const u8, output: []u8) usize {
    if (input[0] == 28) modes[input[2]] += 1;
    return core.nativeEffectPolicy(input, output);
}
fn same(mode: p.Mode, facts: p.Facts) !void {
    const left = p.plan(null, mode, facts);
    const right = p.plan(observed, mode, facts);
    try exact(left.action, right.action);
    try exact(left.words, right.words);
    try std.testing.expectEqualSlices(u8, left.bytes(), right.bytes());
    core.rt.frameReset();
    try exact(left.words, right.words);
    try std.testing.expectEqualSlices(u8, left.bytes(), right.bytes());
}
const values = [_]u64{ 0, 1, 4096, 4294967295, 4294967296, 9007199254740993, std.math.maxInt(u64) };
test "compiled blob decisions preserve exact budgets refusal order and full path tokens" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    for (values) |a| for (values) |b| {
        try same(.directory, .{ .words = .{ a, b, 0, 0, 0, 0 } });
        try same(.write, .{ .words = .{ a, b, 0, 0, 0, 0 } });
        for (0..4) |flags| try same(.memory_write, .{ .flags = @intCast(flags), .words = .{ a, b, 32, 32, 7, 0 } });
        for (0..2) |flags| try same(.memory_read, .{ .flags = @intCast(flags), .words = .{ a, b, 0, 0, 0, 0 } });
        for (0..4) |flags| for (0..2) |extra| try same(.read, .{ .flags = @intCast(flags), .words = .{ a, b, extra, 0, 0, 0 } });
    };
    for (values) |token| for ([_][]const u8{ "", ".", "a/b" }) |dir| for ([_]u64{ 0, 1, 31, 64, 1104, std.math.maxInt(u64) }) |capacity| {
        for (0..2) |flags| try same(.path, .{ .flags = @intCast(flags), .words = .{ token, capacity, 0, 0, 0, 0 }, .a = dir, .b = "00112233445566778899aabbccddeeff" });
    };
    const hash = [_]u8{ 0, 17, 34, 51, 68, 85, 102, 119, 136, 153, 170, 187, 204, 221, 238, 255 };
    try same(.name, .{ .a = &hash });
    for (0..2) |flag| {
        try same(.open, .{ .flags = @intCast(flag) });
        try same(.install, .{ .flags = @intCast(flag) });
    }
}
test "compiled blob bounded probes compare every byte and stop at original short reads" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    var bytes: [4096]u8 = @splat(90);
    var other = bytes;
    for ([_]usize{ 0, 1, 4095, 4096 }) |len| {
        for (0..2) |mismatch| {
            other = bytes;
            if (mismatch != 0 and len != 0) other[len - 1] ^= 1;
            for ([_]u64{ len, len + 1 }) |total| try same(.probe, .{ .flags = 1, .words = .{ total, 0, len, 4096, 0, 0 }, .a = bytes[0..len], .b = other[0..len] });
            try same(.equal, .{ .words = .{ 0, len, 0, 0, 0, 0 }, .a = bytes[0..len], .b = other[0..len] });
        }
        try same(.equal, .{ .flags = 1, .words = .{ len, len, 0, 0, 0, 0 } });
        try same(.equal, .{ .flags = 1, .words = .{ len, len + 1, 0, 0, 0, 0 } });
    }
    try same(.probe, .{});
    for (values[0..6]) |at| try same(.probe, .{ .flags = 1, .words = .{ at + 4096, at, 4096, 4096, 0, 0 }, .a = &bytes, .b = &bytes });
    const hash = [_]u8{0} ** 16;
    var bad = hash;
    bad[15] = 1;
    try same(.hash, .{ .a = &hash, .b = &hash });
    try same(.hash, .{ .a = &hash, .b = &bad });
    try same(.find, .{ .words = .{ 31, 32, 0, 0, 0, 0 }, .a = &hash, .b = &hash });
    try same(.find, .{ .words = .{ 31, 32, 0, 0, 0, 0 }, .a = &hash, .b = &bad });
    for (modes) |count| try std.testing.expect(count != 0);
}
fn sameMemory(left: *reference.MemoryBlobStore, right: *stores.MemoryBlobStore) !void {
    try exact(left.count, right.count);
    try exact(left.dedup_hits, right.dedup_hits);
    for (left.entries[0..left.count], right.entries[0..right.count]) |a, b| {
        try exact(a.hash, b.hash);
        try std.testing.expectEqualSlices(u8, a.bytes, b.bytes);
    }
    core.rt.frameReset();
}
test "compiled blob memory store preserves dedup repair full capacity and frame ownership" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    var left = reference.MemoryBlobStore.init(std.testing.allocator);
    defer left.deinit();
    var right = stores.MemoryBlobStore.init(std.testing.allocator);
    defer right.deinit();
    right.policy = observed;
    var bytes: [8193]u8 = @splat(71);
    for ([_]usize{ 0, 1, 4095, 4096, 4097, 8193 }) |len| {
        const payload = bytes[0..len];
        const hash = stores.hashBytes(payload);
        try left.write(hash, payload);
        try right.write(hash, payload);
        try sameMemory(&left, &right);
        try left.write(hash, payload);
        try right.write(hash, payload);
        try sameMemory(&left, &right);
        var a: [8193]u8 = undefined;
        var b: [8193]u8 = undefined;
        try std.testing.expectEqualSlices(u8, try left.read(hash, a[0..len]), try right.read(hash, b[0..len]));
        if (len != 0) {
            try std.testing.expectError(error.BlobOverBudget, left.read(hash, a[0 .. len - 1]));
            try std.testing.expectError(error.BlobOverBudget, right.read(hash, b[0 .. len - 1]));
            left.entries[left.count - 1].bytes[len - 1] ^= 1;
            right.entries[right.count - 1].bytes[len - 1] ^= 1;
            try std.testing.expectError(error.BlobCorrupt, left.read(hash, &a));
            try std.testing.expectError(error.BlobCorrupt, right.read(hash, &b));
            try left.write(hash, payload);
            try right.write(hash, payload);
            try sameMemory(&left, &right);
        }
    }
    while (left.count < stores.MemoryBlobStore.max_entries) {
        const payload = [_]u8{@intCast(left.count)};
        const hash = stores.hashBytes(&payload);
        try left.write(hash, &payload);
        try right.write(hash, &payload);
    }
    try sameMemory(&left, &right);
    const missing = stores.hashBytes("absent");
    var scratch: [16]u8 = undefined;
    try std.testing.expectError(error.BlobMissing, left.read(missing, &scratch));
    try std.testing.expectError(error.BlobMissing, right.read(missing, &scratch));
    try std.testing.expectError(error.BlobIoFailed, left.write(missing, "absent"));
    try std.testing.expectError(error.BlobIoFailed, right.write(missing, "absent"));
    try sameMemory(&left, &right);
    try left.write(left.entries[0].hash, left.entries[0].bytes);
    try right.write(right.entries[0].hash, right.entries[0].bytes);
    try sameMemory(&left, &right);
    const borrowed = core.rt.frameAlloc(u8, 17);
    @memset(borrowed, 0x5a);
    _ = p.plan(observed, .write, .{});
    try std.testing.expect(std.mem.allEqual(u8, borrowed, 0x5a));
}
test "compiled blob directory store preserves exact-fit spare probes tamper repair and shared writers" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var paths: [2][256]u8 = undefined;
    const a = try std.fmt.bufPrint(&paths[0], ".zig-cache/tmp/{s}/native", .{tmp.sub_path});
    const b = try std.fmt.bufPrint(&paths[1], ".zig-cache/tmp/{s}/compiled", .{tmp.sub_path});
    var left = try reference.DirBlobStore.init(std.testing.io, a);
    var right = try stores.DirBlobStore.initWithPolicy(std.testing.io, b, observed);
    var second = try stores.DirBlobStore.initWithPolicy(std.testing.io, b, observed);
    var bytes: [8193]u8 = @splat(90);
    for ([_]usize{ 0, 1, 4095, 4096, 4097, 8193 }) |len| {
        const payload = bytes[0..len];
        const hash = stores.hashBytes(payload);
        try left.write(hash, payload);
        try right.write(hash, payload);
        try second.write(hash, payload);
        var x: [8193]u8 = undefined;
        var y: [8193]u8 = undefined;
        try std.testing.expectEqualSlices(u8, try left.read(hash, x[0..len]), try right.read(hash, y[0..len]));
        if (len != 0) {
            try std.testing.expectError(error.BlobOverBudget, left.read(hash, x[0 .. len - 1]));
            try std.testing.expectError(error.BlobOverBudget, right.read(hash, y[0 .. len - 1]));
            const name = stores.hexName(hash);
            var path: [512]u8 = undefined;
            const lp = try std.fmt.bufPrint(&path, "{s}/{s}", .{ a, name });
            try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = lp, .data = "tamper" });
            const rp = try std.fmt.bufPrint(&path, "{s}/{s}", .{ b, name });
            try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = rp, .data = "tamper" });
            try std.testing.expectError(error.BlobCorrupt, left.read(hash, &x));
            try std.testing.expectError(error.BlobCorrupt, right.read(hash, &y));
            try left.write(hash, payload);
            try right.write(hash, payload);
            try std.testing.expectEqualSlices(u8, try left.read(hash, x[0..len]), try right.read(hash, y[0..len]));
        }
        core.rt.frameReset();
    }
    try std.testing.expectError(error.BlobDirTooLong, stores.DirBlobStore.initWithPolicy(std.testing.io, "", observed));
    var over: [1025]u8 = @splat('a');
    try std.testing.expectError(error.BlobDirTooLong, stores.DirBlobStore.initWithPolicy(std.testing.io, &over, observed));
    var dir = try tmp.dir.openDir(std.testing.io, "compiled", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var it = dir.iterate();
    var count: usize = 0;
    while (try it.next(std.testing.io)) |entry| {
        try std.testing.expect(!std.mem.endsWith(u8, entry.name, ".partial"));
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 6), count);
}

test "compiled blob allocation failure leaves repair source and capacity state intact" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    var failure = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var store = stores.MemoryBlobStore.init(failure.allocator());
    defer store.deinit();
    store.policy = observed;
    const hash = stores.hashBytes("original");
    try store.write(hash, "original");
    store.entries[0].bytes[0] ^= 1;
    const old = store.entries[0].bytes.ptr;
    const before = store.entries[0].bytes[0];
    failure.fail_index = failure.alloc_index;
    try std.testing.expectError(error.BlobIoFailed, store.write(hash, "original"));
    try std.testing.expectEqual(old, store.entries[0].bytes.ptr);
    try std.testing.expectEqual(before, store.entries[0].bytes[0]);
    try std.testing.expectEqual(@as(usize, 1), store.count);
    try std.testing.expectEqual(@as(usize, 0), store.dedup_hits);
    try std.testing.expectError(error.BlobIoFailed, store.write(stores.hashBytes("new"), "new"));
    try std.testing.expectEqual(@as(usize, 1), store.count);
}
test "compiled blob losing rename accepts exact durable content and cleans failed partials" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var directory: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&directory, ".zig-cache/tmp/{s}/blobs", .{tmp.sub_path});
    var winner = try stores.DirBlobStore.initWithPolicy(std.testing.io, path, observed);
    var loser = try stores.DirBlobStore.initWithPolicy(std.testing.io, path, observed);
    const payload = "encoded image bytes";
    const hash = stores.hashBytes(payload);
    try winner.write(hash, payload);
    const name = stores.hexName(hash);
    var target_buffer: [512]u8 = undefined;
    const target = try std.fmt.bufPrint(&target_buffer, "{s}/{s}", .{ path, name });
    var temp_buffer: [512]u8 = undefined;
    const temp = try std.fmt.bufPrint(&temp_buffer, "{s}/gone.partial", .{path});
    try stores.DirBlobStore.TestAccess.install(&loser, temp, target, payload);
    try std.testing.expectError(error.BlobIoFailed, stores.DirBlobStore.TestAccess.install(&loser, temp, target, "different"));
    var absent_buffer: [512]u8 = undefined;
    const absent = try std.fmt.bufPrint(&absent_buffer, "{s}/absent", .{path});
    try std.testing.expectError(error.BlobIoFailed, stores.DirBlobStore.TestAccess.install(&loser, temp, absent, payload));
    var dir = try tmp.dir.openDir(std.testing.io, "blobs", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var it = dir.iterate();
    var count: usize = 0;
    while (try it.next(std.testing.io)) |entry| {
        try std.testing.expect(!std.mem.endsWith(u8, entry.name, ".partial"));
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}
