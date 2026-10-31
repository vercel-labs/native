//! `native eject component <name>`: transfer ownership of one library
//! composite to the app.
//!
//! The ownership model, stated once: the default is to USE the library
//! composites and theme them through design tokens; ejecting writes the
//! composite's canonical source into the app (`src/components/`) for the
//! moment you need to own its shape. Only library compositions are on the
//! menu — views the library itself builds from public primitives (rows,
//! columns, badges, separators, text). Engine control classes (buttons,
//! text fields, tabs, ...) are never ejectable: their behavior lives in
//! the runtime, so the way to change them is the token system, not a
//! fork.
//!
//! Each canonical source lives as a real file next to this one
//! (`components/`), embedded verbatim at compile time, and held in parity
//! by identity tests (`src/tooling/components/identity_tests.zig`) that
//! build the ejected form and the library form against the same inputs
//! and require identical widget trees. Whether a component ejects as a
//! markup template or a Zig view function is judged per component: a
//! composition the closed markup grammar can express fully becomes a
//! `<template>` (usable from markup and hot-reloaded in dev); one that
//! needs Zig — conditional structure, formatted text, typed messages —
//! becomes a view function.

const std = @import("std");
const buildgraph = @import("buildgraph.zig");

pub const ComponentForm = enum { markup, zig };
pub const ComponentCore = enum { ts, zig };

pub const Component = struct {
    /// The name `native eject component <name>` accepts (the registry
    /// element / builder-sugar name, so users name the thing they see).
    name: []const u8,
    /// Path the eject writes, relative to the app root. Markup templates
    /// keep the component name verbatim (import paths quote it); Zig
    /// files use underscores (Zig source naming convention).
    path: []const u8,
    /// The canonical source, embedded verbatim — the identity tests keep
    /// it building the exact tree the library builds.
    source: []const u8,
    /// The source form written into an app. This is explicit so the CLI can
    /// refuse a future Zig-form component in a TypeScript tree rather than
    /// violating the app-authoring rule.
    form_kind: ComponentForm = .markup,
    /// One-line form summary for listings and the success message.
    form: []const u8,
    /// Legacy Zig source retained for Zig-core apps. TypeScript apps use the
    /// markup source above; Zig apps keep the builder-shaped component API
    /// that existed before markup templates became the default.
    zig_path: ?[]const u8 = null,
    zig_source: ?[]const u8 = null,
    zig_form: []const u8 = "Zig view function",
};

pub const Ejection = struct {
    name: []const u8,
    path: []const u8,
    source: []const u8,
    form: []const u8,
    form_kind: ComponentForm,
};

pub fn forCore(component: *const Component, core: ComponentCore) ?Ejection {
    return switch (core) {
        .ts => .{
            .name = component.name,
            .path = component.path,
            .source = component.source,
            .form = component.form,
            .form_kind = component.form_kind,
        },
        .zig => if (component.zig_path != null and component.zig_source != null) .{
            .name = component.name,
            .path = component.zig_path.?,
            .source = component.zig_source.?,
            .form = component.zig_form,
            .form_kind = .zig,
        } else null,
    };
}

/// The ejectable set. Growing it is three steps: add the canonical
/// source under `components/`, add its identity test, add a row here.
pub const components = [_]Component{
    .{
        .name = "stepper",
        .path = "src/components/stepper.native",
        .source = @embedFile("components/stepper.native"),
        .form = "markup template",
        .form_kind = .markup,
        .zig_path = "src/components/stepper.zig",
        .zig_source = @embedFile("components/stepper.zig"),
    },
    .{
        .name = "timeline",
        .path = "src/components/timeline.native",
        .source = @embedFile("components/timeline.native"),
        .form = "markup template",
        .zig_path = null,
        .zig_source = null,
    },
    .{
        .name = "timeline-item",
        .path = "src/components/timeline-item.native",
        .source = @embedFile("components/timeline-item.native"),
        .form = "markup template",
        .form_kind = .markup,
        .zig_path = "src/components/timeline_item.zig",
        .zig_source = @embedFile("components/timeline_item.zig"),
    },
};

pub fn find(name: []const u8) ?*const Component {
    for (&components) |*component| {
        if (std.mem.eql(u8, component.name, name)) return component;
    }
    return null;
}

/// The comma-separated ejectable names, for teaching messages — comptime
/// so the list can never drift from `components`.
pub const component_list = blk: {
    var text: []const u8 = "";
    for (components, 0..) |component, index| {
        text = text ++ (if (index == 0) "" else ", ") ++ component.name;
    }
    break :blk text;
};

/// Closest ejectable name within edit distance 2 — close enough to be a
/// typo, far enough to avoid nonsense suggestions (the same band the
/// markup checker uses for its vocabulary).
pub fn suggestion(name: []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_distance: usize = 3;
    for (&components) |*component| {
        const distance = editDistance(name, component.name) orelse continue;
        if (distance < best_distance) {
            best_distance = distance;
            best = component.name;
        }
    }
    return best;
}

/// Bounded Levenshtein distance; null when either side is longer than the
/// row buffer (typos of names this vocabulary holds are all short).
fn editDistance(a: []const u8, b: []const u8) ?usize {
    var row_buffer: [64]usize = undefined;
    if (a.len >= row_buffer.len or b.len >= row_buffer.len) return null;
    var row = row_buffer[0 .. b.len + 1];
    for (row, 0..) |*cell, index| cell.* = index;
    for (a, 0..) |a_byte, a_index| {
        var previous_diagonal = row[0];
        row[0] = a_index + 1;
        for (b, 0..) |b_byte, b_index| {
            const substitution = previous_diagonal + @intFromBool(a_byte != b_byte);
            previous_diagonal = row[b_index + 1];
            row[b_index + 1] = @min(substitution, @min(row[b_index] + 1, previous_diagonal + 1));
        }
    }
    return row[b.len];
}

/// Write one component's canonical source into the app. Refuses when the
/// destination already exists — eject transfers ownership exactly once
/// and never overwrites a component the user may have edited.
pub fn eject(io: std.Io, app_dir: []const u8, component: *const Component) error{ AlreadyEjected, WriteFailed }!void {
    return ejectSelection(io, app_dir, forCore(component, .ts).?);
}

pub fn ejectSelection(io: std.Io, app_dir: []const u8, component: Ejection) error{ AlreadyEjected, WriteFailed }!void {
    var dir = std.Io.Dir.cwd().openDir(io, app_dir, .{}) catch return error.WriteFailed;
    defer dir.close(io);
    if (buildgraph.fileExistsIn(io, dir, component.path)) return error.AlreadyEjected;
    dir.createDirPath(io, "src/components") catch return error.WriteFailed;
    dir.writeFile(io, .{ .sub_path = component.path, .data = component.source }) catch return error.WriteFailed;
}

test "every ejectable component writes its canonical source once and refuses twice" {
    const io = std.testing.io;
    const root = ".zig-cache/test-eject-components";
    try std.Io.Dir.cwd().createDirPath(io, root);
    for (&components) |*component| {
        try eject(io, root, component);
        var dir = try std.Io.Dir.cwd().openDir(io, root, .{});
        defer dir.close(io);
        var file = try dir.openFile(io, component.path, .{});
        defer file.close(io);
        var read_buffer: [4096]u8 = undefined;
        var reader = file.reader(io, &read_buffer);
        const written = try reader.interface.allocRemaining(std.testing.allocator, .limited(1024 * 1024));
        defer std.testing.allocator.free(written);
        try std.testing.expectEqualStrings(component.source, written);
        // The ownership contract: a second eject must never overwrite.
        try std.testing.expectError(error.AlreadyEjected, eject(io, root, component));
        try dir.deleteFile(io, component.path);
    }
}

test "each canonical source opens with the ownership header" {
    for (components) |component| {
        try std.testing.expect(std.mem.indexOf(u8, component.source, "Ejected from the Native SDK component library") != null);
        // Re-eject teaching: every header names the command that restores it.
        try std.testing.expect(std.mem.indexOf(u8, component.source, "native eject component") != null);
    }
}

test "unknown names suggest their nearest ejectable component" {
    try std.testing.expectEqualStrings("stepper", suggestion("steppr").?);
    try std.testing.expectEqualStrings("timeline", suggestion("timelines").?);
    try std.testing.expectEqualStrings("timeline-item", suggestion("timeline-itm").?);
    // Distance past the typo band suggests nothing instead of nonsense.
    try std.testing.expect(suggestion("carousel") == null);
    try std.testing.expect(find("stepper") != null);
    try std.testing.expect(find("button") == null);
}

test "the component list names every ejectable component" {
    try std.testing.expectEqualStrings("stepper, timeline, timeline-item", component_list);
}

test "current ejectable components all use the markup form" {
    for (components) |component| {
        try std.testing.expectEqual(ComponentForm.markup, component.form_kind);
        try std.testing.expect(std.mem.endsWith(u8, component.path, ".native"));
        try std.testing.expectEqualStrings("markup template", component.form);
    }
}

test "Zig-core selection preserves the legacy builder sources" {
    try std.testing.expectEqualStrings("src/components/stepper.zig", forCore(&components[0], .zig).?.path);
    try std.testing.expectEqual(ComponentForm.zig, forCore(&components[0], .zig).?.form_kind);
    try std.testing.expect(forCore(&components[1], .zig) == null);
    try std.testing.expectEqualStrings("src/components/timeline_item.zig", forCore(&components[2], .zig).?.path);
    try std.testing.expect(std.mem.indexOf(u8, forCore(&components[2], .zig).?.source, "on_press") != null);
}
