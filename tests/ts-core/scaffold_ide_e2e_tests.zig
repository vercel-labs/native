//! End-to-end: the stock-IDE contract of TypeScript apps, proved with the
//! REAL tsc (the repo's own @typescript/typescript6 install) and zero
//! injected paths — exactly the view VS Code's TypeScript service has.
//!
//! Both directions of the independence contract are pinned:
//!   - editor truth: a fresh `native init` scaffold (and each committed TS
//!     example port) typechecks through nothing but its own tsconfig.json
//!     and the materialized node_modules/@native-sdk/core copy, resolving
//!     `@native-sdk/core` AND the `@native-sdk/core/text` subpath;
//!   - build truth: with node_modules deleted, the transpiler (the build's
//!     checker + emitter) still runs the same core clean — builds never
//!     read the editor surface — and the ensure hook check/dev/build run
//!     re-materializes the copy for the editor.
//!
//! Wired in build.zig behind the same gate as the other ts-core e2e
//! suites: node on PATH plus packages/core's installed dependency.

const std = @import("std");
const tooling = @import("tooling");

const tsc_js = "packages/core/node_modules/@typescript/typescript6/lib/tsc.js";

/// The editor view: real tsc over the app's own tsconfig, no flags beyond
/// the project pointer. Non-zero exit prints tsc's diagnostics verbatim.
fn expectTscClean(allocator: std.mem.Allocator, io: std.Io, app_root: []const u8) !void {
    try runExpectZero(allocator, io, &.{ "node", tsc_js, "-p", app_root, "--noEmit" });
}

fn runExpectZero(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) !void {
    const result = try std.process.run(allocator, io, .{
        .argv = argv,
        .stdout_limit = .limited(512 * 1024),
        .stderr_limit = .limited(512 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    const ok = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok) {
        std.debug.print("command failed: {s} {s}\nstdout:\n{s}\nstderr:\n{s}\n", .{
            argv[0],
            argv[1],
            result.stdout,
            result.stderr,
        });
        return error.CommandFailed;
    }
}

fn copyIntoStage(allocator: std.mem.Allocator, io: std.Io, source_path: []const u8, dest_path: []const u8) !void {
    var cwd = std.Io.Dir.cwd();
    const data = try cwd.readFileAlloc(io, source_path, allocator, .limited(8 * 1024 * 1024));
    defer allocator.free(data);
    if (std.fs.path.dirname(dest_path)) |parent| try cwd.createDirPath(io, parent);
    try cwd.writeFile(io, .{ .sub_path = dest_path, .data = data });
}

test "a fresh ts scaffold typechecks under stock tsc, and builds never need the editor surface" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var cwd = std.Io.Dir.cwd();
    const root = ".zig-cache/e2e-ide-scaffold";
    cwd.deleteTree(io, root) catch {};
    defer cwd.deleteTree(io, root) catch {};

    // `native init` default template (ts-core, slim), against this checkout.
    try tooling.templates.writeDefaultApp(allocator, io, root, .{
        .app_name = "Ide Proof",
        .framework_path = ".",
        .frontend = .native,
    });

    // The scaffold materialized the full editor surface.
    try std.testing.expect(tooling.buildgraph.fileExists(io, root ++ "/package.json"));
    try std.testing.expect(tooling.buildgraph.fileExists(io, root ++ "/tsconfig.json"));
    try std.testing.expect(tooling.buildgraph.fileExists(io, root ++ "/node_modules/@native-sdk/core/package.json"));
    try std.testing.expect(tooling.buildgraph.fileExists(io, root ++ "/node_modules/@native-sdk/core/sdk/core.ts"));
    try std.testing.expect(tooling.buildgraph.fileExists(io, root ++ "/node_modules/@native-sdk/core/sdk/text.ts"));
    try std.testing.expect(tooling.buildgraph.fileExists(io, root ++ "/node_modules/@native-sdk/core/sdk/events.ts"));

    // Editor truth: stock tsc, the scaffold's own tsconfig, zero injected
    // paths — `@native-sdk/core` resolves through node_modules alone.
    try expectTscClean(allocator, io, root);

    // Build truth: delete the editor surface entirely; the transpiler (the
    // exact checker + emitter every build runs) still takes the core clean.
    try cwd.deleteTree(io, root ++ "/node_modules");
    try cwd.createDirPath(io, ".zig-cache/e2e-ide-scaffold-out");
    try runExpectZero(allocator, io, &.{
        "node",
        "packages/core/src/cli.ts",
        root ++ "/src/core.ts",
        "-o",
        ".zig-cache/e2e-ide-scaffold-out/core.zig",
    });

    // The self-heal hook check/dev/build run puts the copy back current.
    try std.testing.expectEqual(tooling.ts_core.EnsureOutcome.materialized, try tooling.ts_core.ensureEditorPackage(allocator, io, ".", root));
    const status = try tooling.ts_core.editorPackageStatus(allocator, io, ".", root);
    defer status.deinit(allocator);
    try std.testing.expect(status.fresh());
    try expectTscClean(allocator, io, root);
}

test "the committed TS example ports typecheck under stock tsc (multi-file cores, ./text subpath)" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var cwd = std.Io.Dir.cwd();

    const bundled = try tooling.ts_core.bundledSdkVersion(allocator, io, ".");
    defer allocator.free(bundled);

    const ports = [_][]const u8{ "examples/soundboard-ts", "examples/system-monitor-ts" };
    for (ports, 0..) |port, index| {
        var stage_buffer: [128]u8 = undefined;
        const stage = try std.fmt.bufPrint(&stage_buffer, ".zig-cache/e2e-ide-port-{d}", .{index});
        cwd.deleteTree(io, stage) catch {};
        defer cwd.deleteTree(io, stage) catch {};

        // Stage the example's committed editor surface + core modules; the
        // ports' pinned @native-sdk/core version must be the SDK's bundled
        // one, or a post-publish `npm install` would fetch stale types.
        var path_buffer: [512]u8 = undefined;
        var dest_buffer: [512]u8 = undefined;
        for ([_][]const u8{ "package.json", "tsconfig.json" }) |file| {
            const source = try std.fmt.bufPrint(&path_buffer, "{s}/{s}", .{ port, file });
            const dest = try std.fmt.bufPrint(&dest_buffer, "{s}/{s}", .{ stage, file });
            try copyIntoStage(allocator, io, source, dest);
        }
        {
            const manifest_path = try std.fmt.bufPrint(&path_buffer, "{s}/package.json", .{port});
            const manifest = try cwd.readFileAlloc(io, manifest_path, allocator, .limited(64 * 1024));
            defer allocator.free(manifest);
            var pin_buffer: [128]u8 = undefined;
            const pin = try std.fmt.bufPrint(&pin_buffer, "\"@native-sdk/core\": \"{s}\"", .{bundled});
            if (std.mem.indexOf(u8, manifest, pin) == null) {
                std.debug.print("{s}/package.json pins a different @native-sdk/core than the SDK's bundled v{s} - update the example's pin with the version bump\n", .{ port, bundled });
                return error.StalePin;
            }
        }
        {
            const src_path = try std.fmt.bufPrint(&path_buffer, "{s}/src", .{port});
            var src_dir = try cwd.openDir(io, src_path, .{ .iterate = true });
            defer src_dir.close(io);
            var it = src_dir.iterate();
            while (try it.next(io)) |entry| {
                if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".ts")) continue;
                var source_buffer: [512]u8 = undefined;
                const source = try std.fmt.bufPrint(&source_buffer, "{s}/src/{s}", .{ port, entry.name });
                const dest = try std.fmt.bufPrint(&dest_buffer, "{s}/src/{s}", .{ stage, entry.name });
                try copyIntoStage(allocator, io, source, dest);
            }
        }

        _ = try tooling.ts_core.ensureEditorPackage(allocator, io, ".", stage);
        try expectTscClean(allocator, io, stage);
    }
}
