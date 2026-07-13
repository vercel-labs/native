//! TypeScript-core plumbing for the `native` CLI: tree detection (which
//! core does this app carry?), the transpiler-checker pass `native check`
//! runs over src/core.ts, and the node dev-harness `native dev --core`
//! launches. The build graph re-derives the same detection in
//! build/app.zig; the CLI checks first so a both-cores tree fails with one
//! clean teaching message instead of a build panic.
//!
//! Multi-file cores: src/core.ts stays the detection root AND the entry
//! module, but a core may split into modules under src/ (relative imports
//! with real .ts filenames) plus SDK library modules
//! ("@native-sdk/core/text"). The transpiler walks that import graph
//! itself, so `native check` reports diagnostics with each module's own
//! path, and `native dev --core` runs the same graph under node (relative
//! imports are real files; the resolver hook maps only the SDK names).

const std = @import("std");
const buildgraph = @import("buildgraph.zig");
const process_tree = @import("process_tree.zig");

pub const Error = error{
    BothCores,
    MissingTsCore,
    MissingNode,
    MissingTranspiler,
    CoreCheckFailed,
    DevHostFailed,
};

/// Which core the app tree carries: `src/core.ts` is a TypeScript core,
/// `src/main.zig` a Zig one. Both at once is a teaching error (the tree is
/// the truth; there is no language flag or config to consult). Other Zig
/// files under src/ never affect detection — and neither does anything
/// else in the tree: a package.json (the TS scaffold's editor surface, or
/// a stray one in a Zig app) is not a language marker.
pub const CoreTree = enum { zig, ts, both, neither };

pub fn detect(io: std.Io) CoreTree {
    return detectAt(io, ".");
}

/// `detect` against an explicit app root instead of the process cwd.
pub fn detectAt(io: std.Io, app_root: []const u8) CoreTree {
    var ts_buffer: [1024]u8 = undefined;
    var zig_buffer: [1024]u8 = undefined;
    const ts_path = std.fmt.bufPrint(&ts_buffer, "{s}/src/core.ts", .{app_root}) catch return .neither;
    const zig_path = std.fmt.bufPrint(&zig_buffer, "{s}/src/main.zig", .{app_root}) catch return .neither;
    const has_ts = buildgraph.fileExists(io, ts_path);
    const has_zig = buildgraph.fileExists(io, zig_path);
    if (has_ts and has_zig) return .both;
    if (has_ts) return .ts;
    if (has_zig) return .zig;
    return .neither;
}

/// The one both-cores teaching message, shared by every verb that detects.
pub fn failBothCores() Error {
    std.debug.print(
        \\this app declares two cores: src/core.ts (TypeScript) and src/main.zig (Zig).
        \\An app has exactly one core - the tree is the truth. Keep src/core.ts and delete
        \\src/main.zig, or keep src/main.zig and delete src/core.ts. (Other Zig files
        \\under src/ are fine either way.)
        \\
    , .{});
    return error.BothCores;
}

fn nodeMissing() Error {
    std.debug.print(
        \\TypeScript app cores need node on PATH (the @native-sdk/core transpiler and the
        \\core dev-harness run under it; the binary you ship carries no JS runtime).
        \\Install Node.js 22+ - https://nodejs.org or `brew install node` - and re-run.
        \\
    , .{});
    return error.MissingNode;
}

fn transpilerPath(allocator: std.mem.Allocator, io: std.Io, framework_root: []const u8, comptime sub: []const u8) ![]const u8 {
    const path = try std.fs.path.join(allocator, &.{ framework_root, "packages", "core", sub });
    errdefer allocator.free(path);
    if (!buildgraph.fileExists(io, path)) {
        std.debug.print("the Native SDK at {s} is missing packages/core/{s} - is the checkout complete?\n", .{ framework_root, sub });
        return error.MissingTranspiler;
    }
    return path;
}

fn requireInstalledTranspiler(allocator: std.mem.Allocator, io: std.Io, framework_root: []const u8) !void {
    const marker = try std.fs.path.join(allocator, &.{ framework_root, "packages", "core", "node_modules", "@typescript", "typescript6" });
    defer allocator.free(marker);
    const stat = std.Io.Dir.cwd().statFile(io, marker, .{}) catch {
        std.debug.print(
            \\the SDK's @native-sdk/core transpiler is missing its installed dependency.
            \\Fix with: cd {s}/packages/core && npm ci
            \\
        , .{framework_root});
        return error.MissingTranspiler;
    };
    _ = stat;
}

/// `native check` over a TypeScript core: run the transpiler (checker +
/// emitter) on src/core.ts — and, through it, the core's whole import
/// graph under src/ — and surface its NS diagnostics verbatim — they
/// are the teaching layer, nothing wraps them (each diagnostic carries
/// the owning module's path). The emitted Zig lands in .native/check/ (a
/// scratch product, gitignored with the rest of .native/). Exit 0 =
/// typechecked, subset-clean, emitted.
pub fn checkCore(allocator: std.mem.Allocator, io: std.Io, base_env: *std.process.Environ.Map, framework_root: []const u8) !void {
    const cli_path = try transpilerPath(allocator, io, framework_root, "src/cli.ts");
    defer allocator.free(cli_path);
    try requireInstalledTranspiler(allocator, io, framework_root);
    try std.Io.Dir.cwd().createDirPath(io, ".native/check");

    var child = std.process.spawn(io, .{
        .argv = &.{ "node", cli_path, "src/core.ts", "-o", ".native/check/core.zig" },
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
        .environ_map = base_env,
    }) catch return nodeMissing();
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code == 0) return,
        else => {},
    }
    // The transpiler's own diagnostics are already on screen; name the
    // failing pass without burying them.
    std.debug.print("native check: src/core.ts failed the @native-sdk/core checker (diagnostics above)\n", .{});
    return error.CoreCheckFailed;
}

pub const DevHostOptions = struct {
    base_env: *std.process.Environ.Map,
    /// NDJSON message script; null = interactive stdin.
    script: ?[]const u8 = null,
    /// Re-run the harness whenever any module of the core changes.
    /// Requires a script (a re-run replays it against the edited core).
    watch: bool = false,
};

/// `native dev --core`: the node dev-harness over src/core.ts — the
/// core-logic loop (dispatch messages, watch the model and effect
/// transcript), not a renderer. Watch mode rides `node --watch`.
pub fn runDevHost(allocator: std.mem.Allocator, io: std.Io, framework_root: []const u8, options: DevHostOptions) !void {
    if (!buildgraph.fileExists(io, "src/core.ts")) {
        std.debug.print("no src/core.ts here - `native dev --core` runs the TypeScript core-logic loop\n", .{});
        return error.MissingTsCore;
    }
    const devhost_path = try transpilerPath(allocator, io, framework_root, "src/devhost.ts");
    defer allocator.free(devhost_path);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, "node");
    if (options.watch) {
        if (options.script == null) {
            std.debug.print("`native dev --core --watch` needs --script <msgs.ndjson>: each re-run replays the script against the edited core\n", .{});
            return error.DevHostFailed;
        }
        try argv.append(allocator, "--watch");
    }
    try argv.append(allocator, devhost_path);
    try argv.append(allocator, "src/core.ts");
    if (options.script) |script| {
        try argv.appendSlice(allocator, &.{ "--script", script });
    }

    std.debug.print("native dev --core: the core-logic loop under node (update/effects, virtual clock) - not a renderer; `native dev` runs the app\n", .{});
    var child = std.process.spawn(io, .{
        .argv = argv.items,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
        .environ_map = options.base_env,
        .pgid = if (process_tree.supported) process_tree.spawnPgid() else null,
    }) catch return nodeMissing();
    const group_pid: i32 = if (process_tree.supported) process_tree.groupId(&child) else 0;
    if (group_pid > 0) process_tree.own(group_pid);
    defer if (group_pid > 0) process_tree.releaseAndKill(group_pid);
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code == 0) return,
        else => {},
    }
    std.debug.print("native dev --core: the harness exited abnormally\n", .{});
    return error.DevHostFailed;
}

// ------------------------------------------------------- editor package
//
// Stock editor TypeScript (VS Code et al.) resolves `@native-sdk/core`
// the only way editors know: node_modules. Until the package is published
// to npm, the CLI materializes `node_modules/@native-sdk/core` inside the
// app itself — a plain COPY (never a symlink; cache paths get GC'd) of
// exactly the files the published artifact will contain (package.json plus
// the `files: ["sdk"]` allowlist: sdk/core.ts, sdk/text.ts, sdk/events.ts,
// and the ambient bytes-text method surface core.ts references).
// The copy is
// EDITOR-AND-VERSIONING SURFACE ONLY: builds transpile against the SDK
// checkout's own sources and never read node_modules — delete it and
// `native build|dev|check|test` still work; the next check/dev/build puts
// it back. Once the real package is published, a user-run `npm install`
// overwrites the copy with identical content; the refresh below compares
// the one `version` field, sees it current, and never touches it again.

/// Where the editor copy lives inside an app.
pub const editor_package_dir = "node_modules/@native-sdk/core";

/// The published artifact's files, relative to packages/core (and to the
/// materialized copy): package.json plus its `files: ["sdk"]` allowlist.
/// packages/core/test/package_manifest.test.ts pins the manifest to this
/// shape, so copy and tarball cannot drift apart.
const editor_package_files = [_][]const u8{ "package.json", "sdk/core.ts", "sdk/text.ts", "sdk/events.ts", "sdk/bytes_text_methods.d.ts" };

/// Extract the top-level "version" of a package.json. A targeted scan, not
/// a JSON parse: both inputs are our own manifest and npm's byte-identical
/// install of it, where the first "version" key is the package version.
pub fn parsePackageVersion(manifest_json: []const u8) ?[]const u8 {
    const key = "\"version\"";
    const key_at = std.mem.indexOf(u8, manifest_json, key) orelse return null;
    var rest = manifest_json[key_at + key.len ..];
    rest = std.mem.trimStart(u8, rest, " \t\r\n");
    if (rest.len == 0 or rest[0] != ':') return null;
    rest = std.mem.trimStart(u8, rest[1..], " \t\r\n");
    if (rest.len == 0 or rest[0] != '"') return null;
    rest = rest[1..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    if (end == 0) return null;
    return rest[0..end];
}

/// The version of the SDK's bundled @native-sdk/core package
/// (packages/core/package.json). Caller frees.
pub fn bundledSdkVersion(allocator: std.mem.Allocator, io: std.Io, framework_root: []const u8) ![]const u8 {
    const path = try std.fs.path.join(allocator, &.{ framework_root, "packages", "core", "package.json" });
    defer allocator.free(path);
    const manifest = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024)) catch
        return error.MissingTranspiler;
    defer allocator.free(manifest);
    const version = parsePackageVersion(manifest) orelse return error.MissingTranspiler;
    return allocator.dupe(u8, version);
}

/// How an app's editor copy compares to the SDK's bundled package.
pub const EditorPackageStatus = struct {
    /// The SDK-bundled @native-sdk/core version (owned).
    bundled: []const u8,
    /// The app copy's version, or null when the copy is missing or
    /// incomplete (owned when present).
    installed: ?[]const u8,

    pub fn fresh(self: EditorPackageStatus) bool {
        const installed = self.installed orelse return false;
        return std.mem.eql(u8, installed, self.bundled);
    }

    pub fn deinit(self: EditorPackageStatus, allocator: std.mem.Allocator) void {
        allocator.free(self.bundled);
        if (self.installed) |installed| allocator.free(installed);
    }
};

/// Compare `<app_root>/node_modules/@native-sdk/core` against the SDK's
/// bundled package. Cheap by design (the refresh trigger runs on every
/// check/dev/build): two one-field manifest reads plus two stats.
pub fn editorPackageStatus(allocator: std.mem.Allocator, io: std.Io, framework_root: []const u8, app_root: []const u8) !EditorPackageStatus {
    const bundled = try bundledSdkVersion(allocator, io, framework_root);
    errdefer allocator.free(bundled);

    const installed: ?[]const u8 = read: {
        const manifest_path = try std.fs.path.join(allocator, &.{ app_root, editor_package_dir, "package.json" });
        defer allocator.free(manifest_path);
        const manifest = std.Io.Dir.cwd().readFileAlloc(io, manifest_path, allocator, .limited(64 * 1024)) catch break :read null;
        defer allocator.free(manifest);
        const version = parsePackageVersion(manifest) orelse break :read null;
        // A manifest without its sdk/ sources is an incomplete copy (a
        // half-deleted tree), not a fresh install at that version.
        for (editor_package_files[1..]) |sub_path| {
            const file_path = try std.fs.path.join(allocator, &.{ app_root, editor_package_dir, sub_path });
            defer allocator.free(file_path);
            if (!buildgraph.fileExists(io, file_path)) break :read null;
        }
        break :read try allocator.dupe(u8, version);
    };
    return .{ .bundled = bundled, .installed = installed };
}

pub const EnsureOutcome = enum { fresh, materialized };

/// Make `<app_root>/node_modules/@native-sdk/core` a current copy of the
/// SDK's bundled package: leave a version-matching copy alone (that is the
/// post-publish `npm install` handoff — npm's content is identical, so the
/// CLI recognizes the version and stops rewriting), (re)materialize
/// otherwise.
pub fn ensureEditorPackage(allocator: std.mem.Allocator, io: std.Io, framework_root: []const u8, app_root: []const u8) !EnsureOutcome {
    const status = try editorPackageStatus(allocator, io, framework_root, app_root);
    defer status.deinit(allocator);
    if (status.fresh()) return .fresh;

    for (editor_package_files) |sub_path| {
        const source_path = try std.fs.path.join(allocator, &.{ framework_root, "packages", "core", sub_path });
        defer allocator.free(source_path);
        const data = std.Io.Dir.cwd().readFileAlloc(io, source_path, allocator, .limited(4 * 1024 * 1024)) catch
            return error.MissingTranspiler;
        defer allocator.free(data);
        const dest_path = try std.fs.path.join(allocator, &.{ app_root, editor_package_dir, sub_path });
        defer allocator.free(dest_path);
        if (std.fs.path.dirname(dest_path)) |parent| {
            try std.Io.Dir.cwd().createDirPath(io, parent);
        }
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dest_path, .data = data });
    }
    return .materialized;
}

/// The self-heal hook `native check|dev|build|test` run over a TS app (cwd
/// = the app root): refresh the editor copy when missing or stale, say so
/// in one line, and never fail the verb — the copy is editor surface, and
/// build truth must not depend on it in either direction.
pub fn selfHealEditorPackage(allocator: std.mem.Allocator, io: std.Io, framework_root: []const u8) void {
    const outcome = ensureEditorPackage(allocator, io, framework_root, ".") catch return;
    if (outcome == .materialized) {
        std.debug.print("refreshed node_modules/@native-sdk/core (editor types for stock tsc; builds never read it)\n", .{});
    }
}

test "core tree detection reads the tree, not config" {
    const io = std.testing.io;
    var cwd = std.Io.Dir.cwd();
    const root = ".zig-cache/test-ts-core-detect";
    cwd.deleteTree(io, root) catch {};
    try cwd.createDirPath(io, root ++ "/src");

    // Empty tree: neither.
    {
        var dir = try cwd.openDir(io, root, .{});
        defer dir.close(io);
        // detect() reads the process cwd; probe the predicate parts instead.
    }
    try std.testing.expect(!buildgraph.fileExists(io, root ++ "/src/core.ts"));
    try cwd.writeFile(io, .{ .sub_path = root ++ "/src/core.ts", .data = "// ts" });
    try std.testing.expect(buildgraph.fileExists(io, root ++ "/src/core.ts"));
    try cwd.writeFile(io, .{ .sub_path = root ++ "/src/main.zig", .data = "// zig" });
    try std.testing.expect(buildgraph.fileExists(io, root ++ "/src/main.zig"));
    cwd.deleteTree(io, root) catch {};
}

test "a stray package.json is not a language marker: detection keys on the core files only" {
    const io = std.testing.io;
    var cwd = std.Io.Dir.cwd();
    const root = ".zig-cache/test-ts-core-detect-residue";
    cwd.deleteTree(io, root) catch {};
    try cwd.createDirPath(io, root ++ "/src");
    defer cwd.deleteTree(io, root) catch {};

    // A Zig app that grew a package.json (frontend tooling, a stray npm
    // init) is still a Zig app.
    try cwd.writeFile(io, .{ .sub_path = root ++ "/src/main.zig", .data = "// zig" });
    try cwd.writeFile(io, .{ .sub_path = root ++ "/package.json", .data = "{ \"name\": \"stray\" }" });
    try std.testing.expectEqual(CoreTree.zig, detectAt(io, root));

    // And a TS app whose editor surface (package.json, node_modules) was
    // deleted is still a TS app.
    try cwd.deleteFile(io, root ++ "/src/main.zig");
    try cwd.deleteFile(io, root ++ "/package.json");
    try cwd.writeFile(io, .{ .sub_path = root ++ "/src/core.ts", .data = "// ts" });
    try std.testing.expectEqual(CoreTree.ts, detectAt(io, root));
}

test "package.json version extraction" {
    try std.testing.expectEqualStrings("0.0.1", parsePackageVersion(
        \\{
        \\  "name": "@native-sdk/core",
        \\  "private": true,
        \\  "version": "0.0.1"
        \\}
    ).?);
    try std.testing.expectEqualStrings("1.2.3", parsePackageVersion("{\"version\":\"1.2.3\"}").?);
    try std.testing.expect(parsePackageVersion("{}") == null);
    try std.testing.expect(parsePackageVersion("{\"version\": 3}") == null);
    try std.testing.expect(parsePackageVersion("{\"version\": \"\"}") == null);
}

// The materialize -> self-heal -> npm-install handoff lifecycle, against a
// fake SDK checkout so the pinned versions are the test's own.
test "editor package: materialize, heal, and the npm-install handoff" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var cwd = std.Io.Dir.cwd();
    const root = ".zig-cache/test-ts-editor-package";
    const sdk = root ++ "/sdk-checkout";
    const app = root ++ "/app";
    cwd.deleteTree(io, root) catch {};
    defer cwd.deleteTree(io, root) catch {};

    try cwd.createDirPath(io, sdk ++ "/packages/core/sdk");
    try cwd.createDirPath(io, app ++ "/src");
    try cwd.writeFile(io, .{ .sub_path = sdk ++ "/packages/core/package.json", .data = "{ \"name\": \"@native-sdk/core\", \"version\": \"0.0.9\" }" });
    try cwd.writeFile(io, .{ .sub_path = sdk ++ "/packages/core/sdk/core.ts", .data = "// core module" });
    try cwd.writeFile(io, .{ .sub_path = sdk ++ "/packages/core/sdk/text.ts", .data = "// text module" });
    try cwd.writeFile(io, .{ .sub_path = sdk ++ "/packages/core/sdk/events.ts", .data = "// events module" });
    try cwd.writeFile(io, .{ .sub_path = sdk ++ "/packages/core/sdk/bytes_text_methods.d.ts", .data = "// ambient text methods" });

    const bundled = try bundledSdkVersion(allocator, io, sdk);
    defer allocator.free(bundled);
    try std.testing.expectEqualStrings("0.0.9", bundled);

    // Missing copy: materialized, and the full artifact lands.
    try std.testing.expectEqual(EnsureOutcome.materialized, try ensureEditorPackage(allocator, io, sdk, app));
    try std.testing.expect(buildgraph.fileExists(io, app ++ "/node_modules/@native-sdk/core/package.json"));
    try std.testing.expect(buildgraph.fileExists(io, app ++ "/node_modules/@native-sdk/core/sdk/core.ts"));
    try std.testing.expect(buildgraph.fileExists(io, app ++ "/node_modules/@native-sdk/core/sdk/text.ts"));
    try std.testing.expect(buildgraph.fileExists(io, app ++ "/node_modules/@native-sdk/core/sdk/events.ts"));
    try std.testing.expect(buildgraph.fileExists(io, app ++ "/node_modules/@native-sdk/core/sdk/bytes_text_methods.d.ts"));

    // Current copy: untouched (this is also the post-publish handoff — a
    // real `npm install` writes identical content at the same version, so
    // user-owned node_modules stop being rewritten). Prove "untouched"
    // through a sentinel edit the refresh must NOT undo.
    try cwd.writeFile(io, .{ .sub_path = app ++ "/node_modules/@native-sdk/core/sdk/core.ts", .data = "// same version, npm-owned bytes" });
    try std.testing.expectEqual(EnsureOutcome.fresh, try ensureEditorPackage(allocator, io, sdk, app));
    const untouched = try cwd.readFileAlloc(io, app ++ "/node_modules/@native-sdk/core/sdk/core.ts", allocator, .limited(1024));
    defer allocator.free(untouched);
    try std.testing.expectEqualStrings("// same version, npm-owned bytes", untouched);

    // Version skew (SDK moved on): refreshed to the bundled content.
    try cwd.writeFile(io, .{ .sub_path = sdk ++ "/packages/core/package.json", .data = "{ \"name\": \"@native-sdk/core\", \"version\": \"0.1.0\" }" });
    try std.testing.expectEqual(EnsureOutcome.materialized, try ensureEditorPackage(allocator, io, sdk, app));
    const refreshed = try cwd.readFileAlloc(io, app ++ "/node_modules/@native-sdk/core/sdk/core.ts", allocator, .limited(1024));
    defer allocator.free(refreshed);
    try std.testing.expectEqualStrings("// core module", refreshed);
    {
        const status = try editorPackageStatus(allocator, io, sdk, app);
        defer status.deinit(allocator);
        try std.testing.expect(status.fresh());
    }

    // A half-deleted copy (manifest present, sdk/ gone) heals too.
    try cwd.deleteFile(io, app ++ "/node_modules/@native-sdk/core/sdk/text.ts");
    try std.testing.expectEqual(EnsureOutcome.materialized, try ensureEditorPackage(allocator, io, sdk, app));
    try std.testing.expect(buildgraph.fileExists(io, app ++ "/node_modules/@native-sdk/core/sdk/text.ts"));
}

// The copy the CLI materializes IS the future published artifact: the
// bundled manifest must carry the exports/files shape editors resolve
// through (pinned in full by packages/core/test/package_manifest.test.ts;
// this cross-check keeps the Zig side honest about the file list it
// copies). Runs against the real repo checkout.
test "the bundled @native-sdk/core manifest matches the materialized file list" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const manifest = std.Io.Dir.cwd().readFileAlloc(io, "packages/core/package.json", allocator, .limited(64 * 1024)) catch return error.SkipZigTest;
    defer allocator.free(manifest);
    try std.testing.expect(parsePackageVersion(manifest) != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"files\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"./sdk/core.ts\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"./text\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"./sdk/text.ts\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"./events\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"./sdk/events.ts\"") != null);
    for (editor_package_files[1..]) |sub_path| {
        var path_buffer: [128]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, "packages/core/{s}", .{sub_path});
        try std.testing.expect(buildgraph.fileExists(io, path));
    }
}
