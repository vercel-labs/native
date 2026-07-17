//! Docs component-preview generator: renders every built-in component
//! through the deterministic reference renderer — the same offscreen
//! pipeline the homepage showcase shots use — and writes theme-aware
//! webp pairs into `docs/public/components/`, plus the markup vocabulary
//! JSON (`docs/src/lib/component-vocab.json`) the Components pages read
//! their attribute tables from, so the docs never hand-invent rows.
//!
//! Regenerate everything with ONE command from the repo root:
//!
//!   zig build docs-component-previews
//!
//! Deterministic: the same engine produces the same pixels (estimator
//! text metrics, fixed frame index, no platform fonts). The PNG → webp
//! conversion shells out to `cwebp` in lossless mode (`brew install
//! webp`), so bytes are stable for a given cwebp release.

const std = @import("std");
const native_sdk = @import("native_sdk");
const markup_docs = @import("native-sdk/markup_docs.zig");
const eject_components = @import("eject_components");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;
const platform = native_sdk.platform;

const preview_scenes = @import("docs_preview_scenes.zig");

const Ui = preview_scenes.Ui;
const Node = preview_scenes.Node;
const Hover = preview_scenes.Hover;
const scenes = preview_scenes.scenes;

const icon_tile_size = preview_scenes.icon_tile_size;
const view_label = "preview";
const png_cache_dir = "/tmp/native-sdk-component-previews";

// ------------------------------------------------------------ renderer

const PreviewApp = struct {
    fn app(self: *@This()) native_sdk.App {
        return .{
            .context = self,
            .name = "docs-component-previews",
            .source = platform.WebViewSource.html("<h1>previews</h1>"),
        };
    }
};

fn renderScenePng(
    gpa: std.mem.Allocator,
    io: std.Io,
    width: f32,
    height: f32,
    scheme: canvas.ColorScheme,
    build: *const fn (ui: *Ui, model: *const preview_scenes.SceneModel) Node,
    model: preview_scenes.SceneModel,
    hover: ?Hover,
    png_path: []const u8,
) !void {
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(width, height) });
    defer harness.destroy(gpa);
    harness.null_platform.gpu_surfaces = true;
    var app_state: PreviewApp = .{};
    const app = app_state.app();
    try harness.start(app);

    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = view_label,
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, width, height),
    });

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const tokens = canvas.DesignTokens.theme(.{ .color_scheme = scheme });
    var ui = Ui.init(arena_state.allocator());
    const tree = try ui.finalizeWithTokens(build(&ui, &model), tokens);

    const nodes = try gpa.alloc(canvas.WidgetLayoutNode, native_sdk.runtime.max_canvas_widget_nodes_per_view);
    defer gpa.free(nodes);
    // Layout with the same resolved tokens the emit pass reads, matching
    // the live wasm host: the static set renders the default register
    // only, whose layout metrics equal the token defaults, so this is
    // byte-identical today — the call exists so the two renderers can
    // never drift if this pipeline ever renders another pack.
    const layout = try canvas.layoutWidgetTreeWithTokens(tree.root, geometry.RectF.init(0, 0, width, height), tokens, nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, view_label, layout);
    _ = try harness.runtime.emitCanvasWidgetDisplayList(1, view_label, tokens);

    if (hover) |target| {
        const frame = hoverFrame(layout, target) orelse return error.HoverTargetNotFound;
        try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
            .window_id = 1,
            .label = view_label,
            .kind = .pointer_move,
            .x = frame.x + frame.width / 2,
            .y = frame.y + frame.height / 2,
        } });
    }

    const pixel_size = try harness.runtime.canvasScreenshotPixelSize(1, view_label, 2);
    const pixels = try gpa.alloc(u8, pixel_size.byte_len);
    defer gpa.free(pixels);
    const scratch = try gpa.alloc(u8, pixel_size.byte_len);
    defer gpa.free(scratch);
    const screenshot = try harness.runtime.renderCanvasScreenshot(1, view_label, 2, pixels, scratch);

    const encoded = try gpa.alloc(u8, try canvas.png.encodedRgba8ByteLen(screenshot.width, screenshot.height));
    defer gpa.free(encoded);
    var writer = std.Io.Writer.fixed(encoded);
    try canvas.png.writeRgba8(&writer, screenshot.width, screenshot.height, screenshot.rgba8);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = png_path, .data = writer.buffered() });
}

fn hoverFrame(layout: canvas.WidgetLayoutTree, target: Hover) ?geometry.RectF {
    var seen: usize = 0;
    for (layout.nodes) |node| {
        if (node.widget.kind != target.kind) continue;
        if (seen == target.index) return node.frame;
        seen += 1;
    }
    return null;
}

fn encodeWebp(io: std.Io, png_path: []const u8, webp_path: []const u8) !void {
    var child = std.process.spawn(io, .{
        .argv = &.{ "cwebp", "-lossless", "-z", "6", "-exact", "-quiet", png_path, "-o", webp_path },
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch |err| {
        if (err == error.FileNotFound) {
            std.debug.print("error: cwebp not found on PATH — install it (brew install webp) and rerun\n", .{});
        }
        return err;
    };
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code != 0) return error.WebpEncodeFailed,
        else => return error.WebpEncodeFailed,
    }
}

fn schemeName(scheme: canvas.ColorScheme) []const u8 {
    return switch (scheme) {
        .light => "light",
        .dark => "dark",
    };
}

// --------------------------------------------------------------- vocab

fn writeDocList(js: *std.json.Stringify, docs: []const markup_docs.Doc) !void {
    try js.beginArray();
    for (docs) |doc| {
        try js.beginObject();
        try js.objectField("name");
        try js.write(doc.name);
        try js.objectField("doc");
        try js.write(doc.doc);
        try js.endObject();
    }
    try js.endArray();
}

fn writeNameList(js: *std.json.Stringify, names: []const []const u8) !void {
    try js.beginArray();
    for (names) |name| try js.write(name);
    try js.endArray();
}

/// The vocabulary JSON the docs attribute tables render from: element,
/// attribute, and event docs come straight from the markup LSP tables
/// (the same strings editors show on hover), the closed value sets from
/// the validator vocabulary — no hand-written rows to drift.
fn writeVocabJson(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    var body: std.Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    var js: std.json.Stringify = .{ .writer = &body.writer, .options = .{ .whitespace = .indent_2 } };

    try js.beginObject();
    try js.objectField("elements");
    try writeDocList(&js, &markup_docs.element_docs);
    try js.objectField("structure");
    try writeDocList(&js, &markup_docs.structure_docs);
    try js.objectField("attributes");
    try writeDocList(&js, &markup_docs.attribute_docs);
    try js.objectField("events");
    try writeDocList(&js, &markup_docs.event_docs);
    try js.objectField("scoped");
    try js.beginObject();
    try js.objectField("markdown");
    try writeDocList(&js, &markup_docs.markdown_attr_docs);
    try js.objectField("stepper");
    try writeDocList(&js, &markup_docs.stepper_attr_docs);
    try js.objectField("timeline");
    try writeDocList(&js, &markup_docs.timeline_attr_docs);
    try js.objectField("timeline-item");
    try writeDocList(&js, &markup_docs.timeline_item_attr_docs);
    try js.objectField("avatar");
    try writeDocList(&js, &markup_docs.avatar_attr_docs);
    try js.objectField("media-surface");
    try writeDocList(&js, &markup_docs.media_surface_attr_docs);
    try js.objectField("chart");
    try writeDocList(&js, &markup_docs.chart_attr_docs);
    try js.objectField("series");
    try writeDocList(&js, &markup_docs.series_attr_docs);
    try js.objectField("input-group");
    try writeDocList(&js, &markup_docs.input_group_attr_docs);
    try js.objectField("input-group-actions");
    try writeDocList(&js, &markup_docs.input_group_actions_attr_docs);
    try js.objectField("span");
    try writeDocList(&js, &markup_docs.span_attr_docs);
    try js.objectField("reactions");
    try writeDocList(&js, &markup_docs.reactions_attr_docs);
    try js.objectField("dropdown-menu");
    try writeDocList(&js, &markup_docs.anchor_attr_docs);
    // Tooltip shares the anchor attribute family (the second anchorable
    // element), so its page resolves the same scoped rows.
    try js.objectField("tooltip");
    try writeDocList(&js, &markup_docs.anchor_attr_docs);
    try js.objectField("template");
    try writeDocList(&js, &markup_docs.template_attr_docs);
    try js.objectField("for");
    try writeDocList(&js, &markup_docs.for_attr_docs);
    try js.objectField("if");
    try writeDocList(&js, &markup_docs.if_attr_docs);
    try js.endObject();
    // Pixel dimensions of every preview pair (2x renders), so the docs
    // image components read sizes from here instead of hand-coding them.
    try js.objectField("previews");
    try js.beginObject();
    for (scenes) |scene| {
        try js.objectField(scene.name);
        try js.beginObject();
        try js.objectField("width");
        try js.write(@as(u32, @intFromFloat(scene.width * 2)));
        try js.objectField("height");
        try js.write(@as(u32, @intFromFloat(scene.height * 2)));
        try js.endObject();
    }
    try js.endObject();
    try js.objectField("iconTileSize");
    try js.write(@as(u32, @intFromFloat(icon_tile_size * 2)));
    try js.objectField("icons");
    try writeNameList(&js, canvas.icons.known_icon_names);
    try js.objectField("variants");
    try writeNameList(&js, &enumNames(canvas.WidgetVariant));
    try js.objectField("sizes");
    try writeNameList(&js, &enumNames(canvas.WidgetSize));
    try js.objectField("colorTokens");
    try writeNameList(&js, &canvas.ui_markup.known_color_token_names);
    try js.objectField("radiusTokens");
    try writeNameList(&js, &canvas.ui_markup.known_radius_token_names);
    // The ejectable registry, straight from the rows `native eject
    // component <name>` dispatches on (src/tooling/eject_components.zig):
    // the docs' <EjectSection> resolves its name, form, and destination
    // path from here and fails the docs build on any name the CLI
    // doesn't accept.
    try js.objectField("ejectable");
    try js.beginArray();
    for (eject_components.components) |component| {
        try js.beginObject();
        try js.objectField("name");
        try js.write(component.name);
        try js.objectField("form");
        try js.write(component.form);
        try js.objectField("path");
        try js.write(component.path);
        try js.endObject();
    }
    try js.endArray();
    try js.endObject();

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = body.written() });
}

fn enumNames(comptime E: type) [@typeInfo(E).@"enum".fields.len][]const u8 {
    const fields = @typeInfo(E).@"enum".fields;
    var names: [fields.len][]const u8 = undefined;
    inline for (fields, 0..) |field, index| names[index] = field.name;
    return names;
}

// ----------------------------------------------------------------- main

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try init.minimal.args.toSlice(arena);
    const out_dir: []const u8 = if (args.len > 1) args[1] else "docs/public/components";
    const vocab_path: []const u8 = if (args.len > 2) args[2] else "docs/src/lib/component-vocab.json";

    try std.Io.Dir.cwd().createDirPath(io, out_dir);
    const icons_dir = try std.fmt.allocPrint(arena, "{s}/icons", .{out_dir});
    try std.Io.Dir.cwd().createDirPath(io, icons_dir);
    try std.Io.Dir.cwd().createDirPath(io, png_cache_dir);

    const schemes = [_]canvas.ColorScheme{ .light, .dark };
    var rendered: usize = 0;

    for (scenes) |scene| {
        for (schemes) |scheme| {
            if (std.c.getenv("DOCS_PREVIEWS_TRACE") != null) std.debug.print("scene {s} ({s})\n", .{ scene.name, schemeName(scheme) });
            const png_path = try std.fmt.allocPrint(arena, "{s}/{s}-{s}.png", .{ png_cache_dir, scene.name, schemeName(scheme) });
            const webp_path = try std.fmt.allocPrint(arena, "{s}/{s}-{s}.webp", .{ out_dir, scene.name, schemeName(scheme) });
            try renderScenePng(gpa, io, scene.width, scene.height, scheme, scene.build, scene.model, scene.hover, png_path);
            try encodeWebp(io, png_path, webp_path);
            rendered += 1;
        }
    }

    // The icon gallery: one small tile per registry icon, named after it.
    inline for (canvas.icons.known_icon_names) |icon_name| {
        const Builder = struct {
            fn build(ui: *Ui, model: *const preview_scenes.SceneModel) Node {
                _ = model;
                return ui.column(.{ .main = .center, .cross = .center, .grow = 1 }, .{ui.icon(.{}, icon_name)});
            }
        };
        for (schemes) |scheme| {
            const png_path = try std.fmt.allocPrint(arena, "{s}/icon-{s}-{s}.png", .{ png_cache_dir, icon_name, schemeName(scheme) });
            const webp_path = try std.fmt.allocPrint(arena, "{s}/icons/{s}-{s}.webp", .{ out_dir, icon_name, schemeName(scheme) });
            try renderScenePng(gpa, io, icon_tile_size, icon_tile_size, scheme, Builder.build, .{}, null, png_path);
            try encodeWebp(io, png_path, webp_path);
            rendered += 1;
        }
    }

    try writeVocabJson(gpa, io, vocab_path);

    std.debug.print("docs-component-previews: wrote {d} webp files to {s} and vocab to {s}\n", .{ rendered, out_dir, vocab_path });
}
