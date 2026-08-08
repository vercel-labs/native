//! End-to-end proof for examples/kanban: the real TypeScript core and
//! shipping self-contained markup driven through TsUiApp. Native file drops
//! cross the platform/runtime/adapter boundary, add every basename to Todo, and
//! the resulting cards keep their global-key identity while a live
//! blank insertion slot reflows either column with retained drag motion and
//! release commits its order.

const std = @import("std");
const native_sdk = @import("native_sdk");
const core = @import("ts_kanban_core");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;
const Adapter = native_sdk.TsUiApp(core);
const App = Adapter.App;
const Bridge = Adapter.Host;

const app_markup = @embedFile("app.native");
const CompiledAppView = canvas.CompiledMarkupView(core.Model, core.Msg, app_markup);

const canvas_label = "kanban-canvas";
const app_views = [_]native_sdk.ShellView{
    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .gpu_backend = .metal },
};
const app_windows = [_]native_sdk.ShellWindow{.{
    .label = "main",
    .title = "Native SDK Kanban",
    .width = 840,
    .height = 560,
    .views = &app_views,
}};
const app_scene: native_sdk.ShellConfig = .{ .windows = &app_windows };

const Harness = struct {
    harness: *native_sdk.TestHarness(),
    app_state: *App,
    app: native_sdk.App,

    fn create() !*Harness {
        const self = try std.testing.allocator.create(Harness);
        errdefer std.testing.allocator.destroy(self);
        self.harness = try native_sdk.TestHarness().create(std.testing.allocator, .{
            .size = geometry.SizeF.init(840, 560),
        });
        errdefer self.harness.destroy(std.testing.allocator);
        self.harness.null_platform.gpu_surfaces = true;
        self.app_state = try std.testing.allocator.create(App);
        errdefer std.testing.allocator.destroy(self.app_state);
        self.app_state.* = Adapter.init(std.heap.page_allocator, .{}, .{
            .name = "kanban-e2e",
            .scene = app_scene,
            .canvas_label = canvas_label,
            .view = CompiledAppView.build,
        });
        self.app = self.app_state.app();
        try self.harness.start(self.app);
        try self.harness.runtime.dispatchPlatformEvent(self.app, .{ .gpu_surface_frame = .{
            .label = canvas_label,
            .size = geometry.SizeF.init(840, 560),
            .scale_factor = 1,
            .frame_index = 1,
            .timestamp_ns = 1_000_000,
        } });
        try std.testing.expect(self.app_state.installed);
        return self;
    }

    fn destroy(self: *Harness) void {
        self.app_state.deinit();
        std.testing.allocator.destroy(self.app_state);
        self.harness.destroy(std.testing.allocator);
        std.testing.allocator.destroy(self);
    }

    fn beginDrag(self: *Harness, id: canvas.ObjectId, x: f32, y: f32) !void {
        const layout = try self.harness.runtime.canvasWidgetLayout(1, canvas_label);
        const source = layout.findById(id).?.frame.normalized().center();
        try self.harness.runtime.dispatchPlatformEvent(self.app, .{ .gpu_surface_input = .{
            .window_id = 1,
            .label = canvas_label,
            .kind = .pointer_down,
            .x = source.x,
            .y = source.y,
        } });
        try self.harness.runtime.dispatchPlatformEvent(self.app, .{ .gpu_surface_input = .{
            .window_id = 1,
            .label = canvas_label,
            .kind = .pointer_drag,
            .x = x,
            .y = y,
            .delta_x = x - source.x,
            .delta_y = y - source.y,
        } });
    }

    fn endDrag(self: *Harness, x: f32, y: f32) !void {
        try self.harness.runtime.dispatchPlatformEvent(self.app, .{ .gpu_surface_input = .{
            .window_id = 1,
            .label = canvas_label,
            .kind = .pointer_up,
            .x = x,
            .y = y,
        } });
    }

    fn escapeDrag(self: *Harness) !void {
        try self.harness.runtime.dispatchPlatformEvent(self.app, .{ .gpu_surface_input = .{
            .window_id = 1,
            .label = canvas_label,
            .kind = .key_down,
            .key = "escape",
        } });
    }

    fn dragTo(self: *Harness, id: canvas.ObjectId, x: f32, y: f32) !void {
        try self.beginDrag(id, x, y);
        try self.endDrag(x, y);
    }

    fn frameFor(self: *Harness, id: canvas.ObjectId) !geometry.RectF {
        const layout = try self.harness.runtime.canvasWidgetLayout(1, canvas_label);
        return layout.findById(id).?.frame.normalized();
    }

    fn hasText(self: *Harness, text: []const u8) bool {
        return findTextIn(self.app_state.tree.?.root, text);
    }

    fn findLabel(self: *Harness, label: []const u8) ?canvas.ObjectId {
        return findByLabel(self.app_state.tree.?.root, label);
    }

    fn click(self: *Harness, id: canvas.ObjectId) !void {
        var buffer: [96]u8 = undefined;
        const command = try std.fmt.bufPrint(&buffer, "widget-click {s} {d}", .{ canvas_label, id });
        try self.harness.runtime.dispatchAutomationCommand(self.app, command);
    }
};

fn findTextIn(widget: canvas.Widget, text: []const u8) bool {
    if (std.mem.indexOf(u8, widget.text, text) != null) return true;
    for (widget.children) |child| {
        if (findTextIn(child, text)) return true;
    }
    return false;
}

fn findByLabel(widget: canvas.Widget, label: []const u8) ?canvas.ObjectId {
    if (std.mem.eql(u8, widget.semantics.label, label)) return widget.id;
    for (widget.children) |child| {
        if (findByLabel(child, label)) |id| return id;
    }
    return null;
}

fn findCard(widget: canvas.Widget, title: []const u8) ?canvas.Widget {
    if (widget.semantics.role == .listitem and std.mem.eql(u8, widget.semantics.label, title)) return widget;
    for (widget.children) |child| {
        if (findCard(child, title)) |found| return found;
    }
    return null;
}

fn countCards(widget: canvas.Widget) usize {
    var count: usize = if (widget.semantics.role == .listitem) 1 else 0;
    for (widget.children) |child| count += countCards(child);
    return count;
}

fn findLayoutMotion(state: canvas.WidgetRenderState, id: canvas.ObjectId) ?canvas.WidgetLayoutMotion {
    for (state.layout_motions) |motion| {
        if (motion.id == id) return motion;
    }
    return null;
}

test "overflowing columns scroll through the live runtime" {
    const h = try Harness.create();
    defer h.destroy();

    const add_button = h.findLabel("Add card").?;
    for (0..5) |_| try h.click(add_button);

    try std.testing.expectEqual(@as(i64, 7), Bridge.model().todoCount());
    const newest = findCard(h.app_state.tree.?.root, "Investigate agent task 10").?;
    const before_scroll = try h.frameFor(newest.id);
    try std.testing.expect(before_scroll.y + before_scroll.height > 560);

    try h.harness.runtime.dispatchPlatformEvent(h.app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = canvas_label,
        .timestamp_ns = 1_000_000_000,
        .kind = .scroll,
        .x = 100,
        .y = 300,
        .delta_y = 240,
    } });

    try std.testing.expect(Bridge.model().todoScroll > 0);
    const after_scroll = try h.frameFor(newest.id);
    try std.testing.expect(after_scroll.y < before_scroll.y);
    try std.testing.expect(after_scroll.y + after_scroll.height <= 560);

    // Drag hit-testing translates the viewport y back into scrolled content
    // coordinates. At this visible y the reserved slot belongs before id 6;
    // ignoring the offset would incorrectly choose the second card, id 2.
    try h.beginDrag(newest.id, 100, 140);
    try std.testing.expectEqual(@as(i64, 6), Bridge.model().dragBeforeId);
    try h.escapeDrag();
}

test "native file drops add cards and card drags preview and commit arbitrary insertion" {
    const h = try Harness.create();
    defer h.destroy();

    try std.testing.expectEqual(@as(usize, 5), Bridge.model().cards.len);
    try std.testing.expectEqual(@as(i64, 1841), Bridge.model().cards[0].ticketNumber);
    try std.testing.expectEqual(@as(i64, 1), Bridge.model().cards[0].avatarId);
    try std.testing.expect(h.hasText("#1841"));
    try std.testing.expect(!h.hasText("added from files"));

    // A drop addressed to another surface is ignored by the core mapper.
    const ignored_paths = [_][]const u8{"/tmp/ignored.txt"};
    try h.harness.runtime.dispatchPlatformEvent(h.app, .{ .files_dropped = .{
        .window_id = 1,
        .view_label = "other-canvas",
        .paths = &ignored_paths,
    } });
    try std.testing.expectEqual(@as(usize, 5), Bridge.model().cards.len);

    // Desktop hosts can identify only the receiving window, leaving the
    // view label empty. The event still carries multiple arbitrary byte
    // paths; both POSIX and Windows separators are reduced to useful card
    // titles in one atomic files_dropped Msg.
    const paths = [_][]const u8{ "/tmp/spec.txt", "C:\\work\\design.pdf" };
    try h.harness.runtime.dispatchPlatformEvent(h.app, .{ .files_dropped = .{
        .window_id = 1,
        .paths = &paths,
    } });
    try std.testing.expectEqual(@as(usize, 7), Bridge.model().cards.len);
    try std.testing.expectEqual(@as(i64, 2), Bridge.model().droppedCount);
    try std.testing.expect(h.hasText("spec.txt"));
    try std.testing.expect(h.hasText("design.pdf"));
    try std.testing.expectEqual(@as(i64, 4), Bridge.model().todoCount());
    try std.testing.expectEqual(@as(i64, 1), Bridge.model().doingCount());
    try std.testing.expectEqual(@as(i64, 2), Bridge.model().doneCount());

    // Reorder within Todo first. The one reserved slot begins exactly where
    // the source stood; moving to the top moves that SAME blank slot there,
    // while the fully opaque card remains under the pointer. The former first
    // card adopts its final layout frame with a presentation offset, so it
    // eases instead of snapping.
    const design_before = findCard(h.app_state.tree.?.root, "design.pdf").?;
    const sketch_before = findCard(h.app_state.tree.?.root, "Retry failed agent runs").?;
    const design_source_frame = try h.frameFor(design_before.id);
    const first_slot_y = (try h.frameFor(sketch_before.id)).center().y - 12;
    try h.beginDrag(design_before.id, 80, first_slot_y);
    try std.testing.expectEqual(@as(i64, 7), Bridge.model().draggingId);
    try std.testing.expectEqual(@as(i64, 7), Bridge.model().cards[6].id);
    const design_standing = findCard(h.app_state.tree.?.root, "design.pdf").?;
    try std.testing.expectEqual(design_before.id, design_standing.id);
    try std.testing.expectEqual(@as(usize, 7), countCards(h.app_state.tree.?.root));
    const destination_frame = try h.frameFor(design_standing.id);
    const sketch_pushed = findCard(h.app_state.tree.?.root, "Retry failed agent runs").?;
    try std.testing.expect(destination_frame.y < (try h.frameFor(sketch_pushed.id)).y);
    try std.testing.expectApproxEqAbs(@as(f32, 69.5), destination_frame.height, 0.01);
    try std.testing.expect(findLayoutMotion(h.harness.runtime.views[0].canvasWidgetRenderState(), sketch_pushed.id) != null);
    try std.testing.expectEqual(@as(i64, 4), Bridge.model().todoCount());
    try h.endDrag(80, first_slot_y);
    try std.testing.expectEqual(@as(i64, 0), Bridge.model().draggingId);
    try std.testing.expectEqual(@as(i64, 7), Bridge.model().cards[0].id);
    const design_landing = findCard(h.app_state.tree.?.root, "design.pdf").?;
    const design_final_frame = try h.frameFor(design_landing.id);
    const landing_motion = findLayoutMotion(h.harness.runtime.views[0].canvasWidgetRenderState(), design_landing.id).?;
    const source_center = design_source_frame.center();
    const floating_origin = geometry.PointF.init(
        design_source_frame.x + 80 - source_center.x,
        design_source_frame.y + first_slot_y - source_center.y,
    );
    try std.testing.expectApproxEqAbs(floating_origin.x - design_final_frame.x, landing_motion.offset.dx, 0.01);
    try std.testing.expectApproxEqAbs(floating_origin.y - design_final_frame.y, landing_motion.offset.dy, 0.01);
    try std.testing.expect(design_final_frame.y < design_source_frame.y);

    // Cancellation returns the single cross-column blank slot to its source
    // and leaves the newly
    // committed Todo order exactly as it stood before the gesture.
    const design_reordered = findCard(h.app_state.tree.?.root, "design.pdf").?;
    const cancel_source_frame = try h.frameFor(design_reordered.id);
    try h.beginDrag(design_reordered.id, 760, 500);
    try std.testing.expect((try h.frameFor(design_reordered.id)).x > 560);
    try std.testing.expectEqual(@as(i64, 4), Bridge.model().todoCount());
    try h.escapeDrag();
    try std.testing.expectEqual(@as(i64, 0), Bridge.model().draggingId);
    try std.testing.expectEqual(@as(i64, 7), Bridge.model().cards[0].id);
    try std.testing.expectEqual(@as(i64, 4), Bridge.model().todoCount());
    const design_returned = findCard(h.app_state.tree.?.root, "design.pdf").?;
    const cancel_final_frame = try h.frameFor(design_returned.id);
    const cancel_motion = findLayoutMotion(h.harness.runtime.views[0].canvasWidgetRenderState(), design_returned.id).?;
    const cancel_source_center = cancel_source_frame.center();
    const cancel_floating_origin = geometry.PointF.init(
        cancel_source_frame.x + 760 - cancel_source_center.x,
        cancel_source_frame.y + 500 - cancel_source_center.y,
    );
    try std.testing.expectApproxEqAbs(cancel_floating_origin.x - cancel_final_frame.x, cancel_motion.offset.dx, 0.01);
    try std.testing.expectApproxEqAbs(cancel_floating_origin.y - cancel_final_frame.y, cancel_motion.offset.dy, 0.01);

    // Move spec.txt across to the exact gap between the two Done cards.
    // The live view contains the one moved blank destination before pointer-up, with
    // the second Done card already springing toward its final location.
    const todo_card = findCard(h.app_state.tree.?.root, "spec.txt").?;
    const first_done = findCard(h.app_state.tree.?.root, "Log agent handoffs").?;
    const second_done = findCard(h.app_state.tree.?.root, "Document sandbox denials").?;
    const middle_done_y = ((try h.frameFor(first_done.id)).center().y + (try h.frameFor(second_done.id)).center().y) / 2;
    try h.beginDrag(todo_card.id, 760, middle_done_y);
    const done_destination = findCard(h.app_state.tree.?.root, "spec.txt").?;
    try std.testing.expectEqual(todo_card.id, done_destination.id);
    const first_done_preview = findCard(h.app_state.tree.?.root, "Log agent handoffs").?;
    const second_done_pushed = findCard(h.app_state.tree.?.root, "Document sandbox denials").?;
    try std.testing.expect((try h.frameFor(first_done_preview.id)).y < (try h.frameFor(done_destination.id)).y);
    try std.testing.expect((try h.frameFor(done_destination.id)).y < (try h.frameFor(second_done_pushed.id)).y);
    try std.testing.expect(findLayoutMotion(h.harness.runtime.views[0].canvasWidgetRenderState(), second_done_pushed.id) != null);
    try std.testing.expectEqual(@as(i64, 4), Bridge.model().todoCount());
    try h.endDrag(760, middle_done_y);
    const done_card = findCard(h.app_state.tree.?.root, "spec.txt").?;
    try std.testing.expectEqual(todo_card.id, done_card.id);
    try std.testing.expectEqual(@as(i64, 3), Bridge.model().todoCount());
    try std.testing.expectEqual(@as(i64, 3), Bridge.model().doneCount());

    // A large y chooses the bottom Todo slot, proving the same insertion
    // path works backwards as well as forwards.
    try h.dragTo(done_card.id, 80, 500);
    const returned_card = findCard(h.app_state.tree.?.root, "spec.txt").?;
    try std.testing.expectEqual(todo_card.id, returned_card.id);
    try std.testing.expectEqual(@as(i64, 4), Bridge.model().todoCount());
    try std.testing.expectEqual(@as(i64, 2), Bridge.model().doneCount());
}
