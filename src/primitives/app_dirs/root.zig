const std = @import("std");
const builtin = @import("builtin");

pub const Error = error{
    MissingHome,
    MissingRequiredEnv,
    InvalidAppName,
    UnsupportedPlatform,
    NoSpaceLeft,
};

pub const Platform = enum {
    macos,
    windows,
    linux,
    ios,
    android,
    unknown,
};

pub const DirKind = enum {
    config,
    cache,
    data,
    state,
    logs,
    temp,
};

pub const AppInfo = struct {
    name: []const u8,
    organization: ?[]const u8 = null,
    qualifier: ?[]const u8 = null,

    pub fn validate(self: AppInfo) Error!void {
        try validateAppName(self.name);
        if (self.organization) |organization| try validateAppName(organization);
        if (self.qualifier) |qualifier| try validateAppName(qualifier);
    }

    pub fn pathName(self: AppInfo) []const u8 {
        return self.name;
    }
};

pub const Env = struct {
    home: ?[]const u8 = null,
    xdg_config_home: ?[]const u8 = null,
    xdg_cache_home: ?[]const u8 = null,
    xdg_data_home: ?[]const u8 = null,
    xdg_state_home: ?[]const u8 = null,
    local_app_data: ?[]const u8 = null,
    app_data: ?[]const u8 = null,
    temp: ?[]const u8 = null,
    tmp: ?[]const u8 = null,
    tmpdir: ?[]const u8 = null,
};

pub const ResolvedDirs = struct {
    config: []const u8,
    cache: []const u8,
    data: []const u8,
    state: []const u8,
    logs: []const u8,
    temp: []const u8,

    pub fn get(self: ResolvedDirs, kind: DirKind) []const u8 {
        return switch (kind) {
            .config => self.config,
            .cache => self.cache,
            .data => self.data,
            .state => self.state,
            .logs => self.logs,
            .temp => self.temp,
        };
    }
};

pub const Buffers = struct {
    config: []u8,
    cache: []u8,
    data: []u8,
    state: []u8,
    logs: []u8,
    temp: []u8,

    pub fn fromArray(comptime len: usize, buffers: *[6][len]u8) Buffers {
        return .{
            .config = buffers[0][0..],
            .cache = buffers[1][0..],
            .data = buffers[2][0..],
            .state = buffers[3][0..],
            .logs = buffers[4][0..],
            .temp = buffers[5][0..],
        };
    }

    fn forKind(self: Buffers, kind: DirKind) []u8 {
        return switch (kind) {
            .config => self.config,
            .cache => self.cache,
            .data => self.data,
            .state => self.state,
            .logs => self.logs,
            .temp => self.temp,
        };
    }
};

pub fn currentPlatform() Platform {
    if (comptime @hasField(@TypeOf(builtin.abi), "android")) {
        if (builtin.abi == .android) return .android;
    }

    return switch (builtin.os.tag) {
        .macos => .macos,
        .windows => .windows,
        .linux => .linux,
        .ios => .ios,
        else => .unknown,
    };
}

pub fn platformSeparator(platform: Platform) u8 {
    return switch (platform) {
        .windows => '\\',
        else => '/',
    };
}

pub fn validateAppName(name: []const u8) Error!void {
    if (name.len == 0) return error.InvalidAppName;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return error.InvalidAppName;

    for (name) |ch| {
        if (ch == 0 or ch == '/' or ch == '\\') return error.InvalidAppName;
    }
}

pub fn resolve(app: AppInfo, platform: Platform, env: Env, buffers: Buffers) Error!ResolvedDirs {
    return .{
        .config = try resolveOne(app, platform, env, .config, buffers.config),
        .cache = try resolveOne(app, platform, env, .cache, buffers.cache),
        .data = try resolveOne(app, platform, env, .data, buffers.data),
        .state = try resolveOne(app, platform, env, .state, buffers.state),
        .logs = try resolveOne(app, platform, env, .logs, buffers.logs),
        .temp = try resolveOne(app, platform, env, .temp, buffers.temp),
    };
}

pub fn resolveOne(app: AppInfo, platform: Platform, env: Env, kind: DirKind, output: []u8) Error![]const u8 {
    try app.validate();

    return switch (platform) {
        .linux => resolveLinux(app.pathName(), env, kind, output),
        .macos => resolveMacos(app.pathName(), env, kind, output),
        .windows => resolveWindows(app.pathName(), env, kind, output),
        .ios => resolveIos(env, kind, output),
        .android => resolveAndroid(env, kind, output),
        .unknown => error.UnsupportedPlatform,
    };
}

pub fn join(platform: Platform, output: []u8, parts: []const []const u8) Error![]const u8 {
    if (parts.len == 0) return output[0..0];

    const sep = platformSeparator(platform);
    var len: usize = 0;

    for (parts, 0..) |part, i| {
        if (part.len == 0) continue;
        if (i != 0 and len > 0 and output[len - 1] != sep) {
            if (len >= output.len) return error.NoSpaceLeft;
            output[len] = sep;
            len += 1;
        }
        if (len + part.len > output.len) return error.NoSpaceLeft;
        @memcpy(output[len..][0..part.len], part);
        len += part.len;
    }

    return output[0..len];
}

fn resolveLinux(app_name: []const u8, env: Env, kind: DirKind, output: []u8) Error![]const u8 {
    const home = env.home;

    return switch (kind) {
        .config => join(.linux, output, if (env.xdg_config_home) |root| &.{ root, app_name } else &.{ home orelse return error.MissingHome, ".config", app_name }),
        .cache => join(.linux, output, if (env.xdg_cache_home) |root| &.{ root, app_name } else &.{ home orelse return error.MissingHome, ".cache", app_name }),
        .data => join(.linux, output, if (env.xdg_data_home) |root| &.{ root, app_name } else &.{ home orelse return error.MissingHome, ".local", "share", app_name }),
        .state => join(.linux, output, if (env.xdg_state_home) |root| &.{ root, app_name } else &.{ home orelse return error.MissingHome, ".local", "state", app_name }),
        .logs => join(.linux, output, if (env.xdg_state_home) |root| &.{ root, app_name, "logs" } else &.{ home orelse return error.MissingHome, ".local", "state", app_name, "logs" }),
        .temp => join(.linux, output, &.{ env.tmpdir orelse "/tmp", app_name }),
    };
}

fn resolveMacos(app_name: []const u8, env: Env, kind: DirKind, output: []u8) Error![]const u8 {
    const home = env.home orelse return error.MissingHome;

    return switch (kind) {
        .config => join(.macos, output, &.{ home, "Library", "Preferences", app_name }),
        .cache => join(.macos, output, &.{ home, "Library", "Caches", app_name }),
        .data => join(.macos, output, &.{ home, "Library", "Application Support", app_name }),
        .state => join(.macos, output, &.{ home, "Library", "Application Support", app_name, "State" }),
        .logs => join(.macos, output, &.{ home, "Library", "Logs", app_name }),
        .temp => join(.macos, output, &.{ env.tmpdir orelse "/tmp", app_name }),
    };
}

/// iOS: every process runs inside its app's sandbox container and `HOME`
/// is the container root, so the container itself is the per-app
/// namespace — no `<app>` child directory (the macOS shape would just
/// nest a redundant level the OS tooling never looks in). `.cache`
/// resolves to the container's `Library/Caches`, which the system
/// already treats as purgeable — exactly where the audio track cache
/// belongs. `.temp` prefers `TMPDIR` (set to the container's `tmp/` in
/// every iOS process) and falls back to that directory by convention.
fn resolveIos(env: Env, kind: DirKind, output: []u8) Error![]const u8 {
    const home = env.home orelse return error.MissingHome;

    return switch (kind) {
        .config => join(.ios, output, &.{ home, "Library", "Preferences" }),
        .cache => join(.ios, output, &.{ home, "Library", "Caches" }),
        .data => join(.ios, output, &.{ home, "Library", "Application Support" }),
        .state => join(.ios, output, &.{ home, "Library", "Application Support", "State" }),
        .logs => join(.ios, output, &.{ home, "Library", "Caches", "Logs" }),
        .temp => if (env.tmpdir) |tmpdir| join(.ios, output, &.{tmpdir}) else join(.ios, output, &.{ home, "tmp" }),
    };
}

/// Android: like iOS, every process runs inside its app's private data
/// directory, so that directory is the per-app namespace — no `<app>`
/// child. The toolkit's Android host exports `HOME` as the app data
/// directory and `TMPDIR` as its `cache/` child before the app starts
/// (the OS gives app processes no per-app environment of its own), so
/// env-based resolution stays honest. The mapping follows the two
/// directories the OS itself manages inside the data dir: `files/` for
/// durable bytes and `cache/` for reclaimable ones (`.cache` is exactly
/// the platform cache directory the system may clear under pressure —
/// where the audio track cache belongs). Android has no per-app tmp
/// directory; the cache directory is the platform's documented home for
/// temporary files, so `.temp` prefers `TMPDIR` and falls back to it.
fn resolveAndroid(env: Env, kind: DirKind, output: []u8) Error![]const u8 {
    const home = env.home orelse return error.MissingHome;

    return switch (kind) {
        .config => join(.android, output, &.{ home, "files", "config" }),
        .cache => join(.android, output, &.{ home, "cache" }),
        .data => join(.android, output, &.{ home, "files" }),
        .state => join(.android, output, &.{ home, "files", "state" }),
        .logs => join(.android, output, &.{ home, "cache", "logs" }),
        .temp => if (env.tmpdir) |tmpdir| join(.android, output, &.{tmpdir}) else join(.android, output, &.{ home, "cache" }),
    };
}

fn resolveWindows(app_name: []const u8, env: Env, kind: DirKind, output: []u8) Error![]const u8 {
    return switch (kind) {
        .config => join(.windows, output, &.{ env.app_data orelse return error.MissingRequiredEnv, app_name }),
        .cache => join(.windows, output, &.{ env.local_app_data orelse return error.MissingRequiredEnv, app_name, "Cache" }),
        .data => join(.windows, output, &.{ env.local_app_data orelse return error.MissingRequiredEnv, app_name, "Data" }),
        .state => join(.windows, output, &.{ env.local_app_data orelse return error.MissingRequiredEnv, app_name, "State" }),
        .logs => join(.windows, output, &.{ env.local_app_data orelse return error.MissingRequiredEnv, app_name, "Logs" }),
        .temp => join(.windows, output, &.{ env.temp orelse env.tmp orelse return error.MissingRequiredEnv, app_name }),
    };
}

fn expectEqualString(expected: []const u8, actual: []const u8) !void {
    try std.testing.expectEqualStrings(expected, actual);
}

fn testBuffers() Buffers {
    const State = struct {
        threadlocal var buffers: [6][256]u8 = undefined;
    };
    return Buffers.fromArray(256, &State.buffers);
}

test "app name validation accepts ordinary names and rejects path-like names" {
    try validateAppName("my-app");
    try validateAppName("My App");
    try validateAppName("com.example.tool");

    try std.testing.expectError(error.InvalidAppName, validateAppName(""));
    try std.testing.expectError(error.InvalidAppName, validateAppName("."));
    try std.testing.expectError(error.InvalidAppName, validateAppName(".."));
    try std.testing.expectError(error.InvalidAppName, validateAppName("my/app"));
    try std.testing.expectError(error.InvalidAppName, validateAppName("my\\app"));
    try std.testing.expectError(error.InvalidAppName, validateAppName("my\x00app"));
    try std.testing.expectError(error.InvalidAppName, (AppInfo{ .name = "app", .organization = "bad/org" }).validate());
}

test "linux xdg paths use explicit environment values" {
    const app: AppInfo = .{ .name = "demo" };
    const env: Env = .{
        .home = "/home/alice",
        .xdg_config_home = "/xdg/config",
        .xdg_cache_home = "/xdg/cache",
        .xdg_data_home = "/xdg/data",
        .xdg_state_home = "/xdg/state",
        .tmpdir = "/run/tmp",
    };
    const dirs = try resolve(app, .linux, env, testBuffers());

    try expectEqualString("/xdg/config/demo", dirs.config);
    try expectEqualString("/xdg/cache/demo", dirs.cache);
    try expectEqualString("/xdg/data/demo", dirs.data);
    try expectEqualString("/xdg/state/demo", dirs.state);
    try expectEqualString("/xdg/state/demo/logs", dirs.logs);
    try expectEqualString("/run/tmp/demo", dirs.temp);
}

test "linux falls back to home defaults" {
    const app: AppInfo = .{ .name = "demo" };
    const env: Env = .{ .home = "/home/alice" };
    const dirs = try resolve(app, .linux, env, testBuffers());

    try expectEqualString("/home/alice/.config/demo", dirs.config);
    try expectEqualString("/home/alice/.cache/demo", dirs.cache);
    try expectEqualString("/home/alice/.local/share/demo", dirs.data);
    try expectEqualString("/home/alice/.local/state/demo", dirs.state);
    try expectEqualString("/home/alice/.local/state/demo/logs", dirs.logs);
    try expectEqualString("/tmp/demo", dirs.temp);
}

test "macos library paths resolve from home" {
    const app: AppInfo = .{ .name = "Demo" };
    const env: Env = .{ .home = "/Users/alice", .tmpdir = "/var/folders/tmp" };
    const dirs = try resolve(app, .macos, env, testBuffers());

    try expectEqualString("/Users/alice/Library/Preferences/Demo", dirs.config);
    try expectEqualString("/Users/alice/Library/Caches/Demo", dirs.cache);
    try expectEqualString("/Users/alice/Library/Application Support/Demo", dirs.data);
    try expectEqualString("/Users/alice/Library/Application Support/Demo/State", dirs.state);
    try expectEqualString("/Users/alice/Library/Logs/Demo", dirs.logs);
    try expectEqualString("/var/folders/tmp/Demo", dirs.temp);
}

test "windows paths resolve from appdata environment" {
    const app: AppInfo = .{ .name = "Demo" };
    const env: Env = .{
        .app_data = "C:\\Users\\alice\\AppData\\Roaming",
        .local_app_data = "C:\\Users\\alice\\AppData\\Local",
        .temp = "C:\\Users\\alice\\AppData\\Local\\Temp",
    };
    const dirs = try resolve(app, .windows, env, testBuffers());

    try expectEqualString("C:\\Users\\alice\\AppData\\Roaming\\Demo", dirs.config);
    try expectEqualString("C:\\Users\\alice\\AppData\\Local\\Demo\\Cache", dirs.cache);
    try expectEqualString("C:\\Users\\alice\\AppData\\Local\\Demo\\Data", dirs.data);
    try expectEqualString("C:\\Users\\alice\\AppData\\Local\\Demo\\State", dirs.state);
    try expectEqualString("C:\\Users\\alice\\AppData\\Local\\Demo\\Logs", dirs.logs);
    try expectEqualString("C:\\Users\\alice\\AppData\\Local\\Temp\\Demo", dirs.temp);
}

test "temp fallback behavior is platform specific" {
    const app: AppInfo = .{ .name = "demo" };

    try expectEqualString("/tmp/demo", try resolveOne(app, .linux, .{ .home = "/home/a" }, .temp, testBuffers().temp));
    try expectEqualString("/custom/demo", try resolveOne(app, .linux, .{ .home = "/home/a", .tmpdir = "/custom" }, .temp, testBuffers().temp));
    try expectEqualString("/tmp/demo", try resolveOne(app, .macos, .{ .home = "/Users/a" }, .temp, testBuffers().temp));
    try expectEqualString("C:\\Tmp\\demo", try resolveOne(app, .windows, .{ .app_data = "C:\\Roaming", .local_app_data = "C:\\Local", .tmp = "C:\\Tmp" }, .temp, testBuffers().temp));
}

test "missing required env produces explicit errors" {
    const app: AppInfo = .{ .name = "demo" };

    try std.testing.expectError(error.MissingHome, resolveOne(app, .linux, .{}, .config, testBuffers().config));
    try std.testing.expectError(error.MissingHome, resolveOne(app, .macos, .{}, .data, testBuffers().data));
    try std.testing.expectError(error.MissingRequiredEnv, resolveOne(app, .windows, .{ .local_app_data = "C:\\Local" }, .config, testBuffers().config));
    try std.testing.expectError(error.MissingRequiredEnv, resolveOne(app, .windows, .{ .app_data = "C:\\Roaming" }, .cache, testBuffers().cache));
}

test "ios resolves inside the app sandbox container" {
    const app: AppInfo = .{ .name = "demo" };
    const home = "/var/mobile/Containers/Data/Application/ABC";
    const env: Env = .{ .home = home, .tmpdir = home ++ "/tmp" };
    const dirs = try resolve(app, .ios, env, testBuffers());

    try expectEqualString(home ++ "/Library/Preferences", dirs.config);
    try expectEqualString(home ++ "/Library/Caches", dirs.cache);
    try expectEqualString(home ++ "/Library/Application Support", dirs.data);
    try expectEqualString(home ++ "/Library/Application Support/State", dirs.state);
    try expectEqualString(home ++ "/Library/Caches/Logs", dirs.logs);
    try expectEqualString(home ++ "/tmp", dirs.temp);
    try expectEqualString(home ++ "/tmp", try resolveOne(app, .ios, .{ .home = home }, .temp, testBuffers().temp));
    try std.testing.expectError(error.MissingHome, resolveOne(app, .ios, .{}, .cache, testBuffers().cache));
}

test "android resolves inside the app data directory" {
    const app: AppInfo = .{ .name = "demo" };
    const home = "/data/user/0/dev.native_sdk.demo";
    const env: Env = .{ .home = home, .tmpdir = home ++ "/cache" };
    const dirs = try resolve(app, .android, env, testBuffers());

    try expectEqualString(home ++ "/files/config", dirs.config);
    try expectEqualString(home ++ "/cache", dirs.cache);
    try expectEqualString(home ++ "/files", dirs.data);
    try expectEqualString(home ++ "/files/state", dirs.state);
    try expectEqualString(home ++ "/cache/logs", dirs.logs);
    try expectEqualString(home ++ "/cache", dirs.temp);
    try expectEqualString(home ++ "/cache", try resolveOne(app, .android, .{ .home = home }, .temp, testBuffers().temp));
    try std.testing.expectError(error.MissingHome, resolveOne(app, .android, .{}, .cache, testBuffers().cache));
}

test "unknown is unsupported in v1" {
    const app: AppInfo = .{ .name = "demo" };

    try std.testing.expectError(error.UnsupportedPlatform, resolveOne(app, .unknown, .{}, .config, testBuffers().config));
}

test "buffer exhaustion returns no space left" {
    const app: AppInfo = .{ .name = "demo" };
    var small: [4]u8 = undefined;

    try std.testing.expectError(error.NoSpaceLeft, resolveOne(app, .linux, .{ .home = "/home/alice" }, .config, &small));
}

test "resolve one matches corresponding resolved field" {
    const app: AppInfo = .{ .name = "demo" };
    const env: Env = .{ .home = "/home/alice" };
    const dirs = try resolve(app, .linux, env, testBuffers());
    var buffer: [256]u8 = undefined;

    try expectEqualString(dirs.cache, try resolveOne(app, .linux, env, .cache, &buffer));
}

test "join and platform helpers" {
    var buffer: [64]u8 = undefined;

    try expectEqualString("a/b/c", try join(.linux, &buffer, &.{ "a", "b", "c" }));
    try expectEqualString("a\\b\\c", try join(.windows, &buffer, &.{ "a", "b", "c" }));
    try std.testing.expectEqual(@as(u8, '\\'), platformSeparator(.windows));
    try std.testing.expectEqual(@as(u8, '/'), platformSeparator(.macos));
    _ = currentPlatform();
}

test {
    std.testing.refAllDecls(@This());
}
