const std = @import("std");

/// The outcome of one signing-pipeline tool run. `message` is always
/// allocated (the tool's own stdout+stderr for failures — codesign says
/// exactly why it refused — or a short success note); the caller frees.
pub const SignResult = struct {
    ok: bool,
    message: []u8,
};

pub const CodesignArgs = struct {
    app_path: []const u8,
    identity: []const u8 = "-",
    entitlements: ?[]const u8 = null,
    hardened_runtime: bool = false,
    secure_timestamp: bool = false,
    deep: bool = true,
};

pub const NotarizeArgs = struct {
    artifact_path: []const u8,
    keychain_profile: []const u8,
};

// Every command in this pipeline is built as an ARGV ARRAY, never as a
// shell string: a bundle path (or identity) with spaces must reach
// codesign/ditto/notarytool as one argument. The shell-string shape this
// replaced split `My App.app` into two arguments, codesign signed
// nothing, and the failure never surfaced.

pub const sign_argv_capacity = 11;

pub fn signArgv(buffer: *[sign_argv_capacity][]const u8, args: CodesignArgs) []const []const u8 {
    var len: usize = 0;
    buffer[len] = "codesign";
    len += 1;
    buffer[len] = "--sign";
    len += 1;
    buffer[len] = args.identity;
    len += 1;
    buffer[len] = "--force";
    len += 1;
    if (args.deep) {
        buffer[len] = "--deep";
        len += 1;
    }
    if (args.hardened_runtime) {
        buffer[len] = "--options";
        len += 1;
        buffer[len] = "runtime";
        len += 1;
    }
    if (args.secure_timestamp) {
        buffer[len] = "--timestamp";
        len += 1;
    }
    if (args.entitlements) |ent| {
        buffer[len] = "--entitlements";
        len += 1;
        buffer[len] = ent;
        len += 1;
    }
    buffer[len] = args.app_path;
    len += 1;
    return buffer[0..len];
}

pub fn verifyArgv(buffer: *[6][]const u8, app_path: []const u8) []const []const u8 {
    buffer.* = .{ "codesign", "--verify", "--deep", "--strict", "--verbose=2", app_path };
    return buffer;
}

pub fn verifyArtifactArgv(buffer: *[5][]const u8, artifact_path: []const u8) []const []const u8 {
    buffer.* = .{ "codesign", "--verify", "--strict", "--verbose=2", artifact_path };
    return buffer;
}

pub fn zipArgv(buffer: *[6][]const u8, app_path: []const u8, zip_path: []const u8) []const []const u8 {
    buffer.* = .{ "ditto", "-c", "-k", "--keepParent", app_path, zip_path };
    return buffer;
}

pub fn stapleArgv(buffer: *[4][]const u8, app_path: []const u8) []const []const u8 {
    buffer.* = .{ "xcrun", "stapler", "staple", app_path };
    return buffer;
}

pub fn stapleValidateArgv(buffer: *[4][]const u8, app_path: []const u8) []const []const u8 {
    buffer.* = .{ "xcrun", "stapler", "validate", app_path };
    return buffer;
}

pub fn notarizeSubmitArgv(buffer: *[9][]const u8, artifact_path: []const u8, keychain_profile: []const u8) []const []const u8 {
    buffer.* = .{
        "xcrun",       "notarytool",         "submit",
        artifact_path, "--keychain-profile", keychain_profile,
        "--wait",      "--output-format",    "json",
    };
    return buffer;
}

pub fn signAdHoc(allocator: std.mem.Allocator, io: std.Io, app_path: []const u8) !SignResult {
    return runSign(allocator, io, .{ .app_path = app_path, .identity = "-", .deep = true });
}

pub fn signIdentity(allocator: std.mem.Allocator, io: std.Io, app_path: []const u8, identity: []const u8, entitlements: ?[]const u8) !SignResult {
    return runSign(allocator, io, .{
        .app_path = app_path,
        .identity = identity,
        .entitlements = entitlements,
        .hardened_runtime = true,
        .secure_timestamp = true,
        .deep = true,
    });
}

pub fn signIdentityArtifact(allocator: std.mem.Allocator, io: std.Io, artifact_path: []const u8, identity: []const u8) !SignResult {
    return runSign(allocator, io, .{
        .app_path = artifact_path,
        .identity = identity,
        .secure_timestamp = true,
        .deep = false,
    });
}

/// `codesign --verify --deep --strict` over the signed bundle: the same
/// check Gatekeeper and an Apple silicon launch effectively run, so a
/// signature that only LOOKS applied (stale seal, unsigned nested code)
/// fails here at package time instead of on the user's machine.
pub fn verify(allocator: std.mem.Allocator, io: std.Io, app_path: []const u8) !SignResult {
    var buffer: [6][]const u8 = undefined;
    return runTool(allocator, io, verifyArgv(&buffer, app_path));
}

pub fn verifyArtifact(allocator: std.mem.Allocator, io: std.Io, artifact_path: []const u8) !SignResult {
    var buffer: [5][]const u8 = undefined;
    return runTool(allocator, io, verifyArtifactArgv(&buffer, artifact_path));
}

pub fn notarizeApp(allocator: std.mem.Allocator, io: std.Io, args: NotarizeArgs) !SignResult {
    const zip_path = try std.fmt.allocPrint(allocator, "{s}.notarize.zip", .{args.artifact_path});
    defer allocator.free(zip_path);
    defer std.Io.Dir.cwd().deleteFile(io, zip_path) catch {};

    var zip_buffer: [6][]const u8 = undefined;
    const zip_result = try runTool(allocator, io, zipArgv(&zip_buffer, args.artifact_path, zip_path));
    if (!zip_result.ok) return failedStep(allocator, "ditto (zip for notarization)", zip_result);
    allocator.free(zip_result.message);

    return notarizeArtifact(allocator, io, .{
        .artifact_path = args.artifact_path,
        .keychain_profile = args.keychain_profile,
    }, zip_path);
}

pub fn notarizeArtifact(allocator: std.mem.Allocator, io: std.Io, args: NotarizeArgs, submission_path: ?[]const u8) !SignResult {
    var submit_buffer: [9][]const u8 = undefined;
    const submit_result = try runTool(allocator, io, notarizeSubmitArgv(&submit_buffer, submission_path orelse args.artifact_path, args.keychain_profile));
    if (!submit_result.ok) return failedStep(allocator, "notarytool submit", submit_result);
    if (!notarizationAccepted(allocator, submit_result.message)) return failedStep(allocator, "notarytool returned a non-accepted status", submit_result);
    allocator.free(submit_result.message);

    var staple_buffer: [4][]const u8 = undefined;
    const staple_result = try runTool(allocator, io, stapleArgv(&staple_buffer, args.artifact_path));
    if (!staple_result.ok) return failedStep(allocator, "stapler staple", staple_result);
    allocator.free(staple_result.message);

    var validate_buffer: [4][]const u8 = undefined;
    const validate_result = try runTool(allocator, io, stapleValidateArgv(&validate_buffer, args.artifact_path));
    if (!validate_result.ok) return failedStep(allocator, "stapler validate", validate_result);
    allocator.free(validate_result.message);

    return .{ .ok = true, .message = try allocator.dupe(u8, "notarization accepted, stapled, and validated") };
}

fn notarizationAccepted(allocator: std.mem.Allocator, output: []const u8) bool {
    const start = std.mem.indexOfScalar(u8, output, '{') orelse return false;
    const end = std.mem.lastIndexOfScalar(u8, output, '}') orelse return false;
    if (end < start) return false;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, output[start .. end + 1], .{}) catch return false;
    defer parsed.deinit();
    const status = switch (parsed.value) {
        .object => |object| object.get("status") orelse return false,
        else => return false,
    };
    return status == .string and std.mem.eql(u8, status.string, "Accepted");
}

fn failedStep(allocator: std.mem.Allocator, step: []const u8, result: SignResult) !SignResult {
    defer allocator.free(result.message);
    return .{ .ok = false, .message = try std.fmt.allocPrint(allocator, "{s} failed:\n{s}", .{ step, result.message }) };
}

fn runSign(allocator: std.mem.Allocator, io: std.Io, args: CodesignArgs) !SignResult {
    var buffer: [sign_argv_capacity][]const u8 = undefined;
    return runTool(allocator, io, signArgv(&buffer, args));
}

/// Run one pipeline tool and report a non-zero exit as a failure that
/// carries the tool's own output: a codesign that exits 1 — or a host
/// without codesign at all — must surface with its reason so callers can
/// refuse to report a signature that does not exist.
fn runTool(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) !SignResult {
    const result = std.process.run(allocator, io, .{
        .argv = argv,
        .stdout_limit = .limited(256 * 1024),
        .stderr_limit = .limited(256 * 1024),
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{
            .ok = false,
            .message = try std.fmt.allocPrint(allocator, "could not run `{s}`: {t} (it ships with the Xcode Command Line Tools; signing macOS bundles needs a macOS host)", .{ argv[0], err }),
        },
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    const ok = result.term == .exited and result.term.exited == 0;
    // codesign explains failures on stderr; notarytool narrates on
    // stdout. Keep both, stderr last so the refusal reads closest to
    // the caller's teaching message.
    return .{ .ok = ok, .message = try std.mem.concat(allocator, u8, &.{ result.stdout, result.stderr }) };
}

test "ad-hoc sign argv keeps a spaced bundle path as one argument" {
    var buffer: [sign_argv_capacity][]const u8 = undefined;
    const argv = signArgv(&buffer, .{ .app_path = "/tmp/My Demo App.app" });
    const expected = [_][]const u8{ "codesign", "--sign", "-", "--force", "--deep", "/tmp/My Demo App.app" };
    try expectArgv(&expected, argv);
}

test "identity sign argv includes runtime and entitlements as single arguments" {
    var buffer: [sign_argv_capacity][]const u8 = undefined;
    const argv = signArgv(&buffer, .{
        .app_path = "/tmp/My Demo App.app",
        .identity = "Developer ID Application: Test Person (ABCD1234)",
        .entitlements = "assets dir/native-sdk.entitlements",
        .hardened_runtime = true,
        .secure_timestamp = true,
    });
    const expected = [_][]const u8{
        "codesign",                                         "--sign",
        "Developer ID Application: Test Person (ABCD1234)", "--force",
        "--deep",                                           "--options",
        "runtime",                                          "--timestamp",
        "--entitlements",                                   "assets dir/native-sdk.entitlements",
        "/tmp/My Demo App.app",
    };
    try expectArgv(&expected, argv);
}

test "distribution artifact sign argv requests a secure timestamp without app-only options" {
    var buffer: [sign_argv_capacity][]const u8 = undefined;
    const argv = signArgv(&buffer, .{
        .app_path = "/tmp/My Demo App.dmg",
        .identity = "Developer ID Application: Test Person (ABCD1234)",
        .secure_timestamp = true,
        .deep = false,
    });
    const expected = [_][]const u8{
        "codesign", "--sign",      "Developer ID Application: Test Person (ABCD1234)",
        "--force",  "--timestamp", "/tmp/My Demo App.dmg",
    };
    try expectArgv(&expected, argv);
}

test "verify argv runs the strict deep check on the bundle path" {
    var buffer: [6][]const u8 = undefined;
    const argv = verifyArgv(&buffer, "/tmp/My Demo App.app");
    const expected = [_][]const u8{ "codesign", "--verify", "--deep", "--strict", "--verbose=2", "/tmp/My Demo App.app" };
    try expectArgv(&expected, argv);
}

test "artifact verify argv runs the strict check without bundle recursion" {
    var buffer: [5][]const u8 = undefined;
    const argv = verifyArtifactArgv(&buffer, "/tmp/My Demo App.dmg");
    const expected = [_][]const u8{ "codesign", "--verify", "--strict", "--verbose=2", "/tmp/My Demo App.dmg" };
    try expectArgv(&expected, argv);
}

test "notarize submit argv uses a keychain profile, waits, and requests JSON" {
    var buffer: [9][]const u8 = undefined;
    const argv = notarizeSubmitArgv(&buffer, "/tmp/My Demo App.dmg", "vercel-release");
    const expected = [_][]const u8{ "xcrun", "notarytool", "submit", "/tmp/My Demo App.dmg", "--keychain-profile", "vercel-release", "--wait", "--output-format", "json" };
    try expectArgv(&expected, argv);
}

test "staple and zip argv carry spaced paths as single arguments" {
    var staple_buffer: [4][]const u8 = undefined;
    const staple = stapleArgv(&staple_buffer, "/tmp/My Demo App.app");
    const staple_expected = [_][]const u8{ "xcrun", "stapler", "staple", "/tmp/My Demo App.app" };
    try expectArgv(&staple_expected, staple);

    var validate_buffer: [4][]const u8 = undefined;
    const validate = stapleValidateArgv(&validate_buffer, "/tmp/My Demo App.app");
    const validate_expected = [_][]const u8{ "xcrun", "stapler", "validate", "/tmp/My Demo App.app" };
    try expectArgv(&validate_expected, validate);

    var zip_buffer: [6][]const u8 = undefined;
    const zip = zipArgv(&zip_buffer, "/tmp/My Demo App.app", "/tmp/My Demo App.app.zip");
    const zip_expected = [_][]const u8{ "ditto", "-c", "-k", "--keepParent", "/tmp/My Demo App.app", "/tmp/My Demo App.app.zip" };
    try expectArgv(&zip_expected, zip);
}

test "notarization accepts only an explicit Accepted JSON status" {
    try std.testing.expect(notarizationAccepted(std.testing.allocator, "{\"id\":\"123\",\"status\":\"Accepted\"}\n"));
    try std.testing.expect(!notarizationAccepted(std.testing.allocator, "{\"id\":\"123\",\"status\":\"Invalid\"}\n"));
    try std.testing.expect(!notarizationAccepted(std.testing.allocator, "not JSON"));
}

test "a failing tool surfaces its own output, not a silent success" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    // `false` exits 1 with no output: the result must be a failure.
    const result = try runTool(std.testing.allocator, std.testing.io, &.{"false"});
    defer std.testing.allocator.free(result.message);
    try std.testing.expect(!result.ok);
}

test "a missing tool reports a failure that names it" {
    const result = try runTool(std.testing.allocator, std.testing.io, &.{"native-sdk-no-such-tool-xyz"});
    defer std.testing.allocator.free(result.message);
    try std.testing.expect(!result.ok);
    try std.testing.expect(std.mem.indexOf(u8, result.message, "native-sdk-no-such-tool-xyz") != null);
}

fn expectArgv(expected: []const []const u8, actual: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |want, got| {
        try std.testing.expectEqualStrings(want, got);
    }
}
