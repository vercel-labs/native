const std = @import("std");
const automation_cli = @import("automation.zig");
const markup_cli = @import("markup.zig");
const skills_cli = @import("skills.zig");
const tooling = @import("tooling");
const automation_protocol = @import("automation_protocol");
const cli_build_info = @import("cli_build_info");

const version = "0.5.4";

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len <= 1) {
        usage();
        std.process.exit(1);
    }

    const command = args[1];
    if (std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h") or std.mem.eql(u8, command, "help")) {
        // Asked-for help is a success: print it and exit 0 (usage() alone
        // is reserved for the exit-1 "you didn't tell me what to do" path).
        usage();
        return;
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
        checkVerbFlags("init", args[2..], .{
            .usage = "init [path] [--template <ts-core|zig-core>] [--frontend <native|next|vite|react|svelte|vue>] [--framework <sdk path>] [--full]",
            .value_flags = &.{ "--frontend", "--framework", "--template" },
            .bool_flags = &.{"--full"},
        });
        const destination = positionalArg(args[2..]) orelse ".";
        const frontend_str = flagValue(args, "--frontend") catch fail("--frontend requires a value: native, next, vite, react, svelte, vue") orelse "native";
        const frontend = tooling.templates.Frontend.parse(frontend_str) orelse fail("invalid --frontend value: use native (default), next, vite, react, svelte, or vue");
        const shape: tooling.templates.Shape = if (flagBool(args, "--full")) .full else .slim;
        // Which core the native template writes (ts-core is the default).
        // The choice leaves no residue: the tree IS the truth, and the
        // build graph re-detects it on every build.
        const core: tooling.templates.CoreTemplate = if (flagValue(args, "--template") catch fail("--template requires a value: ts-core (default) or zig-core")) |value|
            tooling.templates.CoreTemplate.parse(value) orelse fail("invalid --template value: use ts-core (default) or zig-core")
        else
            .ts;
        if (core == .zig and frontend != .native) fail("--template applies to the native frontend (web frontends have no core tier)");
        const app_name, const free_app_name = try initAppName(allocator, init.io, destination);
        defer if (free_app_name) allocator.free(app_name);
        const explicit_framework = try flagValue(args, "--framework");
        const framework_path, const free_framework_path = if (explicit_framework) |value|
            .{ value, false }
        else
            try initFrameworkPath(allocator, init.io, init.environ_map);
        defer if (free_framework_path) allocator.free(framework_path);
        if (!hasFrameworkRoot(allocator, init.io, framework_path)) {
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
        tooling.templates.writeDefaultApp(allocator, init.io, destination, .{ .app_name = app_name, .framework_path = framework_path, .frontend = frontend, .shape = shape, .core = core }) catch |err| return failVerb(err);
        std.debug.print("created Native SDK app at {s} ({s})\n", .{ destination, frontend_str });
        printInitNextSteps(destination, frontend, shape);
    } else if (std.mem.eql(u8, command, "build") or std.mem.eql(u8, command, "test")) {
        const verb: tooling.verbs.Verb = if (std.mem.eql(u8, command, "build")) .build else .@"test";
        checkVerbFlags(command, args[2..], .{
            .usage = if (verb == .build) "build [dir] [--yes] [-D... zig build flags]" else "test [dir] [--yes] [-D... zig build flags]",
            .bool_flags = &.{"--yes"},
            .forwards_build_flags = true,
        });
        const verb_args = parseVerbArgs(allocator, args[2..], &.{}) catch fail("usage: native build|test [dir] [--yes] [-D... zig build flags]");
        try enterAppDir(init.io, verb_args.dir);
        tooling.verbs.run(allocator, init.io, verb, .{
            .base_env = init.environ_map,
            .assume_yes = verb_args.assume_yes,
            .forwarded_args = verb_args.forwarded,
        }) catch |err| return failVerb(err);
    } else if (std.mem.eql(u8, command, "check")) {
        checkVerbFlags("check", args[2..], .{
            .usage = "check [dir] [--strict]",
            .bool_flags = &.{ "--strict", "--yes" },
        });
        const verb_args = parseVerbArgs(allocator, args[2..], &.{}) catch fail("usage: native check [dir] [--strict]");
        try enterAppDir(init.io, verb_args.dir);
        runCheck(allocator, init.io, init.environ_map, flagBool(args, "--strict")) catch |err| return failVerb(err);
    } else if (std.mem.eql(u8, command, "eject")) {
        // `eject component <name>` is dispatched before the plain build
        // eject so `component` is never mistaken for an app directory.
        if (args.len > 2 and std.mem.eql(u8, args[2], "component")) {
            checkVerbFlags("eject component", args[3..], .{
                .usage = "eject component <name> [dir]",
            });
            const name = positionalArg(args[3..]) orelse {
                std.debug.print("which component? ejectable components: {s}\nusage: native eject component <name> [dir]\n", .{tooling.eject_components.component_list});
                std.process.exit(1);
            };
            const verb_args = parseVerbArgs(allocator, args[4..], &.{}) catch fail("usage: native eject component <name> [dir]");
            try enterAppDir(init.io, verb_args.dir);
            runEjectComponent(init.io, name) catch |err| return failVerb(err);
        } else {
            checkVerbFlags("eject", args[2..], .{
                .usage = "eject [dir]",
                .bool_flags = &.{"--yes"},
            });
            const verb_args = parseVerbArgs(allocator, args[2..], &.{}) catch fail("usage: native eject [dir]");
            try enterAppDir(init.io, verb_args.dir);
            runEject(allocator, init.io, init.environ_map) catch |err| return failVerb(err);
        }
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
        checkVerbFlags("validate", args[2..], .{ .usage = "validate [app.zon]" });
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
        checkVerbFlags("bundle-assets", args[2..], .{ .usage = "bundle-assets [app.zon] [assets] [output]" });
        const manifest_path = if (args.len >= 3) args[2] else "app.zon";
        const metadata = try tooling.manifest.readMetadata(allocator, init.io, manifest_path);
        const assets_dir = if (args.len >= 4) args[3] else if (metadata.frontend) |frontend| frontend.dist else "assets";
        const output_dir = if (args.len >= 5) args[4] else "zig-out/assets";
        const stats = try tooling.assets.bundle(allocator, init.io, assets_dir, output_dir);
        std.debug.print("bundled {d} assets into {s}\n", .{ stats.asset_count, output_dir });
    } else if (std.mem.eql(u8, command, "package")) {
        checkVerbFlags("package", args[2..], .{
            .usage = "package [--target macos] [--output path] [--binary path] [--assets path] [--web-engine system|chromium] [--web-layer auto|include|exclude] [--cef-dir path] [--cef-auto-install] [--signing none|adhoc|identity] [--identity name] [--entitlements path] [--team-id id] [--archive]",
            .value_flags = &.{ "--manifest", "--target", "--output", "--binary", "--assets", "--web-engine", "--web-layer", "--cef-dir", "--signing", "--identity", "--entitlements", "--team-id", "--optimize" },
            .bool_flags = &.{ "--cef-auto-install", "--archive" },
        });
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
        // `--web-layer` beats app.zon's `.webview_layer` the same way
        // `-Dweb-layer` beats it in the build graph; the standard build
        // graphs pass their resolved layer decision through this flag so
        // the package always agrees with the exe it wraps.
        const web_layer_setting = if (try flagValue(args, "--web-layer")) |value|
            tooling.manifest.parseWebViewLayerSetting(value) orelse fail("invalid --web-layer value: use auto, include, or exclude")
        else
            null;
        const signing_name = try flagValue(args, "--signing") orelse "none";
        const signing = tooling.package.SigningMode.parse(signing_name) orelse fail("invalid signing mode");
        const default_output = switch (target) {
            .macos => try std.fmt.allocPrint(allocator, "zig-out/package/{s}.app", .{metadata.name}),
            else => try std.fmt.allocPrint(allocator, "zig-out/package/{s}-{s}", .{ metadata.name, target_name }),
        };
        const output_dir = try flagValue(args, "--output") orelse if (args.len >= 3 and args[2].len > 0 and args[2][0] != '-') args[2] else default_output;
        const archive = flagBool(args, "--archive");
        // Packaging is release-shaped on every target, and the optimize
        // label must reflect the binary actually packaged: the mobile
        // targets build the embed static library as ReleaseFast, and the
        // desktop targets pick up the ReleaseFast binary `native build`
        // installs. The label names artifacts (the .dmg/.zip/.tar.gz and
        // the package report), so a Debug default would stamp "Debug" on
        // a ReleaseFast binary. Pass --optimize when packaging a binary
        // built any other way.
        const optimize_value = try flagValue(args, "--optimize") orelse "ReleaseFast";
        const binary_path = try flagValue(args, "--binary") orelse switch (target) {
            .ios => try iosPackageLibrary(allocator, init.io, init.environ_map, metadata.name, optimize_value),
            .android => try androidPackageLibrary(allocator, init.io, init.environ_map, metadata.name, optimize_value),
            else => try discoverAppBinary(allocator, init.io, metadata.name, target),
        };
        if (binary_path == null and target != .ios and target != .android) {
            std.debug.print("warning[package.no-binary]: no app binary at zig-out/bin/{s} and no --binary flag - the package will not contain an executable\n" ++
                "  build the app first (`zig build`) or pass --binary <path>\n", .{metadata.name});
        }
        if (web_engine.engine == .chromium and web_engine.cef_auto_install) {
            try tooling.cef.run(allocator, init.io, init.environ_map, &.{ "install", "--dir", web_engine.cef_dir });
        }
        const stats = try tooling.package.createPackage(allocator, init.io, .{
            .metadata = metadata,
            .target = target,
            .optimize = optimize_value,
            .output_path = output_dir,
            .binary_path = binary_path,
            .assets_dir = try flagValue(args, "--assets") orelse if (metadata.frontend) |frontend| frontend.dist else "assets",
            .frontend = metadata.frontend,
            .web_engine = web_engine.engine,
            .web_layer_setting = web_layer_setting,
            .cef_dir = web_engine.cef_dir,
            .signing = .{ .mode = signing, .identity = try flagValue(args, "--identity"), .entitlements = try flagValue(args, "--entitlements"), .team_id = try flagValue(args, "--team-id") },
            .archive = archive,
            .env_map = init.environ_map,
        });
        tooling.package.printDiagnostic(stats);
    } else if (std.mem.eql(u8, command, "dev")) {
        checkVerbFlags("dev", args[2..], .{
            .usage = "dev [dir] [--yes] [--target ios|android] [--device name] [--url url] [--command \"npm run dev\"] [--timeout-ms n] [-D... zig build flags]\n       native dev [dir] --core [--script msgs.ndjson] [--watch]\n       native dev [--manifest app.zon] --binary path [--url url] [--command \"npm run dev\"] [--timeout-ms n]",
            .value_flags = &.{ "--url", "--command", "--timeout-ms", "--binary", "--manifest", "--target", "--device", "--script" },
            .bool_flags = &.{ "--yes", "--core", "--watch" },
            .forwards_build_flags = true,
        });
        if (flagBool(args, "--core")) {
            // The TypeScript core-logic loop under node (update/effects on a
            // virtual host) - not a renderer; plain `native dev` runs the app.
            const verb_args = parseVerbArgs(allocator, args[2..], &.{"--script"}) catch fail("usage: native dev [dir] --core [--script msgs.ndjson] [--watch]");
            try enterAppDir(init.io, verb_args.dir);
            const framework_root = try tooling.buildgraph.resolveFrameworkRoot(allocator, init.io, init.environ_map) orelse {
                std.debug.print("cannot locate the Native SDK framework; set NATIVE_SDK_PATH to your framework checkout\n", .{});
                std.process.exit(1);
            };
            defer allocator.free(framework_root);
            // The editor surface rides along with the dev loop too (TS
            // trees only — never leave node_modules in a non-app dir).
            if (tooling.ts_core.detect(init.io) == .ts) {
                tooling.ts_core.selfHealEditorPackage(allocator, init.io, framework_root);
            }
            tooling.ts_core.runDevHost(allocator, init.io, framework_root, .{
                .base_env = init.environ_map,
                .script = try flagValue(args, "--script"),
                .watch = flagBool(args, "--watch"),
            }) catch |err| return failVerb(err);
            return;
        }
        if (try flagValue(args, "--target")) |dev_target| {
            // The mobile dev loop: build the embed library for the
            // simulator/emulator, wrap it in the toolkit-owned host,
            // install + launch, and stream the app log.
            const is_ios = std.mem.eql(u8, dev_target, "ios");
            const is_android = std.mem.eql(u8, dev_target, "android");
            if (!is_ios and !is_android) {
                fail("`native dev --target` supports: ios, android (desktop is the default without --target)");
            }
            const verb_args = parseVerbArgs(allocator, args[2..], &.{ "--target", "--device", "--url", "--command", "--timeout-ms" }) catch fail("usage: native dev [dir] --target ios|android [--device name] [--yes] [-D... zig build flags]");
            try enterAppDir(init.io, verb_args.dir);
            if (is_ios) {
                tooling.ios.runDev(allocator, init.io, .{
                    .base_env = init.environ_map,
                    .assume_yes = verb_args.assume_yes,
                    .forwarded_args = verb_args.forwarded,
                    .device = try flagValue(args, "--device"),
                }) catch |err| return failVerb(err);
            } else {
                tooling.android.runDev(allocator, init.io, .{
                    .base_env = init.environ_map,
                    .assume_yes = verb_args.assume_yes,
                    .forwarded_args = verb_args.forwarded,
                    .device = try flagValue(args, "--device"),
                }) catch |err| return failVerb(err);
            }
        } else if ((try flagValue(args, "--binary")) != null) {
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
        checkPackageShortcutFlags(command, args[2..]);
        try packageShortcut(allocator, init.io, init.environ_map, args, .windows, "zig-out/package/windows");
    } else if (std.mem.eql(u8, command, "package-linux")) {
        checkPackageShortcutFlags(command, args[2..]);
        try packageShortcut(allocator, init.io, init.environ_map, args, .linux, "zig-out/package/linux");
    } else if (std.mem.eql(u8, command, "package-ios")) {
        checkPackageShortcutFlags(command, args[2..]);
        const metadata = try tooling.manifest.readMetadata(allocator, init.io, try flagValue(args, "--manifest") orelse "app.zon");
        const web_engine = try tooling.web_engine.resolve(.{ .web_engine = metadata.web_engine, .cef = metadata.cef }, .{});
        const binary_path = try flagValue(args, "--binary") orelse try iosPackageLibrary(allocator, init.io, init.environ_map, metadata.name, "ReleaseFast");
        const stats = try tooling.package.createPackage(allocator, init.io, .{
            .metadata = metadata,
            .target = .ios,
            .optimize = "ReleaseFast",
            .output_path = try flagValue(args, "--output") orelse if (args.len >= 3 and args[2].len > 0 and args[2][0] != '-') args[2] else "zig-out/mobile/ios",
            .binary_path = binary_path,
            .assets_dir = try flagValue(args, "--assets") orelse if (metadata.frontend) |frontend| frontend.dist else "assets",
            .frontend = metadata.frontend,
            .web_engine = web_engine.engine,
            .cef_dir = web_engine.cef_dir,
            .env_map = init.environ_map,
        });
        tooling.package.printDiagnostic(stats);
    } else if (std.mem.eql(u8, command, "package-android")) {
        checkPackageShortcutFlags(command, args[2..]);
        const metadata = try tooling.manifest.readMetadata(allocator, init.io, try flagValue(args, "--manifest") orelse "app.zon");
        const web_engine = try tooling.web_engine.resolve(.{ .web_engine = metadata.web_engine, .cef = metadata.cef }, .{});
        const binary_path = try flagValue(args, "--binary") orelse try androidPackageLibrary(allocator, init.io, init.environ_map, metadata.name, "ReleaseFast");
        const stats = try tooling.package.createPackage(allocator, init.io, .{
            .metadata = metadata,
            .target = .android,
            .optimize = "ReleaseFast",
            .output_path = try flagValue(args, "--output") orelse if (args.len >= 3 and args[2].len > 0 and args[2][0] != '-') args[2] else "zig-out/mobile/android",
            .binary_path = binary_path,
            .assets_dir = try flagValue(args, "--assets") orelse if (metadata.frontend) |frontend| frontend.dist else "assets",
            .frontend = metadata.frontend,
            .web_engine = web_engine.engine,
            .cef_dir = web_engine.cef_dir,
            .env_map = init.environ_map,
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
        std.debug.print("unknown command: {s}\n\n", .{command});
        usage();
        std.process.exit(1);
    }
}

fn usage() void {
    std.debug.print(
        \\usage: native <command>
        \\
        \\commands:
        \\  init [path] [--template <ts-core|zig-core>] [--frontend <native|next|vite|react|svelte|vue>] [--framework <sdk path>] [--full]   (defaults: native + ts-core)
        \\  dev [dir] [--yes] [-D... zig build flags]      build a Debug binary and run it (markup hot reload)
        \\  dev [dir] --target ios [--device name]         build for the iOS simulator, install + launch, stream the log (experimental)
        \\  dev [dir] --target android [--device name]     build a debug APK, install + launch on an emulator via adb, stream the log (experimental)
        \\  dev [dir] --core [--script msgs.ndjson] [--watch]   run the TypeScript core's logic loop under node (update/effects transcript; not a renderer)
        \\  build [dir] [--yes] [-D... zig build flags]    build a ReleaseFast binary into zig-out/bin/
        \\  test [dir] [--yes] [-D... zig build flags]     run the app's test suite
        \\  check [dir] [--strict]                         validate the core (src/core.ts through the subset checker), src/*.native markup, and app.zon
        \\  eject [dir]                                    write an owned build.zig/build.zig.zon into the app
        \\  eject component <name> [dir]                   write an owned copy of a library composite into src/components/
        \\  cef install|path|doctor [--dir path] [--version version] [--source prepared|official] [--force]
        \\  doctor [--strict] [--manifest app.zon] [--web-engine system|chromium] [--cef-dir path] [--cef-auto-install]
        \\  validate [app.zon]
        \\  bundle-assets [app.zon] [assets] [output]
        \\  package [--target macos|windows|linux|ios|android] [--output path] [--binary path] [--assets path] [--web-engine system|chromium] [--web-layer auto|include|exclude] [--cef-dir path] [--cef-auto-install] [--signing none|adhoc|identity] [--identity name] [--entitlements path] [--team-id id] [--archive]
        \\  dev [--manifest app.zon] --binary path [--url http://127.0.0.1:5173/] [--command "npm run dev"] [--timeout-ms 30000]
        \\  package-windows [--output path] [--binary path]
        \\  package-linux [--output path] [--binary path]
        \\  package-ios [--output path] [--binary path]
        \\  package-android [--output path] [--binary path]
        \\  markup check <file.native> [more files...] [--strict] | markup dump <file.native> [--out doc.nsui] | markup lsp
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

/// Flag discipline for every verb parsed here: `<verb> --help` prints the
/// verb's usage and exits 0, and an unrecognized flag prints the same usage
/// and exits 1. A flag typo must never fall through to a real run (`native
/// init --help` once scaffolded a real app named after the cwd).
const VerbSpec = struct {
    usage: []const u8,
    /// Flags that consume the following argument.
    value_flags: []const []const u8 = &.{},
    /// Boolean flags.
    bool_flags: []const []const u8 = &.{},
    /// Verb forwards -D.../--release... to `zig build`.
    forwards_build_flags: bool = false,
};

fn checkPackageShortcutFlags(verb: []const u8, args: []const []const u8) void {
    var usage_buffer: [128]u8 = undefined;
    const usage_text = std.fmt.bufPrint(&usage_buffer, "{s} [--output path] [--binary path] [--manifest app.zon] [--assets path]", .{verb}) catch verb;
    checkVerbFlags(verb, args, .{
        .usage = usage_text,
        .value_flags = &.{ "--manifest", "--output", "--binary", "--assets" },
    });
}

fn checkVerbFlags(verb: []const u8, args: []const []const u8, spec: VerbSpec) void {
    var index: usize = 0;
    args: while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            std.debug.print("usage: native {s}\n", .{spec.usage});
            std.process.exit(0);
        }
        if (!std.mem.startsWith(u8, arg, "-")) continue;
        if (spec.forwards_build_flags and (std.mem.startsWith(u8, arg, "-D") or std.mem.startsWith(u8, arg, "--release"))) continue;
        for (spec.bool_flags) |flag| {
            if (std.mem.eql(u8, arg, flag)) continue :args;
        }
        for (spec.value_flags) |flag| {
            if (std.mem.eql(u8, arg, flag)) {
                index += 1;
                continue :args;
            }
        }
        std.debug.print("unknown flag {s} for `native {s}`\nusage: native {s}\n", .{ arg, verb, spec.usage });
        std.process.exit(1);
    }
}

/// Expected verb failures already printed a teaching message (or zig's own
/// compile errors are on screen); exit without a Zig error-return trace.
fn failVerb(err: anyerror) anyerror!void {
    switch (err) {
        error.MissingManifest,
        error.MissingFramework,
        error.CrossVolumeFramework,
        error.ZigUnavailable,
        error.DownloadDeclined,
        error.UnsupportedPlatform,
        error.ChecksumMismatch,
        error.ZigBuildFailed,
        error.InvalidManifest,
        error.MarkupCheckFailed,
        error.BothCores,
        error.MissingTsCore,
        error.MissingNode,
        error.MissingTranspiler,
        error.BrokenToolchainInstall,
        error.ToolchainVersionMismatch,
        error.CoreCheckFailed,
        error.DevHostFailed,
        error.HostCompileFailed,
        error.SimulatorUnavailable,
        error.SimulatorCommandFailed,
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
        // Verb-specific boolean flags read by the caller via flagBool.
        if (std.mem.eql(u8, arg, "--strict")) continue;
        if (std.mem.eql(u8, arg, "--core")) continue;
        if (std.mem.eql(u8, arg, "--watch")) continue;
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

/// `native check`: validate every markup file under src/ plus app.zon — the
/// no-build confidence pass (markup vocabulary + manifest schema). With a
/// fresh model-contract artifact in zig-out (refreshed by `native test`),
/// the markup pass also verifies
/// bindings, iterables, message tags, and expression types against the
/// app's actual Model/Msg, and reports unused model state as warnings
/// (--strict promotes warnings to failures).
fn runCheck(allocator: std.mem.Allocator, io: std.Io, env_map: *std.process.Environ.Map, strict: bool) !void {
    if (!tooling.buildgraph.fileExists(io, "app.zon")) {
        std.debug.print("no app.zon here — `native check` runs inside an app directory (or pass one: `native check path/to/app`)\n", .{});
        return error.MissingManifest;
    }

    // The core tier first: a TypeScript core runs the @native-sdk/core checker
    // (subset rules + tsc), whose NS diagnostics surface verbatim - the
    // same teaching UX Zig apps get from `zig build`/`native test`.
    const core_tree = tooling.ts_core.detect(io);
    if (core_tree == .both) return tooling.ts_core.failBothCores();
    if (core_tree == .ts) {
        const framework_root = try tooling.buildgraph.resolveFrameworkRoot(allocator, io, env_map) orelse {
            std.debug.print("cannot locate the Native SDK framework; set NATIVE_SDK_PATH to your framework checkout\n", .{});
            return error.MissingFramework;
        };
        defer allocator.free(framework_root);
        // Self-heal the editor surface first: node_modules/@native-sdk/core
        // (the pre-publish copy stock tsc resolves) refreshes whenever it is
        // missing or version-skewed vs the SDK — one info line, never a
        // check failure.
        tooling.ts_core.selfHealEditorPackage(allocator, io, framework_root);
        try tooling.ts_core.checkCore(allocator, io, env_map, framework_root);
    }

    var markup_files: std.ArrayList([]const u8) = .empty;
    defer markup_files.deinit(allocator);
    try collectMarkupFiles(allocator, io, "src", &markup_files);
    var outcome = markup_cli.CheckOutcome{};
    if (markup_files.items.len > 0) {
        outcome = try markup_cli.checkFiles(allocator, io, markup_files.items);
        if (outcome.failures > 0) return error.MarkupCheckFailed;
    }

    const result = try tooling.manifest.validateFile(allocator, io, "app.zon");
    tooling.manifest.printDiagnostic(result);
    if (!result.ok) return error.InvalidManifest;
    // The build-graph web-layer inference, surfaced where authors look:
    // whether this app ships the embedded web layer, and why. `check`
    // takes no engine flag, so the manifest's own engine is the resolved
    // engine here.
    const metadata = try tooling.manifest.readMetadata(allocator, io, "app.zon");
    if (tooling.manifest.webLayerFromManifest(metadata)) |layer| {
        std.debug.print("web layer: {s} ({s})\n", .{ if (layer.enabled) "included" else "none", layer.sourceText() });
    } else |_| {
        // Contradictions and invalid values were already rejected by the
        // validation pass above; nothing more to add here.
    }
    const checked_markup = markup_files.items.len;
    const contract_note: []const u8 = if (outcome.contract_checked) " against the model contract" else "";
    const core_note: []const u8 = if (core_tree == .ts) " and src/core.ts (subset checker clean)" else "";
    std.debug.print("checked {d} markup file{s}{s}, app.zon{s}\n", .{ checked_markup, if (checked_markup == 1) "" else "s", contract_note, core_note });
    if (strict and outcome.warnings > 0) {
        std.debug.print("{d} warning{s} promoted to errors (--strict)\n", .{ outcome.warnings, if (outcome.warnings == 1) "" else "s" });
        return error.MarkupCheckFailed;
    }
}

/// Every `.native` file under the root.
fn collectMarkupFiles(allocator: std.mem.Allocator, io: std.Io, root_path: []const u8, out: *std.ArrayList([]const u8)) !void {
    var root = std.Io.Dir.cwd().openDir(io, root_path, .{ .iterate = true }) catch return;
    defer root.close(io);
    var walker = try root.walk(allocator);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind == .file and markup_cli.hasMarkupExtension(entry.path)) {
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

/// `native eject component <name>`: transfer ownership of one library
/// composite to the app — write its canonical source into
/// src/components/, exactly once. The component registry, the writer,
/// and the did-you-mean live in tooling (`eject_components.zig`); this
/// wrapper owns the CLI's teaching messages.
fn runEjectComponent(io: std.Io, name: []const u8) !void {
    if (!tooling.buildgraph.fileExists(io, "app.zon")) {
        std.debug.print("no app.zon here — `native eject component` runs inside an app directory (or pass one: `native eject component {s} path/to/app`)\n", .{name});
        return error.MissingManifest;
    }
    const component = tooling.eject_components.find(name) orelse {
        if (tooling.eject_components.suggestion(name)) |suggested| {
            std.debug.print("unknown component \"{s}\" (did you mean \"{s}\"?) — ejectable components: {s}\n", .{ name, suggested, tooling.eject_components.component_list });
        } else {
            std.debug.print("unknown component \"{s}\" — ejectable components: {s}\n", .{ name, tooling.eject_components.component_list });
        }
        std.process.exit(1);
    };
    tooling.eject_components.eject(io, ".", component) catch |err| switch (err) {
        error.AlreadyEjected => {
            std.debug.print("already ejected at {s} - delete it to re-eject\n", .{component.path});
            std.process.exit(1);
        },
        error.WriteFailed => {
            std.debug.print("cannot write {s} — check the app directory is writable\n", .{component.path});
            std.process.exit(1);
        },
    };
    std.debug.print(
        \\ejected: {s} now belongs to this app ({s}).
        \\The file's header comment walks through migrating call sites; the
        \\library form keeps working wherever you have not migrated. Run
        \\`native check` to validate the app afterwards.
        \\
    , .{ component.path, component.form });
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

/// `native package --target ios` without --binary: build the DEVICE
/// slice through the app's `zig build lib` step — always a fresh build,
/// never a path discovery, and the install stage is keyed by the target
/// triple (.native/embed/<triple>), so the dev loop's SIMULATOR slice
/// and the Android tier can never leave wrong-target bytes where this
/// build looks. A failed build degrades to a libraryless project with a
/// teaching warning (the repo-shaped webview apps have no mobile UiApp
/// to compile) instead of aborting packaging.
fn iosPackageLibrary(allocator: std.mem.Allocator, io: std.Io, env_map: *std.process.Environ.Map, app_name: []const u8, optimize: []const u8) !?[]const u8 {
    std.debug.print("info[package.ios]: building the embed static library ({s}, {s})\n", .{ tooling.ios.LibSlice.device.zigTriple(), optimize });
    return tooling.ios.buildEmbedLib(allocator, io, app_name, .{
        .base_env = env_map,
        .slice = .device,
        .optimize = optimize,
    }) catch |err| switch (err) {
        error.ZigBuildFailed, error.MissingFramework => {
            std.debug.print("warning[package.no-binary]: could not build the embed library - the project will not contain Libraries/libnative-sdk.a\n" ++
                "  build it first (`zig build lib -Dtarget={s}`) or pass --binary <path>; the app must expose a mobile UiApp (`mobileOptions`)\n", .{tooling.ios.LibSlice.device.zigTriple()});
            return null;
        },
        // Cross-volume SDK: the junction bridge failed, so the generated
        // host project could not build against the SDK either — a
        // libraryless project would ship broken. The teaching message is
        // already on screen; fail the whole package verb without a trace.
        error.CrossVolumeFramework => std.process.exit(1),
        else => return err,
    };
}

/// `native package --target android` without --binary: build the
/// aarch64-linux-android embed static library the generated host project
/// (and its APK assembly) links. A failed build degrades to a
/// libraryless project with a teaching warning instead of aborting
/// packaging, mirroring the iOS path.
fn androidPackageLibrary(allocator: std.mem.Allocator, io: std.Io, env_map: *std.process.Environ.Map, app_name: []const u8, optimize: []const u8) !?[]const u8 {
    std.debug.print("info[package.android]: building the embed static library ({s}, {s})\n", .{ tooling.android.zig_triple, optimize });
    return tooling.android.buildEmbedLib(allocator, io, app_name, .{
        .base_env = env_map,
        .optimize = optimize,
    }) catch |err| switch (err) {
        error.ZigBuildFailed, error.MissingFramework => {
            std.debug.print("warning[package.no-binary]: could not build the embed library - the project will not contain Libraries/libnative-sdk.a\n" ++
                "  build it first (`zig build lib -Dtarget={s}`) or pass --binary <path>; the app must expose a mobile UiApp (`mobileOptions`)\n", .{tooling.android.zig_triple});
            return null;
        },
        // Cross-volume SDK: the junction bridge failed, so the generated
        // host project could not build against the SDK either — a
        // libraryless project would ship broken. The teaching message is
        // already on screen; fail the whole package verb without a trace.
        error.CrossVolumeFramework => std.process.exit(1),
        else => return err,
    };
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

/// Where `native init` points the new app's SDK dependency when no
/// --framework flag is given: the same resolution `native dev|build|test`
/// use (NATIVE_SDK_PATH, then the CLI executable's own location — see
/// buildgraph.resolveFrameworkRoot), so init and the verbs can never
/// disagree about which SDK an app builds against.
fn initFrameworkPath(allocator: std.mem.Allocator, io: std.Io, env_map: *std.process.Environ.Map) !struct { []const u8, bool } {
    if (try tooling.buildgraph.resolveFrameworkRoot(allocator, io, env_map)) |path| return .{ path, true };
    return .{ ".", false };
}

fn hasFrameworkRoot(allocator: std.mem.Allocator, io: std.Io, root: []const u8) bool {
    return tooling.buildgraph.hasFrameworkRoot(allocator, io, root);
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
                std.mem.eql(u8, arg, "--template") or
                std.mem.eql(u8, arg, "--script") or
                std.mem.eql(u8, arg, "--manifest") or
                std.mem.eql(u8, arg, "--target") or
                std.mem.eql(u8, arg, "--output") or
                std.mem.eql(u8, arg, "--binary") or
                std.mem.eql(u8, arg, "--assets") or
                std.mem.eql(u8, arg, "--web-engine") or
                std.mem.eql(u8, arg, "--web-layer") or
                std.mem.eql(u8, arg, "--cef-dir") or
                std.mem.eql(u8, arg, "--signing") or
                std.mem.eql(u8, arg, "--identity") or
                std.mem.eql(u8, arg, "--entitlements") or
                std.mem.eql(u8, arg, "--team-id") or
                std.mem.eql(u8, arg, "--command") or
                std.mem.eql(u8, arg, "--url") or
                std.mem.eql(u8, arg, "--timeout-ms") or
                std.mem.eql(u8, arg, "--device"))
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

fn packageShortcut(allocator: std.mem.Allocator, io: std.Io, env_map: *std.process.Environ.Map, args: []const []const u8, target: tooling.package.PackageTarget, default_output: []const u8) !void {
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
        .env_map = env_map,
    });
    tooling.package.printDiagnostic(stats);
}
