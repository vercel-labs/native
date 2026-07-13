//! Comptime app.zon -> scene conversion: turn the manifest module's
//! `.shell` declaration (the anonymous ZON tuple a build imports as
//! `app_manifest_zon`) into a typed `ShellConfig`, so a generated wiring
//! module can run an app whose ONLY window/scene declaration is app.zon —
//! nothing repeated in Zig. The Zig app template keeps declaring its scene
//! in main.zig (both declarations there are user-owned); this converter is
//! for build-generated wiring where app.zon must be the single source of
//! truth. Unknown enum spellings are teaching @compileErrors naming the
//! field — the manifest validator accepts the same vocabularies at
//! `native check` time (validation.zig), so the two surfaces agree.

const std = @import("std");
const types = @import("types.zig");

/// The `.shell` scene from an imported app.zon module, as a comptime
/// `ShellConfig`. Absent shell (or absent windows) yields the empty
/// config — the runtime then keeps the host's default startup window.
pub fn shellConfigFrom(comptime manifest: anytype) types.ShellConfig {
    comptime {
        if (!@hasField(@TypeOf(manifest), "shell")) return .{};
        const shell = manifest.shell;
        // The whole conversion is ONE comptime evaluation sharing one
        // backwards-branch budget, and the default (1000) does not survive
        // a real manifest: every window and view costs field probes, slice
        // concatenation, and enum-name scans, so a scene one field richer
        // than the smallest demo dies mid-sort deep in std. Budget
        // proportional to the declared scene instead — see
        // sceneEvalBranchQuota for the per-node ceiling.
        @setEvalBranchQuota(sceneEvalBranchQuota(shell));
        var windows: []const types.ShellWindow = &.{};
        if (@hasField(@TypeOf(shell), "windows")) {
            for (shell.windows) |window| {
                windows = windows ++ &[_]types.ShellWindow{shellWindowFrom(window)};
            }
        }
        var chrome: types.ShellChrome = .{};
        if (@hasField(@TypeOf(shell), "chrome")) {
            chrome = shellChromeFrom(shell.chrome);
        }
        return .{ .windows = windows, .chrome = chrome };
    }
}

/// The first `gpu_surface` view label in the scene — the canvas a
/// markup-viewed app renders into. A teaching @compileError when the
/// manifest declares none: a canvas app cannot render without one.
pub fn firstGpuSurfaceLabel(comptime scene: types.ShellConfig) []const u8 {
    comptime {
        // A separate top-level evaluation with its own default branch
        // budget: walking a large converted scene must not die at 1000
        // either. The walk is a compare per view, so a small per-view
        // grant is plenty.
        var views: comptime_int = 1;
        for (scene.windows) |window| views += 1 + window.views.len;
        @setEvalBranchQuota(1_000 + 16 * views);
        for (scene.windows) |window| {
            for (window.views) |view| {
                if (view.kind == .gpu_surface) return view.label;
            }
        }
        @compileError("app.zon declares no gpu_surface view - a canvas app needs one: add" ++
            " .views = .{ .{ .label = \"main-canvas\", .kind = \"gpu_surface\", .fill = true } } to the shell window");
    }
}

fn shellWindowFrom(comptime window: anytype) types.ShellWindow {
    var out: types.ShellWindow = .{};
    if (@hasField(@TypeOf(window), "label")) out.label = window.label;
    if (@hasField(@TypeOf(window), "title")) {
        if (@TypeOf(window.title) != @TypeOf(null)) out.title = window.title;
    }
    if (@hasField(@TypeOf(window), "width")) out.width = window.width;
    if (@hasField(@TypeOf(window), "height")) out.height = window.height;
    if (@hasField(@TypeOf(window), "x")) out.x = window.x;
    if (@hasField(@TypeOf(window), "y")) out.y = window.y;
    if (@hasField(@TypeOf(window), "resizable")) out.resizable = window.resizable;
    if (@hasField(@TypeOf(window), "restore_state")) out.restore_state = window.restore_state;
    if (@hasField(@TypeOf(window), "restore_policy")) {
        out.restore_policy = enumField(types.WindowRestorePolicy, window.restore_policy, "restore_policy");
    }
    if (@hasField(@TypeOf(window), "titlebar")) {
        out.titlebar = enumField(types.WindowTitlebarStyle, window.titlebar, "titlebar");
    }
    if (@hasField(@TypeOf(window), "min_width")) out.min_width = window.min_width;
    if (@hasField(@TypeOf(window), "min_height")) out.min_height = window.min_height;
    if (@hasField(@TypeOf(window), "views")) {
        var views: []const types.ShellView = &.{};
        for (window.views) |view| {
            views = views ++ &[_]types.ShellView{shellViewFrom(view)};
        }
        out.views = views;
    }
    return out;
}

fn shellViewFrom(comptime view: anytype) types.ShellView {
    if (!@hasField(@TypeOf(view), "label")) @compileError("app.zon shell view needs a .label");
    if (!@hasField(@TypeOf(view), "kind")) @compileError("app.zon shell view needs a .kind");
    var out: types.ShellView = .{
        .label = view.label,
        .kind = enumField(types.ViewKind, view.kind, "view kind"),
    };
    if (@hasField(@TypeOf(view), "parent")) out.parent = view.parent;
    if (@hasField(@TypeOf(view), "edge")) out.edge = enumField(types.ShellEdge, view.edge, "edge");
    if (@hasField(@TypeOf(view), "axis")) out.axis = enumField(types.ShellAxis, view.axis, "axis");
    if (@hasField(@TypeOf(view), "x")) out.x = view.x;
    if (@hasField(@TypeOf(view), "y")) out.y = view.y;
    if (@hasField(@TypeOf(view), "width")) out.width = view.width;
    if (@hasField(@TypeOf(view), "height")) out.height = view.height;
    if (@hasField(@TypeOf(view), "min_width")) out.min_width = view.min_width;
    if (@hasField(@TypeOf(view), "min_height")) out.min_height = view.min_height;
    if (@hasField(@TypeOf(view), "max_width")) out.max_width = view.max_width;
    if (@hasField(@TypeOf(view), "max_height")) out.max_height = view.max_height;
    if (@hasField(@TypeOf(view), "fill")) out.fill = view.fill;
    if (@hasField(@TypeOf(view), "layer")) out.layer = view.layer;
    if (@hasField(@TypeOf(view), "visible")) out.visible = view.visible;
    if (@hasField(@TypeOf(view), "enabled")) out.enabled = view.enabled;
    if (@hasField(@TypeOf(view), "role")) out.role = view.role;
    if (@hasField(@TypeOf(view), "accessibility_label")) out.accessibility_label = view.accessibility_label;
    if (@hasField(@TypeOf(view), "url")) out.url = view.url;
    if (@hasField(@TypeOf(view), "text")) out.text = view.text;
    if (@hasField(@TypeOf(view), "command")) out.command = view.command;
    if (@hasField(@TypeOf(view), "gpu_backend")) out.gpu_backend = enumField(types.GpuSurfaceBackend, view.gpu_backend, "gpu_backend");
    if (@hasField(@TypeOf(view), "gpu_pixel_format")) out.gpu_pixel_format = enumField(types.GpuSurfacePixelFormat, view.gpu_pixel_format, "gpu_pixel_format");
    if (@hasField(@TypeOf(view), "gpu_present_mode")) out.gpu_present_mode = enumField(types.GpuSurfacePresentMode, view.gpu_present_mode, "gpu_present_mode");
    if (@hasField(@TypeOf(view), "gpu_alpha_mode")) out.gpu_alpha_mode = enumField(types.GpuSurfaceAlphaMode, view.gpu_alpha_mode, "gpu_alpha_mode");
    if (@hasField(@TypeOf(view), "gpu_color_space")) out.gpu_color_space = enumField(types.GpuSurfaceColorSpace, view.gpu_color_space, "gpu_color_space");
    if (@hasField(@TypeOf(view), "gpu_vsync")) out.gpu_vsync = view.gpu_vsync;
    return out;
}

fn shellChromeFrom(comptime chrome: anytype) types.ShellChrome {
    var out: types.ShellChrome = .{};
    if (@hasField(@TypeOf(chrome), "tabs")) {
        var tabs: []const types.ShellTab = &.{};
        for (chrome.tabs) |tab| {
            var entry: types.ShellTab = .{ .id = tab.id, .label = tab.label };
            if (@hasField(@TypeOf(tab), "icon")) entry.icon = tab.icon;
            tabs = tabs ++ &[_]types.ShellTab{entry};
        }
        out.tabs = tabs;
    }
    if (@hasField(@TypeOf(chrome), "primary_action")) {
        const action = chrome.primary_action;
        var entry: types.ShellPrimaryAction = .{ .id = action.id, .label = action.label };
        if (@hasField(@TypeOf(action), "icon")) entry.icon = action.icon;
        out.primary_action = entry;
    }
    return out;
}

/// The branch budget for converting `shell`, proportional to its size.
/// Counting first is safe: windows.len is comptime-known (no branches),
/// so an interim grant covers the counting walk itself, and the walk is
/// one pass over the windows. The 2000-per-node ceiling is deliberately
/// fat — a view costs ~25 field probes, a slice concatenation, and up to
/// six linear enum-name scans (see enumField), each of which
/// short-circuits on length, so real cost sits far below it.
fn sceneEvalBranchQuota(comptime shell: anytype) comptime_int {
    comptime {
        var nodes: comptime_int = 4; // the shell itself, chrome, slack
        if (@hasField(@TypeOf(shell), "windows")) {
            @setEvalBranchQuota(1_000 + 16 * shell.windows.len);
            for (shell.windows) |window| {
                nodes += 1;
                if (@hasField(@TypeOf(window), "views")) nodes += window.views.len;
            }
        }
        if (@hasField(@TypeOf(shell), "chrome")) {
            if (@hasField(@TypeOf(shell.chrome), "tabs")) nodes += shell.chrome.tabs.len;
        }
        return 2_000 * nodes;
    }
}

fn enumField(comptime E: type, comptime value: []const u8, comptime what: []const u8) E {
    comptime {
        // NOT std.meta.stringToEnum: that builds a sorted StaticStringMap
        // at comptime on EVERY call, and its own quota grant is a @max
        // that never rises above the default for small enums — so each
        // enum-mapped manifest field pays a full comptime pdq sort out of
        // the shared budget. A linear name scan is a handful of branches
        // per member (length short-circuit first) and needs no map.
        for (@typeInfo(E).@"enum".fields) |field| {
            if (std.mem.eql(u8, field.name, value)) return @field(E, field.name);
        }
        @compileError("unknown app.zon " ++ what ++ " \"" ++ value ++ "\" - expected one of: " ++ memberList(E));
    }
}

fn memberList(comptime E: type) []const u8 {
    comptime {
        var out: []const u8 = "";
        for (@typeInfo(E).@"enum".fields, 0..) |field, index| {
            out = out ++ (if (index == 0) "" else ", ") ++ field.name;
        }
        return out;
    }
}

test "shellConfigFrom converts a zon-shaped scene" {
    const manifest = .{
        .name = "demo",
        .shell = .{
            .windows = .{
                .{
                    .label = "main",
                    .title = "Demo",
                    .width = 480,
                    .height = 320,
                    .restore_state = false,
                    .restore_policy = "center_on_primary",
                    .views = .{
                        .{ .label = "main-canvas", .kind = "gpu_surface", .fill = true, .gpu_backend = "metal", .gpu_vsync = true },
                    },
                },
            },
        },
    };
    const scene = comptime shellConfigFrom(manifest);
    try std.testing.expectEqual(@as(usize, 1), scene.windows.len);
    try std.testing.expectEqualStrings("main", scene.windows[0].label);
    try std.testing.expectEqualStrings("Demo", scene.windows[0].title.?);
    try std.testing.expectEqual(@as(f32, 480), scene.windows[0].width);
    try std.testing.expectEqual(types.WindowRestorePolicy.center_on_primary, scene.windows[0].restore_policy);
    try std.testing.expectEqual(@as(usize, 1), scene.windows[0].views.len);
    try std.testing.expectEqual(types.ViewKind.gpu_surface, scene.windows[0].views[0].kind);
    try std.testing.expectEqual(types.GpuSurfaceBackend.metal, scene.windows[0].views[0].gpu_backend.?);
    try std.testing.expect(scene.windows[0].views[0].fill);
    try std.testing.expectEqualStrings("main-canvas", comptime firstGpuSurfaceLabel(scene));
}

test "shellConfigFrom yields the empty scene when app.zon declares none" {
    const scene = comptime shellConfigFrom(.{ .name = "bare" });
    try std.testing.expectEqual(@as(usize, 0), scene.windows.len);
}

// Branch-budget regression guard: a scene substantially richer than any
// shipped example — several windows, every enum-mapped shell field spelled
// as a string, chrome — must CONVERT, not die on "evaluation exceeded N
// backwards branches" in a comptime sort deep in std (the system-monitor-ts
// macOS build regression: one field richer than the smallest demo was
// already over the default quota).
test "shellConfigFrom converts a rich scene without exhausting the branch quota" {
    const rich_view = .{
        .label = "surface",
        .kind = "gpu_surface",
        .parent = "root",
        .edge = "left",
        .axis = "column",
        .x = 0,
        .y = 0,
        .width = 400,
        .height = 300,
        .min_width = 200,
        .min_height = 150,
        .max_width = 800,
        .max_height = 600,
        .fill = true,
        .layer = 1,
        .visible = true,
        .enabled = true,
        .role = "Canvas",
        .accessibility_label = "Main canvas",
        .gpu_backend = "metal",
        .gpu_pixel_format = "bgra8_unorm",
        .gpu_present_mode = "timer",
        .gpu_alpha_mode = "opaque",
        .gpu_color_space = "display_p3",
        .gpu_vsync = true,
    };
    const rich_window = .{
        .label = "main",
        .title = "Rich",
        .width = 1144,
        .height = 720,
        .x = 10,
        .y = 20,
        .resizable = true,
        .restore_state = false,
        .restore_policy = "center_on_primary",
        .titlebar = "hidden_inset_tall",
        .min_width = 1144,
        .min_height = 720,
        .views = .{
            rich_view,
            .{ .label = "side", .kind = "sidebar", .edge = "right", .axis = "row", .width = 240 },
            .{ .label = "status", .kind = "statusbar", .edge = "bottom", .visible = true },
            .{ .label = "tools", .kind = "toolbar", .edge = "top", .enabled = true },
        },
    };
    const manifest = .{
        .name = "rich",
        .shell = .{
            .windows = .{
                rich_window,
                .{
                    .label = "aux",
                    .titlebar = "hidden_inset",
                    .restore_policy = "clamp_to_visible_screen",
                    .views = .{
                        .{ .label = "aux-canvas", .kind = "gpu_surface", .fill = true, .gpu_backend = "software", .gpu_alpha_mode = "premultiplied", .gpu_color_space = "srgb" },
                    },
                },
                .{
                    .label = "chromeless",
                    .titlebar = "chromeless",
                    .views = .{
                        .{ .label = "web", .kind = "webview", .url = "zero://app" },
                        .{ .label = "split", .kind = "split", .axis = "row" },
                    },
                },
            },
            .chrome = .{
                .tabs = .{
                    .{ .id = "one", .label = "One", .icon = "gauge" },
                    .{ .id = "two", .label = "Two" },
                    .{ .id = "three", .label = "Three" },
                },
                .primary_action = .{ .id = "go", .label = "Go", .icon = "play" },
            },
        },
    };
    const scene = comptime shellConfigFrom(manifest);
    try std.testing.expectEqual(@as(usize, 3), scene.windows.len);
    try std.testing.expectEqual(types.WindowTitlebarStyle.hidden_inset_tall, scene.windows[0].titlebar);
    try std.testing.expectEqual(types.WindowRestorePolicy.center_on_primary, scene.windows[0].restore_policy);
    try std.testing.expectEqual(@as(usize, 4), scene.windows[0].views.len);
    try std.testing.expectEqual(types.ShellEdge.left, scene.windows[0].views[0].edge.?);
    try std.testing.expectEqual(types.ShellAxis.column, scene.windows[0].views[0].axis.?);
    try std.testing.expectEqual(types.GpuSurfacePixelFormat.bgra8_unorm, scene.windows[0].views[0].gpu_pixel_format.?);
    try std.testing.expectEqual(types.GpuSurfacePresentMode.timer, scene.windows[0].views[0].gpu_present_mode.?);
    try std.testing.expectEqual(types.GpuSurfaceAlphaMode.@"opaque", scene.windows[0].views[0].gpu_alpha_mode.?);
    try std.testing.expectEqual(types.GpuSurfaceColorSpace.display_p3, scene.windows[0].views[0].gpu_color_space.?);
    try std.testing.expectEqual(types.GpuSurfaceBackend.software, scene.windows[1].views[0].gpu_backend.?);
    try std.testing.expectEqual(types.GpuSurfaceAlphaMode.premultiplied, scene.windows[1].views[0].gpu_alpha_mode.?);
    try std.testing.expectEqual(types.WindowTitlebarStyle.chromeless, scene.windows[2].titlebar);
    try std.testing.expectEqual(@as(usize, 3), scene.chrome.tabs.len);
    try std.testing.expectEqualStrings("go", scene.chrome.primary_action.?.id);
    try std.testing.expectEqualStrings("surface", comptime firstGpuSurfaceLabel(scene));
}
