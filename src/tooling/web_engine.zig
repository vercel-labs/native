const std = @import("std");
const raw_manifest = @import("raw_manifest.zig");

pub const default_engine: Engine = .system;
pub const default_cef_dir = "third_party/cef/macos";

pub const Error = error{
    InvalidWebEngine,
};

pub const Engine = enum {
    system,
    chromium,

    pub fn parse(value: []const u8) ?Engine {
        if (std.mem.eql(u8, value, "system")) return .system;
        if (std.mem.eql(u8, value, "chromium")) return .chromium;
        return null;
    }
};

pub const ValueSource = enum {
    default,
    manifest,
    override,
};

pub const CefConfig = struct {
    dir: []const u8 = default_cef_dir,
    auto_install: bool = false,
};

pub const ManifestConfig = struct {
    web_engine: []const u8 = @tagName(default_engine),
    cef: CefConfig = .{},
    owned: bool = false,

    pub fn deinit(self: ManifestConfig, allocator: std.mem.Allocator) void {
        if (!self.owned) return;
        allocator.free(self.web_engine);
        allocator.free(self.cef.dir);
    }
};

pub const Overrides = struct {
    web_engine: ?Engine = null,
    cef_dir: ?[]const u8 = null,
    cef_auto_install: ?bool = null,
};

pub const Resolved = struct {
    engine: Engine,
    cef_dir: []const u8,
    cef_auto_install: bool,
    engine_source: ValueSource,
    cef_dir_source: ValueSource,
    cef_auto_install_source: ValueSource,
};

pub fn resolve(manifest: ManifestConfig, overrides: Overrides) Error!Resolved {
    const manifest_engine = Engine.parse(manifest.web_engine) orelse return error.InvalidWebEngine;
    return .{
        .engine = overrides.web_engine orelse manifest_engine,
        .cef_dir = overrides.cef_dir orelse manifest.cef.dir,
        .cef_auto_install = overrides.cef_auto_install orelse manifest.cef.auto_install,
        .engine_source = if (overrides.web_engine != null) .override else if (std.mem.eql(u8, manifest.web_engine, @tagName(default_engine))) .default else .manifest,
        .cef_dir_source = if (overrides.cef_dir != null) .override else if (std.mem.eql(u8, manifest.cef.dir, default_cef_dir)) .default else .manifest,
        .cef_auto_install_source = if (overrides.cef_auto_install != null) .override else if (!manifest.cef.auto_install) .default else .manifest,
    };
}

pub fn readManifestConfig(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !ManifestConfig {
    const source = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024));
    defer allocator.free(source);
    return if (std.ascii.eqlIgnoreCase(std.fs.path.extension(path), ".json"))
        parseJsonManifestConfig(allocator, source)
    else
        parseManifestConfig(allocator, source);
}

pub fn parseManifestConfig(allocator: std.mem.Allocator, source: []const u8) !ManifestConfig {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const source_z = try scratch.dupeZ(u8, source);
    @setEvalBranchQuota(4000);
    const raw = try std.zon.parse.fromSliceAlloc(raw_manifest.RawManifest, scratch, source_z, null, .{});
    return duplicateManifestConfig(allocator, raw);
}

pub fn parseJsonManifestConfig(allocator: std.mem.Allocator, source: []const u8) !ManifestConfig {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const raw = try std.json.parseFromSliceLeaky(raw_manifest.RawManifest, arena.allocator(), source, .{ .ignore_unknown_fields = false });
    return duplicateManifestConfig(allocator, raw);
}

fn duplicateManifestConfig(allocator: std.mem.Allocator, raw: raw_manifest.RawManifest) !ManifestConfig {
    return .{
        .web_engine = try allocator.dupe(u8, raw.web_engine),
        .cef = .{
            .dir = try allocator.dupe(u8, raw.cef.dir),
            .auto_install = raw.cef.auto_install,
        },
        .owned = true,
    };
}

test "resolver uses manifest config by default" {
    const config = try parseManifestConfig(std.testing.allocator,
        \\.{
        \\  .id = "com.example.app",
        \\  .name = "example",
        \\  .version = "1.0.0",
        \\  .web_engine = "chromium",
        \\  .cef = .{ .dir = "third_party/cef/macos", .auto_install = true },
        \\}
    );
    defer config.deinit(std.testing.allocator);

    const resolved = try resolve(config, .{});

    try std.testing.expectEqual(Engine.chromium, resolved.engine);
    try std.testing.expectEqualStrings("third_party/cef/macos", resolved.cef_dir);
    try std.testing.expect(resolved.cef_auto_install);
    try std.testing.expectEqual(ValueSource.manifest, resolved.engine_source);
}

test "resolver applies explicit overrides" {
    const config: ManifestConfig = .{
        .web_engine = "chromium",
        .cef = .{ .dir = "third_party/cef/macos", .auto_install = true },
    };

    const resolved = try resolve(config, .{
        .web_engine = .system,
        .cef_dir = "custom/cef",
        .cef_auto_install = false,
    });

    try std.testing.expectEqual(Engine.system, resolved.engine);
    try std.testing.expectEqualStrings("custom/cef", resolved.cef_dir);
    try std.testing.expect(!resolved.cef_auto_install);
    try std.testing.expectEqual(ValueSource.override, resolved.engine_source);
}

test "resolver rejects invalid manifest engine" {
    try std.testing.expectError(error.InvalidWebEngine, resolve(.{ .web_engine = "blink" }, .{}));
}
