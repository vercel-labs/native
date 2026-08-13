//! Engine-owned credential-store adapter shared by core effects and the
//! builtin WebView bridge. PlatformServices remains the one OS vtable; this
//! module fixes the app-facing bounds, app namespace, and closed outcomes so
//! neither caller grows its own interpretation of keychain errors.

const std = @import("std");
const platform = @import("../platform/root.zig");

pub const max_key_bytes: usize = 256;
pub const max_secret_bytes: usize = platform.max_credential_secret_bytes;

pub const Operation = enum(u8) { set, get, delete };

pub const Outcome = enum(u8) {
    ok,
    miss,
    denied,
    locked,
    io_failed,
    over_bound,
    rejected,
};

pub const Execution = struct {
    outcome: Outcome,
    len: usize = 0,
};

/// One app-scoped view over the platform credential vtable. `service` is the
/// stable app identity (app.zon id); `key` becomes the platform account.
pub const Binding = struct {
    services: *const platform.PlatformServices,
    service: []const u8,
    permitted: bool,
};

pub fn validKey(key: []const u8) bool {
    return key.len > 0 and key.len <= max_key_bytes and
        std.mem.indexOfScalar(u8, key, 0) == null and
        std.unicode.utf8ValidateSlice(key);
}

pub fn outcomeName(outcome: Outcome) []const u8 {
    return @tagName(outcome);
}

pub fn outcomeFromName(name: []const u8) ?Outcome {
    inline for (std.meta.tags(Outcome)) |outcome| {
        if (std.mem.eql(u8, name, @tagName(outcome))) return outcome;
    }
    return null;
}

pub fn execute(binding: Binding, operation: Operation, key: []const u8, secret: []const u8, output: []u8) Execution {
    if (!binding.permitted) return .{ .outcome = .denied };
    if (!validKey(key) or binding.service.len == 0 or binding.service.len > platform.max_credential_service_bytes or
        std.mem.indexOfScalar(u8, binding.service, 0) != null or
        !std.unicode.utf8ValidateSlice(binding.service))
    {
        return .{ .outcome = .over_bound };
    }
    if (operation == .set and secret.len > max_secret_bytes) return .{ .outcome = .over_bound };
    const credential_key: platform.CredentialKey = .{ .service = binding.service, .account = key };
    return switch (operation) {
        .set => blk: {
            binding.services.setCredential(.{
                .service = binding.service,
                .account = key,
                .secret = secret,
            }) catch |err| break :blk .{ .outcome = classifyError(err) };
            break :blk .{ .outcome = .ok };
        },
        .get => blk: {
            const bytes = binding.services.getCredential(credential_key, output) catch |err| {
                if (err == error.CredentialNotFound) break :blk .{ .outcome = .miss };
                break :blk .{ .outcome = classifyError(err) };
            };
            if (bytes.len > max_secret_bytes or bytes.len > output.len) break :blk .{ .outcome = .over_bound };
            break :blk .{ .outcome = .ok, .len = bytes.len };
        },
        .delete => blk: {
            binding.services.deleteCredential(credential_key) catch |err| {
                if (err == error.CredentialNotFound) break :blk .{ .outcome = .miss };
                break :blk .{ .outcome = classifyError(err) };
            };
            break :blk .{ .outcome = .ok };
        },
    };
}

fn classifyError(err: anyerror) Outcome {
    return switch (err) {
        error.CredentialNotFound => .miss,
        error.UnsupportedService => .locked,
        error.InvalidCredentialOptions,
        error.CredentialFieldTooLarge,
        error.NoSpaceLeft,
        => .over_bound,
        error.CredentialStoreLocked => .locked,
        error.CredentialStoreFailed => .io_failed,
        error.AccessDenied,
        error.PermissionDenied,
        => .denied,
        else => .io_failed,
    };
}

test "credential adapter validates keys and names closed outcomes" {
    try std.testing.expect(validKey("token"));
    try std.testing.expect(!validKey(""));
    try std.testing.expect(!validKey("token\x00suffix"));
    try std.testing.expect(!validKey(&.{ 0xff, 0xfe }));
    try std.testing.expectEqualStrings("locked", outcomeName(.locked));
    try std.testing.expectEqual(Outcome.denied, outcomeFromName("denied").?);
}
