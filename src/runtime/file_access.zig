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
    /// For an app-directory exemption, the already-open parent directory
    /// capability the worker must use instead of reopening `path`. `basename`
    /// points into `path`. Holding this handle across the worker handoff closes
    /// the canonicalize-then-open race: every parent was opened first and its
    /// handle-identity path verified inside the selected root.
    parent: ?std.Io.Dir = null,
    basename: []const u8 = "",
    /// A read/stat whose parent does not exist is authorized but absent. The
    /// caller returns the operation's ordinary not-found shape without ever
    /// reopening the unresolved pathname.
    missing: bool = false,

    pub fn deinit(self: *Resolved, allocator: std.mem.Allocator, io: std.Io) void {
        if (self.parent) |parent| parent.close(io);
        allocator.free(self.path);
        self.* = undefined;
    }
};

pub const ResolveOptions = struct {
    create_parents: bool = false,
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
    return resolveForOperation(allocator, io, binding, requested_path, .{});
}

pub fn resolveForOperation(
    allocator: std.mem.Allocator,
    io: std.Io,
    binding: Binding,
    requested_path: []const u8,
    options: ResolveOptions,
) !Resolved {
    if (requested_path.len == 0 or std.mem.indexOfScalar(u8, requested_path, 0) != null) return error.InvalidPath;
    const canonical = try canonicalizeTarget(allocator, io, requested_path);
    errdefer allocator.free(canonical);
    if (binding.permitted) return .{ .path = canonical, .decision = .allow };

    for (binding.roots) |root| {
        if (root.len == 0) continue;
        const canonical_root = canonicalizeTarget(allocator, io, root) catch continue;
        defer allocator.free(canonical_root);
        var root_dir = openCanonicalDir(io, canonical_root, options.create_parents) catch {
            // A missing root can only authorize an absent read/stat. Compare
            // canonical lexical spellings, then return the closed absence
            // result; writes created the root above and never take this path.
            if (!options.create_parents and pathIsWithin(canonical_root, canonical)) {
                return .{ .path = canonical, .decision = .allow, .missing = true };
            }
            continue;
        };

        var root_real_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const root_real_len = root_dir.realPath(io, &root_real_storage) catch {
            root_dir.close(io);
            continue;
        };
        const root_real = root_real_storage[0..root_real_len];
        if (!pathIsWithin(root_real, canonical)) {
            root_dir.close(io);
            continue;
        }

        const relative = relativeToRoot(root_real, canonical) orelse {
            root_dir.close(io);
            continue;
        };
        const basename = std.fs.path.basename(relative);
        if (basename.len == 0 or std.mem.eql(u8, basename, ".") or std.mem.eql(u8, basename, "..")) {
            root_dir.close(io);
            continue;
        }
        const parent_path = std.fs.path.dirname(relative) orelse "";
        const parent = openVerifiedParent(io, root_dir, root_real, parent_path, options.create_parents) catch |err| switch (err) {
            error.FileNotFound => return .{ .path = canonical, .decision = .allow, .missing = true },
            else => continue,
        };
        const basename_offset = @intFromPtr(basename.ptr) - @intFromPtr(relative.ptr) +
            (@intFromPtr(relative.ptr) - @intFromPtr(canonical.ptr));
        return .{
            .path = canonical,
            .decision = .allow,
            .parent = parent,
            .basename = canonical[basename_offset .. basename_offset + basename.len],
        };
    }

    return .{ .path = canonical, .decision = if (binding.enforce) .reject else .warn };
}

fn openCanonicalDir(io: std.Io, canonical_path: []const u8, create: bool) !std.Io.Dir {
    var components = std.fs.path.componentIterator(canonical_path);
    const root = components.root() orelse return error.BadPathName;
    var current = try std.Io.Dir.openDirAbsolute(io, root, .{ .follow_symlinks = false });
    errdefer current.close(io);
    while (components.next()) |component| {
        const next = current.openDir(io, component.name, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => if (create) create_component: {
                current.createDir(io, component.name, .default_dir) catch |create_err| switch (create_err) {
                    error.PathAlreadyExists => {},
                    else => return create_err,
                };
                break :create_component try current.openDir(io, component.name, .{ .follow_symlinks = false });
            } else return error.FileNotFound,
            else => return err,
        };
        current.close(io);
        current = next;
    }
    return current;
}

pub fn decide(
    allocator: std.mem.Allocator,
    io: std.Io,
    binding: Binding,
    requested_path: []const u8,
) Decision {
    const resolved = resolve(allocator, io, binding, requested_path) catch return .reject;
    var owned = resolved;
    defer owned.deinit(allocator, io);
    return resolved.decision;
}

fn relativeToRoot(root: []const u8, target: []const u8) ?[]const u8 {
    if (!pathIsWithin(root, target) or pathsEqual(root, target)) return null;
    var at = root.len;
    while (at < target.len and isSeparator(target[at])) at += 1;
    return target[at..];
}

fn openVerifiedParent(
    io: std.Io,
    root_dir: std.Io.Dir,
    canonical_root: []const u8,
    parent_path: []const u8,
    create_parents: bool,
) !std.Io.Dir {
    var current = root_dir;
    errdefer current.close(io);
    var components = std.fs.path.componentIterator(parent_path);
    while (components.next()) |component| {
        var next = current.openDir(io, component.name, .{ .follow_symlinks = true }) catch |err| switch (err) {
            error.FileNotFound => if (create_parents) create: {
                current.createDir(io, component.name, .default_dir) catch |create_err| switch (create_err) {
                    error.PathAlreadyExists => {},
                    else => return create_err,
                };
                // A component we created must still be a directory, not a
                // symlink substituted between create and open.
                break :create try current.openDir(io, component.name, .{ .follow_symlinks = false });
            } else return error.FileNotFound,
            else => return err,
        };
        var next_real_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const next_real_len = next.realPath(io, &next_real_storage) catch |err| {
            next.close(io);
            return err;
        };
        if (!pathIsWithin(canonical_root, next_real_storage[0..next_real_len])) {
            next.close(io);
            return error.AccessDenied;
        }
        current.close(io);
        current = next;
    }
    return current;
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

test "an authorized request retains the opened parent capability" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "app/data/nested");
    var root_buffer: [256]u8 = undefined;
    var target_buffer: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buffer, ".zig-cache/tmp/{s}/app/data", .{tmp.sub_path[0..]});
    const target = try std.fmt.bufPrint(&target_buffer, "{s}/nested/file.bin", .{root});
    var resolved = try resolveForOperation(std.testing.allocator, std.testing.io, .{ .roots = &.{root} }, target, .{ .create_parents = true });
    defer resolved.deinit(std.testing.allocator, std.testing.io);
    try std.testing.expectEqual(Decision.allow, resolved.decision);
    try std.testing.expect(resolved.parent != null);
    try std.testing.expectEqualStrings("file.bin", resolved.basename);
}

test "a retained parent capability ignores a later pathname symlink swap" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "app/data/nested");
    try tmp.dir.createDirPath(std.testing.io, "outside");
    var root_buffer: [256]u8 = undefined;
    var target_buffer: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buffer, ".zig-cache/tmp/{s}/app/data", .{tmp.sub_path[0..]});
    const target = try std.fmt.bufPrint(&target_buffer, "{s}/nested/file.bin", .{root});
    var resolved = try resolveForOperation(std.testing.allocator, std.testing.io, .{ .roots = &.{root} }, target, .{ .create_parents = true });
    defer resolved.deinit(std.testing.allocator, std.testing.io);

    try tmp.dir.rename("app/data/nested", tmp.dir, "app/data/retained", std.testing.io);
    try tmp.dir.symLink(std.testing.io, "../../outside", "app/data/nested", .{ .is_directory = true });
    try resolved.parent.?.writeFile(std.testing.io, .{ .sub_path = resolved.basename, .data = "safe" });

    const retained = try tmp.dir.readFileAlloc(std.testing.io, "app/data/retained/file.bin", std.testing.allocator, .limited(16));
    defer std.testing.allocator.free(retained);
    try std.testing.expectEqualStrings("safe", retained);
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(std.testing.io, "outside/file.bin", .{}));
}
