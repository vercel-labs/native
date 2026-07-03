//! Live proof for T1: a fixture UiApp renders a markdown string (bold /
//! inline code / link / task list) through `zero_native.markdown`, and the
//! full runtime loop — install, automation snapshot, click dispatch,
//! retained re-emission, screenshot — works end to end.

const std = @import("std");
const geometry = @import("geometry");
const canvas = @import("canvas");
const app_manifest = @import("app_manifest");
const core = @import("core.zig");
const ui_app_model = @import("ui_app.zig");

const canvas_label = "notes-canvas";

const note_source =
    \\# Release notes
    \\
    \\Ship the **bold** parts first, run `zig build test`, then read
    \\[the guide](https://example.com/guide) before flipping the flag.
    \\
    \\- [x] spans wired
    \\- [ ] effects wired
    \\
    \\<details>
    \\<summary>Rollout plan</summary>
    \\
    \\Enable for 5% of traffic.
    \\
    \\</details>
;

const NotesModel = struct {
    opened_url: [128]u8 = [_]u8{0} ** 128,
    opened_len: usize = 0,
    details_expanded: [4]bool = .{ false, false, false, false },

    fn openedUrl(self: *const NotesModel) []const u8 {
        return self.opened_url[0..self.opened_len];
    }
};

const NotesMsg = union(enum) {
    open_url: []const u8,
    toggle_details: usize,
};

const NotesApp = ui_app_model.UiApp(NotesModel, NotesMsg);
const Md = canvas.markdown.Markdown(NotesMsg);

fn notesUpdate(model: *NotesModel, msg: NotesMsg) void {
    switch (msg) {
        .open_url => |url| {
            const len = @min(url.len, model.opened_url.len);
            @memcpy(model.opened_url[0..len], url[0..len]);
            model.opened_len = len;
        },
        .toggle_details => |index| {
            if (index < model.details_expanded.len) model.details_expanded[index] = !model.details_expanded[index];
        },
    }
}

fn notesView(ui: *NotesApp.Ui, model: *const NotesModel) NotesApp.Ui.Node {
    return ui.column(.{ .padding = 16 }, .{
        Md.view(ui, note_source, .{
            .on_link = NotesApp.Ui.linkMsg(.open_url),
            .on_details = Md.detailsMsg(.toggle_details),
            .details_expanded = &model.details_expanded,
        }),
    });
}

const notes_views = [_]app_manifest.ShellView{
    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .gpu_backend = .metal },
};
const notes_windows = [_]app_manifest.ShellWindow{.{
    .label = "main",
    .title = "Notes",
    .width = 480,
    .height = 400,
    .views = &notes_views,
}};
const notes_scene: app_manifest.ShellConfig = .{ .windows = &notes_windows };

fn snapshotWidgetNamed(snapshot: anytype, role: []const u8, name: []const u8) ?@TypeOf(snapshot.widgets[0]) {
    for (snapshot.widgets) |widget| {
        if (std.mem.eql(u8, widget.role, role) and std.mem.eql(u8, widget.name, name)) return widget;
    }
    return null;
}

test "markdown note app snapshots links, dispatches clicks, and screenshots" {
    // Runtime and app are large; keep them off the test thread stack.
    const harness = try core.TestHarness().create(std.testing.allocator, .{ .size = geometry.SizeF.init(480, 400) });
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;

    const app_state = try std.testing.allocator.create(NotesApp);
    defer std.testing.allocator.destroy(app_state);
    app_state.* = NotesApp.init(std.heap.page_allocator, .{}, .{
        .name = "markdown-notes",
        .scene = notes_scene,
        .canvas_label = canvas_label,
        .update = notesUpdate,
        .view = notesView,
    });
    defer app_state.deinit();
    const app = app_state.app();
    try harness.start(app);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .label = canvas_label,
        .size = geometry.SizeF.init(480, 400),
        .scale_factor = 2,
        .frame_index = 1,
        .timestamp_ns = 1_000_000,
        .nonblank = true,
    } });
    try std.testing.expect(app_state.installed);

    // The automation snapshot exposes the link with role=link, named by its
    // visible text, pressable — so evals can assert and click it.
    var snapshot = harness.runtime.automationSnapshot("Notes");
    const link = snapshotWidgetNamed(snapshot, "link", "the guide").?;
    try std.testing.expect(link.actions.press);
    try std.testing.expect(link.bounds.width > 0);

    // Task-list checkboxes are display-only: disabled, state mapped.
    const shipped = snapshotWidgetNamed(snapshot, "checkbox", "spans wired").?;
    try std.testing.expect(!shipped.enabled);
    try std.testing.expect(shipped.selected);

    // Clicking the link dispatches the typed Msg carrying the URL.
    var command_buffer: [96]u8 = undefined;
    const click = try std.fmt.bufPrint(&command_buffer, "widget-click {s} {d}", .{ canvas_label, link.id });
    try harness.runtime.dispatchAutomationCommand(app, click);
    try std.testing.expectEqualStrings("https://example.com/guide", app_state.model.openedUrl());

    // The details block is collapsed until the model says otherwise;
    // clicking its summary toggles the caller-owned flag and rebuilds.
    snapshot = harness.runtime.automationSnapshot("Notes");
    try std.testing.expect(snapshotWidgetNamed(snapshot, "text", "Enable for 5% of traffic.") == null);
    const summary = snapshotWidgetNamed(snapshot, "listitem", "▸ Rollout plan").?;
    const toggle = try std.fmt.bufPrint(&command_buffer, "widget-click {s} {d}", .{ canvas_label, summary.id });
    try harness.runtime.dispatchAutomationCommand(app, toggle);
    try std.testing.expect(app_state.model.details_expanded[0]);
    snapshot = harness.runtime.automationSnapshot("Notes");
    try std.testing.expect(snapshotWidgetNamed(snapshot, "text", "Enable for 5% of traffic.") != null);
    try std.testing.expect(snapshotWidgetNamed(snapshot, "listitem", "▾ Rollout plan") != null);

    // The retained widget tree kept the spans (copied + rebased into view
    // storage), so re-emitted display lists still carry the styled runs.
    const layout = try harness.runtime.canvasWidgetLayout(1, canvas_label);
    var span_paragraphs: usize = 0;
    var found_link_span = false;
    for (layout.nodes) |node| {
        if (node.widget.spans.len == 0) continue;
        span_paragraphs += 1;
        for (node.widget.spans) |span| {
            if (std.mem.eql(u8, span.link, "https://example.com/guide")) found_link_span = true;
        }
    }
    try std.testing.expect(span_paragraphs >= 3);
    try std.testing.expect(found_link_span);

    // Screenshot: the reference-rendered canvas is non-blank and encodes
    // to a parseable PNG (the live-evidence artifact).
    const pixel_size = try harness.runtime.canvasScreenshotPixelSize(1, canvas_label, null);
    const pixels = try std.testing.allocator.alloc(u8, pixel_size.byte_len);
    defer std.testing.allocator.free(pixels);
    const scratch = try std.testing.allocator.alloc(u8, pixel_size.byte_len);
    defer std.testing.allocator.free(scratch);
    const screenshot = try harness.runtime.renderCanvasScreenshot(1, canvas_label, null, pixels, scratch);
    var nonblank = false;
    var index: usize = 0;
    while (index + 4 <= screenshot.rgba8.len) : (index += 4) {
        if (screenshot.rgba8[index + 3] != 0 and (screenshot.rgba8[index] != 0 or screenshot.rgba8[index + 1] != 0 or screenshot.rgba8[index + 2] != 0)) {
            nonblank = true;
            break;
        }
    }
    try std.testing.expect(nonblank);
    const encoded = try std.testing.allocator.alloc(u8, try canvas.png.encodedRgba8ByteLen(screenshot.width, screenshot.height));
    defer std.testing.allocator.free(encoded);
    var writer = std.Io.Writer.fixed(encoded);
    try canvas.png.writeRgba8(&writer, screenshot.width, screenshot.height, screenshot.rgba8);
    try std.testing.expect(writer.buffered().len > 8);
}
