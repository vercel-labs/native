//! Open-URL effect coverage: `fx.openUrl` reaches the platform's
//! external-URL service on the loop thread, refuses hostile input
//! (unvetted schemes, control bytes, over-bound URLs) whole before the
//! platform sees any of it, and stays inert under fake execution and
//! session replay so tests/replays never launch a browser.

const std = @import("std");
const platform = @import("../platform/root.zig");
const effects_mod = @import("effects.zig");

const Msg = enum { unused };
const TestEffects = effects_mod.Effects(Msg);

test "open-url effect hands an allowed URL to the platform service" {
    var null_platform = platform.NullPlatform.init(.{});
    var host = null_platform.platform();
    var fx = TestEffects.init(std.testing.allocator);
    defer fx.deinit();
    fx.bindServices(&host.services);

    fx.openUrl("https://example.com/docs/start");
    try std.testing.expectEqualStrings("https://example.com/docs/start", null_platform.lastExternalUrl());

    // The other vetted schemes ride the same path.
    fx.openUrl("http://example.com/plain");
    try std.testing.expectEqualStrings("http://example.com/plain", null_platform.lastExternalUrl());
    fx.openUrl("mailto:hello@example.com");
    try std.testing.expectEqualStrings("mailto:hello@example.com", null_platform.lastExternalUrl());

    // Schemes are case-insensitive per RFC 3986, so the allowlist
    // matches them that way rather than refusing a legitimate URL.
    fx.openUrl("HTTPS://example.com/shouty");
    try std.testing.expectEqualStrings("HTTPS://example.com/shouty", null_platform.lastExternalUrl());
}

test "open-url effect refuses a javascript: URL" {
    var null_platform = platform.NullPlatform.init(.{});
    var host = null_platform.platform();
    var fx = TestEffects.init(std.testing.allocator);
    defer fx.deinit();
    fx.bindServices(&host.services);

    fx.openUrl("javascript:alert(1)");
    // Case games do not widen an allowlist.
    fx.openUrl("JavaScript:alert(1)");

    try std.testing.expectEqualStrings("", null_platform.lastExternalUrl());
}

test "open-url effect refuses a file: URL" {
    var null_platform = platform.NullPlatform.init(.{});
    var host = null_platform.platform();
    var fx = TestEffects.init(std.testing.allocator);
    defer fx.deinit();
    fx.bindServices(&host.services);

    fx.openUrl("file:///etc/passwd");
    fx.openUrl("FILE:///etc/passwd");

    try std.testing.expectEqualStrings("", null_platform.lastExternalUrl());
}

test "open-url effect refuses an over-long URL" {
    var null_platform = platform.NullPlatform.init(.{});
    var host = null_platform.platform();
    var fx = TestEffects.init(std.testing.allocator);
    defer fx.deinit();
    fx.bindServices(&host.services);

    var long_url: [platform.max_external_url_bytes + 1]u8 = undefined;
    const prefix = "https://example.com/";
    @memcpy(long_url[0..prefix.len], prefix);
    @memset(long_url[prefix.len..], 'x');
    fx.openUrl(&long_url);

    // Rejected WHOLE: the bound never truncates a URL into a shorter
    // one the OS would happily open.
    try std.testing.expectEqualStrings("", null_platform.lastExternalUrl());

    // One byte under the bound still rides through, so the rejection
    // above is the bound and not a broken path.
    fx.openUrl(long_url[0..platform.max_external_url_bytes]);
    try std.testing.expectEqual(platform.max_external_url_bytes, null_platform.lastExternalUrl().len);
}

test "open-url effect refuses an embedded NUL and other control bytes" {
    var null_platform = platform.NullPlatform.init(.{});
    var host = null_platform.platform();
    var fx = TestEffects.init(std.testing.allocator);
    defer fx.deinit();
    fx.bindServices(&host.services);

    fx.openUrl("https://example.com/\x00javascript:alert(1)");
    fx.openUrl("https://example.com/ ok");
    fx.openUrl("https://example.com/\nfollow");
    fx.openUrl("");
    fx.openUrl("https://");
    fx.openUrl("ftp://example.com/file.zip");

    try std.testing.expectEqualStrings("", null_platform.lastExternalUrl());
}

test "open-url effect is inert without a service and during fake execution or replay" {
    var unbound = TestEffects.init(std.testing.allocator);
    defer unbound.deinit();
    unbound.openUrl("https://example.com/no-host");

    var null_platform = platform.NullPlatform.init(.{});
    var host = null_platform.platform();
    var fx = TestEffects.init(std.testing.allocator);
    defer fx.deinit();
    fx.bindServices(&host.services);

    fx.executor = .fake;
    fx.openUrl("https://example.com/fake");
    try std.testing.expectEqualStrings("", null_platform.lastExternalUrl());

    fx.armReplay();
    fx.openUrl("https://example.com/replay");
    try std.testing.expectEqualStrings("", null_platform.lastExternalUrl());
}
