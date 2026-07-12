const std = @import("std");
const builtin = @import("builtin");

pub const SignOutcome = enum {
    /// codesign sealed the bundle.
    signed,
    /// codesign is not available on this host (e.g. cross-packaging a macOS
    /// bundle from Linux). Signing is impossible here, so callers may leave
    /// the bundle unsigned without failing the build.
    unavailable,
    /// codesign ran and exited non-zero. On a host that can sign, this is a
    /// hard failure: the bundle is unsigned and must not ship as if it were
    /// signed.
    failed,
};

pub const SignResult = struct {
    outcome: SignOutcome,
    message: []const u8,
};

pub const CodesignArgs = struct {
    app_path: []const u8,
    identity: []const u8 = "-",
    entitlements: ?[]const u8 = null,
    hardened_runtime: bool = false,
    deep: bool = true,
};

pub const NotarizeArgs = struct {
    app_path: []const u8,
    team_id: []const u8,
    apple_id: ?[]const u8 = null,
    password_keychain_item: ?[]const u8 = null,
};

/// codesign's argv never exceeds this many entries: program, `--sign`,
/// identity, `--force`, `--deep`, `--options runtime`, `--entitlements`,
/// its path, and the bundle path.
const max_sign_argv = 10;
/// notarytool submit's argv never exceeds this many entries.
const max_notarize_argv = 11;

/// Build the codesign invocation as an argv array (filled into `buffer`)
/// rather than a shell string. This is the whole fix for spaced bundle
/// paths: passing `{ "codesign", …, "/tmp/My App.app" }` straight to the OS
/// keeps the path a single argument, where a `sh -c` string word-splits it
/// into "/tmp/My" and "App.app" and codesign silently signs nothing. It also
/// removes any command-injection surface from paths or identities.
pub fn buildSignArgv(buffer: [][]const u8, args: CodesignArgs) [][]const u8 {
    var n: usize = 0;
    buffer[n] = "codesign";
    n += 1;
    buffer[n] = "--sign";
    n += 1;
    buffer[n] = args.identity;
    n += 1;
    buffer[n] = "--force";
    n += 1;
    if (args.deep) {
        buffer[n] = "--deep";
        n += 1;
    }
    if (args.hardened_runtime) {
        buffer[n] = "--options";
        n += 1;
        buffer[n] = "runtime";
        n += 1;
    }
    if (args.entitlements) |ent| {
        buffer[n] = "--entitlements";
        n += 1;
        buffer[n] = ent;
        n += 1;
    }
    buffer[n] = args.app_path;
    n += 1;
    return buffer[0..n];
}

pub fn buildNotarizeSubmitArgv(
    buffer: [][]const u8,
    zip_path: []const u8,
    team_id: []const u8,
    apple_id: ?[]const u8,
    keychain_password: ?[]const u8,
) [][]const u8 {
    var n: usize = 0;
    buffer[n] = "xcrun";
    n += 1;
    buffer[n] = "notarytool";
    n += 1;
    buffer[n] = "submit";
    n += 1;
    buffer[n] = zip_path;
    n += 1;
    buffer[n] = "--team-id";
    n += 1;
    buffer[n] = team_id;
    n += 1;
    if (apple_id) |id| {
        buffer[n] = "--apple-id";
        n += 1;
        buffer[n] = id;
        n += 1;
    }
    if (keychain_password) |password| {
        buffer[n] = "--password";
        n += 1;
        buffer[n] = password;
        n += 1;
    }
    buffer[n] = "--wait";
    n += 1;
    return buffer[0..n];
}

pub fn buildStapleArgv(buffer: [][]const u8, app_path: []const u8) [][]const u8 {
    buffer[0] = "xcrun";
    buffer[1] = "stapler";
    buffer[2] = "staple";
    buffer[3] = app_path;
    return buffer[0..4];
}

pub fn buildZipArgv(buffer: [][]const u8, app_path: []const u8, zip_path: []const u8) [][]const u8 {
    buffer[0] = "ditto";
    buffer[1] = "-c";
    buffer[2] = "-k";
    buffer[3] = "--keepParent";
    buffer[4] = app_path;
    buffer[5] = zip_path;
    return buffer[0..6];
}

pub fn signAdHoc(io: std.Io, app_path: []const u8) SignResult {
    return runSign(io, .{ .app_path = app_path, .identity = "-", .deep = true });
}

pub fn signIdentity(io: std.Io, app_path: []const u8, identity: []const u8, entitlements: ?[]const u8) SignResult {
    return runSign(io, .{
        .app_path = app_path,
        .identity = identity,
        .entitlements = entitlements,
        .hardened_runtime = true,
        .deep = true,
    });
}

pub fn notarize(allocator: std.mem.Allocator, io: std.Io, args: NotarizeArgs) !SignResult {
    const zip_path = try std.fmt.allocPrint(allocator, "{s}.zip", .{args.app_path});
    defer allocator.free(zip_path);

    var zip_argv: [6][]const u8 = undefined;
    const zip = buildZipArgv(&zip_argv, args.app_path, zip_path);
    runArgv(io, zip) catch return .{ .outcome = .failed, .message = "failed to zip app for notarization" };

    const keychain_password: ?[]const u8 = if (args.password_keychain_item) |item|
        try std.fmt.allocPrint(allocator, "@keychain:{s}", .{item})
    else
        null;
    defer if (keychain_password) |password| allocator.free(password);

    var submit_argv: [max_notarize_argv][]const u8 = undefined;
    const submit = buildNotarizeSubmitArgv(&submit_argv, zip_path, args.team_id, args.apple_id, keychain_password);
    runArgv(io, submit) catch return .{ .outcome = .failed, .message = "notarytool submit failed" };

    var staple_argv: [4][]const u8 = undefined;
    const staple = buildStapleArgv(&staple_argv, args.app_path);
    runArgv(io, staple) catch return .{ .outcome = .failed, .message = "stapler staple failed" };

    return .{ .outcome = .signed, .message = "notarization complete" };
}

fn runSign(io: std.Io, args: CodesignArgs) SignResult {
    // Only macOS ships codesign. Cross-packaging a macOS bundle from another
    // host leaves it unsigned, but that is not a failure of THIS host — it is
    // simply the wrong place to seal a bundle, so report it as unavailable
    // rather than as a codesign that ran and failed.
    if (builtin.os.tag != .macos)
        return .{ .outcome = .unavailable, .message = "codesign is only available on macOS hosts" };

    var argv_buf: [max_sign_argv][]const u8 = undefined;
    const argv = buildSignArgv(&argv_buf, args);
    runArgv(io, argv) catch return .{ .outcome = .failed, .message = "codesign failed" };
    return .{ .outcome = .signed, .message = "signed" };
}

/// Spawn one tool directly (no `sh -c`) and FAIL on a non-zero exit. Passing
/// argv straight to the OS keeps a path with spaces a single argument — the
/// shell never gets a chance to word-split it — and leaves no command-
/// injection surface from paths or identities. A codesign that exits
/// non-zero, or a spawn that never launches, surfaces as error.CommandFailed
/// so callers record the bundle as unsigned instead of reporting a signature
/// that does not exist.
fn runArgv(io: std.Io, argv: []const []const u8) !void {
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch return error.CommandFailed;
    const term = child.wait(io) catch return error.CommandFailed;
    switch (term) {
        .exited => |code| if (code != 0) return error.CommandFailed,
        else => return error.CommandFailed,
    }
}

fn expectArgv(expected: []const []const u8, actual: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |want, got| try std.testing.expectEqualStrings(want, got);
}

test "ad-hoc sign argv keeps a spaced bundle path as one argument" {
    var buffer: [max_sign_argv][]const u8 = undefined;
    const argv = buildSignArgv(&buffer, .{ .app_path = "/tmp/My App.app" });
    try expectArgv(
        &.{ "codesign", "--sign", "-", "--force", "--deep", "/tmp/My App.app" },
        argv,
    );
}

test "identity sign argv includes runtime and entitlements" {
    var buffer: [max_sign_argv][]const u8 = undefined;
    const argv = buildSignArgv(&buffer, .{
        .app_path = "/tmp/Test.app",
        .identity = "Developer ID Application: Test",
        .entitlements = "assets/native-sdk.entitlements",
        .hardened_runtime = true,
    });
    try expectArgv(&.{
        "codesign",
        "--sign",
        "Developer ID Application: Test",
        "--force",
        "--deep",
        "--options",
        "runtime",
        "--entitlements",
        "assets/native-sdk.entitlements",
        "/tmp/Test.app",
    }, argv);
}

test "notarize submit argv includes team id and wait" {
    var buffer: [max_notarize_argv][]const u8 = undefined;
    const argv = buildNotarizeSubmitArgv(&buffer, "/tmp/Test.app.zip", "ABCD1234", null, null);
    try expectArgv(
        &.{ "xcrun", "notarytool", "submit", "/tmp/Test.app.zip", "--team-id", "ABCD1234", "--wait" },
        argv,
    );
}

test "notarize submit argv carries apple id and keychain password" {
    var buffer: [max_notarize_argv][]const u8 = undefined;
    const argv = buildNotarizeSubmitArgv(&buffer, "/tmp/Test.app.zip", "ABCD1234", "dev@example.com", "@keychain:AC_PASSWORD");
    try expectArgv(&.{
        "xcrun",      "notarytool",            "submit",     "/tmp/Test.app.zip",
        "--team-id",  "ABCD1234",              "--apple-id", "dev@example.com",
        "--password", "@keychain:AC_PASSWORD", "--wait",
    }, argv);
}

test "staple argv targets app path" {
    var buffer: [4][]const u8 = undefined;
    const argv = buildStapleArgv(&buffer, "/tmp/My App.app");
    try expectArgv(&.{ "xcrun", "stapler", "staple", "/tmp/My App.app" }, argv);
}

test "zip argv uses ditto and keeps spaced paths intact" {
    var buffer: [6][]const u8 = undefined;
    const argv = buildZipArgv(&buffer, "/tmp/My App.app", "/tmp/My App.app.zip");
    try expectArgv(
        &.{ "ditto", "-c", "-k", "--keepParent", "/tmp/My App.app", "/tmp/My App.app.zip" },
        argv,
    );
}
