const std = @import("std");
const platform = @import("../platform/root.zig");

pub const Config = struct {
    dist: []const u8 = "dist",
    entry: []const u8 = "index.html",
    origin: []const u8 = "zero://app",
    spa_fallback: bool = true,
    dev_url_env: []const u8 = "ZERO_NATIVE_FRONTEND_URL",
};

pub fn sourceFromEnv(env_map: *std.process.Environ.Map, config: Config) platform.WebViewSource {
    if (env_map.get(config.dev_url_env)) |url| {
        if (url.len > 0) return platform.WebViewSource.url(url);
    }
    if (env_map.get("ZERO_NATIVE_FRONTEND_DIR")) |dir| {
        if (dir.len > 0) {
            return platform.WebViewSource.assets(.{
                .root_path = dir,
                .entry = config.entry,
                .origin = config.origin,
                .spa_fallback = config.spa_fallback,
            });
        }
    }
    return productionSource(config);
}

pub fn productionSource(config: Config) platform.WebViewSource {
    return platform.WebViewSource.assets(.{
        .root_path = config.dist,
        .entry = config.entry,
        .origin = config.origin,
        .spa_fallback = config.spa_fallback,
    });
}

test "frontend source prefers managed dev server url" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("ZERO_NATIVE_FRONTEND_URL", "http://127.0.0.1:5173/");

    const source = sourceFromEnv(&env, .{ .dist = "dist" });

    try std.testing.expectEqual(platform.WebViewSourceKind.url, source.kind);
    try std.testing.expectEqualStrings("http://127.0.0.1:5173/", source.bytes);
}

test "frontend source falls back to production assets" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    const source = sourceFromEnv(&env, .{ .dist = "frontend/dist", .entry = "app.html" });

    try std.testing.expectEqual(platform.WebViewSourceKind.assets, source.kind);
    try std.testing.expectEqualStrings("frontend/dist", source.asset_options.?.root_path);
    try std.testing.expectEqualStrings("app.html", source.asset_options.?.entry);
}
