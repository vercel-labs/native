//! The canonical app verbs: `native dev|build|test` work in any app
//! directory. If the app owns a build.zig (ejected, and every example),
//! the verbs drive it through plain `zig build` — zero behavior change.
//! Otherwise (app.zon + src/ only) the CLI synthesizes the build graph
//! into `<app>/.native/build/` (see buildgraph.zig) and drives that.
//!
//! Callers are expected to have chdir'd into the app directory: every
//! relative path an app uses at runtime (assets/, the src/app.native hot
//! reload watcher, .zig-cache/native-sdk-automation) resolves against the
//! process cwd, so the verbs run zig — and the app — from the app root.

const std = @import("std");
const buildgraph = @import("buildgraph.zig");
const ts_core = @import("ts_core.zig");
const toolchain = @import("toolchain.zig");
const manifest_tool = @import("manifest.zig");
const dev_tool = @import("dev.zig");
const process_tree = @import("process_tree.zig");

pub const Error = error{
    MissingManifest,
    MissingFramework,
};

pub const Verb = enum {
    dev,
    build,
    @"test",
};

pub const Options = struct {
    base_env: *std.process.Environ.Map,
    /// --yes: consent to toolchain download without a prompt.
    assume_yes: bool = false,
    /// -D.../--release flags forwarded verbatim to `zig build`.
    forwarded_args: []const []const u8 = &.{},
    /// dev-only: frontend dev server overrides (same as `native dev` flags).
    url_override: ?[]const u8 = null,
    command_override: ?[]const []const u8 = null,
    timeout_ms: ?u32 = null,
    /// Explain authored-input changes and the content-gated downstream graph.
    explain_rebuild: bool = false,
};

pub fn run(allocator: std.mem.Allocator, io: std.Io, verb: Verb, options: Options) !void {
    if (!buildgraph.fileExists(io, "app.zon")) {
        std.debug.print(
            \\no app.zon here — `native {s}` runs inside an app directory
            \\(or pass one: `native {s} path/to/app`). Start one with `native init`.
            \\
        , .{ @tagName(verb), @tagName(verb) });
        return error.MissingManifest;
    }
    const metadata = try manifest_tool.readMetadata(allocator, io, "app.zon");
    const rebuild_snapshot = if (options.explain_rebuild)
        try explainRebuild(allocator, io)
    else
        null;
    defer if (rebuild_snapshot) |snapshot| allocator.free(snapshot);

    // Tree detection happens here too (the build graph re-derives it), so
    // a both-cores tree fails with one clean teaching message before any
    // zig invocation.
    const core_tree = ts_core.detect(io);
    if (core_tree == .both) return ts_core.failBothCores();
    if (core_tree == .ts) {
        const sqlite_enabled = for (metadata.capabilities) |capability| {
            if (std.mem.eql(u8, capability, "sqlite")) break true;
        } else false;
        // Keep the app's editor surface fresh (node_modules/@native-sdk/core,
        // the pre-publish copy stock tsc resolves): best-effort by design —
        // build truth never depends on it, so an unresolvable framework here
        // is not this verb's failure (the graph below reports its own).
        if (buildgraph.resolveFrameworkRoot(allocator, io, options.base_env) catch null) |framework_root| {
            defer allocator.free(framework_root);
            ts_core.selfHealEditorPackage(allocator, io, framework_root);
            // The build graph runs the frontend inside `zig build`; gate
            // its toolchain resolution before any zig spawns — but ONLY
            // for graphs the CLI itself generates (see the preflight's own
            // doc for why ejected apps must flow past it).
            try tsToolchainPreflight(allocator, io, ".", framework_root);
            if (sqlite_enabled) {
                const sqlite_declarations = try ts_core.generateSqliteSurface(allocator, io, options.base_env, framework_root, true);
                allocator.free(sqlite_declarations);
            }
        }
    }

    const zig_exe = try toolchain.resolveZig(allocator, io, options.base_env, .{ .assume_yes = options.assume_yes });
    defer allocator.free(zig_exe);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{ zig_exe, "build" });

    const ejected = isEjectedAt(io, ".");
    var build_file: ?[]const u8 = null;
    defer if (build_file) |path| allocator.free(path);
    var prefix: ?[]const u8 = null;
    defer if (prefix) |path| allocator.free(path);
    if (!ejected) {
        const framework_root = try buildgraph.resolveFrameworkRoot(allocator, io, options.base_env) orelse {
            std.debug.print(
                \\cannot locate the Native SDK framework for this app.
                \\Set NATIVE_SDK_PATH to your framework checkout, or run a
                \\`native` binary that lives inside one (zig-out/bin/native).
                \\
            , .{});
            return error.MissingFramework;
        };
        defer allocator.free(framework_root);
        build_file = try buildgraph.ensureGeneratedBuild(allocator, io, ".", .{
            .app_name = metadata.name,
            .framework_root = framework_root,
        });
        // Keep artifacts where users expect them: the generated build root
        // is .native/build/, so without a prefix the binary would hide in
        // .native/build/zig-out/. Absolute path: a relative --prefix would
        // resolve against the build root, not the app dir.
        const cwd = try std.process.currentPathAlloc(io, allocator);
        defer allocator.free(cwd);
        prefix = try std.fs.path.join(allocator, &.{ cwd, "zig-out" });
        try argv.appendSlice(allocator, &.{ "--build-file", build_file.?, "--prefix", prefix.? });
    }

    const wants_frontend_dev = verb == .dev and metadata.frontend != null and metadata.frontend.?.dev != null;
    var release_fast = false;
    var dev_debug = false;
    switch (verb) {
        .dev => {
            if (!wants_frontend_dev) try argv.append(allocator, "run");
            // Zig's full summary reports each named build step's duration,
            // cache status, and peak RSS. Native's generated graph names the
            // frontend, corewire, staging, scriptc, and final Zig phases, so
            // slow iterative builds are attributable without reproducing
            // them under an external profiler.
            try argv.appendSlice(allocator, &.{ "--summary", "all" });
            if (!hasOptimizeFlag(options.forwarded_args)) {
                // The dev loop is a Debug loop: the markup hot-reload
                // watcher and the teaching diagnostics are compiled in only
                // when builtin.mode == .Debug, so a release-mode dev run
                // would silently ship a binary that never reloads. Pass an
                // optimize flag explicitly to override.
                try argv.append(allocator, "-Doptimize=Debug");
                dev_debug = true;
            }
        },
        .build => {
            try argv.appendSlice(allocator, &.{ "--summary", "all" });
            if (options.explain_rebuild) try argv.append(allocator, "-Dbuild-trace=true");
            if (!hasOptimizeFlag(options.forwarded_args)) {
                // Both build shapes register -Doptimize (addApp and the
                // expanded template each b.option it by hand).
                try argv.append(allocator, "-Doptimize=ReleaseFast");
                release_fast = true;
            }
        },
        .@"test" => {
            try argv.append(allocator, "test");
            // Never end a passing run in silence: the build summary names
            // the steps that ran and the test tally.
            try argv.appendSlice(allocator, &.{ "--summary", "all" });
        },
    }
    try argv.appendSlice(allocator, options.forwarded_args);

    if (verb == .dev and !wants_frontend_dev) {
        std.debug.print("native dev: building and running {s} ({s}) — hot reload arms in Debug builds\n", .{
            metadata.name,
            if (dev_debug) "Debug" else "optimize forwarded",
        });
    }

    try runZig(io, verb, argv.items);
    if (rebuild_snapshot) |snapshot| try persistRebuildSnapshot(io, snapshot);

    if (wants_frontend_dev) {
        // WebView apps with a dev server config: the binary is built, now
        // hand off to the frontend dev flow (server + shell + HMR env).
        const binary_path = try std.fs.path.join(allocator, &.{ "zig-out", "bin", metadata.name });
        defer allocator.free(binary_path);
        dev_tool.run(allocator, io, .{
            .metadata = metadata,
            .base_env = options.base_env,
            .binary_path = binary_path,
            .url_override = options.url_override,
            .command_override = options.command_override,
            .timeout_ms = options.timeout_ms,
        }) catch |err| {
            // Never fail in silence: name the step that died before the
            // error propagates to a quiet exit.
            std.debug.print("native dev: frontend dev flow failed ({t})\n", .{err});
            return err;
        };
        std.debug.print("native dev: app exited\n", .{});
    } else switch (verb) {
        .build => std.debug.print("native build: built zig-out/bin/{s}{s}\n", .{ metadata.name, if (release_fast) " (ReleaseFast)" else "" }),
        .@"test" => std.debug.print("native test: passed (test tally in the build summary above)\n", .{}),
        .dev => std.debug.print("native dev: app exited\n", .{}),
    }
}

/// The one generated-vs-ejected decision the verbs make: an app that owns
/// a build.zig at its root is EJECTED and the verbs drive it through plain
/// `zig build`; otherwise the CLI synthesizes the graph into .native/build/
/// (the module doc above). Named so the toolchain preflight and the argv
/// assembly cannot drift onto different predicates.
fn isEjectedAt(io: std.Io, app_root: []const u8) bool {
    var buffer: [1024]u8 = undefined;
    const path = std.fmt.bufPrint(&buffer, "{s}/build.zig", .{app_root}) catch return false;
    return buildgraph.fileExists(io, path);
}

/// The pre-spawn TS toolchain gate, scoped to graphs the CLI generates.
/// Generated graphs wire `framework_root` — the CLI's own SDK — as the
/// app's dependency, so an unresolvable toolchain there fails HERE with
/// the CLI's teaching (the checkout's one `npm ci --include=dev`, or the
/// reinstall on an npm layout) instead of a configure-time error inside
/// the graph. npm-installed CLIs always resolve — the toolchain ships as
/// a CLI dependency. EJECTED apps own their build.zig.zon and may pin a
/// DIFFERENT SDK checkout than the CLI resolves, so gating the CLI's SDK
/// would false-fail a healthy app (direct `zig build` works); they flow
/// straight to the zig spawn, where build/app.zig's tsCoreStage safety
/// net teaches against the app's ACTUAL dependency SDK.
fn tsToolchainPreflight(allocator: std.mem.Allocator, io: std.Io, app_root: []const u8, framework_root: []const u8) !void {
    if (isEjectedAt(io, app_root)) return;
    try ts_core.ensureResolvedTranspiler(allocator, io, framework_root);
}

fn hasOptimizeFlag(args: []const []const u8) bool {
    for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "-Doptimize")) return true;
        if (std.mem.startsWith(u8, arg, "--release")) return true;
    }
    return false;
}

const rebuild_snapshot_path = ".native/cache/rebuild-inputs.tsv";

const RebuildInput = struct {
    path: []const u8,
    hash: [std.crypto.hash.sha2.Sha256.digest_length * 2]u8,
};

fn appendRebuildInput(allocator: std.mem.Allocator, io: std.Io, inputs: *std.ArrayList(RebuildInput), path: []const u8) !void {
    const owned_path = try allocator.dupe(u8, path);
    errdefer allocator.free(owned_path);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024 * 1024));
    defer allocator.free(bytes);
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    try inputs.append(allocator, .{ .path = owned_path, .hash = std.fmt.bytesToHex(digest, .lower) });
}

fn rebuildInputs(allocator: std.mem.Allocator, io: std.Io) ![]RebuildInput {
    var inputs: std.ArrayList(RebuildInput) = .empty;
    errdefer {
        for (inputs.items) |input| allocator.free(input.path);
        inputs.deinit(allocator);
    }
    // app.zon is authored build truth just as much as src/: capabilities,
    // windows, services, web-layer selection, and packaging metadata all
    // alter the generated graph or final artifact.
    try appendRebuildInput(allocator, io, &inputs, "app.zon");
    var src = std.Io.Dir.cwd().openDir(io, "src", .{ .iterate = true }) catch return inputs.toOwnedSlice(allocator);
    defer src.close(io);
    var walker = try src.walk(allocator);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".ts") and !std.mem.endsWith(u8, entry.basename, ".native") and !std.mem.endsWith(u8, entry.basename, ".sql")) continue;
        const path = try std.fmt.allocPrint(allocator, "src/{s}", .{entry.path});
        defer allocator.free(path);
        try appendRebuildInput(allocator, io, &inputs, path);
    }
    std.mem.sort(RebuildInput, inputs.items, {}, struct {
        fn less(_: void, a: RebuildInput, b: RebuildInput) bool {
            return std.mem.order(u8, a.path, b.path) == .lt;
        }
    }.less);
    return inputs.toOwnedSlice(allocator);
}

fn explainRebuild(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    const inputs = try rebuildInputs(allocator, io);
    defer {
        for (inputs) |input| allocator.free(input.path);
        allocator.free(inputs);
    }
    const prior = std.Io.Dir.cwd().readFileAlloc(io, rebuild_snapshot_path, allocator, .limited(16 * 1024 * 1024)) catch null;
    defer if (prior) |bytes| allocator.free(bytes);

    var snapshot = std.Io.Writer.Allocating.init(allocator);
    errdefer snapshot.deinit();
    var changed: usize = 0;
    for (inputs) |input| {
        try snapshot.writer.print("{s}\t{s}\n", .{ &input.hash, input.path });
        const old_hash: ?[]const u8 = if (prior) |bytes| old: {
            var lines = std.mem.splitScalar(u8, bytes, '\n');
            while (lines.next()) |line| {
                const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
                if (std.mem.eql(u8, line[tab + 1 ..], input.path)) break :old line[0..tab];
            }
            break :old null;
        } else null;
        if (old_hash != null and std.mem.eql(u8, old_hash.?, &input.hash)) continue;
        changed += 1;
        std.debug.print("native rebuild: {s} {s} -> {s}\n", .{ input.path, old_hash orelse "<new>", &input.hash });
        if (std.mem.eql(u8, input.path, "app.zon")) {
            std.debug.print("  invalidates manifest-derived configuration -> affected contracts, app-code/platform link, and final artifact\n", .{});
        } else if (std.mem.eql(u8, input.path, "src/app.native")) {
            std.debug.print("  invalidates markup data object -> final app link; app-code/core scriptc remain content-gated\n", .{});
        } else if (std.mem.endsWith(u8, input.path, ".native")) {
            std.debug.print("  invalidates staged markup source set -> app-code object -> final link; core scriptc remains content-gated\n", .{});
        } else if (std.mem.startsWith(u8, input.path, "src/services/")) {
            std.debug.print("  invalidates TS frontend -> service contract/source hash -> service host compile; API client/registry/core scriptc change only if API shape changes\n", .{});
        } else if (std.mem.endsWith(u8, input.path, ".ts")) {
            std.debug.print("  invalidates TS frontend -> core contract/facade/stage -> core scriptc -> app-code object -> final link\n", .{});
        } else {
            std.debug.print("  invalidates SQLite schema/migration generation -> app-code object -> final link\n", .{});
        }
    }
    if (prior) |bytes| {
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |line| {
            const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
            const old_hash = line[0..tab];
            const old_path = line[tab + 1 ..];
            const present = for (inputs) |input| {
                if (std.mem.eql(u8, input.path, old_path)) break true;
            } else false;
            if (present) continue;
            changed += 1;
            std.debug.print("native rebuild: {s} {s} -> <deleted>\n", .{ old_path, old_hash });
            if (std.mem.startsWith(u8, old_path, "src/services/")) {
                std.debug.print("  invalidates TS frontend -> service API/source set -> service host; core scriptc changes if the removed module changed API shape\n", .{});
            } else if (std.mem.eql(u8, old_path, "src/app.native")) {
                std.debug.print("  invalidates primary markup data object -> final app link\n", .{});
            } else if (std.mem.endsWith(u8, old_path, ".native")) {
                std.debug.print("  invalidates markup source set -> app-code object -> final link\n", .{});
            } else {
                std.debug.print("  invalidates TS/schema source set and its downstream generated artifacts\n", .{});
            }
        }
    }
    if (prior == null) std.debug.print("native rebuild: no prior successful snapshot; current inputs are the baseline\n", .{});
    if (prior != null and changed == 0) std.debug.print("native rebuild: no authored input hashes changed\n", .{});
    return snapshot.toOwnedSlice();
}

fn persistRebuildSnapshot(io: std.Io, snapshot: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(io, ".native/cache");
    var atomic = try std.Io.Dir.cwd().createFileAtomic(io, rebuild_snapshot_path, .{ .make_path = true, .replace = true });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, snapshot);
    try atomic.replace(io);
}

fn runZig(io: std.Io, verb: Verb, argv: []const []const u8) !void {
    // The dev verb owns a whole process TREE: `zig build run` spawns the
    // app as its child, and a `native dev` that dies (Ctrl-C, a driver
    // killing the CLI) must not leave that app running — an orphaned
    // automation-enabled app keeps publishing snapshots and impersonates
    // the next build. Dev children get their own process group, killed on
    // exit signals and swept after a normal wait.
    const own_tree = verb == .dev and process_tree.supported;
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
        .pgid = if (own_tree) process_tree.spawnPgid() else null,
    });
    // Capture the group id at spawn: wait() clears the child's id.
    const group_pid: i32 = if (own_tree) process_tree.groupId(&child) else 0;
    if (group_pid > 0) process_tree.own(group_pid);
    defer if (group_pid > 0) process_tree.releaseAndKill(group_pid);
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code == 0) return,
        else => {},
    }
    // A failing exit must never be silent: even when the child printed
    // nothing (or was killed), name the step that failed.
    switch (term) {
        .exited => |code| std.debug.print("native {t}: `zig build` step failed (exit code {d})\n", .{ verb, code }),
        else => std.debug.print("native {t}: `zig build` step terminated abnormally ({t})\n", .{ verb, term }),
    }
    // The child's compile errors streamed straight through above. The one
    // failure class worth a pointer is code written for an older Zig — the
    // SDK builds with Zig 0.16, where std APIs moved, and those failures
    // read "no member named 'cwd'/'init'/'io'" on std types.
    std.debug.print("if the errors above name missing std members, the code may use pre-0.16 Zig idioms - run `native skills get zig` or see https://native-sdk.dev/zig\n", .{});
    std.debug.print("if generated core wiring exceeds Zig's eval branch quota, do not regenerate the TypeScript contract or add an app-side quota - update or report the SDK-generated scan\n", .{});
    return error.ZigBuildFailed;
}

test "toolchain preflight: ejected TS apps skip the CLI-SDK gate, generated ones keep it" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var cwd = std.Io.Dir.cwd();
    const root = ".zig-cache/test-verbs-ts-preflight";
    const sdk = root ++ "/sdk-checkout";
    const ejected_app = root ++ "/ejected-app";
    const generated_app = root ++ "/generated-app";
    cwd.deleteTree(io, root) catch {};
    defer cwd.deleteTree(io, root) catch {};

    // A CLI framework root whose toolchain is ABSENT: packages/core/test
    // marks the checkout layout, and no node_modules ever lands — the gate
    // teaches `npm ci --include=dev` whenever it actually runs. The pin
    // manifest rides along: the gate reads its exact compiler pin from
    // packages/core/package.json, which every real layout carries.
    try cwd.createDirPath(io, sdk ++ "/packages/core/test");
    try cwd.writeFile(io, .{ .sub_path = sdk ++ "/packages/core/package.json", .data = "{ \"name\": \"@native-sdk/core\", \"version\": \"0.0.9\", \"devDependencies\": { \"@typescript/old\": \"npm:typescript@9.9.9\" } }" });

    // The ejected-shaped TS layout: an app-owned build.zig (+ build.zig.zon)
    // at the root, src/core.ts present. Its zon may pin a DIFFERENT SDK
    // than the CLI's, so the preflight must NOT fail on the CLI SDK's
    // missing toolchain — the verb reaches the spawn decision, where
    // build/app.zig's in-graph teaching names the app's actual dependency.
    try cwd.createDirPath(io, ejected_app ++ "/src");
    try cwd.writeFile(io, .{ .sub_path = ejected_app ++ "/build.zig", .data = "// app-owned graph" });
    try cwd.writeFile(io, .{ .sub_path = ejected_app ++ "/build.zig.zon", .data = ".{ .dependencies = .{ .native_sdk = .{ .path = \"../elsewhere\" } } }" });
    try cwd.writeFile(io, .{ .sub_path = ejected_app ++ "/src/core.ts", .data = "// ts core" });
    try std.testing.expectEqual(ts_core.CoreTree.ts, ts_core.detectAt(io, ejected_app));
    try std.testing.expect(isEjectedAt(io, ejected_app));
    try tsToolchainPreflight(allocator, io, ejected_app, sdk);

    // The generated-shaped layout (no build.zig: the CLI synthesizes the
    // graph against ITS OWN SDK) keeps the friendly pre-spawn gate: the
    // absent toolchain still teaches before any zig spawn.
    try cwd.createDirPath(io, generated_app ++ "/src");
    try cwd.writeFile(io, .{ .sub_path = generated_app ++ "/src/core.ts", .data = "// ts core" });
    try std.testing.expect(!isEjectedAt(io, generated_app));
    try std.testing.expectError(error.MissingTranspiler, tsToolchainPreflight(allocator, io, generated_app, sdk));

    // And a resolvable CLI SDK passes the generated gate silently: land the
    // wrapper AND the aliased real compiler it re-exports, as npm does —
    // the compiler at the version the staged pin manifest names.
    const toolchain_manifest = "{ \"name\": \"@typescript/typescript6\", \"version\": \"0.0.2\", \"main\": \"./lib/typescript.js\" }";
    const compiler_manifest = "{ \"name\": \"typescript\", \"version\": \"9.9.9\", \"main\": \"./lib/typescript.js\" }";
    try cwd.createDirPath(io, sdk ++ "/packages/core/node_modules/@typescript/typescript6/lib");
    try cwd.writeFile(io, .{ .sub_path = sdk ++ "/packages/core/node_modules/@typescript/typescript6/package.json", .data = toolchain_manifest });
    try cwd.writeFile(io, .{ .sub_path = sdk ++ "/packages/core/node_modules/@typescript/typescript6/lib/typescript.js", .data = "// fake wrapper" });
    try cwd.createDirPath(io, sdk ++ "/packages/core/node_modules/@typescript/old/lib");
    try cwd.writeFile(io, .{ .sub_path = sdk ++ "/packages/core/node_modules/@typescript/old/package.json", .data = compiler_manifest });
    try cwd.writeFile(io, .{ .sub_path = sdk ++ "/packages/core/node_modules/@typescript/old/lib/typescript.js", .data = "// fake compiler" });
    try tsToolchainPreflight(allocator, io, generated_app, sdk);
}

test "optimize flags are detected among forwarded args" {
    try std.testing.expect(hasOptimizeFlag(&.{"-Doptimize=Debug"}));
    try std.testing.expect(hasOptimizeFlag(&.{ "-Dautomation=true", "--release=safe" }));
    try std.testing.expect(!hasOptimizeFlag(&.{"-Dautomation=true"}));
    try std.testing.expect(!hasOptimizeFlag(&.{}));
}

test "rebuild explanations persist manifest and source hashes" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const root = ".zig-cache/test-rebuild-explain";
    var cwd = std.Io.Dir.cwd();
    cwd.deleteTree(io, root) catch {};
    defer cwd.deleteTree(io, root) catch {};
    try cwd.createDirPath(io, root ++ "/src/services");
    try cwd.writeFile(io, .{ .sub_path = root ++ "/app.zon", .data = ".{ .name = \"rebuild-test\" }\n" });
    try cwd.writeFile(io, .{ .sub_path = root ++ "/src/core.ts", .data = "export const core = 1;\n" });
    try cwd.writeFile(io, .{ .sub_path = root ++ "/src/app.native", .data = "<column/>\n" });
    try cwd.writeFile(io, .{ .sub_path = root ++ "/src/services/work.ts", .data = "export function work(): number { return 1; }\n" });
    const original = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(original);
    try std.process.setCurrentPath(io, root);
    defer std.process.setCurrentPath(io, original) catch {};
    const first = try explainRebuild(allocator, io);
    defer allocator.free(first);
    try std.testing.expect(std.mem.indexOf(u8, first, "\tapp.zon\n") != null);
    try persistRebuildSnapshot(io, first);
    const second = try explainRebuild(allocator, io);
    defer allocator.free(second);
    try std.testing.expectEqualStrings(first, second);
    try cwd.writeFile(io, .{ .sub_path = "src/services/work.ts", .data = "// comment\nexport function work(): number { return 1; }\n" });
    const changed = try explainRebuild(allocator, io);
    defer allocator.free(changed);
    try std.testing.expect(!std.mem.eql(u8, first, changed));
    try cwd.writeFile(io, .{ .sub_path = "app.zon", .data = ".{ .name = \"rebuild-test\", .capabilities = .{\"store\"} }\n" });
    const manifest_changed = try explainRebuild(allocator, io);
    defer allocator.free(manifest_changed);
    try std.testing.expect(!std.mem.eql(u8, changed, manifest_changed));
}
