//! Runtime policy for raw file effects.
//!
//! A manifest `filesystem` grant allows any process-visible path. Without
//! that grant, raw file effects are confined to the six directories the
//! app-dir resolver owns for this app. The check canonicalizes the existing
//! target, or the deepest existing parent for a target that will be created,
//! before comparing roots. Consequently an in-root symlink that points out
//! is not an app-directory exemption.

const std = @import("std");

pub const max_roots: usize = 6;

pub const Binding = struct {
    roots: []const []const u8 = &.{},
    permitted: bool = false,
    /// The migration seam. Shipping runners set this true; embedders may use
    /// false for one warning release while still exercising normalization.
    enforce: bool = true,
};

pub const Decision = enum { allow, warn, reject };

pub const Resolved = struct {
    path: []u8,
    decision: Decision,
};

/// Normalize first, then decide authority over that exact spelling. Callers
/// perform I/O against `path`, never against the original request, so the
/// checked symlink/parent resolution is also the path handed to the worker.
pub fn resolve(
    allocator: std.mem.Allocator,
    io: std.Io,
    binding: Binding,
    requested_path: []const u8,
) !Resolved {
    if (requested_path.len == 0 or std.mem.indexOfScalar(u8, requested_path, 0) != null) return error.InvalidPath;
    const canonical = try canonicalizeTarget(allocator, io, requested_path);
    errdefer allocator.free(canonical);
    if (binding.permitted) return .{ .path = canonical, .decision = .allow };
    const inside = canonicalIsInsideAnyRoot(allocator, io, binding.roots, canonical);
    return .{
        .path = canonical,
        .decision = if (inside) .allow else if (binding.enforce) .reject else .warn,
    };
}

pub fn decide(
    allocator: std.mem.Allocator,
    io: std.Io,
    binding: Binding,
    requested_path: []const u8,
) Decision {
    const resolved = resolve(allocator, io, binding, requested_path) catch return .reject;
    defer allocator.free(resolved.path);
    return resolved.decision;
}

/// Canonicalize the target when it exists. For a new target, walk upward to
/// the deepest existing parent, canonicalize that parent (resolving every
/// symlink in the chain), then append the missing lexical suffix. Root paths
/// are canonicalized independently so aliases such as macOS `/tmp` and
/// `/private/tmp` compare correctly.
pub fn isInsideAnyRoot(
    allocator: std.mem.Allocator,
    io: std.Io,
    roots: []const []const u8,
    requested_path: []const u8,
) bool {
    if (requested_path.len == 0 or roots.len == 0 or std.mem.indexOfScalar(u8, requested_path, 0) != null) return false;
    const canonical_target = canonicalizeTarget(allocator, io, requested_path) catch return false;
    defer allocator.free(canonical_target);
    return canonicalIsInsideAnyRoot(allocator, io, roots, canonical_target);
}

fn canonicalIsInsideAnyRoot(allocator: std.mem.Allocator, io: std.Io, roots: []const []const u8, canonical_target: []const u8) bool {
    for (roots) |root| {
        if (root.len == 0) continue;
        const canonical_root = canonicalizeTarget(allocator, io, root) catch continue;
        defer allocator.free(canonical_root);
        if (pathIsWithin(canonical_root, canonical_target)) return true;
    }
    return false;
}

fn canonicalizeTarget(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    const cwd = std.Io.Dir.cwd();
    if (cwd.realPathFileAlloc(io, path, allocator)) |resolved| {
        defer allocator.free(resolved);
        return allocator.dupe(u8, resolved);
    } else |_| {}

    // Preserve every missing component while searching for an existing
    // ancestor. `std.fs.path.resolve` then normalizes `.`/`..` in the joined
    // result, after the existing prefix has been resolved through symlinks.
    var ancestor = path;
    var suffix: std.ArrayList([]const u8) = .empty;
    defer suffix.deinit(allocator);
    while (true) {
        const parent = std.fs.path.dirname(ancestor) orelse break;
        const base = std.fs.path.basename(ancestor);
        try suffix.append(allocator, base);
        if (cwd.realPathFileAlloc(io, parent, allocator)) |resolved_parent| {
            defer allocator.free(resolved_parent);
            var parts: std.ArrayList([]const u8) = .empty;
            defer parts.deinit(allocator);
            try parts.append(allocator, resolved_parent);
            var index = suffix.items.len;
            while (index > 0) {
                index -= 1;
                try parts.append(allocator, suffix.items[index]);
            }
            return std.fs.path.resolve(allocator, parts.items);
        } else |_| {}
        if (std.mem.eql(u8, parent, ancestor)) break;
        ancestor = parent;
    }
    // A completely missing relative tail still has one existing parent: cwd.
    // Resolve it explicitly and append every requested component lexically.
    if (!std.fs.path.isAbsolute(path)) {
        const cwd_resolved = try cwd.realPathFileAlloc(io, ".", allocator);
        defer allocator.free(cwd_resolved);
        return std.fs.path.resolve(allocator, &.{ cwd_resolved, path });
    }
    return error.FileNotFound;
}

fn pathIsWithin(root: []const u8, target: []const u8) bool {
    if (pathsEqual(root, target)) return true;
    if (root.len == 0 or target.len <= root.len) return false;
    if (!pathPrefixEqual(root, target[0..root.len])) return false;
    return isSeparator(target[root.len]) or isSeparator(root[root.len - 1]);
}

fn pathsEqual(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    return pathPrefixEqual(a, b);
}

fn pathPrefixEqual(a: []const u8, b: []const u8) bool {
    if (@import("builtin").os.tag != .windows) return std.mem.eql(u8, a, b);
    return std.ascii.eqlIgnoreCase(a, b);
}

fn isSeparator(byte: u8) bool {
    return byte == '/' or (@import("builtin").os.tag == .windows and byte == '\\');
}

test "canonical containment rejects lexical escapes and symlinks that point out" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "app/data");
    try tmp.dir.createDirPath(std.testing.io, "outside");

    var root_buffer: [256]u8 = undefined;
    var inside_buffer: [256]u8 = undefined;
    var escape_buffer: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buffer, ".zig-cache/tmp/{s}/app/data", .{tmp.sub_path[0..]});
    const inside = try std.fmt.bufPrint(&inside_buffer, "{s}/nested/new.bin", .{root});
    const escaped = try std.fmt.bufPrint(&escape_buffer, "{s}/../../outside/new.bin", .{root});
    try std.testing.expect(isInsideAnyRoot(std.testing.allocator, std.testing.io, &.{root}, inside));
    try std.testing.expect(!isInsideAnyRoot(std.testing.allocator, std.testing.io, &.{root}, escaped));

    if (@import("builtin").os.tag != .windows) {
        try tmp.dir.symLink(std.testing.io, "../../outside", "app/data/link", .{ .is_directory = true });
        var symlink_buffer: [256]u8 = undefined;
        const through_symlink = try std.fmt.bufPrint(&symlink_buffer, "{s}/link/new.bin", .{root});
        try std.testing.expect(!isInsideAnyRoot(std.testing.allocator, std.testing.io, &.{root}, through_symlink));
    }
}
