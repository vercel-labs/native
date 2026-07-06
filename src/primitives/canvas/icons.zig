//! The curated built-in icon set: stroke icons in the common dialect
//! (24x24 viewBox, stroke-width 2, round caps and joins, `currentColor`)
//! authored for this framework and parsed at COMPTIME from the SVG
//! sources in `icons/` — the binary carries only lowered path elements,
//! and an invalid icon source is a compile error.
//!
//! Names are the closed vocabulary behind `<icon name="..."/>` in markup
//! and `Ui.icon` in Zig views; both engines validate against
//! `known_icon_names` (markup at comptime in the compiled engine, at
//! build/parse time in the validator and interpreter).
//!
//! Apps can parse their own `assets/icons/*.svg` (any file in the
//! common stroke-icon dialect) with `svg_icon.parseComptime(@embedFile(...))`
//! and register them under app-chosen names with `registerAppIcons` at
//! boot: the widget draw paths resolve names through `resolve` (built-ins
//! first, then the app table), so a registered app icon renders exactly
//! like a built-in — `Ui.icon` (comptime-checked) stays built-in-only;
//! use `Ui.appIcon` for registered names. Markup `<icon name>` keeps the
//! closed built-in vocabulary: the compiled engine validates names at
//! comptime, where runtime registrations cannot exist, and the two
//! engines stay in strict parity.

const svg_icon = @import("svg_icon.zig");

pub const Icon = svg_icon.Icon;

pub const Entry = struct {
    name: []const u8,
    icon: *const Icon,
};

fn builtin(comptime name: []const u8) Icon {
    return svg_icon.parseComptime(@embedFile("icons/" ++ name ++ ".svg"));
}

const alert = builtin("alert");
const archive = builtin("archive");
const arrow_down = builtin("arrow-down");
const arrow_right = builtin("arrow-right");
const arrow_up = builtin("arrow-up");
const check = builtin("check");
const check_circle = builtin("check-circle");
const chevron_down = builtin("chevron-down");
const chevron_left = builtin("chevron-left");
const chevron_right = builtin("chevron-right");
const chevron_up = builtin("chevron-up");
const circle_dot = builtin("circle-dot");
const clock = builtin("clock");
const copy = builtin("copy");
const download = builtin("download");
const edit = builtin("edit");
const ellipsis = builtin("ellipsis");
const external_link = builtin("external-link");
const eye = builtin("eye");
const file_text = builtin("file-text");
const folder = builtin("folder");
const folder_open = builtin("folder-open");
const git_branch = builtin("git-branch");
const git_merge = builtin("git-merge");
const git_pull_request = builtin("git-pull-request");
const info = builtin("info");
const menu = builtin("menu");
const moon = builtin("moon");
const music = builtin("music");
const panel_left = builtin("panel-left");
const panel_right = builtin("panel-right");
const pause = builtin("pause");
const play = builtin("play");
const plus = builtin("plus");
const refresh_cw = builtin("refresh-cw");
const repeat = builtin("repeat");
const save = builtin("save");
const search = builtin("search");
const send = builtin("send");
const settings = builtin("settings");
const shuffle = builtin("shuffle");
const skip_back = builtin("skip-back");
const skip_forward = builtin("skip-forward");
const sun = builtin("sun");
const terminal = builtin("terminal");
const trash = builtin("trash");
const volume = builtin("volume");
const wrench = builtin("wrench");
const x = builtin("x");
const x_circle = builtin("x-circle");

/// Sorted by name; kept in lockstep with `known_icon_names` below (a
/// unit test enforces it).
pub const entries = [_]Entry{
    .{ .name = "alert", .icon = &alert },
    .{ .name = "archive", .icon = &archive },
    .{ .name = "arrow-down", .icon = &arrow_down },
    .{ .name = "arrow-right", .icon = &arrow_right },
    .{ .name = "arrow-up", .icon = &arrow_up },
    .{ .name = "check", .icon = &check },
    .{ .name = "check-circle", .icon = &check_circle },
    .{ .name = "chevron-down", .icon = &chevron_down },
    .{ .name = "chevron-left", .icon = &chevron_left },
    .{ .name = "chevron-right", .icon = &chevron_right },
    .{ .name = "chevron-up", .icon = &chevron_up },
    .{ .name = "circle-dot", .icon = &circle_dot },
    .{ .name = "clock", .icon = &clock },
    .{ .name = "copy", .icon = &copy },
    .{ .name = "download", .icon = &download },
    .{ .name = "edit", .icon = &edit },
    .{ .name = "ellipsis", .icon = &ellipsis },
    .{ .name = "external-link", .icon = &external_link },
    .{ .name = "eye", .icon = &eye },
    .{ .name = "file-text", .icon = &file_text },
    .{ .name = "folder", .icon = &folder },
    .{ .name = "folder-open", .icon = &folder_open },
    .{ .name = "git-branch", .icon = &git_branch },
    .{ .name = "git-merge", .icon = &git_merge },
    .{ .name = "git-pull-request", .icon = &git_pull_request },
    .{ .name = "info", .icon = &info },
    .{ .name = "menu", .icon = &menu },
    .{ .name = "moon", .icon = &moon },
    .{ .name = "music", .icon = &music },
    .{ .name = "panel-left", .icon = &panel_left },
    .{ .name = "panel-right", .icon = &panel_right },
    .{ .name = "pause", .icon = &pause },
    .{ .name = "play", .icon = &play },
    .{ .name = "plus", .icon = &plus },
    .{ .name = "refresh-cw", .icon = &refresh_cw },
    .{ .name = "repeat", .icon = &repeat },
    .{ .name = "save", .icon = &save },
    .{ .name = "search", .icon = &search },
    .{ .name = "send", .icon = &send },
    .{ .name = "settings", .icon = &settings },
    .{ .name = "shuffle", .icon = &shuffle },
    .{ .name = "skip-back", .icon = &skip_back },
    .{ .name = "skip-forward", .icon = &skip_forward },
    .{ .name = "sun", .icon = &sun },
    .{ .name = "terminal", .icon = &terminal },
    .{ .name = "trash", .icon = &trash },
    .{ .name = "volume", .icon = &volume },
    .{ .name = "wrench", .icon = &wrench },
    .{ .name = "x", .icon = &x },
    .{ .name = "x-circle", .icon = &x_circle },
};

/// The markup-facing name list (comptime-validated attribute values).
pub const known_icon_names = blk: {
    var names: [entries.len][]const u8 = undefined;
    for (entries, 0..) |entry, index| names[index] = entry.name;
    const const_names = names;
    break :blk &const_names;
};

/// Resolve a BUILT-IN icon by name; null lets callers fall back. This is
/// the comptime-safe lookup (markup validation, `Ui.icon`'s compile-time
/// check); draw paths use `resolve`, which also consults the app table.
pub fn find(name: []const u8) ?*const Icon {
    for (&entries) |*entry| {
        if (stringsEqual(entry.name, name)) return entry.icon;
    }
    return null;
}

// --------------------------------------------------------- app registry

/// App-registered icons: process-global, installed once at boot. The
/// slice and everything it references must have static lifetime (a
/// `pub const` table of `svg_icon.parseComptime` icons is the intended
/// shape). Not synchronized — register before the runtime starts and
/// never mutate afterwards.
var app_entries: []const Entry = &.{};

/// Register the app's own parsed icons so the widget draw paths (icon
/// leaves, buttons, icon buttons) resolve their names like built-ins.
/// Call once from `main` before the app runs; built-in names always win
/// on collision (`resolve` checks the built-in table first), so an app
/// name shadowing a built-in is simply never reached — pick fresh names.
pub fn registerAppIcons(app_icons: []const Entry) void {
    app_entries = app_icons;
}

/// The currently registered app icons (empty unless the app registered
/// some at boot).
pub fn appIcons() []const Entry {
    return app_entries;
}

/// Resolve an icon name for DRAWING: built-ins first, then the
/// app-registered table. Runtime-only (the app table cannot exist at
/// comptime); validation paths keep using `find`.
pub fn resolve(name: []const u8) ?*const Icon {
    if (find(name)) |icon| return icon;
    for (app_entries) |*entry| {
        if (stringsEqual(entry.name, name)) return entry.icon;
    }
    return null;
}

fn stringsEqual(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (left != right) return false;
    }
    return true;
}
