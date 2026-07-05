const std = @import("std");
const automation_cli = @import("automation.zig");
const markup_cli = @import("markup.zig");
const skills_cli = @import("skills.zig");
const tooling = @import("tooling");
const automation_protocol = @import("automation_protocol");
const cli_build_info = @import("cli_build_info");

const version = "0.3.0";

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len <= 1) return usage();

    const command = args[1];
    if (std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h") or std.mem.eql(u8, command, "help")) {
        return usage();
    } else if (std.mem.eql(u8, command, "--version") or std.mem.eql(u8, command, "version")) {
        // Payload, not a diagnostic: scripts parse `native version`, so it
        // belongs on stdout (see automation.zig's emitPayload contract).
        // Commit + automation protocol make binary/framework skew a
        // one-command check (a stale zig-out `native` binary once
        // silently drove a days-old dropbox).
        var stdout_buffer: [128]u8 = undefined;
        var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
        try stdout_writer.interface.print("native {s} (commit {s}, automation protocol v{d})\n", .{ version, cli_build_info.build_commit, automation_protocol.version });
        try stdout_writer.interface.flush();
    } else if (std.mem.eql(u8, command, "init")) {
        const destination = positionalArg(args[2..]) orelse ".";
        const frontend_str = flagValue(args, "--frontend") catch fail("--frontend requires a value: native, next, vite, react, svelte, vue") orelse "native";
        const frontend = tooling.templates.Frontend.parse(frontend_str) orelse fail("invalid --frontend value: use native (default), next, vite, react, svelte, or vue");
        const shape: tooling.templates.Shape = if (flagBool(args, "--full")) .full else .slim;
        const app_name, const free_app_name = try initAppName(allocator, init.io, destination);
        defer if (free_app_name) allocator.free(app_name);
        const explicit_framework = try flagValue(args, "--framework");
        const framework_path, const free_framework_path = if (explicit_framework) |value|
            .{ value, false }
        else
            try initFrameworkPath(allocator, init.io);
        defer if (free_framework_path) allocator.free(framework_path);
        if (!try hasFrameworkRoot(allocator, init.io, framework_path)) {
            if (explicit_framework) |value| {
                std.debug.print("error: --framework {s} is not a Native SDK checkout (no src/root.zig there)\n", .{value});
            } else {
                std.debug.print("error: could not locate the Native SDK framework from this `native` binary's location\n" ++
                    "  `native init` records where the framework lives so the new app can build against it.\n" ++
                    "  Run the `native` built inside an SDK checkout (zig-out/bin/native) or installed via npm,\n" ++
                    "  or pass --framework <path to the Native SDK repo>.\n", .{});
            }
            std.process.exit(1);
        }
        try tooling.templates.writeDefaultApp(allocator, init.io, destination, .{ .app_name = app_name, .framework_path = framework_path, .frontend = frontend, .shape = shape });
        std.debug.print("created Native SDK app at {s} ({s})\n", .{ destination, frontend_str });
        printInitNextSteps(destination, frontend, shape);
    } else if (std.mem.eql(u8, command, "build") or std.mem.eql(u8, command, "test")) {
        const verb: tooling.verbs.Verb = if (std.mem.eql(u8, command, "build")) .build else .@"test";
        const verb_args = parseVerbArgs(allocator, args[2..], &.{}) catch fail("usage: native build|test [dir] [--yes] [-D... zig build flags]");
        try enterAppDir(init.io, verb_args.dir);
        tooling.verbs.run(allocator, init.io, verb, .{
            .base_env = init.environ_map,
            .assume_yes = verb_args.assume_yes,
            .forwarded_args = verb_args.forwarded,
        }) catch |err| return failVerb(err);
    } else if (std.mem.eql(u8, command, "check")) {
        const verb_args = parseVerbArgs(allocator, args[2..], &.{}) catch fail("usage: native check [dir]");
        try enterAppDir(init.io, verb_args.dir);
        runCheck(allocator, init.io) catch |err| return failVerb(err);
    } else if (std.mem.eql(u8, command, "eject")) {
        const verb_args = parseVerbArgs(allocator, args[2..], &.{}) catch fail("usage: native eject [dir]");
        try enterAppDir(init.io, verb_args.dir);
        runEject(allocator, init.io, init.environ_map) catch |err| return failVerb(err);
    } else if (std.mem.eql(u8, command, "doctor")) {
        try tooling.doctor.run(allocator, init.io, init.environ_map, args[2..]);
    } else if (std.mem.eql(u8, command, "cef")) {
        tooling.cef.run(allocator, init.io, init.environ_map, args[2..]) catch |err| switch (err) {
            error.InvalidArguments,
            error.UnsupportedPlatform,
            error.MissingLayout,
            error.CommandFailed,
            error.WrapperBuildFailed,
            => std.process.exit(1),
            else => return err,
        };
    } else if (std.mem.eql(u8, command, "markup")) {
        try markup_cli.run(allocator, init.io, args[2..]);
    } else if (std.mem.eql(u8, command, "validate")) {
        const path = if (args.len >= 3) args[2] else "app.zon";
        const result = tooling.manifest.validateFile(allocator, init.io, path) catch |err| switch (err) {
            error.FileNotFound => {
                std.debug.print("error: {s} not found - run this from your app's root (the folder containing app.zon), or pass a path: native validate <path/to/app.zon>\n", .{path});
                std.process.exit(1);
            },
            else => return err,
        };
        tooling.manifest.printDiagnostic(result);
        // Exit directly: the diagnostic above is the whole story, and a
        // returned error would bury it under the CLI's own return trace.
        if (!result.ok) std.process.exit(1);
    } else if (std.mem.eql(u8, command, "bundle-assets")) {
        const manifest_path = if (args.len >= 3) args[2] else "app.zon";
        const metadata = try tooling.manifest.readMetadata(allocator, init.io, manifest_path);
        const assets_dir = if (args.len >= 4) args[3] else if (metadata.frontend) |frontend| frontend.dist else "assets";
        const output_dir = if (args.len >= 5) args[4] else "zig-out/assets";
        const stats = try tooling.assets.bundle(allocator, init.io, assets_dir, output_dir);
        std.debug.print("bundled {d} assets into {s}\n", .{ stats.asset_count, output_dir });
    } else if (std.mem.eql(u8, command, "package")) {
        const manifest_path = try flagValue(args, "--manifest") orelse "app.zon";
        const metadata = tooling.manifest.readMetadata(allocator, init.io, manifest_path) catch |err| switch (err) {
            error.FileNotFound => {
                std.debug.print("error: {s} not found - run this from your app's root (the folder containing app.zon), or pass --manifest <path/to/app.zon>\n", .{manifest_path});
                std.process.exit(1);
            },
            else => return err,
        };
        const target_name = try flagValue(args, "--target") orelse "macos";
        const target = tooling.package.PackageTarget.parse(target_name) orelse fail("invalid package target");
        const web_engine_override = if (try flagValue(args, "--web-engine")) |value|
            tooling.web_engine.Engine.parse(value) orelse fail("invalid web engine")
        else
            null;
        const web_engine = try tooling.web_engine.resolve(.{ .web_engine = metadata.web_engine, .cef = metadata.cef }, .{
            .web_engine = web_engine_override,
            .cef_dir = try flagValue(args, "--cef-dir"),
            .cef_auto_install = if (flagBool(args, "--cef-auto-install")) true else null,
        });
        const signing_name = try flagValue(args, "--signing") orelse "none";
        const signing = tooling.package.SigningMode.parse(signing_name) orelse fail("invalid signing mode");
        const default_output = switch (target) {
            .macos => try std.fmt.allocPrint(allocator, "zig-out/package/{s}.app", .{metadata.name}),
            else => try std.fmt.allocPrint(allocator, "zig-out/package/{s}-{s}", .{ metadata.name, target_name }),
        };
        const output_dir = try flagValue(args, "--output") orelse if (args.len >= 3 and args[2].len > 0 and args[2][0] != '-') args[2] else default_output;
        const archive = flagBool(args, "--archive");
        const binary_path = try flagValue(args, "--binary") orelse try discoverAppBinary(allocator, init.io, metadata.name, target);
        if (binary_path == null) {
            std.debug.print("warning[package.no-binary]: no app binary at zig-out/bin/{s} and no --binary flag - the package will not contain an executable\n" ++
                "  build the app first (`zig build`) or pass --binary <path>\n", .{metadata.name});
        }
        if (web_engine.engine == .chromium and web_engine.cef_auto_install) {
            try tooling.cef.run(allocator, init.io, init.environ_map, &.{ "install", "--dir", web_engine.cef_dir });
        }
        const stats = try tooling.package.createPackage(allocator, init.io, .{
            .metadata = metadata,
            .target = target,
            .optimize = try flagValue(args, "--optimize") orelse "Debug",
            .output_path = output_dir,
            .binary_path = binary_path,
            .assets_dir = try flagValue(args, "--assets") orelse if (metadata.frontend) |frontend| frontend.dist else "assets",
            .frontend = metadata.frontend,
            .web_engine = web_engine.engine,
            .cef_dir = web_engine.cef_dir,
            .signing = .{ .mode = signing, .identity = try flagValue(args, "--identity"), .entitlements = try flagValue(args, "--entitlements"), .team_id = try flagValue(args, "--team-id") },
            .archive = archive,
        });
        tooling.package.printDiagnostic(stats);
    } else if (std.mem.eql(u8, command, "dev")) {
        if ((try flagValue(args, "--binary")) != null) {
            // Legacy shape (`--binary` provided): the caller already built
            // the shell — e.g. the expanded template's `zig build dev` step —
            // so only run the frontend-server + shell flow. Unchanged.
            const manifest_path = try flagValue(args, "--manifest") orelse "app.zon";
            const metadata = try tooling.manifest.readMetadata(allocator, init.io, manifest_path);
            const command_override = if (try flagValue(args, "--command")) |value| try splitCommand(allocator, value) else null;
            try tooling.dev.run(allocator, init.io, .{
                .metadata = metadata,
                .base_env = init.environ_map,
                .binary_path = try flagValue(args, "--binary"),
                .url_override = try flagValue(args, "--url"),
                .command_override = command_override,
                .timeout_ms = if (try flagValue(args, "--timeout-ms")) |value| try std.fmt.parseUnsigned(u32, value, 10) else null,
            });
        } else {
            const verb_args = parseVerbArgs(allocator, args[2..], &.{ "--url", "--command", "--timeout-ms" }) catch fail("usage: native dev [dir] [--yes] [--url url] [--command \"npm run dev\"] [--timeout-ms n] [-D... zig build flags]");
            try enterAppDir(init.io, verb_args.dir);
            const command_override = if (try flagValue(args, "--command")) |value| try splitCommand(allocator, value) else null;
            tooling.verbs.run(allocator, init.io, .dev, .{
                .base_env = init.environ_map,
                .assume_yes = verb_args.assume_yes,
                .forwarded_args = verb_args.forwarded,
                .url_override = try flagValue(args, "--url"),
                .command_override = command_override,
                .timeout_ms = if (try flagValue(args, "--timeout-ms")) |value| try std.fmt.parseUnsigned(u32, value, 10) else null,
            }) catch |err| return failVerb(err);
        }
    } else if (std.mem.eql(u8, command, "package-windows")) {
        try packageShortcut(allocator, init.io, args, .windows, "zig-out/package/windows");
    } else if (std.mem.eql(u8, command, "package-linux")) {
        try packageShortcut(allocator, init.io, args, .linux, "zig-out/package/linux");
    } else if (std.mem.eql(u8, command, "package-ios")) {
        const metadata = try tooling.manifest.readMetadata(allocator, init.io, try flagValue(args, "--manifest") orelse "app.zon");
        const web_engine = try tooling.web_engine.resolve(.{ .web_engine = metadata.web_engine, .cef = metadata.cef }, .{});
        const stats = try tooling.package.createPackage(allocator, init.io, .{
            .metadata = metadata,
            .target = .ios,
            .output_path = try flagValue(args, "--output") orelse if (args.len >= 3 and args[2].len > 0 and args[2][0] != '-') args[2] else "zig-out/mobile/ios",
            .binary_path = try flagValue(args, "--binary"),
            .assets_dir = try flagValue(args, "--assets") orelse if (metadata.frontend) |frontend| frontend.dist else "assets",
            .frontend = metadata.frontend,
            .web_engine = web_engine.engine,
            .cef_dir = web_engine.cef_dir,
        });
        tooling.package.printDiagnostic(stats);
    } else if (std.mem.eql(u8, command, "package-android")) {
        const metadata = try tooling.manifest.readMetadata(allocator, init.io, try flagValue(args, "--manifest") orelse "app.zon");
        const web_engine = try tooling.web_engine.resolve(.{ .web_engine = metadata.web_engine, .cef = metadata.cef }, .{});
        const stats = try tooling.package.createPackage(allocator, init.io, .{
            .metadata = metadata,
            .target = .android,
            .output_path = try flagValue(args, "--output") orelse if (args.len >= 3 and args[2].len > 0 and args[2][0] != '-') args[2] else "zig-out/mobile/android",
            .binary_path = try flagValue(args, "--binary"),
            .assets_dir = try flagValue(args, "--assets") orelse if (metadata.frontend) |frontend| frontend.dist else "assets",
            .frontend = metadata.frontend,
            .web_engine = web_engine.engine,
            .cef_dir = web_engine.cef_dir,
        });
        tooling.package.printDiagnostic(stats);
    } else if (std.mem.eql(u8, command, "automate")) {
        try automation_cli.run(allocator, init.io, init.environ_map, args[2..]);
    } else if (std.mem.eql(u8, command, "skills")) {
        skills_cli.run(allocator, init.io, init.environ_map, args[2..]) catch |err| switch (err) {
            error.WriteFailed => return,
            else => return err,
        };
    } else {
        return usage();
    }
}

fn usage() void {
    std.debug.print(
        \\usage: native <command>
        \\
        \\commands:
        \\  init [path] [--frontend <native|next|vite|react|svelte|vue>] [--framework <sdk path>] [--full]   (default: native)
        \\  dev [dir] [--yes] [-D... zig build flags]      build and run the app (hot reload)
        \\  build [dir] [--yes] [-D... zig build flags]    build a ReleaseFast binary into zig-out/bin/
        \\  test [dir] [--yes] [-D... zig build flags]     run the app's test suite
        \\  check [dir]                                    validate src/*.zml markup and app.zon
        \\  eject [dir]                                    write an owned build.zig/build.zig.zon into the app
        \\  cef install|path|doctor [--dir path] [--version version] [--source prepared|official] [--force]
        \\  doctor [--strict] [--manifest app.zon] [--web-engine system|chromium] [--cef-dir path] [--cef-auto-install]
        \\  validate [app.zon]
        \\  bundle-assets [app.zon] [assets] [output]
        \\  package [--target macos] [--output path] [--binary path] [--assets path] [--web-engine system|chromium] [--cef-dir path] [--cef-auto-install] [--signing none|adhoc|identity] [--identity name] [--entitlements path] [--team-id id] [--archive]
        \\  dev [--manifest app.zon] --binary path [--url http://127.0.0.1:5173/] [--command "npm run dev"] [--timeout-ms 30000]
        \\  package-windows [--output path] [--binary path]
        \\  package-linux [--output path] [--binary path]
        \\  package-ios [--output path] [--binary path]
        \\  package-android [--output path] [--binary path]
        \\  markup check <file.zml> [more files...] | markup lsp
        \\  automate <command>
        \\  skills list|get
        \\  version
        \\
    , .{});
}

fn fail(message: []const u8) noreturn {
    std.debug.print("{s}\n", .{message});
    std.process.exit(1);
}

/// Expected verb failures already printed a teaching message (or zig's own
/// compile errors are on screen); exit without a Zig error-return trace.
fn failVerb(err: anyerror) anyerror!void {
    switch (err) {
        error.MissingManifest,
        error.MissingFramework,
        error.ZigUnavailable,
        error.DownloadDeclined,
        error.UnsupportedPlatform,
        error.ChecksumMismatch,
        error.ZigBuildFailed,
        error.InvalidManifest,
        error.MarkupCheckFailed,
        => std.process.exit(1),
        else => return err,
    }
}

fn printInitNextSteps(destination: []const u8, frontend: tooling.templates.Frontend, shape: tooling.templates.Shape) void {
    std.debug.print("\nNext steps:\n", .{});
    if (!std.mem.eql(u8, destination, ".")) {
        std.debug.print("  cd {s}\n", .{destination});
    }
    if (frontend == .native and shape == .slim) {
        std.debug.print("  native dev\n", .{});
    } else {
        std.debug.print("  zig build run\n", .{});
    }
}

const VerbArgs = struct {
    dir: []const u8 = ".",
    assume_yes: bool = false,
    forwarded: []const []const u8 = &.{},
};

/// Parse `native <verb>` arguments: an optional app directory, --yes, and
/// -D/--release flags forwarded verbatim to `zig build`. `value_flags`
/// names verb-specific flags whose values must be skipped (handled by the
/// caller through flagValue).
fn parseVerbArgs(allocator: std.mem.Allocator, args: []const []const u8, value_flags: []const []const u8) !VerbArgs {
    var out: VerbArgs = .{};
    var forwarded: std.ArrayList([]const u8) = .empty;
    errdefer forwarded.deinit(allocator);
    var index: usize = 0;
    args: while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--yes")) {
            out.assume_yes = true;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-D") or std.mem.startsWith(u8, arg, "--release")) {
            try forwarded.append(allocator, arg);
            continue;
        }
        for (value_flags) |flag| {
            if (std.mem.eql(u8, arg, flag)) {
                index += 1;
                if (index >= args.len) return error.InvalidArguments;
                continue :args;
            }
        }
        if (std.mem.startsWith(u8, arg, "-")) return error.InvalidArguments;
        if (!std.mem.eql(u8, out.dir, ".")) return error.InvalidArguments;
        out.dir = arg;
    }
    out.forwarded = try forwarded.toOwnedSlice(allocator);
    return out;
}

fn enterAppDir(io: std.Io, dir: []const u8) !void {
    if (std.mem.eql(u8, dir, ".")) return;
    std.process.setCurrentPath(io, dir) catch {
        std.debug.print("cannot enter app directory {s}\n", .{dir});
        return error.MissingAppDirectory;
    };
}

/// `native check`: validate every .zml under src/ plus app.zon — the
/// no-build confidence pass (markup vocabulary + manifest schema).
fn runCheck(allocator: std.mem.Allocator, io: std.Io) !void {
    if (!tooling.buildgraph.fileExists(io, "app.zon")) {
        std.debug.print("no app.zon here — `native check` runs inside an app directory (or pass one: `native check path/to/app`)\n", .{});
        return error.MissingManifest;
    }

    var markup_args: std.ArrayList([]const u8) = .empty;
    defer markup_args.deinit(allocator);
    try markup_args.append(allocator, "check");
    try collectZmlFiles(allocator, io, "src", &markup_args);
    if (markup_args.items.len > 1) {
        try markup_cli.run(allocator, io, markup_args.items);
    }

    const result = try tooling.manifest.validateFile(allocator, io, "app.zon");
    tooling.manifest.printDiagnostic(result);
    if (!result.ok) return error.InvalidManifest;
    const checked_markup = markup_args.items.len - 1;
    std.debug.print("checked {d} markup file{s} and app.zon\n", .{ checked_markup, if (checked_markup == 1) "" else "s" });
}

fn collectZmlFiles(allocator: std.mem.Allocator, io: std.Io, root_path: []const u8, out: *std.ArrayList([]const u8)) !void {
    var root = std.Io.Dir.cwd().openDir(io, root_path, .{ .iterate = true }) catch return;
    defer root.close(io);
    var walker = try root.walk(allocator);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.path, ".zml")) {
            try out.append(allocator, try std.fs.path.join(allocator, &.{ root_path, entry.path }));
        }
    }
}

/// `native eject`: transfer build ownership to the app exactly once.
fn runEject(allocator: std.mem.Allocator, io: std.Io, env_map: *std.process.Environ.Map) !void {
    if (!tooling.buildgraph.fileExists(io, "app.zon")) {
        std.debug.print("no app.zon here — `native eject` runs inside an app directory (or pass one: `native eject path/to/app`)\n", .{});
        return error.MissingManifest;
    }
    const metadata = try tooling.manifest.readMetadata(allocator, io, "app.zon");
    const framework_root = try tooling.buildgraph.resolveFrameworkRoot(allocator, io, env_map) orelse {
        std.debug.print("cannot locate the Native SDK framework; set NATIVE_SDK_PATH to your framework checkout\n", .{});
        return error.MissingFramework;
    };
    defer allocator.free(framework_root);

    tooling.buildgraph.eject(allocator, io, ".", .{
        .app_name = metadata.name,
        .framework_root = framework_root,
    }) catch |err| switch (err) {
        error.AlreadyEjected => {
            std.debug.print("build.zig or build.zig.zon already exists — eject writes the owned build exactly once and never overwrites it\n", .{});
            std.process.exit(1);
        },
        else => return err,
    };
    std.debug.print(
        \\ejected: build.zig and build.zig.zon now belong to this app.
        \\`native dev|build|test` drive them via `zig build` from now on; the
        \\generated graph under .native/ is unused and safe to delete.
        \\
    , .{});
}

fn initAppName(allocator: std.mem.Allocator, io: std.Io, destination: []const u8) !struct { []const u8, bool } {
    if (!std.mem.eql(u8, destination, ".")) {
        return .{ std.fs.path.basename(destination), false };
    }

    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);
    const basename = std.fs.path.basename(cwd);
    if (basename.len == 0) return .{ try allocator.dupe(u8, "native-sdk-app"), true };
    return .{ try allocator.dupe(u8, basename), true };
}

/// `native package` without --binary: the scaffolded build installs the
/// app binary at zig-out/bin/<manifest name>, so look there before
/// falling back to a binaryless bundle.
fn discoverAppBinary(allocator: std.mem.Allocator, io: std.Io, app_name: []const u8, target: tooling.package.PackageTarget) !?[]const u8 {
    const suffix: []const u8 = if (target == .windows) ".exe" else "";
    const candidate = try std.fmt.allocPrint(allocator, "zig-out/bin/{s}{s}", .{ app_name, suffix });
    var file = std.Io.Dir.cwd().openFile(io, candidate, .{}) catch {
        allocator.free(candidate);
        return null;
    };
    file.close(io);
    std.debug.print("info[package.binary]: using zig-out/bin/{s}\n", .{app_name});
    return candidate;
}

fn initFrameworkPath(allocator: std.mem.Allocator, io: std.Io) !struct { []const u8, bool } {
    if (try frameworkRootFromExecutable(allocator, io)) |path| return .{ path, true };
    return .{ ".", false };
}

fn frameworkRootFromExecutable(allocator: std.mem.Allocator, io: std.Io) !?[]const u8 {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const executable_len = std.process.executablePath(io, &buffer) catch return null;
    const executable_path = buffer[0..executable_len];
    const bin_dir = std.fs.path.dirname(executable_path) orelse return null;
    const package_root = std.fs.path.dirname(bin_dir) orelse return null;

    if (try hasFrameworkRoot(allocator, io, package_root)) {
        return try allocator.dupe(u8, package_root);
    }
    if (std.fs.path.dirname(package_root)) |repo_root| {
        if (try hasFrameworkRoot(allocator, io, repo_root)) {
            return try allocator.dupe(u8, repo_root);
        }
    }
    return null;
}

fn hasFrameworkRoot(allocator: std.mem.Allocator, io: std.Io, root: []const u8) !bool {
    const root_zig = try std.fs.path.join(allocator, &.{ root, "src", "root.zig" });
    defer allocator.free(root_zig);
    var file = std.Io.Dir.cwd().openFile(io, root_zig, .{}) catch return false;
    defer file.close(io);
    return true;
}

fn flagValue(args: []const []const u8, name: []const u8) error{MissingFlagValue}!?[]const u8 {
    for (args, 0..) |arg, index| {
        if (std.mem.eql(u8, arg, name)) {
            if (index + 1 < args.len) return args[index + 1];
            return error.MissingFlagValue;
        }
    }
    return null;
}

fn flagBool(args: []const []const u8, name: []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, name)) return true;
    }
    return false;
}

fn positionalArg(args: []const []const u8) ?[]const u8 {
    var skip_next = false;
    for (args) |arg| {
        if (skip_next) {
            skip_next = false;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--")) {
            if (std.mem.eql(u8, arg, "--frontend") or
                std.mem.eql(u8, arg, "--framework") or
                std.mem.eql(u8, arg, "--manifest") or
                std.mem.eql(u8, arg, "--target") or
                std.mem.eql(u8, arg, "--output") or
                std.mem.eql(u8, arg, "--binary") or
                std.mem.eql(u8, arg, "--assets") or
                std.mem.eql(u8, arg, "--web-engine") or
                std.mem.eql(u8, arg, "--cef-dir") or
                std.mem.eql(u8, arg, "--signing") or
                std.mem.eql(u8, arg, "--identity") or
                std.mem.eql(u8, arg, "--entitlements") or
                std.mem.eql(u8, arg, "--team-id") or
                std.mem.eql(u8, arg, "--command") or
                std.mem.eql(u8, arg, "--url") or
                std.mem.eql(u8, arg, "--timeout-ms"))
            {
                skip_next = true;
            }
            continue;
        }
        return arg;
    }
    return null;
}

fn splitCommand(allocator: std.mem.Allocator, value: []const u8) ![]const []const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    errdefer parts.deinit(allocator);
    var tokens = std.mem.tokenizeScalar(u8, value, ' ');
    while (tokens.next()) |token| {
        try parts.append(allocator, try allocator.dupe(u8, token));
    }
    return parts.toOwnedSlice(allocator);
}

fn packageShortcut(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8, target: tooling.package.PackageTarget, default_output: []const u8) !void {
    const metadata = try tooling.manifest.readMetadata(allocator, io, try flagValue(args, "--manifest") orelse "app.zon");
    const web_engine = try tooling.web_engine.resolve(.{ .web_engine = metadata.web_engine, .cef = metadata.cef }, .{});
    const stats = try tooling.package.createPackage(allocator, io, .{
        .metadata = metadata,
        .target = target,
        .output_path = try flagValue(args, "--output") orelse default_output,
        .binary_path = try flagValue(args, "--binary"),
        .assets_dir = try flagValue(args, "--assets") orelse if (metadata.frontend) |frontend| frontend.dist else "assets",
        .frontend = metadata.frontend,
        .web_engine = web_engine.engine,
        .cef_dir = web_engine.cef_dir,
    });
    tooling.package.printDiagnostic(stats);
}
