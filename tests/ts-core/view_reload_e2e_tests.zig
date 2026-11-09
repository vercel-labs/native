//! Markup reload for a compiled TypeScript core with the development view
//! exports: the running app applies the watcher's updates on its markup
//! watch timer. The model, widget identities and focus survive a reload; a
//! broken edit, a program for another build, an update for another session
//! and a damaged file all keep the last good view.
const std = @import("std");
const native_sdk = @import("native_sdk");
const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;
const core = @import("view_reload_core");
const updates = @import("view_reload_updates");

const Adapter = native_sdk.TsUiAppWithFeatures(core, .{ .runtime_markup = false, .compiled_model = true, .view_reload = true });
const App = Adapter.App;
const Driver = native_sdk.view_reload.Driver(core);
/// The session view_reload_updates.ts addresses its updates to.
const session: u64 = 0x5eed;

const canvas_label = "view-reload-canvas";
const automation_dir = ".zig-cache/tmp/view-reload-automation";

/// Provenance names the button in `source`, hashed as write-back hashes the file.
fn expectButtonSource(text: []const u8, source: []const u8) !void {
    var expected: [512]u8 = undefined;
    const at = std.mem.indexOf(u8, source, "<button").?;
    const end = std.mem.indexOfPos(u8, source, at, "</button>").? + "</button>".len;
    try std.testing.expect(std.mem.startsWith(u8, text, "provenance ok view=view-reload-canvas id="));
    try std.testing.expect(std.mem.indexOf(u8, text, " authored=markup watching=true root=src/app.native\n") != null);
    const node = try std.fmt.bufPrint(&expected, "\nnode file=src/app.native stamped= hash={x:0>16} span={d}..{d}", .{ std.hash.Wyhash.hash(0, source), at, end });
    try std.testing.expect(std.mem.indexOf(u8, text, node) != null);
}
const views = [_]native_sdk.ShellView{
    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .gpu_backend = .metal },
};
const windows = [_]native_sdk.ShellWindow{.{ .label = "main", .title = "View reload", .width = 360, .height = 240, .views = &views }};
const scene: native_sdk.ShellConfig = .{ .windows = &windows };

fn view(ui: *App.Ui, model: *const Adapter.Model) App.Ui.Node {
    return @import("view_reload_decoder").buildRuntime(ui, model);
}

fn command(name: []const u8) ?core.Msg {
    if (std.mem.eql(u8, name, "increment")) return .increment;
    return null;
}

const Harness = struct {
    harness: *native_sdk.TestHarness(),
    state: *App,
    app: native_sdk.App,
    time: u64 = 1_000_000,

    fn create() !*Harness {
        const self = try std.testing.allocator.create(Harness);
        errdefer std.testing.allocator.destroy(self);
        self.* = .{ .harness = undefined, .state = undefined, .app = undefined };
        self.harness = try native_sdk.TestHarness().create(std.testing.allocator, .{ .size = geometry.SizeF.init(360, 240) });
        errdefer self.harness.destroy(std.testing.allocator);
        self.harness.null_platform.gpu_surfaces = true;
        self.harness.runtime.options.automation = native_sdk.automation.Server.init(std.testing.io, automation_dir, "View reload");
        self.state = try std.testing.allocator.create(App);
        errdefer std.testing.allocator.destroy(self.state);
        self.state.* = Adapter.init(std.heap.page_allocator, .{}, .{
            .name = "view-reload-e2e",
            .scene = scene,
            .canvas_label = canvas_label,
            .view = view,
            .on_command = command,
        });
        self.app = self.state.app();
        try self.harness.start(self.app);
        try self.harness.runtime.dispatchPlatformEvent(self.app, .{ .gpu_surface_frame = .{
            .label = canvas_label,
            .size = geometry.SizeF.init(360, 240),
            .scale_factor = 1,
            .frame_index = 1,
            .timestamp_ns = self.time,
        } });
        try std.testing.expect(self.state.installed);
        return self;
    }

    fn destroy(self: *Harness) void {
        self.state.deinit();
        std.testing.allocator.destroy(self.state);
        self.harness.destroy(std.testing.allocator);
        std.testing.allocator.destroy(self);
    }

    fn menu(self: *Harness, name: []const u8) !void {
        try self.harness.runtime.dispatchPlatformEvent(self.app, .{ .menu_command = .{ .name = name, .window_id = 1 } });
    }

    /// One tick of the markup watch timer: the app polls for an update.
    fn tick(self: *Harness) !void {
        self.time += 250_000_000;
        try self.harness.runtime.dispatchPlatformEvent(self.app, self.harness.null_platform.fireTimer(App.markup_watch_timer_id, self.time).?);
    }

    /// The `provenance` verb's answer for one widget, as the CLI reads it.
    fn provenance(self: *Harness, id: canvas.ObjectId) ![]u8 {
        try self.harness.runtime.dispatchEvent(self.app, .{ .automation_provenance = .{ .window_id = 1, .view_label = canvas_label, .widget_id = id } });
        return std.Io.Dir.cwd().readFileAlloc(std.testing.io, automation_dir ++ "/provenance.txt", std.testing.allocator, .limited(8192));
    }

    fn root(self: *Harness) canvas.Widget {
        return self.state.tree.?.root;
    }

    fn focused(self: *Harness) canvas.ObjectId {
        for (self.harness.runtime.views[0..self.harness.runtime.view_count]) |entry| {
            if (std.mem.eql(u8, entry.label, canvas_label)) return entry.canvas_widget_focused_id;
        }
        return 0;
    }
};

fn hasText(widget: canvas.Widget, text: []const u8) bool {
    if (std.mem.eql(u8, widget.text, text)) return true;
    for (widget.children) |child| if (hasText(child, text)) return true;
    return false;
}

fn idOf(widget: canvas.Widget, kind: canvas.WidgetKind) ?canvas.ObjectId {
    if (widget.kind == kind) return widget.id;
    for (widget.children) |child| if (idOf(child, kind)) |id| return id;
    return null;
}

/// Hand the app one of the generated updates, as the watcher would.
fn deliver(dir: std.Io.Dir, name: []const u8, damage: bool) !void {
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/{s}", .{ updates.updates_dir, name });
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(1 << 20));
    defer std.testing.allocator.free(bytes);
    if (damage) bytes[bytes.len - 1] ^= 1;
    try dir.writeFile(std.testing.io, .{ .sub_path = native_sdk.view_reload.update_file, .data = bytes });
}

fn snapshot() ![]u8 {
    return std.testing.allocator.dupe(u8, core.modelSnapshot());
}

test "markup reload replaces the compiled view while the model, widget ids and focus persist" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buffer: [256]u8 = undefined;
    const dir_path = try std.fmt.bufPrint(&dir_buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    var driver = try Driver.init(std.testing.allocator, std.testing.io, dir_path, session);
    defer driver.deinit();
    // A leftover update from an earlier launch is discarded on announce.
    try deliver(tmp.dir, "edited.update", false);
    try driver.announce("{\"model\":\"Model\"}\n");
    const announced = try tmp.dir.readFileAlloc(std.testing.io, native_sdk.view_reload.build_file, std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(announced);
    try std.testing.expectEqualStrings("{\"format\":1,\"session\":\"0000000000005eed\",\"contract\":{\"model\":\"Model\"}}\n", announced);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(std.testing.io, native_sdk.view_reload.update_file, .{}));

    native_sdk.view_reload.installed = driver.hook();
    defer native_sdk.view_reload.installed = null;
    const h = try Harness.create();
    defer h.destroy();
    try std.testing.expect(h.harness.null_platform.startedTimer(App.markup_watch_timer_id) != null);
    try h.menu("increment");
    try h.menu("increment");
    try std.testing.expect(hasText(h.root(), "Count 2"));
    const input = idOf(h.root(), .input).?;
    const button = idOf(h.root(), .button).?;
    const focused = h.focused();
    try std.testing.expectEqual(input, focused);
    // The compiled view answers provenance for the markup it was built from.
    const booted = try h.provenance(button);
    defer std.testing.allocator.free(booted);
    try expectButtonSource(booted, @embedFile("view_reload/app.native"));
    const model = try snapshot();
    defer std.testing.allocator.free(model);

    // No update yet, then one for another session: nothing changes.
    try h.tick();
    try deliver(tmp.dir, "stale.update", false);
    try h.tick();
    try std.testing.expect(hasText(h.root(), "Count 2"));
    try std.testing.expect(h.state.markup_diagnostic == null);

    // The edited view: same model, same widget identities, same focus.
    try deliver(tmp.dir, "edited.update", false);
    try h.tick();
    try std.testing.expect(hasText(h.root(), "Total 2 items"));
    try std.testing.expect(hasText(h.root(), "Add one"));
    try std.testing.expect(hasText(h.root(), "Edited view"));
    try std.testing.expect(!hasText(h.root(), "Count 2"));
    try std.testing.expectEqual(input, idOf(h.root(), .input).?);
    try std.testing.expectEqual(button, idOf(h.root(), .button).?);
    try std.testing.expectEqual(focused, h.focused());
    const reloaded = try snapshot();
    defer std.testing.allocator.free(reloaded);
    try std.testing.expectEqualSlices(u8, model, reloaded);
    try std.testing.expect(h.state.markup_diagnostic == null);
    // After the reload, provenance names the edited bytes, so write-back edits them.
    const edited = try h.provenance(button);
    defer std.testing.allocator.free(edited);
    try expectButtonSource(edited, @embedFile("view_reload/edited.native"));

    // The reloaded view follows the model like the compiled one.
    try h.menu("increment");
    try std.testing.expect(hasText(h.root(), "Total 3 items"));

    // A broken edit reports its location and keeps the last good view.
    try deliver(tmp.dir, "broken.update", false);
    try h.tick();
    try std.testing.expect(hasText(h.root(), "Total 3 items"));
    const broken = h.state.markup_diagnostic.?;
    try std.testing.expectEqualStrings("src/app.native", broken.path);
    try std.testing.expectEqual(@as(usize, 2), broken.line);
    try std.testing.expect(std.mem.indexOf(u8, broken.message, "missing") != null);

    // A program compiled for another build is refused by the core.
    try deliver(tmp.dir, "foreign.update", false);
    try h.tick();
    try std.testing.expect(hasText(h.root(), "Total 3 items"));
    try std.testing.expect(std.mem.indexOf(u8, h.state.markup_diagnostic.?.message, "rebuild the app") != null);

    // Fixing the markup reloads again and clears the diagnostic.
    try deliver(tmp.dir, "edited.update", false);
    try h.tick();
    try std.testing.expect(hasText(h.root(), "Total 3 items"));
    try std.testing.expect(h.state.markup_diagnostic == null);

    // Back to the source the build compiled: the compiled view serves again.
    try deliver(tmp.dir, "compiled.update", false);
    try h.tick();
    try std.testing.expect(hasText(h.root(), "Count 3"));
    try std.testing.expect(!hasText(h.root(), "Edited view"));
    try std.testing.expectEqual(input, idOf(h.root(), .input).?);
    try std.testing.expectEqual(focused, h.focused());

    // A damaged update is never applied.
    try deliver(tmp.dir, "edited.update", true);
    try h.tick();
    try std.testing.expect(hasText(h.root(), "Count 3"));
    try std.testing.expect(h.state.markup_diagnostic == null);
}
