const std = @import("std");
const junction = @import("junction.zig");

/// The SDK's default app icon, rendered from vector source by
/// `zig build generate-icon` (tools/generate_app_icon.zig). Embedded so
/// `native init` always scaffolds a real icon regardless of the
/// directory the CLI runs from. The scaffold ships the one-image PNG
/// contract (`assets/icon.png` in app.zon `.icons`; packaging generates
/// every platform's artifacts from it); the `.icns` twin stays embedded
/// for packaging's no-icon fallback (src/tooling/package.zig).
const default_icon_png = @embedFile("default_icon.png");

pub const Frontend = enum {
    next,
    vite,
    react,
    svelte,
    vue,
    /// Native-rendered markup app (.native + Zig): no WebView, no npm frontend.
    native,

    pub fn parse(value: []const u8) ?Frontend {
        if (std.mem.eql(u8, value, "next")) return .next;
        if (std.mem.eql(u8, value, "vite")) return .vite;
        if (std.mem.eql(u8, value, "react")) return .react;
        if (std.mem.eql(u8, value, "svelte")) return .svelte;
        if (std.mem.eql(u8, value, "vue")) return .vue;
        if (std.mem.eql(u8, value, "native")) return .native;
        return null;
    }

    pub fn distDir(self: Frontend) []const u8 {
        return switch (self) {
            .next => "frontend/out",
            .vite, .react, .svelte, .vue => "frontend/dist",
            .native => "assets",
        };
    }

    pub fn devPort(self: Frontend) []const u8 {
        return switch (self) {
            .next => "3000",
            .vite, .react, .svelte, .vue, .native => "5173",
        };
    }

    pub fn devUrl(self: Frontend) []const u8 {
        return switch (self) {
            .next => "http://127.0.0.1:3000/",
            .vite, .react, .svelte, .vue, .native => "http://127.0.0.1:5173/",
        };
    }
};

/// Scaffold shape for the native frontend. `slim` is the zero-config
/// default: app.zon + src/ + assets + README only — the `native` CLI owns
/// the build graph (`native dev|build|test`) and `native eject` writes an
/// owned build.zig later. `full` keeps the pre-zero-config shape
/// (build.zig, build.zig.zon, .vscode, CI workflow) for users who want to
/// own the build from day one. Web frontends always scaffold full: their
/// npm build pipeline needs the expanded build.zig.
pub const Shape = enum {
    slim,
    full,
};

pub const InitOptions = struct {
    app_name: []const u8,
    framework_path: []const u8 = ".",
    frontend: Frontend = .vite,
    shape: Shape = .slim,
};

pub fn writeDefaultApp(allocator: std.mem.Allocator, io: std.Io, destination: []const u8, options: InitOptions) !void {
    const names = try TemplateNames.init(allocator, options.app_name);
    defer names.deinit(allocator);
    const framework_path = try defaultFrameworkPath(allocator, io, destination, options.framework_path);
    defer allocator.free(framework_path);

    var cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, destination);
    var app_dir = try cwd.openDir(io, destination, .{});
    defer app_dir.close(io);

    try app_dir.createDirPath(io, "src");
    try app_dir.createDirPath(io, "assets");

    if (options.frontend == .native) {
        if (options.shape == .slim) {
            return writeNativeAppSlim(allocator, io, app_dir, names);
        }
        // build.zig.zon path dependencies must be relative to the app root.
        const dependency_path = try nativeDependencyPath(allocator, io, destination, framework_path);
        defer allocator.free(dependency_path);
        return writeNativeApp(allocator, io, app_dir, names, dependency_path);
    }

    const build_zig = try buildZig(allocator, names, framework_path, options.frontend);
    defer allocator.free(build_zig);
    const build_zon = try buildZon(allocator, names);
    defer allocator.free(build_zon);
    const main_zig = try mainZig(allocator, names, options.frontend);
    defer allocator.free(main_zig);
    const app_zon = try appZon(allocator, names, options.frontend);
    defer allocator.free(app_zon);
    const readme_md = try readme(allocator, names, framework_path, options.frontend);
    defer allocator.free(readme_md);
    const ci_yaml = try frontendCiYaml(allocator, names);
    defer allocator.free(ci_yaml);

    try app_dir.createDirPath(io, ".github/workflows");
    try writeFile(app_dir, io, "build.zig", build_zig);
    try writeFile(app_dir, io, "build.zig.zon", build_zon);
    try writeFile(app_dir, io, "src/main.zig", main_zig);
    try writeFile(app_dir, io, "src/runner.zig", runnerZig());
    try writeFile(app_dir, io, "app.zon", app_zon);
    try writeFile(app_dir, io, "assets/icon.png", default_icon_png);
    try writeFile(app_dir, io, ".github/workflows/ci.yml", ci_yaml);
    try writeFile(app_dir, io, "README.md", readme_md);

    try writeFrontendFiles(allocator, io, app_dir, names, options.frontend);
}

/// The zero-config scaffold: no build files, no editor config, no CI — the
/// README teaches the `native` verbs and everything else is app source.
fn writeNativeAppSlim(allocator: std.mem.Allocator, io: std.Io, app_dir: std.Io.Dir, names: TemplateNames) !void {
    const main_zig = try nativeMainZig(allocator, names);
    defer allocator.free(main_zig);
    const tests_zig = try nativeTestsZig(allocator, names);
    defer allocator.free(tests_zig);
    const app_zon = try nativeAppZon(allocator, names);
    defer allocator.free(app_zon);
    const readme_md = try slimNativeReadme(allocator, names);
    defer allocator.free(readme_md);

    try writeFile(app_dir, io, "src/main.zig", main_zig);
    try writeFile(app_dir, io, "src/app.native", nativeAppMarkup());
    try writeFile(app_dir, io, "src/tests.zig", tests_zig);
    try writeFile(app_dir, io, "app.zon", app_zon);
    try writeFile(app_dir, io, "assets/icon.png", default_icon_png);
    try writeFile(app_dir, io, ".gitignore", slimGitignore());
    try writeFile(app_dir, io, "README.md", readme_md);
}

fn slimGitignore() []const u8 {
    return
    \\.native/
    \\zig-out/
    \\.zig-cache/
    \\
    ;
}

fn slimNativeReadme(allocator: std.mem.Allocator, names: TemplateNames) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "# ");
    try out.appendSlice(allocator, names.display_name);
    try out.appendSlice(allocator,
        \\
        \\
        \\A native-rendered Native SDK app: the view lives in `src/app.native`
        \\(declarative markup) and the logic in `src/main.zig` (`Model`, `Msg`,
        \\`update`). No WebView, no npm, no build files — the `native` CLI owns
        \\the build.
        \\
        \\## Commands
        \\
        \\```sh
        \\native dev     # build and run the app with hot reload
        \\native test    # run the app's test suite
        \\native build   # produce a ReleaseFast binary in zig-out/bin/
        \\native check   # validate src/*.native markup and app.zon
        \\```
        \\
        \\## Hot reload
        \\
        \\`src/app.native` is watched while `native dev` runs: edit it and the
        \\window updates within ~2s without losing model state. Parse failures
        \\keep the last good view.
        \\
        \\## Owning the build
        \\
        \\Need custom build logic? `native eject` writes a build.zig and
        \\build.zig.zon into the app — from then on the `native` verbs drive
        \\your files through `zig build` and never regenerate them.
        \\
    );
    return out.toOwnedSlice(allocator);
}

fn writeNativeApp(allocator: std.mem.Allocator, io: std.Io, app_dir: std.Io.Dir, names: TemplateNames, framework_path: []const u8) !void {
    try app_dir.createDirPath(io, ".vscode");
    try app_dir.createDirPath(io, ".github/workflows");

    const build_zig = try nativeBuildZig(allocator, names);
    defer allocator.free(build_zig);
    const build_zon = try nativeBuildZon(allocator, names, framework_path);
    defer allocator.free(build_zon);
    const main_zig = try nativeMainZig(allocator, names);
    defer allocator.free(main_zig);
    const tests_zig = try nativeTestsZig(allocator, names);
    defer allocator.free(tests_zig);
    const app_zon = try nativeAppZon(allocator, names);
    defer allocator.free(app_zon);
    const readme_md = try nativeReadme(allocator, names, framework_path);
    defer allocator.free(readme_md);
    const ci_yaml = try nativeCiYaml(allocator, names, framework_path);
    defer allocator.free(ci_yaml);

    try writeFile(app_dir, io, "build.zig", build_zig);
    try writeFile(app_dir, io, "build.zig.zon", build_zon);
    try writeFile(app_dir, io, "src/main.zig", main_zig);
    try writeFile(app_dir, io, "src/app.native", nativeAppMarkup());
    try writeFile(app_dir, io, "src/tests.zig", tests_zig);
    try writeFile(app_dir, io, "app.zon", app_zon);
    try writeFile(app_dir, io, "assets/icon.png", default_icon_png);
    try writeFile(app_dir, io, ".vscode/settings.json", nativeVscodeSettings());
    try writeFile(app_dir, io, ".github/workflows/ci.yml", ci_yaml);
    try writeFile(app_dir, io, ".gitignore", nativeGitignore());
    try writeFile(app_dir, io, "README.md", readme_md);
}

fn nativeBuildZig(allocator: std.mem.Allocator, names: TemplateNames) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator,
        \\const std = @import("std");
        \\const native_sdk = @import("native_sdk");
        \\
        \\pub fn build(b: *std.Build) void {
        \\    native_sdk.addApp(b, b.dependency("native_sdk", .{}), .{ .name =
    );
    try out.appendSlice(allocator, " ");
    try appendZigString(&out, allocator, names.package_name);
    try out.appendSlice(allocator,
        \\ });
        \\}
        \\
    );
    return out.toOwnedSlice(allocator);
}

fn nativeBuildZon(allocator: std.mem.Allocator, names: TemplateNames, framework_path: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator,
        \\.{
        \\    .name = .
    );
    try out.appendSlice(allocator, names.module_name);
    try out.appendSlice(allocator,
        \\,
        \\    .fingerprint = 0x
    );
    var fingerprint_buffer: [16]u8 = undefined;
    const fingerprint = try std.fmt.bufPrint(&fingerprint_buffer, "{x}", .{fingerprintForName(names.module_name)});
    try out.appendSlice(allocator, fingerprint);
    try out.appendSlice(allocator,
        \\,
        \\    .version = "0.1.0",
        \\    .minimum_zig_version = "0.16.0",
        \\    .dependencies = .{ .native_sdk = .{ .path =
    );
    try out.appendSlice(allocator, " ");
    try appendZigString(&out, allocator, framework_path);
    try out.appendSlice(allocator,
        \\ } },
        \\    .paths = .{ "build.zig", "build.zig.zon", "src", "assets", "app.zon", "README.md" },
        \\}
        \\
    );
    return out.toOwnedSlice(allocator);
}

fn nativeMainZig(allocator: std.mem.Allocator, names: TemplateNames) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator,
        \\//! A minimal native-rendered Native SDK app: the view lives in
        \\//! `app.native` (embedded into the binary, and watched for hot reload in
        \\//! dev); this file is the logic: `Model`, `Msg`, and `update`.
        \\
        \\const std = @import("std");
        \\const runner = @import("runner");
        \\const native_sdk = @import("native_sdk");
        \\
        \\pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);
        \\
        \\const canvas = native_sdk.canvas;
        \\const geometry = native_sdk.geometry;
        \\
        \\const canvas_label = "main-canvas";
        \\const window_width: f32 = 480;
        \\const window_height: f32 = 320;
        \\
        \\const app_permissions = [_][]const u8{ native_sdk.security.permission_command, native_sdk.security.permission_view };
        \\const shell_views = [_]native_sdk.ShellView{
        \\    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .role = "Counter canvas", .accessibility_label = "Counter", .gpu_backend = .metal, .gpu_pixel_format = .bgra8_unorm, .gpu_present_mode = .timer, .gpu_alpha_mode = .@"opaque", .gpu_color_space = .srgb, .gpu_vsync = true },
        \\};
        \\const shell_windows = [_]native_sdk.ShellWindow{.{
        \\    .label = "main",
        \\    .title =
    );
    try out.appendSlice(allocator, " ");
    try appendZigString(&out, allocator, names.display_name);
    try out.appendSlice(allocator,
        \\,
        \\    .width = window_width,
        \\    .height = window_height,
        \\    .restore_state = false,
        \\    .views = &shell_views,
        \\}};
        \\const shell_scene: native_sdk.ShellConfig = .{ .windows = &shell_windows };
        \\
        \\// ------------------------------------------------------------------ model
        \\
        \\pub const Msg = union(enum) {
        \\    increment,
        \\    decrement,
        \\    reset,
        \\};
        \\
        \\pub const Model = struct {
        \\    count: i64 = 0,
        \\};
        \\
        \\pub fn update(model: *Model, msg: Msg) void {
        \\    switch (msg) {
        \\        .increment => model.count += 1,
        \\        .decrement => model.count -= 1,
        \\        .reset => model.count = 0,
        \\    }
        \\}
        \\
        \\// ------------------------------------------------------------------- view
        \\
        \\pub const AppUi = canvas.Ui(Msg);
        \\pub const app_markup = @embedFile("app.native");
        \\
        \\// -------------------------------------------------------------------- app
        \\
        \\const CounterApp = native_sdk.UiApp(Model, Msg);
        \\
        \\pub fn initialModel() Model {
        \\    return .{};
        \\}
        \\
        \\pub fn main(init: std.process.Init) !void {
        \\    // The app struct (and any real Model) is multi-MB: `create`
        \\    // heap-allocates and constructs everything in place, so neither
        \\    // ever rides the stack. Mutate `app_state.model` through the
        \\    // pointer before running if boot state is not the default.
        \\    const app_state = try CounterApp.create(std.heap.page_allocator, .{
        \\        .name =
    );
    try out.appendSlice(allocator, " ");
    try appendZigString(&out, allocator, names.package_name);
    try out.appendSlice(allocator,
        \\,
        \\        .scene = shell_scene,
        \\        .canvas_label = canvas_label,
        \\        .update = update,
        \\        .markup = .{ .source = app_markup, .watch_path = "src/app.native", .io = init.io },
        \\    });
        \\    defer app_state.destroy();
        \\    app_state.model = initialModel();
        \\
        \\    try runner.runWithOptions(app_state.app(), .{
        \\        .app_name =
    );
    try out.appendSlice(allocator, " ");
    try appendZigString(&out, allocator, names.package_name);
    try out.appendSlice(allocator,
        \\,
        \\        .window_title =
    );
    try out.appendSlice(allocator, " ");
    try appendZigString(&out, allocator, names.display_name);
    try out.appendSlice(allocator,
        \\,
        \\        .bundle_id =
    );
    try out.appendSlice(allocator, " ");
    try appendZigString(&out, allocator, names.app_id);
    try out.appendSlice(allocator,
        \\,
        \\        .icon_path = "assets/icon.png",
        \\        .default_frame = geometry.RectF.init(0, 0, window_width, window_height),
        \\        .restore_state = false,
        \\        .js_window_api = false,
        \\        .security = .{
        \\            .permissions = &app_permissions,
        \\            .navigation = .{ .allowed_origins = &.{ "zero://inline", "zero://app" } },
        \\        },
        \\    }, init);
        \\}
        \\
        \\test {
        \\    _ = @import("tests.zig");
        \\}
        \\
    );
    return out.toOwnedSlice(allocator);
}

fn nativeAppMarkup() []const u8 {
    return
    \\<!-- The whole view. Embedded into the binary and hot-reloaded in dev:
    \\     edit this file while the app runs and the window updates without
    \\     losing the count. Validate with: native markup check src/app.native -->
    \\<column gap="12" padding="16">
    \\  <row gap="8" cross="center">
    \\    <text grow="1">Counter</text>
    \\    <button size="sm" variant="ghost" on-press="reset">Reset</button>
    \\  </row>
    \\  <row gap="8" main="center" cross="center" grow="1">
    \\    <button variant="secondary" on-press="decrement">-</button>
    \\    <text>{count}</text>
    \\    <button variant="primary" on-press="increment">+</button>
    \\  </row>
    \\  <status-bar>count: {count}</status-bar>
    \\</column>
    \\
    ;
}

fn nativeTestsZig(allocator: std.mem.Allocator, names: TemplateNames) ![]const u8 {
    _ = names;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator,
        \\const std = @import("std");
        \\const native_sdk = @import("native_sdk");
        \\const main = @import("main.zig");
        \\
        \\const canvas = native_sdk.canvas;
        \\const testing = std.testing;
        \\
        \\const AppUi = main.AppUi;
        \\const Model = main.Model;
        \\const Msg = main.Msg;
        \\
        \\const AppMarkup = canvas.MarkupView(Model, Msg);
        \\
        \\fn buildTree(arena: std.mem.Allocator, model: *const Model) !AppUi.Tree {
        \\    var view = try AppMarkup.init(arena, main.app_markup);
        \\    var ui = AppUi.init(arena);
        \\    const node = view.build(&ui, model) catch |err| {
        \\        // Name the app.native position instead of leaving a bare error
        \\        // trace: the usual causes are a binding without a matching
        \\        // Model field or an on-* message without a Msg arm.
        \\        if (err == error.MarkupBuild) {
        \\            std.debug.print("app.native:{d}:{d}: {s}\n", .{ view.diagnostic.line, view.diagnostic.column, view.diagnostic.message });
        \\        }
        \\        return err;
        \\    };
        \\    return ui.finalize(node);
        \\}
        \\
        \\fn findByText(widget: canvas.Widget, kind: canvas.WidgetKind, text: []const u8) ?canvas.Widget {
        \\    if (widget.kind == kind and std.mem.eql(u8, widget.text, text)) return widget;
        \\    for (widget.children) |child| {
        \\        if (findByText(child, kind, text)) |found| return found;
        \\    }
        \\    return null;
        \\}
        \\
        \\/// A miss fails the test with the mismatch spelled out instead of a
        \\/// null-unwrap panic: the usual cause is app.native and this test
        \\/// drifting apart after an edit.
        \\fn expectByText(widget: canvas.Widget, kind: canvas.WidgetKind, text: []const u8) !canvas.Widget {
        \\    return findByText(widget, kind, text) orelse {
        \\        std.debug.print("no {t} with text \"{s}\" in the view - if you changed app.native, update this test to match\n", .{ kind, text });
        \\        return error.WidgetNotFound;
        \\    };
        \\}
        \\
        \\test "clicking the buttons drives the model through typed dispatch" {
        \\    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        \\    defer arena_state.deinit();
        \\    const arena = arena_state.allocator();
        \\
        \\    var model = main.initialModel();
        \\
        \\    var tree = try buildTree(arena, &model);
        \\    _ = try expectByText(tree.root, .text, "0");
        \\    _ = try expectByText(tree.root, .status_bar, "count: 0");
        \\
        \\    // Click "+": the count increments and the view rebuilds with the
        \\    // new value, keeping widget ids stable.
        \\    const plus = try expectByText(tree.root, .button, "+");
        \\    main.update(&model, tree.msgForPointer(plus.id, .up).?);
        \\    try testing.expectEqual(@as(i64, 1), model.count);
        \\
        \\    tree = try buildTree(arena, &model);
        \\    _ = try expectByText(tree.root, .text, "1");
        \\    _ = try expectByText(tree.root, .status_bar, "count: 1");
        \\    try testing.expectEqual(plus.id, (try expectByText(tree.root, .button, "+")).id);
        \\
        \\    // Click "-" twice: the count goes negative.
        \\    const minus = try expectByText(tree.root, .button, "-");
        \\    main.update(&model, tree.msgForPointer(minus.id, .up).?);
        \\    main.update(&model, tree.msgForPointer(minus.id, .up).?);
        \\    try testing.expectEqual(@as(i64, -1), model.count);
        \\
        \\    // Click "Reset": back to zero.
        \\    tree = try buildTree(arena, &model);
        \\    const reset = try expectByText(tree.root, .button, "Reset");
        \\    main.update(&model, tree.msgForPointer(reset.id, .up).?);
        \\    try testing.expectEqual(@as(i64, 0), model.count);
        \\
        \\    tree = try buildTree(arena, &model);
        \\    _ = try expectByText(tree.root, .status_bar, "count: 0");
        \\}
        \\
        \\test "the view lays out through the canvas engine" {
        \\    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        \\    defer arena_state.deinit();
        \\
        \\    var model = main.initialModel();
        \\    const tree = try buildTree(arena_state.allocator(), &model);
        \\
        \\    var nodes: [64]canvas.WidgetLayoutNode = undefined;
        \\    const layout = try canvas.layoutWidgetTree(tree.root, native_sdk.geometry.RectF.init(0, 0, 480, 320), &nodes);
        \\    try testing.expect(layout.nodes.len > 0);
        \\
        \\    const plus = try expectByText(tree.root, .button, "+");
        \\    var saw_button = false;
        \\    for (layout.nodes) |node| {
        \\        if (node.widget.id == plus.id) saw_button = true;
        \\    }
        \\    try testing.expect(saw_button);
        \\}
        \\
    );
    return out.toOwnedSlice(allocator);
}

fn nativeAppZon(allocator: std.mem.Allocator, names: TemplateNames) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator,
        \\.{
        \\    .id =
    );
    try out.appendSlice(allocator, " ");
    try appendZigString(&out, allocator, names.app_id);
    try out.appendSlice(allocator,
        \\,
        \\    .name =
    );
    try out.appendSlice(allocator, " ");
    try appendZigString(&out, allocator, names.package_name);
    try out.appendSlice(allocator,
        \\,
        \\    .display_name =
    );
    try out.appendSlice(allocator, " ");
    try appendZigString(&out, allocator, names.display_name);
    try out.appendSlice(allocator,
        \\,
        \\    .description = "A counter that lives in one native window.",
        \\    .version = "0.1.0",
        \\    .icons = .{"assets/icon.png"},
        \\    .platforms = .{"macos"},
        \\    .permissions = .{ "view", "command" },
        \\    .capabilities = .{ "native_views", "gpu_surfaces" },
        \\    .shell = .{
        \\        .windows = .{
        \\            .{
        \\                .label = "main",
        \\                .title =
    );
    try out.appendSlice(allocator, " ");
    try appendZigString(&out, allocator, names.display_name);
    try out.appendSlice(allocator,
        \\,
        \\                .width = 480,
        \\                .height = 320,
        \\                .restore_state = false,
        \\                .restore_policy = "center_on_primary",
        \\                .views = .{
        \\                    .{ .label = "main-canvas", .kind = "gpu_surface", .fill = true, .role = "Counter canvas", .accessibility_label = "Counter", .gpu_backend = "metal", .gpu_pixel_format = "bgra8_unorm", .gpu_present_mode = "timer", .gpu_alpha_mode = "opaque", .gpu_color_space = "srgb", .gpu_vsync = true },
        \\                },
        \\            },
        \\        },
        \\    },
        \\    .security = .{
        \\        .navigation = .{
        \\            .allowed_origins = .{ "zero://app", "zero://inline" },
        \\            .external_links = .{ .action = "deny" },
        \\        },
        \\    },
        \\    .web_engine = "system",
        \\    .cef = .{ .dir = "third_party/cef/macos", .auto_install = false },
        \\}
        \\
    );
    return out.toOwnedSlice(allocator);
}

fn nativeVscodeSettings() []const u8 {
    return
    \\{
    \\  "files.associations": { "*.native": "html" }
    \\}
    \\
    ;
}

fn nativeGitignore() []const u8 {
    return
    \\zig-out/
    \\.zig-cache/
    \\
    ;
}

fn nativeReadme(allocator: std.mem.Allocator, names: TemplateNames, framework_path: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "# ");
    try out.appendSlice(allocator, names.display_name);
    try out.appendSlice(allocator,
        \\
        \\
        \\A native-rendered Native SDK app: the view lives in `src/app.native`
        \\(declarative markup) and the logic in `src/main.zig` (`Model`, `Msg`,
        \\`update`). No WebView, no npm — the UI renders on a GPU surface.
        \\
        \\## Commands
        \\
        \\```sh
        \\zig build run                          # build and launch the app
        \\zig build test                         # run the full-loop UI tests
        \\native markup check src/app.native   # validate the markup without building
        \\```
        \\
        \\## Hot reload
        \\
        \\`src/app.native` is embedded into the binary and watched during development:
        \\edit it while the app runs and the window updates within ~2s without
        \\losing model state. Parse failures keep the last good view.
        \\
        \\## Framework path
        \\
        \\`build.zig.zon` points the `native_sdk` dependency at:
        \\
        \\```text
        \\
    );
    try out.appendSlice(allocator, framework_path);
    try out.appendSlice(allocator,
        \\
        \\```
        \\
        \\Edit `.dependencies.native_sdk.path` in `build.zig.zon` if you move
        \\this app or the framework checkout.
        \\
    );
    return out.toOwnedSlice(allocator);
}

/// GitHub Actions workflow for a native-rendered app: a null-platform
/// logic-test job plus a Linux Xvfb automation smoke job that launches the
/// real binary and asserts on the accessibility snapshot. The generated
/// file belongs to the user, like everything init writes.
fn nativeCiYaml(allocator: std.mem.Allocator, names: TemplateNames, framework_path: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator,
        \\name: CI
        \\
        \\on:
        \\  pull_request:
        \\  push:
        \\    branches:
        \\      - main
        \\
        \\permissions:
        \\  contents: read
        \\
        \\env:
        \\  # build.zig.zon expects the Native SDK framework checkout at this
        \\  # path, relative to the repository root. Adjust both together if
        \\  # your framework checkout lives elsewhere.
        \\  NATIVE_SDK_PATH:
    );
    try out.appendSlice(allocator, " ");
    try appendEscapedString(&out, allocator, framework_path);
    try out.appendSlice(allocator,
        \\
        \\
        \\jobs:
        \\  test:
        \\    name: Logic Tests
        \\    runs-on: ubuntu-latest
        \\    steps:
        \\      - uses: actions/checkout@v4
        \\      - uses: mlugg/setup-zig@v2
        \\        with:
        \\          version: 0.16.0
        \\      - name: Fetch native-sdk
        \\        run: |
        \\          if [ ! -f "$NATIVE_SDK_PATH/build.zig" ]; then
        \\            git clone --depth 1 https://github.com/vercel-labs/native.git "$NATIVE_SDK_PATH"
        \\          fi
        \\      - run: zig build test -Dplatform=null
        \\
        \\  smoke:
        \\    name: Automation Smoke (Linux)
        \\    runs-on: ubuntu-latest
        \\    steps:
        \\      - uses: actions/checkout@v4
        \\      - uses: mlugg/setup-zig@v2
        \\        with:
        \\          version: 0.16.0
        \\      - name: Install GTK and Xvfb
        \\        # No WebKitGTK dev package: this app declares no web use, so its
        \\        # Linux host compiles without the embedded web layer and never
        \\        # links WebKitGTK (install it alongside a .frontend block or
        \\        # the "webview" capability if the app grows web content).
        \\        run: sudo apt-get update && sudo apt-get install -y libgtk-4-dev xvfb
        \\      - name: Fetch native-sdk
        \\        run: |
        \\          if [ ! -f "$NATIVE_SDK_PATH/build.zig" ]; then
        \\            git clone --depth 1 https://github.com/vercel-labs/native.git "$NATIVE_SDK_PATH"
        \\          fi
        \\      - name: Build the Native SDK CLI
        \\        run: cd "$NATIVE_SDK_PATH" && zig build
        \\      - name: Build and drive the app headless
        \\        run: |
        \\          set -euo pipefail
        \\          cli="$NATIVE_SDK_PATH/zig-out/bin/native"
        \\          zig build -Dplatform=linux -Dweb-engine=system -Dautomation=true
        \\          rm -rf .zig-cache/native-sdk-automation
        \\          xvfb-run -a ./zig-out/bin/
    );
    try out.appendSlice(allocator, names.package_name);
    try out.appendSlice(allocator,
        \\ &
        \\          pid=$!
        \\          trap 'kill "$pid" >/dev/null 2>&1 || true' EXIT
        \\          "$cli" automate wait
        \\          "$cli" automate assert 'gpu_nonblank=true' 'role=button name="Reset"' 'count: 0'
        \\          "$cli" automate screenshot main-canvas
        \\          test -s .zig-cache/native-sdk-automation/screenshot-main-canvas.png
        \\
    );
    return out.toOwnedSlice(allocator);
}

/// GitHub Actions workflow for a web-frontend app: null-platform logic
/// tests, pointing `-Dnative-sdk-path` at a framework checkout fetched in
/// CI (web templates default to a machine-local path).
fn frontendCiYaml(allocator: std.mem.Allocator, names: TemplateNames) ![]const u8 {
    _ = names;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator,
        \\name: CI
        \\
        \\on:
        \\  pull_request:
        \\  push:
        \\    branches:
        \\      - main
        \\
        \\permissions:
        \\  contents: read
        \\
        \\env:
        \\  # Where CI keeps the Native SDK framework checkout; the build
        \\  # override below points the app at it.
        \\  NATIVE_SDK_PATH: "../native-sdk"
        \\
        \\jobs:
        \\  test:
        \\    name: Logic Tests
        \\    runs-on: ubuntu-latest
        \\    steps:
        \\      - uses: actions/checkout@v4
        \\      - uses: mlugg/setup-zig@v2
        \\        with:
        \\          version: 0.16.0
        \\      - name: Fetch native-sdk
        \\        run: |
        \\          if [ ! -f "$NATIVE_SDK_PATH/build.zig" ]; then
        \\            git clone --depth 1 https://github.com/vercel-labs/native.git "$NATIVE_SDK_PATH"
        \\          fi
        \\      - run: zig build test -Dplatform=null -Dnative-sdk-path="$NATIVE_SDK_PATH"
        \\
    );
    return out.toOwnedSlice(allocator);
}

fn writeFile(dir: std.Io.Dir, io: std.Io, path: []const u8, bytes: []const u8) !void {
    try dir.writeFile(io, .{ .sub_path = path, .data = bytes });
}

const TemplateNames = struct {
    package_name: []const u8,
    module_name: []const u8,
    display_name: []const u8,
    app_id: []const u8,

    fn init(allocator: std.mem.Allocator, app_name: []const u8) !TemplateNames {
        const package_name = try normalizePackageName(allocator, app_name);
        errdefer allocator.free(package_name);
        const module_name = try normalizeModuleName(allocator, package_name);
        errdefer allocator.free(module_name);
        const display_name = try displayName(allocator, package_name);
        errdefer allocator.free(display_name);
        const app_id = try std.fmt.allocPrint(allocator, "dev.native_sdk.{s}", .{package_name});
        errdefer allocator.free(app_id);
        return .{
            .package_name = package_name,
            .module_name = module_name,
            .display_name = display_name,
            .app_id = app_id,
        };
    }

    fn deinit(self: TemplateNames, allocator: std.mem.Allocator) void {
        allocator.free(self.package_name);
        allocator.free(self.module_name);
        allocator.free(self.display_name);
        allocator.free(self.app_id);
    }
};

fn buildZig(allocator: std.mem.Allocator, names: TemplateNames, framework_path: []const u8, frontend: Frontend) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator,
        \\const std = @import("std");
        \\
        \\const PlatformOption = enum {
        \\    auto,
        \\    @"null",
        \\    macos,
        \\    linux,
        \\    windows,
        \\};
        \\
        \\const TraceOption = enum {
        \\    off,
        \\    events,
        \\    runtime,
        \\    all,
        \\};
        \\
        \\const WebEngineOption = enum {
        \\    system,
        \\    chromium,
        \\};
        \\
        \\const WebLayerOption = enum {
        \\    auto,
        \\    include,
        \\    exclude,
        \\};
        \\
        \\const PackageTarget = enum {
        \\    macos,
        \\    windows,
        \\    linux,
        \\};
        \\
        \\const default_native_sdk_path =
    );
    try appendZigString(&out, allocator, framework_path);
    try out.appendSlice(allocator, ";\nconst app_exe_name = ");
    try appendZigString(&out, allocator, names.package_name);
    try out.appendSlice(allocator,
        \\;
        \\
        \\pub fn build(b: *std.Build) void {
        \\    const target = nativeSdkTarget(b);
        \\    const optimize = b.standardOptimizeOption(.{});
        \\    const platform_option = b.option(PlatformOption, "platform", "Desktop backend: auto, null, macos, linux, windows") orelse .auto;
        \\    const trace_option = b.option(TraceOption, "trace", "Trace output: off, events, runtime, all") orelse .events;
        \\    const debug_overlay = b.option(bool, "debug-overlay", "Enable debug overlay output") orelse false;
        \\    const automation_enabled = b.option(bool, "automation", "Enable Native SDK automation artifacts") orelse false;
        \\    const js_bridge_enabled = b.option(bool, "js-bridge", "Enable optional JavaScript bridge stubs") orelse false;
        \\    const web_engine_override = b.option(WebEngineOption, "web-engine", "Override app.zon web engine: system, chromium");
        \\    const web_layer_override = b.option(WebLayerOption, "web-layer", "Override app.zon webview_layer: auto, include, exclude");
        \\    const cef_dir_override = b.option([]const u8, "cef-dir", "Override CEF root directory for Chromium builds");
        \\    const cef_auto_install_override = b.option(bool, "cef-auto-install", "Override app.zon CEF auto-install setting");
        \\    const package_target = b.option(PackageTarget, "package-target", "Package target: macos, windows, linux") orelse .macos;
        \\    const native_sdk_path = b.option([]const u8, "native-sdk-path", "Path to the Native SDK framework checkout") orelse default_native_sdk_path;
        \\    const optimize_name = @tagName(optimize);
        \\    const selected_platform: PlatformOption = switch (platform_option) {
        \\        .auto => if (target.result.os.tag == .macos) .macos else if (target.result.os.tag == .linux) .linux else if (target.result.os.tag == .windows) .windows else .@"null",
        \\        else => platform_option,
        \\    };
        \\    if (selected_platform == .macos and target.result.os.tag != .macos) {
        \\        @panic("-Dplatform=macos requires a macOS target");
        \\    }
        \\    if (selected_platform == .linux and target.result.os.tag != .linux) {
        \\        @panic("-Dplatform=linux requires a Linux target");
        \\    }
        \\    if (selected_platform == .windows and target.result.os.tag != .windows) {
        \\        @panic("-Dplatform=windows requires a Windows target");
        \\    }
        \\    const app_config = appManifestBuildConfig(b);
        \\    const web_engine = web_engine_override orelse app_config.web_engine;
        \\    const cef_dir = cef_dir_override orelse defaultCefDir(selected_platform, app_config.cef_dir);
        \\    const cef_auto_install = cef_auto_install_override orelse app_config.cef_auto_install;
        \\    if (web_engine == .chromium and selected_platform != .macos) {
        \\        @panic("-Dweb-engine=chromium currently requires -Dplatform=macos");
        \\    }
        \\    const web_layer = resolveWebLayer(app_config, web_engine, web_layer_override);
        \\
        \\    const native_sdk_mod = nativeSdkModule(b, target, optimize, native_sdk_path);
        \\    const options = b.addOptions();
        \\    options.addOption([]const u8, "platform", switch (selected_platform) {
        \\        .auto => unreachable,
        \\        .@"null" => "null",
        \\        .macos => "macos",
        \\        .linux => "linux",
        \\        .windows => "windows",
        \\    });
        \\    options.addOption([]const u8, "trace", @tagName(trace_option));
        \\    options.addOption([]const u8, "web_engine", @tagName(web_engine));
        \\    options.addOption(bool, "debug_overlay", debug_overlay);
        \\    options.addOption(bool, "automation", automation_enabled);
        \\    options.addOption(bool, "js_bridge", js_bridge_enabled);
        \\    options.addOption(bool, "web_layer", web_layer);
        \\    const options_mod = options.createModule();
        \\
        \\    const runner_mod = localModule(b, target, optimize, "src/runner.zig");
        \\    runner_mod.addImport("native_sdk", native_sdk_mod);
        \\    runner_mod.addImport("build_options", options_mod);
        \\    runner_mod.addImport("app_manifest_zon", b.createModule(.{ .root_source_file = b.path("app.zon") }));
        \\
        \\    const app_mod = localModule(b, target, optimize, "src/main.zig");
        \\    app_mod.addImport("native_sdk", native_sdk_mod);
        \\    app_mod.addImport("runner", runner_mod);
        \\    const exe = b.addExecutable(.{
        \\        .name = app_exe_name,
        \\        .root_module = app_mod,
        \\    });
        \\    linkPlatform(b, target, app_mod, exe, selected_platform, web_engine, web_layer, native_sdk_path, cef_dir, cef_auto_install);
        \\    b.installArtifact(exe);
        \\
        \\    const frontend_install = b.addSystemCommand(&.{ "npm", "install", "--prefix", "frontend" });
        \\    const frontend_install_step = b.step("frontend-install", "Install frontend dependencies");
        \\    frontend_install_step.dependOn(&frontend_install.step);
        \\
        \\    const frontend_build = b.addSystemCommand(&.{ "npm", "--prefix", "frontend", "run", "build" });
        \\    frontend_build.step.dependOn(&frontend_install.step);
        \\    const frontend_step = b.step("frontend-build", "Build the frontend");
        \\    frontend_step.dependOn(&frontend_build.step);
        \\
        \\    const run = b.addRunArtifact(exe);
        \\    run.step.dependOn(&frontend_build.step);
        \\    addCefRuntimeRunFiles(b, target, run, exe, web_engine, cef_dir);
        \\    addWebView2RuntimeRunFiles(b, target, run, web_engine, web_layer, native_sdk_path);
        \\    const run_step = b.step("run", "Run the app");
        \\    run_step.dependOn(&run.step);
        \\
        \\    const dev = b.addSystemCommand(&.{ "native", "dev", "--manifest", "app.zon", "--binary" });
        \\    dev.addFileArg(exe.getEmittedBin());
        \\    addWebView2RuntimeRunFiles(b, target, dev, web_engine, web_layer, native_sdk_path);
        \\    dev.step.dependOn(&exe.step);
        \\    dev.step.dependOn(&frontend_install.step);
        \\    const dev_step = b.step("dev", "Run the frontend dev server and native shell");
        \\    dev_step.dependOn(&dev.step);
        \\
        \\    const package = b.addSystemCommand(&.{
        \\        "native",
        \\        "package",
        \\        "--target",
        \\        @tagName(package_target),
        \\        "--manifest",
        \\        "app.zon",
        \\        "--assets",
    );
    try appendZigString(&out, allocator, frontend.distDir());
    try out.appendSlice(allocator,
        \\,
        \\        "--optimize",
        \\        optimize_name,
        \\        "--output",
        \\        b.fmt("zig-out/package/{s}-0.1.0-{s}-{s}{s}", .{ app_exe_name, @tagName(package_target), optimize_name, packageSuffix(package_target) }),
        \\        "--binary",
        \\    });
        \\    // The CLI resolves SDK-owned package inputs (the vendored WebView2
        \\    // loader) from the framework root; a PATH-resolved `native` could
        \\    // belong to a different checkout than the one this build compiled
        \\    // against, so hand the same root over explicitly.
        \\    package.setEnvironmentVariable("NATIVE_SDK_PATH", b.pathFromRoot(native_sdk_path));
        \\    package.addFileArg(exe.getEmittedBin());
        \\    package.addArgs(&.{ "--web-engine", @tagName(web_engine), "--cef-dir", cef_dir });
        \\    // Forward the RESOLVED web-layer decision, never the raw inputs:
        \\    // this graph already decided web vs native-only for the exe it is
        \\    // packaging (app.zon declarations plus -Dweb-layer/-Dweb-engine),
        \\    // and the CLI re-inferring from app.zon alone would miss a
        \\    // flag-driven override. Handing over the decision itself makes
        \\    // exe/package agreement structural.
        \\    package.addArgs(&.{ "--web-layer", if (web_layer) "include" else "exclude" });
        \\    if (cef_auto_install) package.addArg("--cef-auto-install");
        \\    package.step.dependOn(&exe.step);
        \\    package.step.dependOn(&frontend_build.step);
        \\    const package_step = b.step("package", "Create a local package artifact");
        \\    package_step.dependOn(&package.step);
        \\
        \\    const tests = b.addTest(.{ .root_module = app_mod });
        \\    const test_step = b.step("test", "Run tests");
        \\    test_step.dependOn(&b.addRunArtifact(tests).step);
        \\}
        \\
        \\fn nativeSdkTarget(b: *std.Build) std.Build.ResolvedTarget {
        \\    const target = b.standardTargetOptions(.{});
        \\    if (target.result.os.tag != .macos) return target;
        \\
        \\    if (b.sysroot == null) {
        \\        b.sysroot = macosSdkPath(b) orelse b.sysroot;
        \\    }
        \\
        \\    var query = target.query;
        \\    query.os_tag = .macos;
        \\    query.os_version_min = .{ .semver = .{ .major = 11, .minor = 0, .patch = 0 } };
        \\    return b.resolveTargetQuery(query);
        \\}
        \\
        \\fn macosSdkPath(b: *std.Build) ?[]const u8 {
        \\    if (b.graph.environ_map.get("SDKROOT")) |sdkroot| {
        \\        if (sdkroot.len > 0) return sdkroot;
        \\    }
        \\
        \\    const result = std.process.run(b.allocator, b.graph.io, .{
        \\        .argv = &.{ "xcrun", "--sdk", "macosx", "--show-sdk-path" },
        \\        .stdout_limit = .limited(4096),
        \\        .stderr_limit = .limited(4096),
        \\    }) catch return null;
        \\    defer b.allocator.free(result.stderr);
        \\    if (result.term != .exited or result.term.exited != 0) {
        \\        b.allocator.free(result.stdout);
        \\        return null;
        \\    }
        \\    return std.mem.trimEnd(u8, result.stdout, "\r\n");
        \\}
        \\
        \\fn localModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, path: []const u8) *std.Build.Module {
        \\    return b.createModule(.{
        \\        .root_source_file = b.path(path),
        \\        .target = target,
        \\        .optimize = optimize,
        \\    });
        \\}
        \\
        \\fn nativeSdkPath(b: *std.Build, native_sdk_path: []const u8, sub_path: []const u8) std.Build.LazyPath {
        \\    return .{ .cwd_relative = b.pathJoin(&.{ native_sdk_path, sub_path }) };
        \\}
        \\
        \\fn nativeSdkModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, native_sdk_path: []const u8) *std.Build.Module {
        \\    const geometry_mod = externalModule(b, target, optimize, native_sdk_path, "src/primitives/geometry/root.zig");
        \\    const assets_mod = externalModule(b, target, optimize, native_sdk_path, "src/primitives/assets/root.zig");
        \\    const app_dirs_mod = externalModule(b, target, optimize, native_sdk_path, "src/primitives/app_dirs/root.zig");
        \\    const trace_mod = externalModule(b, target, optimize, native_sdk_path, "src/primitives/trace/root.zig");
        \\    const app_manifest_mod = externalModule(b, target, optimize, native_sdk_path, "src/primitives/app_manifest/root.zig");
        \\    const diagnostics_mod = externalModule(b, target, optimize, native_sdk_path, "src/primitives/diagnostics/root.zig");
        \\    const platform_info_mod = externalModule(b, target, optimize, native_sdk_path, "src/primitives/platform_info/root.zig");
        \\    const json_mod = externalModule(b, target, optimize, native_sdk_path, "src/primitives/json/root.zig");
        \\    const canvas_mod = externalModule(b, target, optimize, native_sdk_path, "src/primitives/canvas/root.zig");
        \\    canvas_mod.addImport("geometry", geometry_mod);
        \\    canvas_mod.addImport("json", json_mod);
        \\    const debug_mod = externalModule(b, target, optimize, native_sdk_path, "src/debug/root.zig");
        \\    debug_mod.addImport("app_dirs", app_dirs_mod);
        \\    debug_mod.addImport("trace", trace_mod);
        \\
        \\    const native_sdk_mod = externalModule(b, target, optimize, native_sdk_path, "src/root.zig");
        \\    native_sdk_mod.addImport("geometry", geometry_mod);
        \\    native_sdk_mod.addImport("assets", assets_mod);
        \\    native_sdk_mod.addImport("app_dirs", app_dirs_mod);
        \\    native_sdk_mod.addImport("trace", trace_mod);
        \\    native_sdk_mod.addImport("app_manifest", app_manifest_mod);
        \\    native_sdk_mod.addImport("diagnostics", diagnostics_mod);
        \\    native_sdk_mod.addImport("platform_info", platform_info_mod);
        \\    native_sdk_mod.addImport("json", json_mod);
        \\    native_sdk_mod.addImport("canvas", canvas_mod);
        \\    return native_sdk_mod;
        \\}
        \\
        \\fn externalModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, native_sdk_path: []const u8, path: []const u8) *std.Build.Module {
        \\    return b.createModule(.{
        \\        .root_source_file = nativeSdkPath(b, native_sdk_path, path),
        \\        .target = target,
        \\        .optimize = optimize,
        \\    });
        \\}
        \\
        \\fn linkPlatform(b: *std.Build, target: std.Build.ResolvedTarget, app_mod: *std.Build.Module, exe: *std.Build.Step.Compile, platform: PlatformOption, web_engine: WebEngineOption, web_layer: bool, native_sdk_path: []const u8, cef_dir: []const u8, cef_auto_install: bool) void {
        \\    if (platform == .macos) {
        \\        switch (web_engine) {
        \\            .system => {
        \\                const sdk_include = if (b.sysroot) |sysroot| b.fmt("-I{s}/usr/include", .{sysroot}) else "";
        \\                const flags: []const []const u8 = if (b.sysroot) |sysroot| &.{ "-fobjc-arc", "-fno-sanitize=builtin", "-ObjC", "-mmacosx-version-min=11.0", "-isysroot", sysroot, sdk_include } else &.{ "-fobjc-arc", "-fno-sanitize=builtin", "-ObjC", "-mmacosx-version-min=11.0" };
        \\                app_mod.addCSourceFile(.{ .file = nativeSdkPath(b, native_sdk_path, "src/platform/macos/appkit_host.m"), .flags = flags });
        \\                app_mod.linkFramework("WebKit", .{});
        \\            },
        \\            .chromium => {
        \\                const cef_check = addCefCheck(b, target, cef_dir);
        \\                if (cef_auto_install) {
        \\                    const cef_auto = b.addSystemCommand(&.{ "native", "cef", "install", "--dir", cef_dir });
        \\                    cef_check.step.dependOn(&cef_auto.step);
        \\                }
        \\                exe.step.dependOn(&cef_check.step);
        \\                const include_arg = b.fmt("-I{s}", .{cef_dir});
        \\                const define_arg = b.fmt("-DNATIVE_SDK_CEF_DIR=\"{s}\"", .{cef_dir});
        \\                // The SDK's usr/include must stay a system include dir (searched after zig's
        \\                // bundled libc++/libc headers). A plain -I shadows libc++'s <string.h>/<math.h>
        \\                // wrappers in ObjC++ and surfaces SDK nullability gaps as a diagnostic flood.
        \\                const sdk_include = if (b.sysroot) |sysroot| b.fmt("-isystem{s}/usr/include", .{sysroot}) else "";
        \\                const flags: []const []const u8 = if (b.sysroot) |sysroot| &.{ "-fobjc-arc", "-fno-sanitize=builtin", "-ObjC++", "-std=c++17", "-stdlib=libc++", "-mmacosx-version-min=11.0", "-isysroot", sysroot, sdk_include, include_arg, define_arg } else &.{ "-fobjc-arc", "-fno-sanitize=builtin", "-ObjC++", "-std=c++17", "-stdlib=libc++", "-mmacosx-version-min=11.0", include_arg, define_arg };
        \\                app_mod.addCSourceFile(.{ .file = nativeSdkPath(b, native_sdk_path, "src/platform/macos/cef_host.mm"), .flags = flags });
        \\                app_mod.addObjectFile(b.path(b.fmt("{s}/libcef_dll_wrapper/libcef_dll_wrapper.a", .{cef_dir})));
        \\                app_mod.addFrameworkPath(b.path(b.fmt("{s}/Release", .{cef_dir})));
        \\                app_mod.linkFramework("Chromium Embedded Framework", .{});
        \\                app_mod.addRPath(.{ .cwd_relative = "@executable_path/Frameworks" });
        \\            },
        \\        }
        \\        if (b.sysroot) |sysroot| {
        \\            app_mod.addFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sysroot, "System/Library/Frameworks" }) });
        \\        }
        \\        app_mod.linkFramework("AppKit", .{});
        \\        app_mod.linkFramework("AVFoundation", .{});
        \\        app_mod.linkFramework("MediaToolbox", .{});
        \\        app_mod.linkFramework("Accelerate", .{});
        \\        app_mod.linkFramework("Foundation", .{});
        \\        app_mod.linkFramework("CoreText", .{});
        \\        app_mod.linkFramework("UniformTypeIdentifiers", .{});
        \\        app_mod.linkFramework("Security", .{});
        \\        app_mod.linkFramework("Metal", .{});
        \\        app_mod.linkFramework("QuartzCore", .{});
        \\        app_mod.linkSystemLibrary("c", .{});
        \\        if (web_engine == .chromium) app_mod.linkSystemLibrary("c++", .{});
        \\    } else if (platform == .linux) {
        \\        switch (web_engine) {
        \\            .system => if (web_layer) {
        \\                app_mod.addCSourceFile(.{ .file = nativeSdkPath(b, native_sdk_path, "src/platform/linux/gtk_host.c"), .flags = &.{} });
        \\                app_mod.linkSystemLibrary("gtk4", .{});
        \\                app_mod.linkSystemLibrary("webkitgtk-6.0", .{});
        \\                app_mod.linkSystemLibrary("dl", .{});
        \\            } else {
        \\                // Native-only app (nothing in app.zon declares web use):
        \\                // compile the GTK host without the embedded web layer.
        \\                // The stub define excludes the layer outright — the host
        \\                // honors it before probing for the WebKitGTK header, so
        \\                // the layer stays out even on machines where the
        \\                // development package is installed — libwebkitgtk is
        \\                // neither linked nor required at runtime, and the
        \\                // executable carries no WebKit reference at all.
        \\                app_mod.addCSourceFile(.{ .file = nativeSdkPath(b, native_sdk_path, "src/platform/linux/gtk_host.c"), .flags = &.{"-DNATIVE_SDK_ALLOW_WEBKITGTK_STUB"} });
        \\                app_mod.linkSystemLibrary("gtk4", .{});
        \\                app_mod.linkSystemLibrary("dl", .{});
        \\            },
        \\            .chromium => {
        \\                const cef_check = addCefCheck(b, target, cef_dir);
        \\                if (cef_auto_install) {
        \\                    const cef_auto = b.addSystemCommand(&.{ "native", "cef", "install", "--dir", cef_dir });
        \\                    cef_check.step.dependOn(&cef_auto.step);
        \\                }
        \\                exe.step.dependOn(&cef_check.step);
        \\                const include_arg = b.fmt("-I{s}", .{cef_dir});
        \\                const define_arg = b.fmt("-DNATIVE_SDK_CEF_DIR=\"{s}\"", .{cef_dir});
        \\                app_mod.addCSourceFile(.{ .file = nativeSdkPath(b, native_sdk_path, "src/platform/linux/cef_host.cpp"), .flags = &.{ "-std=c++17", include_arg, define_arg } });
        \\                app_mod.addObjectFile(b.path(b.fmt("{s}/libcef_dll_wrapper/libcef_dll_wrapper.a", .{cef_dir})));
        \\                app_mod.addLibraryPath(b.path(b.fmt("{s}/Release", .{cef_dir})));
        \\                app_mod.linkSystemLibrary("cef", .{});
        \\                app_mod.addRPath(.{ .cwd_relative = "$ORIGIN" });
        \\            },
        \\        }
        \\        app_mod.linkSystemLibrary("c", .{});
        \\        if (web_engine == .chromium) app_mod.linkSystemLibrary("stdc++", .{});
        \\    } else if (platform == .windows) {
        \\        switch (web_engine) {
        \\            .system => if (web_layer) {
        \\                // The vendored WebView2 SDK header (third_party/webview2)
        \\                // turns on the host's embedded-WebView layer; the host
        \\                // fails the compile by design if it cannot be found.
        \\                app_mod.addIncludePath(nativeSdkPath(b, native_sdk_path, "third_party/webview2/include"));
        \\                app_mod.addCSourceFile(.{ .file = nativeSdkPath(b, native_sdk_path, "src/platform/windows/webview2_host.cpp"), .flags = &.{ "-std=c++17" } });
        \\                // WebView2Loader.dll rides next to the installed app
        \\                // executable: the host loads it at runtime to discover
        \\                // the machine's WebView2 runtime. Canvas apps never
        \\                // touch it.
        \\                const loader = b.addInstallBinFile(nativeSdkPath(b, native_sdk_path, webView2LoaderSubPath(target)), "WebView2Loader.dll");
        \\                b.getInstallStep().dependOn(&loader.step);
        \\            } else {
        \\                // Native-only app (nothing in app.zon declares web use):
        \\                // compile the host without the embedded-WebView layer.
        \\                // The stub define excludes the layer outright — the host
        \\                // honors it before probing for the WebView2 header, so
        \\                // the layer stays out even on machines where the SDK
        \\                // headers are reachable through the system include paths
        \\                // — no WebView2Loader.dll is installed or path-wired,
        \\                // and the executable carries no reference to it at all.
        \\                app_mod.addCSourceFile(.{ .file = nativeSdkPath(b, native_sdk_path, "src/platform/windows/webview2_host.cpp"), .flags = &.{ "-std=c++17", "-DNATIVE_SDK_ALLOW_WEBVIEW2_STUB" } });
        \\            },
        \\            .chromium => {
        \\                const cef_check = addCefCheck(b, target, cef_dir);
        \\                if (cef_auto_install) {
        \\                    const cef_auto = b.addSystemCommand(&.{ "native", "cef", "install", "--dir", cef_dir });
        \\                    cef_check.step.dependOn(&cef_auto.step);
        \\                }
        \\                exe.step.dependOn(&cef_check.step);
        \\                const include_arg = b.fmt("-I{s}", .{cef_dir});
        \\                const define_arg = b.fmt("-DNATIVE_SDK_CEF_DIR=\"{s}\"", .{cef_dir});
        \\                app_mod.addCSourceFile(.{ .file = nativeSdkPath(b, native_sdk_path, "src/platform/windows/cef_host.cpp"), .flags = &.{ "-std=c++17", include_arg, define_arg } });
        \\                app_mod.addObjectFile(b.path(b.fmt("{s}/libcef_dll_wrapper/libcef_dll_wrapper.lib", .{cef_dir})));
        \\                app_mod.addLibraryPath(b.path(b.fmt("{s}/Release", .{cef_dir})));
        \\            },
        \\        }
        \\        app_mod.linkSystemLibrary("c", .{});
        \\        app_mod.linkSystemLibrary("c++", .{});
        \\        app_mod.linkSystemLibrary("user32", .{});
        \\        app_mod.linkSystemLibrary("gdi32", .{});
        \\        app_mod.linkSystemLibrary("imm32", .{});
        \\        app_mod.linkSystemLibrary("comctl32", .{});
        \\        app_mod.linkSystemLibrary("ole32", .{});
        \\        app_mod.linkSystemLibrary("oleacc", .{});
        \\        app_mod.linkSystemLibrary("shell32", .{});
        \\        // The audio backend: Media Foundation (session + source resolver
        \\        // + streaming audio renderer) and WinHTTP (the cache fill).
        \\        app_mod.linkSystemLibrary("mf", .{});
        \\        app_mod.linkSystemLibrary("mfplat", .{});
        \\        app_mod.linkSystemLibrary("winhttp", .{});
        \\        if (web_engine == .chromium) app_mod.linkSystemLibrary("libcef", .{});
        \\    }
        \\}
        \\
        \\/// The vendored WebView2Loader.dll for the target architecture, relative
        \\/// to the framework root.
        \\fn webView2LoaderSubPath(target: std.Build.ResolvedTarget) []const u8 {
        \\    return if (target.result.cpu.arch == .aarch64)
        \\        "third_party/webview2/arm64/WebView2Loader.dll"
        \\    else
        \\        "third_party/webview2/x64/WebView2Loader.dll";
        \\}
        \\
        \\/// `zig build run` and `zig build dev` execute the cached artifact, which
        \\/// has no installed WebView2Loader.dll beside it; the vendored loader's
        \\/// directory goes on the step's PATH so the host's LoadLibrary resolves it
        \\/// (`native dev` passes its environment on to the app it spawns). A
        \\/// native-only build never loads the library, so its PATH stays clean.
        \\fn addWebView2RuntimeRunFiles(b: *std.Build, target: std.Build.ResolvedTarget, run: *std.Build.Step.Run, web_engine: WebEngineOption, web_layer: bool, native_sdk_path: []const u8) void {
        \\    if (web_engine != .system) return;
        \\    if (!web_layer) return;
        \\    if (target.result.os.tag != .windows) return;
        \\    const loader_dir = std.fs.path.dirname(webView2LoaderSubPath(target)).?;
        \\    run.addPathDir(b.pathFromRoot(b.pathJoin(&.{ native_sdk_path, loader_dir })));
        \\}
        \\
        \\fn addCefRuntimeRunFiles(b: *std.Build, target: std.Build.ResolvedTarget, run: *std.Build.Step.Run, exe: *std.Build.Step.Compile, web_engine: WebEngineOption, cef_dir: []const u8) void {
        \\    if (web_engine != .chromium) return;
        \\    if (target.result.os.tag != .macos) return;
        \\    const copy = b.addSystemCommand(&.{ "sh", "-c", b.fmt(
        \\        \\set -e
        \\        \\exe="$0"
        \\        \\exe_dir="$(dirname "$exe")"
        \\        \\rm -rf "zig-out/Frameworks/Chromium Embedded Framework.framework" "zig-out/bin/Frameworks/Chromium Embedded Framework.framework" ".zig-cache/o/Frameworks/Chromium Embedded Framework.framework" &&
        \\        \\mkdir -p "zig-out/Frameworks" "zig-out/bin/Frameworks" ".zig-cache/o/Frameworks" "$exe_dir" &&
        \\        \\cp -R "{s}/Release/Chromium Embedded Framework.framework" "zig-out/Frameworks/" &&
        \\        \\cp -R "{s}/Release/Chromium Embedded Framework.framework" "zig-out/bin/Frameworks/" &&
        \\        \\cp -R "{s}/Release/Chromium Embedded Framework.framework" ".zig-cache/o/Frameworks/" &&
        \\        \\cp "{s}/Release/Chromium Embedded Framework.framework/Libraries/libEGL.dylib" "$exe_dir/" &&
        \\        \\cp "{s}/Release/Chromium Embedded Framework.framework/Libraries/libGLESv2.dylib" "$exe_dir/" &&
        \\        \\cp "{s}/Release/Chromium Embedded Framework.framework/Libraries/libvk_swiftshader.dylib" "$exe_dir/" &&
        \\        \\cp "{s}/Release/Chromium Embedded Framework.framework/Libraries/vk_swiftshader_icd.json" "$exe_dir/"
        \\    , .{ cef_dir, cef_dir, cef_dir, cef_dir, cef_dir, cef_dir, cef_dir }) });
        \\    copy.addFileArg(exe.getEmittedBin());
        \\    run.step.dependOn(&copy.step);
        \\}
        \\
        \\fn addCefCheck(b: *std.Build, target: std.Build.ResolvedTarget, cef_dir: []const u8) *std.Build.Step.Run {
        \\    const script = switch (target.result.os.tag) {
        \\        .macos => b.fmt(
        \\        \\test -f "{s}/include/cef_app.h" &&
        \\        \\test -d "{s}/Release/Chromium Embedded Framework.framework" &&
        \\        \\test -f "{s}/libcef_dll_wrapper/libcef_dll_wrapper.a" || {{
        \\        \\  echo "missing CEF dependency for -Dweb-engine=chromium" >&2
        \\        \\  echo "Expected:" >&2
        \\        \\  echo "  {s}/include/cef_app.h" >&2
        \\        \\  echo "  {s}/Release/Chromium Embedded Framework.framework" >&2
        \\        \\  echo "  {s}/libcef_dll_wrapper/libcef_dll_wrapper.a" >&2
        \\        \\  echo "Fix with: native cef install --dir {s}" >&2
        \\        \\  echo "Or rerun with: -Dcef-auto-install=true" >&2
        \\        \\  echo "Pass -Dcef-dir=/path/to/cef if your bundle lives elsewhere." >&2
        \\        \\  exit 1
        \\        \\}}
        \\        , .{ cef_dir, cef_dir, cef_dir, cef_dir, cef_dir, cef_dir, cef_dir }),
        \\        .linux => b.fmt(
        \\        \\test -f "{s}/include/cef_app.h" &&
        \\        \\test -f "{s}/Release/libcef.so" &&
        \\        \\test -f "{s}/libcef_dll_wrapper/libcef_dll_wrapper.a" || {{
        \\        \\  echo "missing CEF dependency for -Dweb-engine=chromium" >&2
        \\        \\  echo "Fix with: native cef install --dir {s}" >&2
        \\        \\  exit 1
        \\        \\}}
        \\        , .{ cef_dir, cef_dir, cef_dir, cef_dir }),
        \\        .windows => b.fmt(
        \\        \\test -f "{s}/include/cef_app.h" &&
        \\        \\test -f "{s}/Release/libcef.dll" &&
        \\        \\test -f "{s}/libcef_dll_wrapper/libcef_dll_wrapper.lib" || {{
        \\        \\  echo "missing CEF dependency for -Dweb-engine=chromium" >&2
        \\        \\  echo "Fix with: native cef install --dir {s}" >&2
        \\        \\  exit 1
        \\        \\}}
        \\        , .{ cef_dir, cef_dir, cef_dir, cef_dir }),
        \\        else => "echo unsupported CEF target >&2; exit 1",
        \\    };
        \\    return b.addSystemCommand(&.{ "sh", "-c", script });
        \\}
        \\
        \\fn packageSuffix(target: PackageTarget) []const u8 {
        \\    return switch (target) {
        \\        .macos => ".app",
        \\        .windows, .linux => "",
        \\    };
        \\}
        \\
        \\/// What this build graph reads out of app.zon: the web-engine/CEF
        \\/// knobs and the web-layer inference inputs. An unreadable or
        \\/// unparsable manifest falls back to the system engine WITH the web
        \\/// layer kept — over-inclusion is a size cost, wrong exclusion is a
        \\/// broken app.
        \\const AppManifestBuildConfig = struct {
        \\    web_engine: WebEngineOption = .system,
        \\    cef_dir: []const u8 = "third_party/cef/macos",
        \\    cef_auto_install: bool = false,
        \\    webview_layer: WebLayerOption = .auto,
        \\    /// The first web declaration found (for teaching messages), or
        \\    /// null when app.zon declares no web use. `web_engine = "system"`
        \\    /// alone is NOT web intent — it is the default in many canvas
        \\    /// manifests.
        \\    web_declaration: ?[]const u8 = null,
        \\};
        \\
        \\/// The lenient app.zon shape parsed for inference: only the fields
        \\/// that decide the web layer and the web engine; everything else is
        \\/// ignored. Full schema validation stays with `native validate`.
        \\const InferenceManifest = struct {
        \\    capabilities: []const []const u8 = &.{},
        \\    web_engine: []const u8 = "system",
        \\    webview_layer: []const u8 = "auto",
        \\    cef: struct {
        \\        dir: []const u8 = "third_party/cef/macos",
        \\        auto_install: bool = false,
        \\    } = .{},
        \\    frontend: ?struct {} = null,
        \\    shell: struct {
        \\        windows: []const struct {
        \\            views: []const struct {
        \\                kind: []const u8 = "",
        \\            } = &.{},
        \\        } = &.{},
        \\    } = .{},
        \\};
        \\
        \\fn defaultCefDir(platform: PlatformOption, configured: []const u8) []const u8 {
        \\    if (!std.mem.eql(u8, configured, "third_party/cef/macos")) return configured;
        \\    return switch (platform) {
        \\        .linux => "third_party/cef/linux",
        \\        .windows => "third_party/cef/windows",
        \\        else => configured,
        \\    };
        \\}
        \\
        \\fn appManifestBuildConfig(b: *std.Build) AppManifestBuildConfig {
        \\    // The fallback for a manifest this lenient parse cannot read
        \\    // keeps the web layer (see AppManifestBuildConfig): a shape
        \\    // mismatch here is not proof the app declares no web use.
        \\    const fallback: AppManifestBuildConfig = .{ .web_declaration = "an app.zon this build graph could not parse" };
        \\    const source: [:0]const u8 = @embedFile("app.zon");
        \\    @setEvalBranchQuota(2000);
        \\    const raw = std.zon.parse.fromSliceAlloc(InferenceManifest, b.allocator, source, null, .{ .ignore_unknown_fields = true }) catch return fallback;
        \\    var config: AppManifestBuildConfig = .{
        \\        .web_engine = parseWebEngine(raw.web_engine) orelse .system,
        \\        .cef_dir = raw.cef.dir,
        \\        .cef_auto_install = raw.cef.auto_install,
        \\        .webview_layer = parseWebLayer(raw.webview_layer) orelse @panic("app.zon .webview_layer must be \"auto\", \"include\", or \"exclude\""),
        \\    };
        \\    config.web_declaration = blk: {
        \\        if (raw.frontend != null) break :blk "a .frontend block";
        \\        for (raw.capabilities) |capability| {
        \\            if (std.mem.eql(u8, capability, "webview")) break :blk "the \"webview\" capability";
        \\        }
        \\        for (raw.shell.windows) |window| {
        \\            for (window.views) |view| {
        \\                if (std.mem.eql(u8, view.kind, "webview")) break :blk "a .shell webview view";
        \\            }
        \\        }
        \\        break :blk null;
        \\    };
        \\    return config;
        \\}
        \\
        \\/// The web-layer decision for this build — the same declare-to-use
        \\/// contract the Native SDK's standard build graph, CLI, and runner
        \\/// apply: an app is WEB when app.zon declares web use (a .frontend
        \\/// block, the "webview" capability, a .shell webview view) or the
        \\/// build resolves to the Chromium engine; otherwise it is
        \\/// NATIVE-ONLY and the platform host compiles without the
        \\/// embedded-WebView layer. `.webview_layer` (and `-Dweb-layer`)
        \\/// override the inference — but an exclude that contradicts a web
        \\/// declaration is a hard configure error, never a silently broken
        \\/// app.
        \\fn resolveWebLayer(config: AppManifestBuildConfig, web_engine: WebEngineOption, override: ?WebLayerOption) bool {
        \\    const setting = override orelse config.webview_layer;
        \\    const declaration: ?[]const u8 = config.web_declaration orelse
        \\        (if (web_engine == .chromium) "the Chromium web engine" else null);
        \\    return switch (setting) {
        \\        .include => true,
        \\        .auto => declaration != null,
        \\        .exclude => {
        \\            if (declaration) |reason| {
        \\                std.debug.panic(
        \\                    "the web layer is excluded ({s}) but the app declares web use ({s}); remove the exclude or drop the web declaration",
        \\                    .{ if (override != null) "-Dweb-layer=exclude" else "app.zon .webview_layer = \"exclude\"", reason },
        \\                );
        \\            }
        \\            return false;
        \\        },
        \\    };
        \\}
        \\
        \\fn parseWebEngine(value: []const u8) ?WebEngineOption {
        \\    if (std.mem.eql(u8, value, "system")) return .system;
        \\    if (std.mem.eql(u8, value, "chromium")) return .chromium;
        \\    return null;
        \\}
        \\
        \\fn parseWebLayer(value: []const u8) ?WebLayerOption {
        \\    if (std.mem.eql(u8, value, "auto")) return .auto;
        \\    if (std.mem.eql(u8, value, "include")) return .include;
        \\    if (std.mem.eql(u8, value, "exclude")) return .exclude;
        \\    return null;
        \\}
        \\
    );
    return out.toOwnedSlice(allocator);
}

fn buildZon(allocator: std.mem.Allocator, names: TemplateNames) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator,
        \\.{
        \\    .name = .
    );
    try out.appendSlice(allocator, names.module_name);
    try out.appendSlice(allocator,
        \\,
        \\    .fingerprint = 0x
    );
    var fingerprint_buffer: [16]u8 = undefined;
    const fingerprint = try std.fmt.bufPrint(&fingerprint_buffer, "{x}", .{fingerprintForName(names.module_name)});
    try out.appendSlice(allocator, fingerprint);
    try out.appendSlice(allocator,
        \\,
        \\    .version = "0.1.0",
        \\    .minimum_zig_version = "0.16.0",
        \\    .dependencies = .{},
        \\    .paths = .{ "build.zig", "build.zig.zon", "src", "assets", "frontend", "app.zon", "README.md" },
        \\}
        \\
    );
    return out.toOwnedSlice(allocator);
}

fn mainZig(allocator: std.mem.Allocator, names: TemplateNames, frontend: Frontend) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator,
        \\const std = @import("std");
        \\const runner = @import("runner");
        \\const native_sdk = @import("native_sdk");
        \\
        \\pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);
        \\
        \\const App = struct {
        \\    env_map: *std.process.Environ.Map,
        \\
        \\    fn app(self: *@This()) native_sdk.App {
        \\        return .{
        \\            .context = self,
        \\            .name =
    );
    try appendZigString(&out, allocator, names.package_name);
    try out.appendSlice(allocator,
        \\,
        \\            .source = native_sdk.frontend.productionSource(.{ .dist =
    );
    try appendZigString(&out, allocator, frontend.distDir());
    try out.appendSlice(allocator,
        \\ }),
        \\            .source_fn = source,
        \\        };
        \\    }
        \\
        \\    fn source(context: *anyopaque) anyerror!native_sdk.WebViewSource {
        \\        const self: *@This() = @ptrCast(@alignCast(context));
        \\        return native_sdk.frontend.sourceFromEnv(self.env_map, .{
        \\            .dist =
    );
    try appendZigString(&out, allocator, frontend.distDir());
    try out.appendSlice(allocator,
        \\,
        \\            .entry = "index.html",
        \\        });
        \\    }
        \\};
        \\
        \\const dev_origins = [_][]const u8{ "zero://app", "zero://inline",
    );
    const dev_origin = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{s}", .{frontend.devPort()});
    defer allocator.free(dev_origin);
    try out.appendSlice(allocator, " ");
    try appendZigString(&out, allocator, dev_origin);
    try out.appendSlice(allocator,
        \\ };
        \\
        \\pub fn main(init: std.process.Init) !void {
        \\    var app = App{ .env_map = init.environ_map };
        \\    try runner.runWithOptions(app.app(), .{
        \\        .app_name =
    );
    try appendZigString(&out, allocator, names.display_name);
    try out.appendSlice(allocator,
        \\,
        \\        .window_title =
    );
    try appendZigString(&out, allocator, names.display_name);
    try out.appendSlice(allocator,
        \\,
        \\        .bundle_id =
    );
    try appendZigString(&out, allocator, names.app_id);
    try out.appendSlice(allocator,
        \\,
        \\        .icon_path = "assets/icon.png",
        \\        .security = .{
        \\            .navigation = .{ .allowed_origins = &dev_origins },
        \\        },
        \\    }, init);
        \\}
        \\
        \\test "app name is configured" {
        \\    try std.testing.expectEqualStrings(
    );
    try appendZigString(&out, allocator, names.package_name);
    try out.appendSlice(allocator,
        \\,
    );
    try appendZigString(&out, allocator, names.package_name);
    try out.appendSlice(allocator,
        \\);
        \\}
        \\
    );
    return out.toOwnedSlice(allocator);
}

fn runnerZig() []const u8 {
    return
    \\const std = @import("std");
    \\const build_options = @import("build_options");
    \\const native_sdk = @import("native_sdk");
    \\const app_manifest = @import("app_manifest_zon");
    \\const manifest_commands = if (@hasField(@TypeOf(app_manifest), "commands")) app_manifest.commands else .{};
    \\const manifest_shortcuts = if (@hasField(@TypeOf(app_manifest), "shortcuts")) app_manifest.shortcuts else .{};
    \\const manifest_menus = if (@hasField(@TypeOf(app_manifest), "menus")) app_manifest.menus else .{};
    \\const manifest_windows = if (@hasField(@TypeOf(app_manifest), "windows")) app_manifest.windows else .{};
    \\
    \\pub const StdoutTraceSink = struct {
    \\    pub fn sink(self: *StdoutTraceSink) native_sdk.trace.Sink {
    \\        return .{ .context = self, .write_fn = write };
    \\    }
    \\
    \\    fn write(context: *anyopaque, record: native_sdk.trace.Record) native_sdk.trace.WriteError!void {
    \\        _ = context;
    \\        if (!shouldTrace(record)) return;
    \\        // Never fail on an oversized record: logging failures must
    \\        // degrade (truncated output), not fail dispatch upstream.
    \\        var buffer: [4096]u8 = undefined;
    \\        std.debug.print("{s}\n", .{native_sdk.trace.formatTextBounded(record, &buffer)});
    \\    }
    \\};
    \\
    \\pub const RunOptions = struct {
    \\    app_name: []const u8,
    \\    window_title: []const u8 = "",
    \\    bundle_id: []const u8,
    \\    icon_path: []const u8 = "assets/icon.png",
    \\    bridge: ?native_sdk.BridgeDispatcher = null,
    \\    builtin_bridge: native_sdk.BridgePolicy = .{},
    \\    security: native_sdk.SecurityPolicy = .{},
    \\    js_window_api: bool = false,
    \\    commands: ?[]const native_sdk.Command = null,
    \\    menus: ?[]const native_sdk.Menu = null,
    \\    shortcuts: ?[]const native_sdk.Shortcut = null,
    \\
    \\    fn appInfo(self: RunOptions, buffers: *StateBuffers) native_sdk.AppInfo {
    \\        var info: native_sdk.AppInfo = .{
    \\            .app_name = self.app_name,
    \\            .has_web_content = manifestHasWebContent(),
    \\            .window_title = self.window_title,
    \\            .bundle_id = self.bundle_id,
    \\            .icon_path = self.icon_path,
    \\        };
    \\        const windows = manifestWindowOptions(buffers);
    \\        if (windows.len > 0) {
    \\            info.main_window = windows[0];
    \\            info.windows = windows;
    \\        }
    \\        return info;
    \\    }
    \\
    \\    fn resolvedShortcuts(self: RunOptions, storage: *ShortcutStorage) []const native_sdk.Shortcut {
    \\        return self.shortcuts orelse storage.fromManifest();
    \\    }
    \\
    \\    fn resolvedCommands(self: RunOptions, storage: *CommandStorage) []const native_sdk.Command {
    \\        return self.commands orelse storage.fromManifest();
    \\    }
    \\
    \\    fn resolvedMenus(self: RunOptions, storage: *MenuStorage) []const native_sdk.Menu {
    \\        return self.menus orelse storage.fromManifest();
    \\    }
    \\};
    \\
    \\const CommandStorage = struct {
    \\    commands: [native_sdk.app_manifest.max_commands]native_sdk.Command = undefined,
    \\
    \\    fn fromManifest(self: *CommandStorage) []const native_sdk.Command {
    \\        comptime {
    \\            if (manifest_commands.len > native_sdk.app_manifest.max_commands) {
    \\                @compileError("app.zon defines too many commands");
    \\            }
    \\        }
    \\
    \\        inline for (manifest_commands, 0..) |command, index| {
    \\            self.commands[index] = .{
    \\                .id = command.id,
    \\                .title = if (@hasField(@TypeOf(command), "title")) command.title else "",
    \\                .enabled = if (@hasField(@TypeOf(command), "enabled")) command.enabled else true,
    \\                .checked = if (@hasField(@TypeOf(command), "checked")) command.checked else false,
    \\            };
    \\        }
    \\        return self.commands[0..manifest_commands.len];
    \\    }
    \\};
    \\
    \\const MenuStorage = struct {
    \\    menus: [native_sdk.platform.max_menus]native_sdk.Menu = undefined,
    \\    items: [native_sdk.platform.max_menu_items]native_sdk.MenuItem = undefined,
    \\
    \\    fn fromManifest(self: *MenuStorage) []const native_sdk.Menu {
    \\        comptime {
    \\            if (manifest_menus.len > native_sdk.platform.max_menus) {
    \\                @compileError("app.zon defines too many menus");
    \\            }
    \\            var item_count: usize = 0;
    \\            for (manifest_menus) |menu| {
    \\                const items = if (@hasField(@TypeOf(menu), "items")) menu.items else .{};
    \\                item_count += items.len;
    \\            }
    \\            if (item_count > native_sdk.platform.max_menu_items) {
    \\                @compileError("app.zon defines too many menu items");
    \\            }
    \\        }
    \\
    \\        var item_index: usize = 0;
    \\        inline for (manifest_menus, 0..) |menu, menu_index| {
    \\            const items = if (@hasField(@TypeOf(menu), "items")) menu.items else .{};
    \\            const first_item = item_index;
    \\            inline for (items) |item| {
    \\                self.items[item_index] = menuItem(item);
    \\                item_index += 1;
    \\            }
    \\            self.menus[menu_index] = .{
    \\                .title = menu.title,
    \\                .items = self.items[first_item..item_index],
    \\            };
    \\        }
    \\        return self.menus[0..manifest_menus.len];
    \\    }
    \\};
    \\
    \\const ShortcutStorage = struct {
    \\    shortcuts: [native_sdk.platform.max_shortcuts]native_sdk.Shortcut = undefined,
    \\
    \\    fn fromManifest(self: *ShortcutStorage) []const native_sdk.Shortcut {
    \\        comptime {
    \\            if (manifest_shortcuts.len > native_sdk.platform.max_shortcuts) {
    \\                @compileError("app.zon defines too many shortcuts");
    \\            }
    \\        }
    \\
    \\        inline for (manifest_shortcuts, 0..) |shortcut, index| {
    \\            self.shortcuts[index] = .{
    \\                .id = shortcut.id,
    \\                .key = shortcut.key,
    \\                .modifiers = shortcutModifiers(shortcut),
    \\            };
    \\        }
    \\        return self.shortcuts[0..manifest_shortcuts.len];
    \\    }
    \\};
    \\
    \\fn manifestWindowOptions(buffers: *StateBuffers) []const native_sdk.WindowOptions {
    \\    comptime {
    \\        if (manifest_windows.len > native_sdk.platform.max_windows) {
    \\            @compileError("app.zon defines too many windows");
    \\        }
    \\    }
    \\
    \\    inline for (manifest_windows, 0..) |window, index| {
    \\        buffers.restored_windows[index] = manifestWindow(window, index);
    \\    }
    \\    return buffers.restored_windows[0..manifest_windows.len];
    \\}
    \\
    \\fn manifestWindow(comptime window: anytype, comptime index: usize) native_sdk.WindowOptions {
    \\    return .{
    \\        .id = index + 1,
    \\        .label = windowLabel(window, index),
    \\        .title = windowTitle(window),
    \\        .default_frame = native_sdk.geometry.RectF.init(
    \\            windowFloat(window, "x", 0),
    \\            windowFloat(window, "y", 0),
    \\            windowFloat(window, "width", 720),
    \\            windowFloat(window, "height", 480),
    \\        ),
    \\        .resizable = windowBool(window, "resizable", true),
    \\        .restore_state = windowBool(window, "restore_state", true),
    \\        .restore_policy = windowRestorePolicy(window),
    \\    };
    \\}
    \\
    \\fn windowLabel(comptime window: anytype, comptime index: usize) []const u8 {
    \\    if (comptime @hasField(@TypeOf(window), "label")) return window.label;
    \\    return if (index == 0) "main" else "window";
    \\}
    \\
    \\fn windowTitle(comptime window: anytype) []const u8 {
    \\    if (comptime !@hasField(@TypeOf(window), "title")) return "";
    \\    const title = window.title;
    \\    if (comptime @TypeOf(title) == @TypeOf(null)) return "";
    \\    return title;
    \\}
    \\
    \\fn windowFloat(comptime window: anytype, comptime field: []const u8, comptime default_value: f32) f32 {
    \\    if (comptime @hasField(@TypeOf(window), field)) return @field(window, field);
    \\    return default_value;
    \\}
    \\
    \\fn windowBool(comptime window: anytype, comptime field: []const u8, comptime default_value: bool) bool {
    \\    if (comptime @hasField(@TypeOf(window), field)) return @field(window, field);
    \\    return default_value;
    \\}
    \\
    \\fn windowRestorePolicy(comptime window: anytype) native_sdk.WindowRestorePolicy {
    \\    if (comptime !@hasField(@TypeOf(window), "restore_policy")) return .clamp_to_visible_screen;
    \\    const value = window.restore_policy;
    \\    if (comptime std.mem.eql(u8, value, "clamp_to_visible_screen")) return .clamp_to_visible_screen;
    \\    if (comptime std.mem.eql(u8, value, "center_on_primary")) return .center_on_primary;
    \\    @compileError("unknown app.zon window restore_policy");
    \\}
    \\
    \\fn menuItem(comptime item: anytype) native_sdk.MenuItem {
    \\    return .{
    \\        .label = if (@hasField(@TypeOf(item), "label")) item.label else "",
    \\        .command = if (@hasField(@TypeOf(item), "command")) item.command else "",
    \\        .key = if (@hasField(@TypeOf(item), "key")) item.key else "",
    \\        .modifiers = shortcutModifiers(item),
    \\        .separator = if (@hasField(@TypeOf(item), "separator")) item.separator else false,
    \\        .enabled = if (@hasField(@TypeOf(item), "enabled")) item.enabled else true,
    \\        .checked = if (@hasField(@TypeOf(item), "checked")) item.checked else false,
    \\    };
    \\}
    \\
    \\fn shortcutModifiers(comptime shortcut: anytype) native_sdk.ShortcutModifiers {
    \\    const values = if (@hasField(@TypeOf(shortcut), "modifiers")) shortcut.modifiers else .{};
    \\    var modifiers: native_sdk.ShortcutModifiers = .{};
    \\    inline for (values) |value| {
    \\        const modifier: []const u8 = value;
    \\        if (comptime std.mem.eql(u8, modifier, "primary")) {
    \\            modifiers.primary = true;
    \\        } else if (comptime std.mem.eql(u8, modifier, "command")) {
    \\            modifiers.command = true;
    \\        } else if (comptime std.mem.eql(u8, modifier, "control")) {
    \\            modifiers.control = true;
    \\        } else if (comptime std.mem.eql(u8, modifier, "option") or std.mem.eql(u8, modifier, "alt")) {
    \\            modifiers.option = true;
    \\        } else if (comptime std.mem.eql(u8, modifier, "shift")) {
    \\            modifiers.shift = true;
    \\        } else {
    \\            @compileError("unknown app.zon shortcut modifier");
    \\        }
    \\    }
    \\    return modifiers;
    \\}
    \\
    \\pub fn runWithOptions(app: native_sdk.App, options: RunOptions, init: std.process.Init) !void {
    \\    if (build_options.debug_overlay) {
    \\        std.debug.print("debug-overlay=true backend={s} web-engine={s} trace={s}\n", .{ build_options.platform, build_options.web_engine, build_options.trace });
    \\    }
    \\    if (comptime std.mem.eql(u8, build_options.platform, "macos")) {
    \\        try runMacos(app, options, init);
    \\    } else if (comptime std.mem.eql(u8, build_options.platform, "linux")) {
    \\        try runLinux(app, options, init);
    \\    } else if (comptime std.mem.eql(u8, build_options.platform, "windows")) {
    \\        try runWindows(app, options, init);
    \\    } else {
    \\        try runNull(app, options, init);
    \\    }
    \\}
    \\
    \\fn runNull(app: native_sdk.App, options: RunOptions, init: std.process.Init) !void {
    \\    var buffers: StateBuffers = undefined;
    \\    var app_info = options.appInfo(&buffers);
    \\    const store = prepareStateStore(init.io, init.environ_map, &app_info, &buffers);
    \\    var null_platform = native_sdk.NullPlatform.initWithOptions(.{}, webEngine(), app_info);
    \\    var trace_sink = StdoutTraceSink{};
    \\    var log_buffers: native_sdk.debug.LogPathBuffers = .{};
    \\    const log_setup = native_sdk.debug.setupLogging(init.io, init.environ_map, app_info.bundle_id, &log_buffers) catch null;
    \\    if (log_setup) |setup| native_sdk.debug.installPanicCapture(init.io, setup.paths);
    \\    var file_trace_sink: native_sdk.debug.FileTraceSink = undefined;
    \\    var fanout_sinks: [2]native_sdk.trace.Sink = undefined;
    \\    var fanout_sink: native_sdk.debug.FanoutTraceSink = undefined;
    \\    var runtime_trace_sink = trace_sink.sink();
    \\    if (log_setup) |setup| {
    \\        file_trace_sink = native_sdk.debug.FileTraceSink.init(init.io, setup.paths.log_dir, setup.paths.log_file, setup.format);
    \\        fanout_sinks = .{ trace_sink.sink(), file_trace_sink.sink() };
    \\        fanout_sink = .{ .sinks = &fanout_sinks };
    \\        runtime_trace_sink = fanout_sink.sink();
    \\    }
    \\    var shortcut_storage: ShortcutStorage = .{};
    \\    const shortcuts = options.resolvedShortcuts(&shortcut_storage);
    \\    var menu_storage: MenuStorage = .{};
    \\    const menus = options.resolvedMenus(&menu_storage);
    \\    var command_storage: CommandStorage = .{};
    \\    const commands = options.resolvedCommands(&command_storage);
    \\    // The Runtime is multi-megabyte; default thread stacks overflow on a
    \\    // stack instance, so construct it on the heap.
    \\    const runtime = try std.heap.page_allocator.create(native_sdk.Runtime);
    \\    defer std.heap.page_allocator.destroy(runtime);
    \\    native_sdk.Runtime.initAt(runtime, .{
    \\        .platform = null_platform.platform(),
    \\        .trace_sink = runtime_trace_sink,
    \\        .log_path = if (log_setup) |setup| setup.paths.log_file else null,
    \\        .bridge = options.bridge,
    \\        .builtin_bridge = options.builtin_bridge,
    \\        .security = options.security,
    \\        .js_window_api = options.js_window_api,
    \\        .web_layer = webLayerEnabled(),
    \\        .commands = commands,
    \\        .menus = menus,
    \\        .shortcuts = shortcuts,
    \\        .automation = if (build_options.automation) native_sdk.automation.Server.init(init.io, ".zig-cache/native-sdk-automation", app_info.resolvedWindowTitle()) else null,
    \\        .window_state_store = store,
    \\        .environ = init.minimal.environ,
    \\    });
    \\
    \\    try runtime.run(app);
    \\}
    \\
    \\fn runMacos(app: native_sdk.App, options: RunOptions, init: std.process.Init) !void {
    \\    var buffers: StateBuffers = undefined;
    \\    var app_info = options.appInfo(&buffers);
    \\    const store = prepareStateStore(init.io, init.environ_map, &app_info, &buffers);
    \\    var mac_platform = try native_sdk.platform.macos.MacPlatform.initWithOptions(native_sdk.geometry.SizeF.init(720, 480), webEngine(), app_info);
    \\    defer mac_platform.deinit();
    \\    var trace_sink = StdoutTraceSink{};
    \\    var log_buffers: native_sdk.debug.LogPathBuffers = .{};
    \\    const log_setup = native_sdk.debug.setupLogging(init.io, init.environ_map, app_info.bundle_id, &log_buffers) catch null;
    \\    if (log_setup) |setup| native_sdk.debug.installPanicCapture(init.io, setup.paths);
    \\    var file_trace_sink: native_sdk.debug.FileTraceSink = undefined;
    \\    var fanout_sinks: [2]native_sdk.trace.Sink = undefined;
    \\    var fanout_sink: native_sdk.debug.FanoutTraceSink = undefined;
    \\    var runtime_trace_sink = trace_sink.sink();
    \\    if (log_setup) |setup| {
    \\        file_trace_sink = native_sdk.debug.FileTraceSink.init(init.io, setup.paths.log_dir, setup.paths.log_file, setup.format);
    \\        fanout_sinks = .{ trace_sink.sink(), file_trace_sink.sink() };
    \\        fanout_sink = .{ .sinks = &fanout_sinks };
    \\        runtime_trace_sink = fanout_sink.sink();
    \\    }
    \\    var shortcut_storage: ShortcutStorage = .{};
    \\    const shortcuts = options.resolvedShortcuts(&shortcut_storage);
    \\    var menu_storage: MenuStorage = .{};
    \\    const menus = options.resolvedMenus(&menu_storage);
    \\    var command_storage: CommandStorage = .{};
    \\    const commands = options.resolvedCommands(&command_storage);
    \\    // The Runtime is multi-megabyte; default thread stacks overflow on a
    \\    // stack instance, so construct it on the heap.
    \\    const runtime = try std.heap.page_allocator.create(native_sdk.Runtime);
    \\    defer std.heap.page_allocator.destroy(runtime);
    \\    native_sdk.Runtime.initAt(runtime, .{
    \\        .platform = mac_platform.platform(),
    \\        .trace_sink = runtime_trace_sink,
    \\        .log_path = if (log_setup) |setup| setup.paths.log_file else null,
    \\        .bridge = options.bridge,
    \\        .builtin_bridge = options.builtin_bridge,
    \\        .security = options.security,
    \\        .js_window_api = options.js_window_api,
    \\        .web_layer = webLayerEnabled(),
    \\        .commands = commands,
    \\        .menus = menus,
    \\        .shortcuts = shortcuts,
    \\        .automation = if (build_options.automation) native_sdk.automation.Server.init(init.io, ".zig-cache/native-sdk-automation", app_info.resolvedWindowTitle()) else null,
    \\        .window_state_store = store,
    \\        .environ = init.minimal.environ,
    \\    });
    \\
    \\    try runtime.run(app);
    \\}
    \\
    \\fn runLinux(app: native_sdk.App, options: RunOptions, init: std.process.Init) !void {
    \\    var buffers: StateBuffers = undefined;
    \\    var app_info = options.appInfo(&buffers);
    \\    const store = prepareStateStore(init.io, init.environ_map, &app_info, &buffers);
    \\    var linux_platform = try native_sdk.platform.linux.LinuxPlatform.initWithOptions(native_sdk.geometry.SizeF.init(720, 480), webEngine(), app_info);
    \\    defer linux_platform.deinit();
    \\    var trace_sink = StdoutTraceSink{};
    \\    var log_buffers: native_sdk.debug.LogPathBuffers = .{};
    \\    const log_setup = native_sdk.debug.setupLogging(init.io, init.environ_map, app_info.bundle_id, &log_buffers) catch null;
    \\    if (log_setup) |setup| native_sdk.debug.installPanicCapture(init.io, setup.paths);
    \\    var file_trace_sink: native_sdk.debug.FileTraceSink = undefined;
    \\    var fanout_sinks: [2]native_sdk.trace.Sink = undefined;
    \\    var fanout_sink: native_sdk.debug.FanoutTraceSink = undefined;
    \\    var runtime_trace_sink = trace_sink.sink();
    \\    if (log_setup) |setup| {
    \\        file_trace_sink = native_sdk.debug.FileTraceSink.init(init.io, setup.paths.log_dir, setup.paths.log_file, setup.format);
    \\        fanout_sinks = .{ trace_sink.sink(), file_trace_sink.sink() };
    \\        fanout_sink = .{ .sinks = &fanout_sinks };
    \\        runtime_trace_sink = fanout_sink.sink();
    \\    }
    \\    var shortcut_storage: ShortcutStorage = .{};
    \\    const shortcuts = options.resolvedShortcuts(&shortcut_storage);
    \\    var menu_storage: MenuStorage = .{};
    \\    const menus = options.resolvedMenus(&menu_storage);
    \\    var command_storage: CommandStorage = .{};
    \\    const commands = options.resolvedCommands(&command_storage);
    \\    // The Runtime is multi-megabyte; default thread stacks overflow on a
    \\    // stack instance, so construct it on the heap.
    \\    const runtime = try std.heap.page_allocator.create(native_sdk.Runtime);
    \\    defer std.heap.page_allocator.destroy(runtime);
    \\    native_sdk.Runtime.initAt(runtime, .{
    \\        .platform = linux_platform.platform(),
    \\        .trace_sink = runtime_trace_sink,
    \\        .log_path = if (log_setup) |setup| setup.paths.log_file else null,
    \\        .bridge = options.bridge,
    \\        .builtin_bridge = options.builtin_bridge,
    \\        .security = options.security,
    \\        .js_window_api = options.js_window_api,
    \\        .web_layer = webLayerEnabled(),
    \\        .commands = commands,
    \\        .menus = menus,
    \\        .shortcuts = shortcuts,
    \\        .automation = if (build_options.automation) native_sdk.automation.Server.init(init.io, ".zig-cache/native-sdk-automation", app_info.resolvedWindowTitle()) else null,
    \\        .window_state_store = store,
    \\        .environ = init.minimal.environ,
    \\    });
    \\
    \\    try runtime.run(app);
    \\}
    \\
    \\fn runWindows(app: native_sdk.App, options: RunOptions, init: std.process.Init) !void {
    \\    var buffers: StateBuffers = undefined;
    \\    var app_info = options.appInfo(&buffers);
    \\    const store = prepareStateStore(init.io, init.environ_map, &app_info, &buffers);
    \\    var windows_platform = try native_sdk.platform.windows.WindowsPlatform.initWithOptions(native_sdk.geometry.SizeF.init(720, 480), webEngine(), app_info);
    \\    defer windows_platform.deinit();
    \\    var trace_sink = StdoutTraceSink{};
    \\    var log_buffers: native_sdk.debug.LogPathBuffers = .{};
    \\    const log_setup = native_sdk.debug.setupLogging(init.io, init.environ_map, app_info.bundle_id, &log_buffers) catch null;
    \\    if (log_setup) |setup| native_sdk.debug.installPanicCapture(init.io, setup.paths);
    \\    var file_trace_sink: native_sdk.debug.FileTraceSink = undefined;
    \\    var fanout_sinks: [2]native_sdk.trace.Sink = undefined;
    \\    var fanout_sink: native_sdk.debug.FanoutTraceSink = undefined;
    \\    var runtime_trace_sink = trace_sink.sink();
    \\    if (log_setup) |setup| {
    \\        file_trace_sink = native_sdk.debug.FileTraceSink.init(init.io, setup.paths.log_dir, setup.paths.log_file, setup.format);
    \\        fanout_sinks = .{ trace_sink.sink(), file_trace_sink.sink() };
    \\        fanout_sink = .{ .sinks = &fanout_sinks };
    \\        runtime_trace_sink = fanout_sink.sink();
    \\    }
    \\    var shortcut_storage: ShortcutStorage = .{};
    \\    const shortcuts = options.resolvedShortcuts(&shortcut_storage);
    \\    var menu_storage: MenuStorage = .{};
    \\    const menus = options.resolvedMenus(&menu_storage);
    \\    var command_storage: CommandStorage = .{};
    \\    const commands = options.resolvedCommands(&command_storage);
    \\    // The Runtime is multi-megabyte; default thread stacks overflow on a
    \\    // stack instance, so construct it on the heap.
    \\    const runtime = try std.heap.page_allocator.create(native_sdk.Runtime);
    \\    defer std.heap.page_allocator.destroy(runtime);
    \\    native_sdk.Runtime.initAt(runtime, .{
    \\        .platform = windows_platform.platform(),
    \\        .trace_sink = runtime_trace_sink,
    \\        .log_path = if (log_setup) |setup| setup.paths.log_file else null,
    \\        .bridge = options.bridge,
    \\        .builtin_bridge = options.builtin_bridge,
    \\        .security = options.security,
    \\        .js_window_api = options.js_window_api,
    \\        .web_layer = webLayerEnabled(),
    \\        .commands = commands,
    \\        .menus = menus,
    \\        .shortcuts = shortcuts,
    \\        .automation = if (build_options.automation) native_sdk.automation.Server.init(init.io, ".zig-cache/native-sdk-automation", app_info.resolvedWindowTitle()) else null,
    \\        .window_state_store = store,
    \\        .environ = init.minimal.environ,
    \\    });
    \\
    \\    try runtime.run(app);
    \\}
    \\
    \\fn shouldTrace(record: native_sdk.trace.Record) bool {
    \\    if (comptime std.mem.eql(u8, build_options.trace, "off")) return false;
    \\    if (comptime std.mem.eql(u8, build_options.trace, "all")) return true;
    \\    if (comptime std.mem.eql(u8, build_options.trace, "events")) return true;
    \\    return std.mem.indexOf(u8, record.name, build_options.trace) != null;
    \\}
    \\
    \\fn webEngine() native_sdk.WebEngine {
    \\    if (comptime std.mem.eql(u8, build_options.web_engine, "chromium")) return .chromium;
    \\    return .system;
    \\}
    \\
    \\/// Whether app.zon declares web content — the shared declare-to-use
    \\/// contract (native_sdk.app_manifest.web_layer) over the comptime
    \\/// manifest import: a .frontend block, the "webview" capability, a
    \\/// .shell webview view, or .web_engine = "chromium". Hosts build
    \\/// honest default menus from this — web items like Reload only exist
    \\/// when a webview can answer them.
    \\fn manifestHasWebContent() bool {
    \\    return manifestWebDeclaration() != null;
    \\}
    \\
    \\/// The first web declaration visible in app.zon, evaluated at
    \\/// comptime. The engine input is the MANIFEST engine: the runner
    \\/// never sees the -Dweb-engine flag, so an engine resolved to
    \\/// Chromium by flag alone stays a configure-time error in build.zig,
    \\/// which does see the flag.
    \\fn manifestWebDeclaration() ?native_sdk.app_manifest.web_layer.Declaration {
    \\    const engine: native_sdk.app_manifest.WebEngine = comptime blk: {
    \\        if (!@hasField(@TypeOf(app_manifest), "web_engine")) break :blk .system;
    \\        break :blk native_sdk.app_manifest.web_layer.parseWebEngine(app_manifest.web_engine) orelse .system;
    \\    };
    \\    return comptime native_sdk.app_manifest.web_layer.webDeclaration(app_manifest, engine);
    \\}
    \\
    \\/// Whether this build ships the embedded web layer (build.zig's
    \\/// -Dweb-layer inference); a build_options module that predates the
    \\/// option keeps the layer — over-inclusion is safe.
    \\fn webLayerEnabled() bool {
    \\    if (comptime !@hasDecl(build_options, "web_layer")) return true;
    \\    return build_options.web_layer;
    \\}
    \\
    \\// A build that excludes the web layer while app.zon declares web use
    \\// must fail at compile time: the declared webviews of a layerless
    \\// host would otherwise only fail later, at runtime.
    \\comptime {
    \\    if (!webLayerEnabled()) {
    \\        if (manifestWebDeclaration()) |declaration| {
    \\            @compileError("this build excludes the web layer (-Dweb-layer=exclude) but app.zon declares web use (" ++ declaration.text() ++ "); remove the exclude or drop the web declaration");
    \\        }
    \\    }
    \\}
    \\
    \\const StateBuffers = struct {
    \\    state_dir: [1024]u8 = undefined,
    \\    file_path: [1200]u8 = undefined,
    \\    read: [8192]u8 = undefined,
    \\    restored_windows: [native_sdk.platform.max_windows]native_sdk.WindowOptions = undefined,
    \\};
    \\
    \\fn prepareStateStore(io: std.Io, env_map: *std.process.Environ.Map, app_info: *native_sdk.AppInfo, buffers: *StateBuffers) ?native_sdk.window_state.Store {
    \\    const paths = native_sdk.window_state.defaultPaths(&buffers.state_dir, &buffers.file_path, app_info.bundle_id, native_sdk.debug.envFromMap(env_map)) catch return null;
    \\    const store = native_sdk.window_state.Store.init(io, paths.state_dir, paths.file_path);
    \\    if (app_info.windows.len > 0) {
    \\        const restored_windows = buffers.restored_windows[0..app_info.windows.len];
    \\        for (restored_windows, 0..) |*window, index| {
    \\            if (!window.restore_state) continue;
    \\            if (store.loadWindow(window.label, &buffers.read) catch null) |saved| {
    \\                window.default_frame = saved.frame;
    \\                if (index == 0) app_info.main_window.default_frame = saved.frame;
    \\            }
    \\        }
    \\    } else if (app_info.main_window.restore_state) {
    \\        if (store.loadWindow(app_info.main_window.label, &buffers.read) catch null) |saved| {
    \\            app_info.main_window.default_frame = saved.frame;
    \\        }
    \\    }
    \\    return store;
    \\}
    \\
    ;
}

fn appZon(allocator: std.mem.Allocator, names: TemplateNames, frontend: Frontend) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator,
        \\.{
        \\    .id =
    );
    try appendZigString(&out, allocator, names.app_id);
    try out.appendSlice(allocator,
        \\,
        \\    .name =
    );
    try appendZigString(&out, allocator, names.package_name);
    try out.appendSlice(allocator,
        \\,
        \\    .display_name =
    );
    try appendZigString(&out, allocator, names.display_name);
    try out.appendSlice(allocator,
        \\,
        \\    .version = "0.1.0",
        \\    .icons = .{ "assets/icon.png" },
        \\    .platforms = .{ "macos", "linux" },
        \\    .permissions = .{},
        \\    .capabilities = .{ "webview" },
        \\    .frontend = .{
        \\        .dist =
    );
    try appendZigString(&out, allocator, frontend.distDir());
    try out.appendSlice(allocator,
        \\,
        \\        .entry = "index.html",
        \\        .spa_fallback = true,
        \\        .dev = .{
        \\            .url =
    );
    try appendZigString(&out, allocator, frontend.devUrl());
    try out.appendSlice(allocator,
        \\,
        \\            .command = .{ "npm", "--prefix", "frontend", "run", "dev"
    );
    if (frontend != .next) {
        try out.appendSlice(allocator,
            \\, "--", "--host", "127.0.0.1"
        );
    }
    try out.appendSlice(allocator,
        \\ },
        \\            .ready_path = "/",
        \\            .timeout_ms = 30000,
        \\        },
        \\    },
        \\    .security = .{
        \\        .navigation = .{
        \\            .allowed_origins = .{ "zero://app", "zero://inline",
    );
    try out.appendSlice(allocator, " ");
    const dev_origin = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{s}", .{frontend.devPort()});
    defer allocator.free(dev_origin);
    try appendZigString(&out, allocator, dev_origin);
    try out.appendSlice(allocator,
        \\ },
        \\            .external_links = .{ .action = "deny" },
        \\        },
        \\    },
        \\    .web_engine = "system",
        \\    .cef = .{ .dir = "third_party/cef/macos", .auto_install = false },
        \\    .windows = .{
        \\        .{ .label = "main", .title =
    );
    try appendZigString(&out, allocator, names.display_name);
    try out.appendSlice(allocator,
        \\, .width = 720, .height = 480, .restore_state = true },
        \\    },
        \\}
        \\
    );
    return out.toOwnedSlice(allocator);
}

fn writeFrontendFiles(allocator: std.mem.Allocator, io: std.Io, app_dir: std.Io.Dir, names: TemplateNames, frontend: Frontend) !void {
    switch (frontend) {
        .next => try writeNextFrontend(allocator, io, app_dir, names),
        .vite => try writeViteFrontend(allocator, io, app_dir, names),
        .react => try writeReactFrontend(allocator, io, app_dir, names),
        .svelte => try writeSvelteFrontend(allocator, io, app_dir, names),
        .vue => try writeVueFrontend(allocator, io, app_dir, names),
        // Native apps never reach here: writeDefaultApp dispatches to
        // writeNativeApp before any frontend files are written.
        .native => unreachable,
    }
}

fn writeNextFrontend(allocator: std.mem.Allocator, io: std.Io, app_dir: std.Io.Dir, names: TemplateNames) !void {
    try app_dir.createDirPath(io, "frontend/app");
    const package_json = try nextPackageJson(allocator, names);
    defer allocator.free(package_json);
    try writeFile(app_dir, io, "frontend/package.json", package_json);
    try writeFile(app_dir, io, "frontend/next.config.js", nextConfig());
    try writeFile(app_dir, io, "frontend/tsconfig.json", nextTsconfig());
    const layout = try nextLayout(allocator, names);
    defer allocator.free(layout);
    try writeFile(app_dir, io, "frontend/app/layout.tsx", layout);
    const page = try nextPage(allocator, names);
    defer allocator.free(page);
    try writeFile(app_dir, io, "frontend/app/page.tsx", page);
    try writeFile(app_dir, io, "frontend/app/globals.css", frontendStylesCss());
}

fn writeViteFrontend(allocator: std.mem.Allocator, io: std.Io, app_dir: std.Io.Dir, names: TemplateNames) !void {
    try app_dir.createDirPath(io, "frontend/src");
    const package_json = try vitePackageJson(allocator, names);
    defer allocator.free(package_json);
    const index_html = try viteIndexHtml(allocator, names);
    defer allocator.free(index_html);
    try writeFile(app_dir, io, "frontend/package.json", package_json);
    try writeFile(app_dir, io, "frontend/index.html", index_html);
    try writeFile(app_dir, io, "frontend/src/main.js", viteMainJs());
    try writeFile(app_dir, io, "frontend/src/styles.css", frontendStylesCss());
}

fn writeReactFrontend(allocator: std.mem.Allocator, io: std.Io, app_dir: std.Io.Dir, names: TemplateNames) !void {
    try app_dir.createDirPath(io, "frontend/src");
    const package_json = try reactPackageJson(allocator, names);
    defer allocator.free(package_json);
    const index_html = try reactIndexHtml(allocator, names);
    defer allocator.free(index_html);
    const app_tsx = try reactAppTsx(allocator, names);
    defer allocator.free(app_tsx);
    try writeFile(app_dir, io, "frontend/package.json", package_json);
    try writeFile(app_dir, io, "frontend/vite.config.js", reactViteConfig());
    try writeFile(app_dir, io, "frontend/index.html", index_html);
    try writeFile(app_dir, io, "frontend/src/main.tsx", reactMainTsx());
    try writeFile(app_dir, io, "frontend/src/App.tsx", app_tsx);
    try writeFile(app_dir, io, "frontend/src/index.css", frontendStylesCss());
}

fn writeSvelteFrontend(allocator: std.mem.Allocator, io: std.Io, app_dir: std.Io.Dir, names: TemplateNames) !void {
    try app_dir.createDirPath(io, "frontend/src");
    const package_json = try sveltePackageJson(allocator, names);
    defer allocator.free(package_json);
    const index_html = try svelteIndexHtml(allocator, names);
    defer allocator.free(index_html);
    try writeFile(app_dir, io, "frontend/package.json", package_json);
    try writeFile(app_dir, io, "frontend/svelte.config.js", svelteConfig());
    try writeFile(app_dir, io, "frontend/vite.config.js", svelteViteConfig());
    try writeFile(app_dir, io, "frontend/index.html", index_html);
    try writeFile(app_dir, io, "frontend/src/main.js", svelteMainJs());
    try writeFile(app_dir, io, "frontend/src/App.svelte", svelteAppComponent(names));
    try writeFile(app_dir, io, "frontend/src/app.css", frontendStylesCss());
}

fn writeVueFrontend(allocator: std.mem.Allocator, io: std.Io, app_dir: std.Io.Dir, names: TemplateNames) !void {
    try app_dir.createDirPath(io, "frontend/src");
    const package_json = try vuePackageJson(allocator, names);
    defer allocator.free(package_json);
    const index_html = try vueIndexHtml(allocator, names);
    defer allocator.free(index_html);
    try writeFile(app_dir, io, "frontend/package.json", package_json);
    try writeFile(app_dir, io, "frontend/vite.config.js", vueViteConfig());
    try writeFile(app_dir, io, "frontend/index.html", index_html);
    try writeFile(app_dir, io, "frontend/src/main.js", vueMainJs());
    try writeFile(app_dir, io, "frontend/src/App.vue", vueAppComponent(names));
    try writeFile(app_dir, io, "frontend/src/style.css", frontendStylesCss());
}

fn nextPackageJson(allocator: std.mem.Allocator, names: TemplateNames) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\n  \"name\": ");
    try appendJsonString(&out, allocator, names.package_name);
    try out.appendSlice(allocator,
        \\,
        \\  "private": true,
        \\  "version": "0.1.0",
        \\  "scripts": {
        \\    "dev": "next dev",
        \\    "build": "next build",
        \\    "start": "next start"
        \\  },
        \\  "dependencies": {
        \\    "next": "^16.2.6",
        \\    "react": "^19.2.6",
        \\    "react-dom": "^19.2.6"
        \\  },
        \\  "devDependencies": {
        \\    "@types/node": "^25.6.2",
        \\    "@types/react": "^19.2.14",
        \\    "@types/react-dom": "^19.2.3",
        \\    "typescript": "^6.0.3"
        \\  }
        \\}
        \\
    );
    return out.toOwnedSlice(allocator);
}

fn nextConfig() []const u8 {
    return
    \\/** @type {import('next').NextConfig} */
    \\const nextConfig = {
    \\  output: "export",
    \\};
    \\
    \\module.exports = nextConfig;
    \\
    ;
}

fn nextTsconfig() []const u8 {
    return
    \\{
    \\  "compilerOptions": {
    \\    "target": "ES2017",
    \\    "lib": ["dom", "dom.iterable", "esnext"],
    \\    "allowJs": true,
    \\    "skipLibCheck": true,
    \\    "strict": true,
    \\    "noEmit": true,
    \\    "esModuleInterop": true,
    \\    "module": "esnext",
    \\    "moduleResolution": "bundler",
    \\    "resolveJsonModule": true,
    \\    "isolatedModules": true,
    \\    "jsx": "react-jsx",
    \\    "incremental": true,
    \\    "plugins": [{ "name": "next" }],
    \\    "paths": { "@/*": ["./app/*"] }
    \\  },
    \\  "include": ["next-env.d.ts", "**/*.ts", "**/*.tsx", ".next/types/**/*.ts", ".next/dev/types/**/*.ts"],
    \\  "exclude": ["node_modules"]
    \\}
    \\
    ;
}

fn nextLayout(allocator: std.mem.Allocator, names: TemplateNames) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator,
        \\import "./globals.css";
        \\
        \\export const metadata = {
        \\  title: "
    );
    try out.appendSlice(allocator, names.display_name);
    try out.appendSlice(allocator,
        \\",
        \\};
        \\
        \\export default function RootLayout({ children }: { children: React.ReactNode }) {
        \\  return (
        \\    <html lang="en">
        \\      <body>{children}</body>
        \\    </html>
        \\  );
        \\}
        \\
    );
    return out.toOwnedSlice(allocator);
}

fn nextPage(allocator: std.mem.Allocator, names: TemplateNames) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator,
        \\"use client";
        \\
        \\import { useEffect, useState } from "react";
        \\
        \\export default function Home() {
        \\  const [bridge, setBridge] = useState("checking...");
        \\
        \\  useEffect(() => {
        \\    setBridge((window as any).zero ? "available" : "not enabled");
        \\  }, []);
        \\
        \\  return (
        \\    <main>
        \\      <p className="eyebrow">Native SDK + Next.js</p>
        \\      <h1>
    );
    try out.appendSlice(allocator, names.display_name);
    try out.appendSlice(allocator,
        \\</h1>
        \\      <p className="lede">A Next.js frontend running inside the system WebView.</p>
        \\      <div className="card">
        \\        <span>Native bridge</span>
        \\        <strong>{bridge}</strong>
        \\      </div>
        \\    </main>
        \\  );
        \\}
        \\
    );
    return out.toOwnedSlice(allocator);
}

fn vitePackageJson(allocator: std.mem.Allocator, names: TemplateNames) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\n  \"name\": ");
    try appendJsonString(&out, allocator, names.package_name);
    try out.appendSlice(allocator,
        \\,
        \\  "private": true,
        \\  "version": "0.1.0",
        \\  "type": "module",
        \\  "scripts": {
        \\    "dev": "vite",
        \\    "build": "vite build",
        \\    "preview": "vite preview"
        \\  },
        \\  "devDependencies": {
        \\    "vite": "^8.0.11"
        \\  }
        \\}
        \\
    );
    return out.toOwnedSlice(allocator);
}

fn viteIndexHtml(allocator: std.mem.Allocator, names: TemplateNames) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator,
        \\<!doctype html>
        \\<html lang="en">
        \\  <head>
        \\    <meta charset="UTF-8" />
        \\    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
        \\    <meta http-equiv="Content-Security-Policy" content="default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self' http://127.0.0.1:5173 ws://127.0.0.1:5173" />
        \\    <title>
    );
    try out.appendSlice(allocator, names.display_name);
    try out.appendSlice(allocator,
        \\</title>
        \\  </head>
        \\  <body>
        \\    <main id="app">
        \\      <p class="eyebrow">Native SDK + Vite</p>
        \\      <h1>
    );
    try out.appendSlice(allocator, names.display_name);
    try out.appendSlice(allocator,
        \\</h1>
        \\      <p class="lede">A minimal web frontend running inside the system WebView.</p>
        \\      <div class="card">
        \\        <span>Native bridge</span>
        \\        <strong id="bridge-status">checking...</strong>
        \\      </div>
        \\    </main>
        \\    <script type="module" src="/src/main.js"></script>
        \\  </body>
        \\</html>
        \\
    );
    return out.toOwnedSlice(allocator);
}

fn viteMainJs() []const u8 {
    return
    \\import "./styles.css";
    \\
    \\const bridgeStatus = document.querySelector("#bridge-status");
    \\const hasBridge = typeof window !== "undefined" && Boolean(window.zero);
    \\
    \\bridgeStatus.textContent = hasBridge ? "available" : "not enabled";
    \\bridgeStatus.dataset.ready = "true";
    \\
    ;
}

fn frontendStylesCss() []const u8 {
    return
    \\:root {
    \\  color: #0f172a;
    \\  background: #f8fafc;
    \\  font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    \\}
    \\
    \\body {
    \\  min-width: 320px;
    \\  min-height: 100vh;
    \\  margin: 0;
    \\  display: grid;
    \\  place-items: center;
    \\}
    \\
    \\main {
    \\  width: min(560px, calc(100vw - 48px));
    \\  padding: 32px;
    \\  border-radius: 24px;
    \\  background: white;
    \\  box-shadow: 0 24px 60px rgba(15, 23, 42, 0.14);
    \\}
    \\
    \\h1 {
    \\  margin: 0 0 12px;
    \\  font-size: clamp(2rem, 8vw, 4rem);
    \\  line-height: 1;
    \\}
    \\
    \\.eyebrow {
    \\  margin: 0 0 12px;
    \\  color: #2563eb;
    \\  font-weight: 700;
    \\  letter-spacing: 0.08em;
    \\  text-transform: uppercase;
    \\}
    \\
    \\.lede {
    \\  margin: 0 0 24px;
    \\  color: #475569;
    \\  line-height: 1.6;
    \\}
    \\
    \\.card {
    \\  display: flex;
    \\  align-items: center;
    \\  justify-content: space-between;
    \\  gap: 16px;
    \\  padding: 16px;
    \\  border: 1px solid #e2e8f0;
    \\  border-radius: 16px;
    \\  background: #f8fafc;
    \\}
    \\
    ;
}

fn reactPackageJson(allocator: std.mem.Allocator, names: TemplateNames) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\n  \"name\": ");
    try appendJsonString(&out, allocator, names.package_name);
    try out.appendSlice(allocator,
        \\,
        \\  "private": true,
        \\  "version": "0.1.0",
        \\  "type": "module",
        \\  "scripts": {
        \\    "dev": "vite",
        \\    "build": "vite build",
        \\    "preview": "vite preview"
        \\  },
        \\  "dependencies": {
        \\    "react": "^19.2.6",
        \\    "react-dom": "^19.2.6"
        \\  },
        \\  "devDependencies": {
        \\    "@types/react": "^19.2.14",
        \\    "@types/react-dom": "^19.2.3",
        \\    "@vitejs/plugin-react": "^6.0.1",
        \\    "vite": "^8.0.11"
        \\  }
        \\}
        \\
    );
    return out.toOwnedSlice(allocator);
}

fn reactViteConfig() []const u8 {
    return
    \\import { defineConfig } from "vite";
    \\import react from "@vitejs/plugin-react";
    \\
    \\export default defineConfig({
    \\  plugins: [react()],
    \\});
    \\
    ;
}

fn reactIndexHtml(allocator: std.mem.Allocator, names: TemplateNames) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator,
        \\<!doctype html>
        \\<html lang="en">
        \\  <head>
        \\    <meta charset="UTF-8" />
        \\    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
        \\    <title>
    );
    try out.appendSlice(allocator, names.display_name);
    try out.appendSlice(allocator,
        \\</title>
        \\  </head>
        \\  <body>
        \\    <div id="root"></div>
        \\    <script type="module" src="/src/main.tsx"></script>
        \\  </body>
        \\</html>
        \\
    );
    return out.toOwnedSlice(allocator);
}

fn reactMainTsx() []const u8 {
    return
    \\import { StrictMode } from "react";
    \\import { createRoot } from "react-dom/client";
    \\import App from "./App";
    \\import "./index.css";
    \\
    \\createRoot(document.getElementById("root")!).render(
    \\  <StrictMode>
    \\    <App />
    \\  </StrictMode>
    \\);
    \\
    ;
}

fn reactAppTsx(allocator: std.mem.Allocator, names: TemplateNames) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator,
        \\import { useEffect, useState } from "react";
        \\
        \\export default function App() {
        \\  const [bridge, setBridge] = useState("checking...");
        \\
        \\  useEffect(() => {
        \\    setBridge((window as any).zero ? "available" : "not enabled");
        \\  }, []);
        \\
        \\  return (
        \\    <main>
        \\      <p className="eyebrow">Native SDK + React</p>
        \\      <h1>
    );
    try out.appendSlice(allocator, names.display_name);
    try out.appendSlice(allocator,
        \\</h1>
        \\      <p className="lede">A React frontend running inside the system WebView.</p>
        \\      <div className="card">
        \\        <span>Native bridge</span>
        \\        <strong>{bridge}</strong>
        \\      </div>
        \\    </main>
        \\  );
        \\}
        \\
    );
    return out.toOwnedSlice(allocator);
}

fn sveltePackageJson(allocator: std.mem.Allocator, names: TemplateNames) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\n  \"name\": ");
    try appendJsonString(&out, allocator, names.package_name);
    try out.appendSlice(allocator,
        \\,
        \\  "private": true,
        \\  "version": "0.1.0",
        \\  "type": "module",
        \\  "scripts": {
        \\    "dev": "vite",
        \\    "build": "vite build",
        \\    "preview": "vite preview"
        \\  },
        \\  "dependencies": {
        \\    "svelte": "^5.55.5"
        \\  },
        \\  "devDependencies": {
        \\    "@sveltejs/vite-plugin-svelte": "^7.1.2",
        \\    "vite": "^8.0.11"
        \\  }
        \\}
        \\
    );
    return out.toOwnedSlice(allocator);
}

fn svelteViteConfig() []const u8 {
    return
    \\import { defineConfig } from "vite";
    \\import { svelte } from "@sveltejs/vite-plugin-svelte";
    \\
    \\export default defineConfig({
    \\  plugins: [svelte()],
    \\});
    \\
    ;
}

fn svelteConfig() []const u8 {
    return
    \\export default {};
    \\
    ;
}

fn svelteIndexHtml(allocator: std.mem.Allocator, names: TemplateNames) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator,
        \\<!doctype html>
        \\<html lang="en">
        \\  <head>
        \\    <meta charset="UTF-8" />
        \\    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
        \\    <title>
    );
    try out.appendSlice(allocator, names.display_name);
    try out.appendSlice(allocator,
        \\</title>
        \\  </head>
        \\  <body>
        \\    <div id="app"></div>
        \\    <script type="module" src="/src/main.js"></script>
        \\  </body>
        \\</html>
        \\
    );
    return out.toOwnedSlice(allocator);
}

fn svelteMainJs() []const u8 {
    return
    \\import App from "./App.svelte";
    \\import "./app.css";
    \\
    \\const app = new App({ target: document.getElementById("app") });
    \\
    \\export default app;
    \\
    ;
}

fn svelteAppComponent(names: TemplateNames) []const u8 {
    _ = names;
    return
    \\<script>
    \\  import { onMount } from "svelte";
    \\
    \\  let bridge = $state("checking...");
    \\
    \\  onMount(() => {
    \\    bridge = window.zero ? "available" : "not enabled";
    \\  });
    \\</script>
    \\
    \\<main>
    \\  <p class="eyebrow">Native SDK + Svelte</p>
    \\  <h1>App</h1>
    \\  <p class="lede">A Svelte frontend running inside the system WebView.</p>
    \\  <div class="card">
    \\    <span>Native bridge</span>
    \\    <strong>{bridge}</strong>
    \\  </div>
    \\</main>
    \\
    ;
}

fn vuePackageJson(allocator: std.mem.Allocator, names: TemplateNames) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\n  \"name\": ");
    try appendJsonString(&out, allocator, names.package_name);
    try out.appendSlice(allocator,
        \\,
        \\  "private": true,
        \\  "version": "0.1.0",
        \\  "type": "module",
        \\  "scripts": {
        \\    "dev": "vite",
        \\    "build": "vite build",
        \\    "preview": "vite preview"
        \\  },
        \\  "dependencies": {
        \\    "vue": "^3.5.34"
        \\  },
        \\  "devDependencies": {
        \\    "@vitejs/plugin-vue": "^6.0.6",
        \\    "vite": "^8.0.11"
        \\  }
        \\}
        \\
    );
    return out.toOwnedSlice(allocator);
}

fn vueViteConfig() []const u8 {
    return
    \\import { defineConfig } from "vite";
    \\import vue from "@vitejs/plugin-vue";
    \\
    \\export default defineConfig({
    \\  plugins: [vue()],
    \\});
    \\
    ;
}

fn vueIndexHtml(allocator: std.mem.Allocator, names: TemplateNames) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator,
        \\<!doctype html>
        \\<html lang="en">
        \\  <head>
        \\    <meta charset="UTF-8" />
        \\    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
        \\    <title>
    );
    try out.appendSlice(allocator, names.display_name);
    try out.appendSlice(allocator,
        \\</title>
        \\  </head>
        \\  <body>
        \\    <div id="app"></div>
        \\    <script type="module" src="/src/main.js"></script>
        \\  </body>
        \\</html>
        \\
    );
    return out.toOwnedSlice(allocator);
}

fn vueMainJs() []const u8 {
    return
    \\import { createApp } from "vue";
    \\import App from "./App.vue";
    \\import "./style.css";
    \\
    \\createApp(App).mount("#app");
    \\
    ;
}

fn vueAppComponent(names: TemplateNames) []const u8 {
    _ = names;
    return
    \\<script setup>
    \\import { ref, onMounted } from "vue";
    \\
    \\const bridge = ref("checking...");
    \\
    \\onMounted(() => {
    \\  bridge.value = window.zero ? "available" : "not enabled";
    \\});
    \\</script>
    \\
    \\<template>
    \\  <main>
    \\    <p class="eyebrow">Native SDK + Vue</p>
    \\    <h1>App</h1>
    \\    <p class="lede">A Vue frontend running inside the system WebView.</p>
    \\    <div class="card">
    \\      <span>Native bridge</span>
    \\      <strong>{{ bridge }}</strong>
    \\    </div>
    \\  </main>
    \\</template>
    \\
    ;
}

fn readme(allocator: std.mem.Allocator, names: TemplateNames, framework_path: []const u8, frontend: Frontend) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "# ");
    try out.appendSlice(allocator, names.display_name);
    try out.appendSlice(allocator,
        \\
        \\
        \\A minimal native-sdk desktop app with a web frontend.
        \\
        \\## Setup
        \\
        \\`zig build dev`, `zig build run`, and `zig build package` install frontend dependencies automatically. To install them explicitly, run:
        \\
        \\```sh
        \\npm install --prefix frontend
        \\```
        \\
        \\The generated build defaults to this Native SDK framework path:
        \\
        \\```text
    );
    try out.append(allocator, '\n');
    try out.appendSlice(allocator, framework_path);
    try out.append(allocator, '\n');
    try out.appendSlice(allocator,
        \\
        \\```
        \\
        \\Override it with `-Dnative-sdk-path=/path/to/native-sdk` if you move this app.
        \\
        \\## Commands
        \\
        \\```sh
        \\zig build dev
        \\zig build run
        \\zig build test
        \\zig build package
        \\native doctor --manifest app.zon
        \\```
        \\
        \\`zig build dev` starts the frontend dev server from `app.zon`, waits for it, and launches the native shell with `NATIVE_SDK_FRONTEND_URL`.
        \\
        \\Frontend:
        \\
        \\- Type: 
    );
    try out.appendSlice(allocator, @tagName(frontend));
    try out.appendSlice(allocator,
        \\
        \\- Production assets: `
    );
    try out.appendSlice(allocator, frontend.distDir());
    try out.appendSlice(allocator,
        \\`
        \\- Dev URL: `
    );
    try out.appendSlice(allocator, frontend.devUrl());
    try out.appendSlice(allocator,
        \\`
        \\
        \\## Web Engines
        \\
        \\The generated app defaults to the system WebView. On macOS you can switch to Chromium/CEF with:
        \\
        \\```sh
        \\native cef install
        \\zig build run -Dplatform=macos -Dweb-engine=chromium
        \\```
        \\
        \\`native cef install` downloads Native SDK's prepared CEF runtime, including the native wrapper library.
        \\
        \\For one-command local setup, opt into build-time install:
        \\
        \\```sh
        \\zig build run -Dplatform=macos -Dweb-engine=chromium -Dcef-auto-install=true
        \\```
        \\
        \\Use `-Dcef-dir=/path/to/cef` when you keep CEF outside the platform default under `third_party/cef`.
        \\
        \\```sh
        \\native doctor --web-engine chromium
        \\```
        \\
        \\Diagnostics:
        \\
        \\- Set `NATIVE_SDK_LOG_DIR` to override the platform log directory during development.
        \\- Set `NATIVE_SDK_LOG_FORMAT=text|jsonl` to choose persistent log format.
        \\
    );
    return out.toOwnedSlice(allocator);
}

test "template strings are non-empty" {
    const names = try TemplateNames.init(std.testing.allocator, "app");
    defer names.deinit(std.testing.allocator);
    const build_zig = try buildZig(std.testing.allocator, names, "..", .vite);
    defer std.testing.allocator.free(build_zig);
    const main_zig = try mainZig(std.testing.allocator, names, .vite);
    defer std.testing.allocator.free(main_zig);
    try std.testing.expect(build_zig.len > 0);
    try std.testing.expect(main_zig.len > 0);
    try std.testing.expect(runnerZig().len > 0);
}

test "template names are sanitized for generated metadata" {
    const names = try TemplateNames.init(std.testing.allocator, "My Cool_App!");
    defer names.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("my-cool-app", names.package_name);
    try std.testing.expectEqualStrings("my_cool_app", names.module_name);
    try std.testing.expectEqualStrings("My Cool App", names.display_name);
    try std.testing.expectEqualStrings("dev.native_sdk.my-cool-app", names.app_id);
}

test "template fingerprint includes package name checksum" {
    try std.testing.expectEqual(@as(u64, 0x92a6f71c5a707070), fingerprintForName("test_vite_init_smoke"));
}

test "writeDefaultApp emits Vite project files" {
    const destination = ".zig-cache/test-vite-init-template";
    try writeDefaultApp(std.testing.allocator, std.testing.io, destination, .{ .app_name = "My App", .framework_path = ".", .frontend = .vite });

    const app_zon_text = try readTestFile(std.testing.allocator, std.testing.io, destination, "app.zon");
    defer std.testing.allocator.free(app_zon_text);
    const build_zig_text = try readTestFile(std.testing.allocator, std.testing.io, destination, "build.zig");
    defer std.testing.allocator.free(build_zig_text);
    const main_zig_text = try readTestFile(std.testing.allocator, std.testing.io, destination, "src/main.zig");
    defer std.testing.allocator.free(main_zig_text);
    const runner_zig_text = try readTestFile(std.testing.allocator, std.testing.io, destination, "src/runner.zig");
    defer std.testing.allocator.free(runner_zig_text);
    const package_json_text = try readTestFile(std.testing.allocator, std.testing.io, destination, "frontend/package.json");
    defer std.testing.allocator.free(package_json_text);
    const main_js_text = try readTestFile(std.testing.allocator, std.testing.io, destination, "frontend/src/main.js");
    defer std.testing.allocator.free(main_js_text);

    try std.testing.expect(std.mem.indexOf(u8, app_zon_text, ".frontend") != null);
    try std.testing.expect(std.mem.indexOf(u8, app_zon_text, "frontend/dist") != null);
    try std.testing.expect(std.mem.indexOf(u8, app_zon_text, "npm") != null);
    try std.testing.expect(std.mem.indexOf(u8, app_zon_text, ".windows") != null);
    try std.testing.expect(std.mem.indexOf(u8, build_zig_text, "frontend-install") != null);
    try std.testing.expect(std.mem.indexOf(u8, build_zig_text, "\"npm\", \"install\", \"--prefix\", \"frontend\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, build_zig_text, "frontend-build") != null);
    try std.testing.expect(std.mem.indexOf(u8, build_zig_text, "frontend_build.step.dependOn(&frontend_install.step)") != null);
    try std.testing.expect(std.mem.indexOf(u8, build_zig_text, "\"native\", \"dev\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, build_zig_text, "dev.step.dependOn(&frontend_install.step)") != null);
    try std.testing.expect(std.mem.indexOf(u8, build_zig_text, "addWebView2RuntimeRunFiles(b, target, dev, web_engine, web_layer, native_sdk_path)") != null);
    try std.testing.expect(std.mem.indexOf(u8, build_zig_text, "package.setEnvironmentVariable(\"NATIVE_SDK_PATH\", b.pathFromRoot(native_sdk_path))") != null);
    try std.testing.expect(std.mem.indexOf(u8, build_zig_text, "chromium") != null);
    try std.testing.expect(std.mem.indexOf(u8, build_zig_text, "cef-dir") != null);
    try std.testing.expect(std.mem.indexOf(u8, build_zig_text, "src/platform/macos/cef_host.mm") != null);
    try std.testing.expect(std.mem.indexOf(u8, build_zig_text, "src/platform/linux/gtk_host.c") != null);
    try std.testing.expect(std.mem.indexOf(u8, build_zig_text, "app_manifest_zon") != null);
    // The generated graph carries the whole web-layer feature: the
    // override option, the app.zon inference with its conflict panic,
    // the option handed to the runner, and the conditional WebView2
    // wiring (include + source + loader when web, stubbed host and no
    // loader when native-only).
    try std.testing.expect(std.mem.indexOf(u8, build_zig_text, "b.option(WebLayerOption, \"web-layer\", \"Override app.zon webview_layer: auto, include, exclude\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, build_zig_text, "const web_layer = resolveWebLayer(app_config, web_engine, web_layer_override)") != null);
    // The emitted package step forwards the graph's resolved decision so
    // the packaged artifact structurally agrees with the compiled exe.
    try std.testing.expect(std.mem.indexOf(u8, build_zig_text, "package.addArgs(&.{ \"--web-layer\", if (web_layer) \"include\" else \"exclude\" })") != null);
    try std.testing.expect(std.mem.indexOf(u8, build_zig_text, "options.addOption(bool, \"web_layer\", web_layer)") != null);
    try std.testing.expect(std.mem.indexOf(u8, build_zig_text, "std.zon.parse.fromSliceAlloc(InferenceManifest") != null);
    try std.testing.expect(std.mem.indexOf(u8, build_zig_text, "the web layer is excluded ({s}) but the app declares web use ({s})") != null);
    try std.testing.expect(std.mem.indexOf(u8, build_zig_text, ".system => if (web_layer) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, build_zig_text, "\"-DNATIVE_SDK_ALLOW_WEBVIEW2_STUB\"") != null);
    // The Linux seam mirrors it: gtk_host.c compiles with the WebKitGTK
    // stub define and webkitgtk-6.0 is not linked when native-only.
    try std.testing.expect(std.mem.indexOf(u8, build_zig_text, "\"-DNATIVE_SDK_ALLOW_WEBKITGTK_STUB\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, build_zig_text, "if (!web_layer) return;") != null);
    try std.testing.expect(std.mem.indexOf(u8, main_zig_text, "frontend/dist") != null);
    try std.testing.expect(std.mem.indexOf(u8, main_zig_text, "127.0.0.1:5173") != null);
    try std.testing.expect(std.mem.indexOf(u8, runner_zig_text, "@import(\"app_manifest_zon\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, runner_zig_text, "commands: ?[]const native_sdk.Command = null") != null);
    try std.testing.expect(std.mem.indexOf(u8, runner_zig_text, "resolvedCommands") != null);
    try std.testing.expect(std.mem.indexOf(u8, runner_zig_text, "menus: ?[]const native_sdk.Menu = null") != null);
    try std.testing.expect(std.mem.indexOf(u8, runner_zig_text, "resolvedMenus") != null);
    try std.testing.expect(std.mem.indexOf(u8, runner_zig_text, "shortcuts: ?[]const native_sdk.Shortcut = null") != null);
    try std.testing.expect(std.mem.indexOf(u8, runner_zig_text, "resolvedShortcuts") != null);
    try std.testing.expect(std.mem.indexOf(u8, runner_zig_text, "const manifest_windows") != null);
    try std.testing.expect(std.mem.indexOf(u8, runner_zig_text, "fn appInfo(self: RunOptions, buffers: *StateBuffers)") != null);
    try std.testing.expect(std.mem.indexOf(u8, runner_zig_text, "fn manifestWindowOptions") != null);
    try std.testing.expect(std.mem.indexOf(u8, runner_zig_text, "info.windows = windows") != null);
    try std.testing.expect(std.mem.indexOf(u8, runner_zig_text, "for (restored_windows, 0..)") != null);
    // The Runtime is multi-megabyte; the generated runner must heap-allocate
    // it and construct in place, never build it by value on the stack.
    try std.testing.expect(std.mem.indexOf(u8, runner_zig_text, "std.heap.page_allocator.create(native_sdk.Runtime)") != null);
    try std.testing.expect(std.mem.indexOf(u8, runner_zig_text, "defer std.heap.page_allocator.destroy(runtime)") != null);
    try std.testing.expect(std.mem.indexOf(u8, runner_zig_text, "native_sdk.Runtime.initAt(runtime, .{") != null);
    try std.testing.expect(std.mem.indexOf(u8, runner_zig_text, "Runtime.init(.{") == null);
    // The generated runner consumes the same web-layer contract: the
    // shared inference for honest menus, the build option threaded into
    // every runtime init, and the comptime conflict guard.
    try std.testing.expect(std.mem.indexOf(u8, runner_zig_text, ".has_web_content = manifestHasWebContent()") != null);
    try std.testing.expect(std.mem.indexOf(u8, runner_zig_text, "native_sdk.app_manifest.web_layer.webDeclaration(app_manifest, engine)") != null);
    try std.testing.expect(std.mem.indexOf(u8, runner_zig_text, ".web_layer = webLayerEnabled(),") != null);
    try std.testing.expect(std.mem.indexOf(u8, runner_zig_text, "@compileError(\"this build excludes the web layer") != null);
    try std.testing.expect(std.mem.indexOf(u8, package_json_text, "\"vite\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, main_js_text, "window.zero") != null);

    const ci_yaml_text = try readTestFile(std.testing.allocator, std.testing.io, destination, ".github/workflows/ci.yml");
    defer std.testing.allocator.free(ci_yaml_text);
    try expectBasicYaml(ci_yaml_text);
    try std.testing.expect(std.mem.indexOf(u8, ci_yaml_text, "zig build test -Dplatform=null -Dnative-sdk-path=\"$NATIVE_SDK_PATH\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ci_yaml_text, "mlugg/setup-zig@v2") != null);
    // Web-frontend workflows stop at logic tests: the automation smoke
    // recipe is native-app specific.
    try std.testing.expect(std.mem.indexOf(u8, ci_yaml_text, "smoke:") == null);
}

test "writeDefaultApp emits frontend-specific Next paths" {
    const destination = ".zig-cache/test-next-init-template";
    try writeDefaultApp(std.testing.allocator, std.testing.io, destination, .{ .app_name = "Next App", .framework_path = ".", .frontend = .next });

    const app_zon_text = try readTestFile(std.testing.allocator, std.testing.io, destination, "app.zon");
    defer std.testing.allocator.free(app_zon_text);
    const build_zig_text = try readTestFile(std.testing.allocator, std.testing.io, destination, "build.zig");
    defer std.testing.allocator.free(build_zig_text);
    const main_zig_text = try readTestFile(std.testing.allocator, std.testing.io, destination, "src/main.zig");
    defer std.testing.allocator.free(main_zig_text);
    const tsconfig_text = try readTestFile(std.testing.allocator, std.testing.io, destination, "frontend/tsconfig.json");
    defer std.testing.allocator.free(tsconfig_text);

    try std.testing.expect(std.mem.indexOf(u8, app_zon_text, "frontend/out") != null);
    try std.testing.expect(std.mem.indexOf(u8, app_zon_text, "127.0.0.1:3000") != null);
    try std.testing.expect(std.mem.indexOf(u8, build_zig_text, "frontend/out") != null);
    try std.testing.expect(std.mem.indexOf(u8, main_zig_text, "frontend/out") != null);
    try std.testing.expect(std.mem.indexOf(u8, main_zig_text, "127.0.0.1:3000") != null);
    try std.testing.expect(std.mem.indexOf(u8, tsconfig_text, "\"@/*\": [\"./app/*\"]") != null);
}

test "writeDefaultApp emits a slim native scaffold by default" {
    const destination = ".zig-cache/test-native-slim-template";
    try writeDefaultApp(std.testing.allocator, std.testing.io, destination, .{ .app_name = "My App", .framework_path = ".", .frontend = .native });

    const app_zon_text = try readTestFile(std.testing.allocator, std.testing.io, destination, "app.zon");
    defer std.testing.allocator.free(app_zon_text);
    const main_zig_text = try readTestFile(std.testing.allocator, std.testing.io, destination, "src/main.zig");
    defer std.testing.allocator.free(main_zig_text);
    const gitignore_text = try readTestFile(std.testing.allocator, std.testing.io, destination, ".gitignore");
    defer std.testing.allocator.free(gitignore_text);
    const readme_text = try readTestFile(std.testing.allocator, std.testing.io, destination, "README.md");
    defer std.testing.allocator.free(readme_text);
    const icon = try readTestFile(std.testing.allocator, std.testing.io, destination, "assets/icon.png");
    defer std.testing.allocator.free(icon);

    // Zero-config: no build files, no editor config, no CI workflow.
    try std.testing.expectError(error.FileNotFound, readTestFile(std.testing.allocator, std.testing.io, destination, "build.zig"));
    try std.testing.expectError(error.FileNotFound, readTestFile(std.testing.allocator, std.testing.io, destination, "build.zig.zon"));
    try std.testing.expectError(error.FileNotFound, readTestFile(std.testing.allocator, std.testing.io, destination, ".vscode/settings.json"));
    try std.testing.expectError(error.FileNotFound, readTestFile(std.testing.allocator, std.testing.io, destination, ".github/workflows/ci.yml"));

    try std.testing.expect(std.mem.indexOf(u8, app_zon_text, "gpu_surface") != null);
    try std.testing.expect(std.mem.indexOf(u8, main_zig_text, "native_sdk.UiApp(Model, Msg)") != null);
    // The generated + derived state is ignored wholesale.
    try std.testing.expect(std.mem.indexOf(u8, gitignore_text, ".native/") != null);
    try std.testing.expect(std.mem.indexOf(u8, gitignore_text, "zig-out/") != null);
    // The README teaches the native verbs, not zig build.
    try std.testing.expect(std.mem.indexOf(u8, readme_text, "native dev") != null);
    try std.testing.expect(std.mem.indexOf(u8, readme_text, "native test") != null);
    try std.testing.expect(std.mem.indexOf(u8, readme_text, "native build") != null);
    try std.testing.expect(std.mem.indexOf(u8, readme_text, "native check") != null);
    try std.testing.expect(std.mem.indexOf(u8, readme_text, "native eject") != null);
    try std.testing.expect(std.mem.indexOf(u8, readme_text, "zig build run") == null);
}

test "writeDefaultApp emits native project files" {
    const destination = ".zig-cache/test-native-init-template";
    try writeDefaultApp(std.testing.allocator, std.testing.io, destination, .{ .app_name = "My App", .framework_path = ".", .frontend = .native, .shape = .full });

    const app_zon_text = try readTestFile(std.testing.allocator, std.testing.io, destination, "app.zon");
    defer std.testing.allocator.free(app_zon_text);
    const build_zig_text = try readTestFile(std.testing.allocator, std.testing.io, destination, "build.zig");
    defer std.testing.allocator.free(build_zig_text);
    const build_zon_text = try readTestFile(std.testing.allocator, std.testing.io, destination, "build.zig.zon");
    defer std.testing.allocator.free(build_zon_text);
    const main_zig_text = try readTestFile(std.testing.allocator, std.testing.io, destination, "src/main.zig");
    defer std.testing.allocator.free(main_zig_text);
    const app_markup_text = try readTestFile(std.testing.allocator, std.testing.io, destination, "src/app.native");
    defer std.testing.allocator.free(app_markup_text);
    const tests_zig_text = try readTestFile(std.testing.allocator, std.testing.io, destination, "src/tests.zig");
    defer std.testing.allocator.free(tests_zig_text);
    const vscode_text = try readTestFile(std.testing.allocator, std.testing.io, destination, ".vscode/settings.json");
    defer std.testing.allocator.free(vscode_text);
    const gitignore_text = try readTestFile(std.testing.allocator, std.testing.io, destination, ".gitignore");
    defer std.testing.allocator.free(gitignore_text);
    const readme_text = try readTestFile(std.testing.allocator, std.testing.io, destination, "README.md");
    defer std.testing.allocator.free(readme_text);

    // No WebView frontend files.
    try std.testing.expectError(error.FileNotFound, readTestFile(std.testing.allocator, std.testing.io, destination, "frontend/package.json"));
    try std.testing.expectError(error.FileNotFound, readTestFile(std.testing.allocator, std.testing.io, destination, "src/runner.zig"));

    try std.testing.expect(std.mem.indexOf(u8, app_zon_text, "gpu_surface") != null);
    try std.testing.expect(std.mem.indexOf(u8, app_zon_text, "\"native_views\", \"gpu_surfaces\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, app_zon_text, "dev.native_sdk.my-app") != null);
    try std.testing.expect(std.mem.indexOf(u8, app_zon_text, ".frontend") == null);
    try std.testing.expect(std.mem.indexOf(u8, build_zig_text, "native_sdk.addApp(b, b.dependency(\"native_sdk\", .{}), .{ .name = \"my-app\" })") != null);
    try std.testing.expect(std.mem.indexOf(u8, build_zon_text, ".native_sdk = .{ .path = ") != null);
    try std.testing.expect(std.mem.indexOf(u8, build_zon_text, ".name = .my_app") != null);
    try std.testing.expect(std.mem.indexOf(u8, main_zig_text, "native_sdk.UiApp(Model, Msg)") != null);
    try std.testing.expect(std.mem.indexOf(u8, main_zig_text, "@embedFile(\"app.native\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, main_zig_text, ".watch_path = \"src/app.native\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, app_markup_text, "on-press=\"increment\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tests_zig_text, "msgForPointer") != null);
    try std.testing.expect(std.mem.indexOf(u8, tests_zig_text, "canvas.MarkupView(Model, Msg)") != null);
    try std.testing.expect(std.mem.indexOf(u8, vscode_text, "\"*.native\": \"html\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, gitignore_text, "zig-out/") != null);
    try std.testing.expect(std.mem.indexOf(u8, readme_text, "native markup check src/app.native") != null);
    try std.testing.expect(std.mem.indexOf(u8, readme_text, "hot") != null or std.mem.indexOf(u8, readme_text, "Hot") != null);
}

test "writeDefaultApp emits a CI workflow for native apps" {
    const destination = ".zig-cache/test-native-ci-template";
    try writeDefaultApp(std.testing.allocator, std.testing.io, destination, .{ .app_name = "My App", .framework_path = ".", .frontend = .native, .shape = .full });

    const ci_yaml_text = try readTestFile(std.testing.allocator, std.testing.io, destination, ".github/workflows/ci.yml");
    defer std.testing.allocator.free(ci_yaml_text);

    try expectBasicYaml(ci_yaml_text);
    // Both jobs are present, sized for a user app.
    try std.testing.expect(std.mem.indexOf(u8, ci_yaml_text, "jobs:") != null);
    try std.testing.expect(std.mem.indexOf(u8, ci_yaml_text, "  test:") != null);
    try std.testing.expect(std.mem.indexOf(u8, ci_yaml_text, "  smoke:") != null);
    try std.testing.expect(std.mem.indexOf(u8, ci_yaml_text, "mlugg/setup-zig@v2") != null);
    try std.testing.expect(std.mem.indexOf(u8, ci_yaml_text, "version: 0.16.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, ci_yaml_text, "zig build test -Dplatform=null") != null);
    // The smoke job builds with automation, launches under Xvfb, and drives
    // the snapshot: the binary name comes from the template context. A
    // native app's smoke never needs WebKitGTK — its host compiles
    // without the embedded web layer.
    try std.testing.expect(std.mem.indexOf(u8, ci_yaml_text, "libgtk-4-dev xvfb") != null);
    try std.testing.expect(std.mem.indexOf(u8, ci_yaml_text, "libwebkitgtk-6.0-dev") == null);
    try std.testing.expect(std.mem.indexOf(u8, ci_yaml_text, "zig build -Dplatform=linux -Dweb-engine=system -Dautomation=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, ci_yaml_text, "xvfb-run -a ./zig-out/bin/my-app &") != null);
    try std.testing.expect(std.mem.indexOf(u8, ci_yaml_text, "automate wait") != null);
    try std.testing.expect(std.mem.indexOf(u8, ci_yaml_text, "automate assert 'gpu_nonblank=true' 'role=button name=\"Reset\"' 'count: 0'") != null);
    try std.testing.expect(std.mem.indexOf(u8, ci_yaml_text, "automate screenshot main-canvas") != null);
    try std.testing.expect(std.mem.indexOf(u8, ci_yaml_text, "test -s .zig-cache/native-sdk-automation/screenshot-main-canvas.png") != null);
    // The framework fetch step reuses the build.zig.zon dependency path.
    try std.testing.expect(std.mem.indexOf(u8, ci_yaml_text, "NATIVE_SDK_PATH:") != null);
    try std.testing.expect(std.mem.indexOf(u8, ci_yaml_text, "git clone --depth 1 https://github.com/vercel-labs/native.git \"$NATIVE_SDK_PATH\"") != null);
}

/// Structural sanity for generated workflows (the repo scaffold CI job runs
/// a real YAML parse over the generated file): top-level keys present, no
/// tabs, space indentation in even steps, no trailing whitespace.
fn expectBasicYaml(text: []const u8) !void {
    try std.testing.expect(std.mem.startsWith(u8, text, "name: CI\n"));
    try std.testing.expect(std.mem.indexOf(u8, text, "\non:\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\njobs:\n") != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, text, '\t') == null);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        try std.testing.expect(!std.ascii.isWhitespace(line[line.len - 1]));
        var indent: usize = 0;
        while (indent < line.len and line[indent] == ' ') indent += 1;
        try std.testing.expect(indent % 2 == 0);
    }
}

pub fn normalizePackageName(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var last_separator = false;
    for (value) |ch| {
        if (isAsciiAlpha(ch) or isAsciiDigit(ch)) {
            try out.append(allocator, std.ascii.toLower(ch));
            last_separator = false;
        } else if (!last_separator and out.items.len > 0) {
            try out.append(allocator, '-');
            last_separator = true;
        }
    }
    if (out.items.len > 0 and out.items[out.items.len - 1] == '-') _ = out.pop();
    if (out.items.len == 0) try out.appendSlice(allocator, "native-sdk-app");
    return out.toOwnedSlice(allocator);
}

pub fn normalizeModuleName(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    const max_zig_package_name_len = 32;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    if (value.len == 0 or isAsciiDigit(value[0])) try out.appendSlice(allocator, "app_");
    for (value) |ch| {
        if (out.items.len >= max_zig_package_name_len) break;
        if (isAsciiAlpha(ch) or isAsciiDigit(ch)) {
            try out.append(allocator, std.ascii.toLower(ch));
        } else {
            try out.append(allocator, '_');
        }
    }
    return out.toOwnedSlice(allocator);
}

test "normalizeModuleName caps Zig package names" {
    const module_name = try normalizeModuleName(std.testing.allocator, "scaffold-package-smoke-1778284313");
    defer std.testing.allocator.free(module_name);

    try std.testing.expect(module_name.len <= 32);
    try std.testing.expectEqualStrings("scaffold_package_smoke_177828431", module_name);
}

fn displayName(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var start_word = true;
    for (value) |ch| {
        if (ch == '-') {
            if (out.items.len > 0 and out.items[out.items.len - 1] != ' ') try out.append(allocator, ' ');
            start_word = true;
            continue;
        }
        if (start_word and isAsciiAlpha(ch)) {
            try out.append(allocator, std.ascii.toUpper(ch));
        } else {
            try out.append(allocator, ch);
        }
        start_word = false;
    }
    if (out.items.len == 0) try out.appendSlice(allocator, "Native SDK app");
    return out.toOwnedSlice(allocator);
}

pub fn fingerprintForName(name: []const u8) u64 {
    const checksum: u64 = std.hash.Crc32.hash(name);
    return (checksum << 32) | 0x5a707070;
}

fn defaultFrameworkPath(allocator: std.mem.Allocator, io: std.Io, destination: []const u8, framework_path: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(framework_path)) {
        return allocator.dupe(u8, framework_path);
    }
    if (std.fs.path.isAbsolute(destination)) {
        const cwd = try std.process.currentPathAlloc(io, allocator);
        defer allocator.free(cwd);
        return std.fs.path.join(allocator, &.{ cwd, framework_path });
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var destination_parts = std.mem.tokenizeAny(u8, destination, "/\\");
    while (destination_parts.next()) |part| {
        if (std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) continue;
        if (out.items.len > 0) try out.append(allocator, '/');
        try out.appendSlice(allocator, "..");
    }

    var framework_parts = std.mem.tokenizeAny(u8, framework_path, "/\\");
    while (framework_parts.next()) |part| {
        if (std.mem.eql(u8, part, ".")) continue;
        if (part.len == 0) continue;
        if (out.items.len > 0) try out.append(allocator, '/');
        try out.appendSlice(allocator, part);
    }

    if (out.items.len == 0) try out.append(allocator, '.');
    return out.toOwnedSlice(allocator);
}

/// The native_sdk dependency path for build.zig.zon: always relative to the
/// generated app root, since Zig rejects absolute paths in path dependencies.
/// `framework_path` comes from defaultFrameworkPath, so it is either already
/// destination-relative or absolute.
fn nativeDependencyPath(allocator: std.mem.Allocator, io: std.Io, destination: []const u8, framework_path: []const u8) ![]const u8 {
    if (!std.fs.path.isAbsolute(framework_path)) {
        return allocator.dupe(u8, framework_path);
    }

    // Resolve symlinks (e.g. /tmp -> /private/tmp on macOS) before computing
    // the relative path, so `..` segments traverse the real directory tree.
    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);
    const destination_real = try std.Io.Dir.cwd().realPathFileAlloc(io, destination, allocator);
    defer allocator.free(destination_real);
    const framework_real = try std.Io.Dir.realPathFileAbsoluteAlloc(io, framework_path, allocator);
    defer allocator.free(framework_real);

    const relative = try std.fs.path.relative(allocator, cwd, null, destination_real, framework_real);
    errdefer allocator.free(relative);
    // On Windows, two different volumes (drive letters or UNC shares) have
    // no relative path between them, and std.fs.path.relative degrades to
    // the absolute target — which build.zig.zon rejects. The full scaffold's
    // build files are user-owned from day one, so the CLI cannot bridge with
    // a junction it would never refresh; teach the constraint instead.
    if (junction.crossesVolumes(relative)) {
        std.debug.print(
            \\cannot scaffold a full-shape app at {s}:
            \\the Native SDK ({s})
            \\sits on a different Windows volume, and the scaffolded
            \\build.zig.zon needs a relative SDK path — no relative path
            \\crosses volumes.
            \\
        , .{ destination_real, framework_real });
        std.debug.print(junction.cross_volume_ways_out, .{});
        return error.CrossVolumeFramework;
    }
    if (relative.len == 0) {
        // Dupe before freeing `relative`: if the dupe fails, the errdefer
        // above still owns `relative` and must free it exactly once.
        const dot = try allocator.dupe(u8, ".");
        allocator.free(relative);
        return dot;
    }
    return relative;
}

test "nativeDependencyPath falls back to `.` for a same-directory scaffold" {
    const io = std.testing.io;
    const destination = ".zig-cache/test-native-dependency-same-dir";
    try std.Io.Dir.cwd().createDirPath(io, destination);
    const destination_real = try std.Io.Dir.cwd().realPathFileAlloc(io, destination, std.testing.allocator);
    defer std.testing.allocator.free(destination_real);

    const dependency = try nativeDependencyPath(std.testing.allocator, io, destination, destination_real);
    defer std.testing.allocator.free(dependency);
    try std.testing.expectEqualStrings(".", dependency);
}

fn expectSameDirDependencyDot(allocator: std.mem.Allocator, io: std.Io, destination: []const u8, framework_path: []const u8) !void {
    const dependency = try nativeDependencyPath(allocator, io, destination, framework_path);
    defer allocator.free(dependency);
    try std.testing.expectEqualStrings(".", dependency);
}

test "nativeDependencyPath survives every allocation-failure point of the `.` fallback" {
    // Walks every allocation-failure point of the `.` fallback and asserts
    // no leak and no swallowed OutOfMemory at each index. The fallback's
    // ownership rule — the errdefer releases the relative path exactly
    // once, so the fallible dupe must run before the manual free — keeps
    // this loop clean at the index where the dupe itself fails. (The slice
    // in this branch is empty, and freeing an empty slice is a no-op, so a
    // free-then-dupe ordering would not crash here today; the test pins
    // the ordering so the branch stays safe if it ever handles a non-empty
    // allocation.)
    const io = std.testing.io;
    const destination = ".zig-cache/test-native-dependency-oom";
    try std.Io.Dir.cwd().createDirPath(io, destination);
    const destination_real = try std.Io.Dir.cwd().realPathFileAlloc(io, destination, std.testing.allocator);
    defer std.testing.allocator.free(destination_real);

    try std.testing.checkAllAllocationFailures(std.testing.allocator, expectSameDirDependencyDot, .{ io, destination, destination_real });
}

fn appendZigString(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: []const u8) !void {
    try appendEscapedString(out, allocator, value);
}

fn appendJsonString(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: []const u8) !void {
    try appendEscapedString(out, allocator, value);
}

fn appendEscapedString(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: []const u8) !void {
    try out.append(allocator, '"');
    for (value) |ch| {
        switch (ch) {
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '"' => try out.appendSlice(allocator, "\\\""),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => try out.append(allocator, ch),
        }
    }
    try out.append(allocator, '"');
}

fn isAsciiAlpha(ch: u8) bool {
    return (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z');
}

fn isAsciiDigit(ch: u8) bool {
    return ch >= '0' and ch <= '9';
}

fn readTestFile(allocator: std.mem.Allocator, io: std.Io, root: []const u8, path: []const u8) ![]u8 {
    var root_dir = try std.Io.Dir.cwd().openDir(io, root, .{});
    defer root_dir.close(io);
    var file = try root_dir.openFile(io, path, .{});
    defer file.close(io);
    var read_buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &read_buffer);
    return reader.interface.allocRemaining(allocator, .limited(1024 * 1024));
}
