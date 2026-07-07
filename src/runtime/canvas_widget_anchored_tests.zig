//! The anchored floating surface contract through the REAL dispatch
//! paths: a TEA picker (select trigger + anchored dropdown-menu) whose
//! open state is model-owned, closed by Escape and click-outside via
//! `on_dismiss` Msgs, clicked through automation while floating over
//! later siblings, plus press-and-hold (`on_hold`) through the runtime
//! timer path and the right-click alternative, and the per-view anchored
//! budget.

const std = @import("std");
const geometry = @import("geometry");
const canvas = @import("canvas");
const app_manifest = @import("app_manifest");
const core = @import("core.zig");
const ui_app_model = @import("ui_app.zig");
const support = @import("test_support.zig");

const canvas_label = "picker-canvas";

const PickerModel = struct {
    open: bool = false,
    picked: u32 = 99,
    // Counts commit Msgs so tests can pin "arrows never commit" and
    // "Enter/click commits exactly once" independently of the value.
    picks: u32 = 0,
    toggles: u32 = 0,
    dismissals: u32 = 0,
    holds: u32 = 0,
    crumb_presses: u32 = 0,
    // The crumb-switcher leg: a NON-focusable text trigger whose click
    // opens an anchored menu (dev-2's breadcrumb switcher).
    switcher_open: bool = false,
    switcher_dismissals: u32 = 0,
};

const PickerMsg = union(enum) {
    toggle_picker,
    close_picker,
    pick: u32,
    crumb_hold,
    crumb_press,
    toggle_switcher,
    close_switcher,
};

const PickerApp = ui_app_model.UiApp(PickerModel, PickerMsg);

fn pickerUpdate(model: *PickerModel, msg: PickerMsg) void {
    switch (msg) {
        .toggle_picker => {
            model.open = !model.open;
            model.toggles += 1;
        },
        .close_picker => {
            model.open = false;
            model.dismissals += 1;
        },
        .pick => |index| {
            model.picked = index;
            model.picks += 1;
            model.open = false;
        },
        .crumb_hold => model.holds += 1,
        .crumb_press => model.crumb_presses += 1,
        .toggle_switcher => model.switcher_open = !model.switcher_open,
        .close_switcher => {
            model.switcher_open = false;
            model.switcher_dismissals += 1;
        },
    }
}

fn pickerView(ui: *PickerApp.Ui, model: *const PickerModel) PickerApp.Ui.Node {
    const trigger = ui.el(.select, .{ .text = "Repo", .width = 160, .on_press = .toggle_picker }, .{});
    const picker = if (model.open) ui.stack(.{ .height = 28 }, .{
        trigger,
        ui.el(.dropdown_menu, .{
            .anchor = .below,
            .anchor_alignment = .stretch,
            .width = 160,
            .height = 90,
            .on_dismiss = .close_picker,
        }, .{
            ui.el(.menu_item, .{ .key = .{ .int = 0 }, .text = "Alpha", .height = 26, .selected = model.picked == 0, .on_press = PickerMsg{ .pick = 0 } }, .{}),
            ui.el(.menu_item, .{ .key = .{ .int = 1 }, .text = "Beta", .height = 26, .selected = model.picked == 1, .on_press = PickerMsg{ .pick = 1 } }, .{}),
        }),
    }) else ui.stack(.{ .height = 28 }, .{trigger});

    // A plain-text trigger: pressable (the handler makes it a hit
    // target) but NOT focusable — clicking it clears widget focus, so
    // its menu floats with nothing focused.
    const switcher_trigger = ui.text(.{ .on_press = .toggle_switcher }, "Files");
    const switcher = if (model.switcher_open) ui.stack(.{ .height = 20 }, .{
        switcher_trigger,
        ui.el(.dropdown_menu, .{
            .anchor = .below,
            .width = 140,
            .height = 56,
            .on_dismiss = .close_switcher,
        }, .{
            ui.el(.menu_item, .{ .key = .{ .int = 10 }, .text = "Sibling", .height = 26, .on_press = .crumb_press }, .{}),
        }),
    }) else ui.stack(.{ .height = 20 }, .{switcher_trigger});

    return ui.column(.{ .gap = 8, .padding = 12 }, .{
        picker,
        switcher,
        ui.button(.{ .on_press = .crumb_press, .on_hold = .crumb_hold }, "Crumb"),
        ui.text(.{}, ui.fmt("picked {d}", .{model.picked})),
    });
}

const picker_views = [_]app_manifest.ShellView{
    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .gpu_backend = .metal },
};
const picker_windows = [_]app_manifest.ShellWindow{.{
    .label = "main",
    .title = "Picker",
    .width = 400,
    .height = 300,
    .views = &picker_views,
}};
const picker_scene: app_manifest.ShellConfig = .{ .windows = &picker_windows };

fn pickerOptions() PickerApp.Options {
    return .{
        .name = "ui-app-picker",
        .scene = picker_scene,
        .canvas_label = canvas_label,
        .update = pickerUpdate,
        .view = pickerView,
    };
}

const Fixture = struct {
    harness: *core.TestHarness(),
    app_state: *PickerApp,
    app: core.App,

    fn create() !Fixture {
        const harness = try core.TestHarness().create(std.testing.allocator, .{ .size = geometry.SizeF.init(400, 300) });
        errdefer harness.destroy(std.testing.allocator);
        harness.null_platform.gpu_surfaces = true;
        const app_state = try PickerApp.create(std.heap.page_allocator, pickerOptions());
        const app = app_state.app();
        try harness.start(app);
        try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
            .label = canvas_label,
            .size = geometry.SizeF.init(400, 300),
            .scale_factor = 2,
            .frame_index = 1,
            .timestamp_ns = 1_000_000,
            .nonblank = true,
        } });
        return .{ .harness = harness, .app_state = app_state, .app = app };
    }

    fn destroy(self: Fixture) void {
        self.app_state.destroy();
        self.harness.destroy(std.testing.allocator);
    }

    fn widgetIdByText(self: Fixture, kind: canvas.WidgetKind, text: []const u8) ?canvas.ObjectId {
        return findIn(self.app_state.tree.?.root, kind, text);
    }

    fn findIn(widget: canvas.Widget, kind: canvas.WidgetKind, text: []const u8) ?canvas.ObjectId {
        if (widget.kind == kind and std.mem.eql(u8, widget.text, text)) return widget.id;
        for (widget.children) |child| {
            if (findIn(child, kind, text)) |id| return id;
        }
        return null;
    }

    fn retainedFrame(self: Fixture, id: canvas.ObjectId) !?geometry.RectF {
        const layout = try self.harness.runtime.canvasWidgetLayout(1, canvas_label);
        const node = layout.findById(id) orelse return null;
        if (node.widget.semantics.hidden) return null;
        return node.frame;
    }

    fn pointer(self: Fixture, kind: support.platform.GpuSurfaceInputKind, point: geometry.PointF) !void {
        try self.harness.runtime.dispatchPlatformEvent(self.app, .{ .gpu_surface_input = .{
            .label = canvas_label,
            .kind = kind,
            .x = point.x,
            .y = point.y,
        } });
    }

    fn click(self: Fixture, point: geometry.PointF) !void {
        try self.pointer(.pointer_down, point);
        try self.pointer(.pointer_up, point);
    }

    fn clickWidget(self: Fixture, id: canvas.ObjectId) !void {
        const frame = (try self.retainedFrame(id)) orelse return error.TestUnexpectedResult;
        try self.click(frame.center());
    }

    fn key(self: Fixture, name: []const u8) !void {
        try self.harness.runtime.dispatchPlatformEvent(self.app, .{ .gpu_surface_input = .{
            .label = canvas_label,
            .kind = .key_down,
            .key = name,
        } });
    }
};

test "anchored picker: trigger opens, menu floats, item click picks and closes" {
    const fixture = try Fixture.create();
    defer fixture.destroy();

    const trigger_id = fixture.widgetIdByText(.select, "Repo").?;
    try fixture.clickWidget(trigger_id);
    try std.testing.expect(fixture.app_state.model.open);
    try std.testing.expectEqual(@as(u32, 1), fixture.app_state.model.toggles);

    // The dropdown floats BELOW the trigger, stretched to its width.
    const alpha_id = fixture.widgetIdByText(.menu_item, "Alpha").?;
    const trigger_frame = (try fixture.retainedFrame(trigger_id)).?;
    const alpha_frame = (try fixture.retainedFrame(alpha_id)).?;
    try std.testing.expect(alpha_frame.y > trigger_frame.maxY());

    // Clicking the floating item picks and the model closes the picker;
    // no dismissal fires (the click is inside the surface).
    try fixture.clickWidget(alpha_id);
    try std.testing.expectEqual(@as(u32, 0), fixture.app_state.model.picked);
    try std.testing.expect(!fixture.app_state.model.open);
    try std.testing.expectEqual(@as(u32, 0), fixture.app_state.model.dismissals);
    try std.testing.expect((try fixture.retainedFrame(alpha_id)) == null);
}

test "anchored picker: escape dismisses as a Msg the model owns" {
    const fixture = try Fixture.create();
    defer fixture.destroy();

    const trigger_id = fixture.widgetIdByText(.select, "Repo").?;
    try fixture.clickWidget(trigger_id);
    try std.testing.expect(fixture.app_state.model.open);

    // Walk the highlight into the menu first: the dismissal below must
    // discard the provisional position, not commit it.
    try fixture.key("arrowdown");
    try fixture.harness.runtime.dispatchPlatformEvent(fixture.app, .{ .gpu_surface_input = .{
        .label = canvas_label,
        .kind = .key_down,
        .key = "escape",
    } });
    try std.testing.expectEqual(@as(u32, 1), fixture.app_state.model.dismissals);
    try std.testing.expect(!fixture.app_state.model.open);
    // Dismissal never commits: the highlighted row died with the menu.
    try std.testing.expectEqual(@as(u32, 99), fixture.app_state.model.picked);
    try std.testing.expectEqual(@as(u32, 0), fixture.app_state.model.picks);
    // The rebuilt source tree agrees: the surface is gone, not hidden.
    try std.testing.expect(fixture.widgetIdByText(.menu_item, "Alpha") == null);
}

test "escape dismisses an anchored surface opened from a NON-focusable trigger" {
    const fixture = try Fixture.create();
    defer fixture.destroy();

    // Clicking the plain-text crumb opens the menu but takes no focus:
    // text is not focusable, so the pointer path clears the focused id.
    const trigger_id = fixture.widgetIdByText(.text, "Files").?;
    try fixture.clickWidget(trigger_id);
    try std.testing.expect(fixture.app_state.model.switcher_open);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), fixture.harness.runtime.views[0].canvas_widget_focused_id);

    // Escape still finds the mounted surface: with no focus chain to
    // walk, the topmost mounted anchored surface dismisses, through the
    // same on_dismiss Msg contract the focused path uses.
    try fixture.harness.runtime.dispatchPlatformEvent(fixture.app, .{ .gpu_surface_input = .{
        .label = canvas_label,
        .kind = .key_down,
        .key = "escape",
    } });
    try std.testing.expectEqual(@as(u32, 1), fixture.app_state.model.switcher_dismissals);
    try std.testing.expect(!fixture.app_state.model.switcher_open);
    try std.testing.expect(fixture.widgetIdByText(.menu_item, "Sibling") == null);
}

test "escape from an unrelated focused widget falls back to the topmost mounted anchored surface" {
    const fixture = try Fixture.create();
    defer fixture.destroy();

    // Open the switcher menu (non-focusable trigger), then move focus
    // to the select trigger WITHOUT opening its own picker.
    const trigger_id = fixture.widgetIdByText(.text, "Files").?;
    try fixture.clickWidget(trigger_id);
    try std.testing.expect(fixture.app_state.model.switcher_open);
    const select_id = fixture.widgetIdByText(.select, "Repo").?;
    var command_buffer: [96]u8 = undefined;
    const focus_command = try std.fmt.bufPrint(&command_buffer, "widget-action {s} {d} focus", .{ canvas_label, select_id });
    try fixture.harness.runtime.dispatchAutomationCommand(fixture.app, focus_command);
    try std.testing.expectEqual(select_id, fixture.harness.runtime.views[0].canvas_widget_focused_id);

    // The focus chain from the select finds no open surface (its own
    // picker is closed), so Escape falls back to the mounted menu.
    try fixture.harness.runtime.dispatchPlatformEvent(fixture.app, .{ .gpu_surface_input = .{
        .label = canvas_label,
        .kind = .key_down,
        .key = "escape",
    } });
    try std.testing.expectEqual(@as(u32, 1), fixture.app_state.model.switcher_dismissals);
    try std.testing.expect(!fixture.app_state.model.switcher_open);
}

test "anchored picker: click outside dismisses as a Msg; clicking the trigger toggles exactly once" {
    const fixture = try Fixture.create();
    defer fixture.destroy();

    const trigger_id = fixture.widgetIdByText(.select, "Repo").?;
    try fixture.clickWidget(trigger_id);
    try std.testing.expect(fixture.app_state.model.open);

    // Click far outside trigger and menu: one dismissal Msg, no toggle,
    // and — like every dismissal — no commit.
    try fixture.click(geometry.PointF.init(360, 280));
    try std.testing.expectEqual(@as(u32, 1), fixture.app_state.model.dismissals);
    try std.testing.expectEqual(@as(u32, 1), fixture.app_state.model.toggles);
    try std.testing.expect(!fixture.app_state.model.open);
    try std.testing.expectEqual(@as(u32, 0), fixture.app_state.model.picks);

    // Re-open, then click the TRIGGER while open: the anchor owns its
    // surface's toggling — exactly one toggle Msg closes it, and no
    // dismiss-then-reopen race leaves it open.
    try fixture.clickWidget(trigger_id);
    try std.testing.expect(fixture.app_state.model.open);
    try fixture.clickWidget(trigger_id);
    try std.testing.expect(!fixture.app_state.model.open);
    try std.testing.expectEqual(@as(u32, 3), fixture.app_state.model.toggles);
    try std.testing.expectEqual(@as(u32, 1), fixture.app_state.model.dismissals);
}

test "anchored picker: automation clicks land on the floating menu item" {
    const fixture = try Fixture.create();
    defer fixture.destroy();

    const trigger_id = fixture.widgetIdByText(.select, "Repo").?;
    var command_buffer: [96]u8 = undefined;
    const open_click = try std.fmt.bufPrint(&command_buffer, "widget-click {s} {d}", .{ canvas_label, trigger_id });
    try fixture.harness.runtime.dispatchAutomationCommand(fixture.app, open_click);
    try std.testing.expect(fixture.app_state.model.open);

    // The floating item is in the snapshot-visible tree and clickable by
    // id through the same synthesized-pointer path automation uses live.
    const beta_id = fixture.widgetIdByText(.menu_item, "Beta").?;
    var beta_buffer: [96]u8 = undefined;
    const beta_click = try std.fmt.bufPrint(&beta_buffer, "widget-click {s} {d}", .{ canvas_label, beta_id });
    try fixture.harness.runtime.dispatchAutomationCommand(fixture.app, beta_click);
    try std.testing.expectEqual(@as(u32, 1), fixture.app_state.model.picked);
    try std.testing.expect(!fixture.app_state.model.open);
}

test "anchored picker: the open-select keymap opens, walks, commits, and returns focus" {
    const fixture = try Fixture.create();
    defer fixture.destroy();

    // Focus the closed trigger, then ArrowDown: the arrow presses the
    // trigger (the model-owned open), exactly like Enter would.
    const trigger_id = fixture.widgetIdByText(.select, "Repo").?;
    var command_buffer: [96]u8 = undefined;
    const focus_command = try std.fmt.bufPrint(&command_buffer, "widget-action {s} {d} focus", .{ canvas_label, trigger_id });
    try fixture.harness.runtime.dispatchAutomationCommand(fixture.app, focus_command);
    try fixture.key("arrowdown");
    try std.testing.expect(fixture.app_state.model.open);
    try std.testing.expectEqual(trigger_id, fixture.harness.runtime.views[0].canvas_widget_focused_id);

    // With the menu mounted the next ArrowDown walks INTO it: nothing
    // is marked selected yet (picked starts sentinel), so the first row
    // takes the keyboard.
    const alpha_id = fixture.widgetIdByText(.menu_item, "Alpha").?;
    const beta_id = fixture.widgetIdByText(.menu_item, "Beta").?;
    try fixture.key("arrowdown");
    try std.testing.expectEqual(alpha_id, fixture.harness.runtime.views[0].canvas_widget_focused_id);

    // Arrows walk the rows; Home/End jump to the edges. Walking is a
    // PROVISIONAL highlight only: no commit Msg fires and the model's
    // committed value never moves off the sentinel while arrowing.
    try fixture.key("arrowdown");
    try std.testing.expectEqual(beta_id, fixture.harness.runtime.views[0].canvas_widget_focused_id);
    try fixture.key("home");
    try std.testing.expectEqual(alpha_id, fixture.harness.runtime.views[0].canvas_widget_focused_id);
    try fixture.key("end");
    try std.testing.expectEqual(beta_id, fixture.harness.runtime.views[0].canvas_widget_focused_id);
    try std.testing.expectEqual(@as(u32, 99), fixture.app_state.model.picked);
    try std.testing.expectEqual(@as(u32, 0), fixture.app_state.model.picks);

    // Enter commits the focused row: EXACTLY one commit Msg, the model
    // picks and closes, and the keyboard returns to the trigger the
    // menu came from.
    try fixture.key("enter");
    try std.testing.expectEqual(@as(u32, 1), fixture.app_state.model.picked);
    try std.testing.expectEqual(@as(u32, 1), fixture.app_state.model.picks);
    try std.testing.expect(!fixture.app_state.model.open);
    try std.testing.expect(fixture.widgetIdByText(.menu_item, "Beta") == null);
    try std.testing.expectEqual(trigger_id, fixture.harness.runtime.views[0].canvas_widget_focused_id);
}

test "anchored picker: arrows enter at the marked row and escape returns focus to the trigger" {
    const fixture = try Fixture.create();
    defer fixture.destroy();

    const trigger_id = fixture.widgetIdByText(.select, "Repo").?;
    var command_buffer: [96]u8 = undefined;
    const focus_command = try std.fmt.bufPrint(&command_buffer, "widget-action {s} {d} focus", .{ canvas_label, trigger_id });
    try fixture.harness.runtime.dispatchAutomationCommand(fixture.app, focus_command);

    // Commit Beta once so the reopened menu carries a marked row.
    try fixture.key("arrowup");
    try std.testing.expect(fixture.app_state.model.open);
    try fixture.key("arrowdown");
    try fixture.key("arrowdown");
    try fixture.key("enter");
    try std.testing.expectEqual(@as(u32, 1), fixture.app_state.model.picked);

    // Reopen: the entry arrow lands on the SELECTED row, not the first.
    try fixture.key("arrowdown");
    try std.testing.expect(fixture.app_state.model.open);
    const beta_id = fixture.widgetIdByText(.menu_item, "Beta").?;
    try fixture.key("arrowdown");
    try std.testing.expectEqual(beta_id, fixture.harness.runtime.views[0].canvas_widget_focused_id);

    // Escape dismisses through the model and hands the keyboard back to
    // the trigger, ready to reopen. Only the FIRST Enter committed.
    try fixture.key("escape");
    try std.testing.expect(!fixture.app_state.model.open);
    try std.testing.expectEqual(@as(u32, 1), fixture.app_state.model.dismissals);
    try std.testing.expectEqual(@as(u32, 1), fixture.app_state.model.picks);
    try std.testing.expectEqual(trigger_id, fixture.harness.runtime.views[0].canvas_widget_focused_id);
}

test "anchored picker: Tab while inside the open menu dismisses without committing" {
    const fixture = try Fixture.create();
    defer fixture.destroy();

    // Open from the keyboard and walk the highlight onto the first row.
    const trigger_id = fixture.widgetIdByText(.select, "Repo").?;
    var command_buffer: [96]u8 = undefined;
    const focus_command = try std.fmt.bufPrint(&command_buffer, "widget-action {s} {d} focus", .{ canvas_label, trigger_id });
    try fixture.harness.runtime.dispatchAutomationCommand(fixture.app, focus_command);
    try fixture.key("arrowdown");
    try std.testing.expect(fixture.app_state.model.open);
    const alpha_id = fixture.widgetIdByText(.menu_item, "Alpha").?;
    try fixture.key("arrowdown");
    try std.testing.expectEqual(alpha_id, fixture.harness.runtime.views[0].canvas_widget_focused_id);

    // Tab is focus departure: the menu is a transient choice, so the
    // keyboard leaving closes it through the same on_dismiss Msg as
    // Escape — no commit, and the Tab itself is consumed with focus
    // handed back to the trigger.
    try fixture.key("tab");
    try std.testing.expect(!fixture.app_state.model.open);
    try std.testing.expectEqual(@as(u32, 1), fixture.app_state.model.dismissals);
    try std.testing.expectEqual(@as(u32, 99), fixture.app_state.model.picked);
    try std.testing.expectEqual(@as(u32, 0), fixture.app_state.model.picks);
    try std.testing.expectEqual(trigger_id, fixture.harness.runtime.views[0].canvas_widget_focused_id);

    // With the menu closed, Tab is plain focus traversal again — no
    // phantom dismissal Msg.
    try fixture.key("tab");
    try std.testing.expectEqual(@as(u32, 1), fixture.app_state.model.dismissals);
}

test "anchored picker: the open menu washes the ACTIVE row and checkmarks the COMMITTED row" {
    const fixture = try Fixture.create();
    defer fixture.destroy();

    // Commit Beta, then reopen: Beta is committed, and the keyboard
    // entry lands on it (the marked row).
    const trigger_id = fixture.widgetIdByText(.select, "Repo").?;
    var command_buffer: [96]u8 = undefined;
    const focus_command = try std.fmt.bufPrint(&command_buffer, "widget-action {s} {d} focus", .{ canvas_label, trigger_id });
    try fixture.harness.runtime.dispatchAutomationCommand(fixture.app, focus_command);
    try fixture.key("arrowdown");
    try fixture.key("arrowdown");
    try fixture.key("arrowdown");
    try fixture.key("enter");
    try std.testing.expectEqual(@as(u32, 1), fixture.app_state.model.picked);
    try fixture.key("arrowdown");
    const alpha_id = fixture.widgetIdByText(.menu_item, "Alpha").?;
    const beta_id = fixture.widgetIdByText(.menu_item, "Beta").?;
    try fixture.key("arrowdown");
    try std.testing.expectEqual(beta_id, fixture.harness.runtime.views[0].canvas_widget_focused_id);

    // Arrow AWAY from the committed row: Alpha carries the highlight
    // while Beta keeps the checkmark — independent affordances.
    try fixture.key("arrowup");
    try std.testing.expectEqual(alpha_id, fixture.harness.runtime.views[0].canvas_widget_focused_id);

    const display_list = try fixture.harness.runtime.canvasDisplayList(1, canvas_label);
    var alpha_wash = false;
    var alpha_outline = false;
    var beta_outline = false;
    var alpha_check = false;
    var beta_check = false;
    for (display_list.commands) |command| {
        switch (command) {
            // The active row's affordance is the FULL-ROW wash at the
            // row's fill slot...
            .fill_rounded_rect => |fill| {
                if (fill.id == partId(alpha_id, 1)) alpha_wash = true;
            },
            // ...never a focus-ring outline on any row.
            .stroke_rect => |stroke| {
                if (stroke.id == partId(alpha_id, 2)) alpha_outline = true;
                if (stroke.id == partId(beta_id, 2)) beta_outline = true;
            },
            // The committed row (and ONLY it) draws the checkmark path
            // at the trailing marker slot (13 = the marker's stroke).
            .stroke_path => |stroke| {
                if (stroke.id == partId(beta_id, 13)) beta_check = true;
                if (stroke.id == partId(alpha_id, 13)) alpha_check = true;
            },
            else => {},
        }
    }
    try std.testing.expect(alpha_wash);
    try std.testing.expect(!alpha_outline);
    try std.testing.expect(!beta_outline);
    try std.testing.expect(beta_check);
    try std.testing.expect(!alpha_check);
}

/// The engine's widget part-id scheme (id * 16 + slot), spelled out
/// locally so display-list pins read as slot lookups.
fn partId(id: canvas.ObjectId, slot: canvas.ObjectId) canvas.ObjectId {
    return id *% 16 +% slot;
}

test "press-and-hold fires through the runtime timer path and suppresses the release press" {
    const fixture = try Fixture.create();
    defer fixture.destroy();

    const crumb_id = fixture.widgetIdByText(.button, "Crumb").?;
    const crumb_frame = (try fixture.retainedFrame(crumb_id)).?;
    const center = crumb_frame.center();

    // Hold: down arms the reserved timer; firing it dispatches the hold
    // Msg; the release then presses nothing.
    try fixture.pointer(.pointer_down, center);
    try std.testing.expect(fixture.harness.null_platform.startedTimer(PickerApp.press_hold_timer_id) != null);
    const fire = fixture.harness.null_platform.fireTimer(PickerApp.press_hold_timer_id, 2_000_000).?;
    try fixture.harness.runtime.dispatchPlatformEvent(fixture.app, fire);
    try std.testing.expectEqual(@as(u32, 1), fixture.app_state.model.holds);
    try fixture.pointer(.pointer_up, center);
    try std.testing.expectEqual(@as(u32, 0), fixture.app_state.model.crumb_presses);

    // Quick click: the timer is cancelled before it fires and the press
    // dispatches normally.
    try fixture.pointer(.pointer_down, center);
    try fixture.pointer(.pointer_up, center);
    try std.testing.expectEqual(@as(u32, 1), fixture.app_state.model.crumb_presses);
    try std.testing.expectEqual(@as(u32, 1), fixture.app_state.model.holds);
    try std.testing.expect(fixture.harness.null_platform.fireTimer(PickerApp.press_hold_timer_id, 3_000_000) == null);
}

test "a secondary click with no context menu dispatches the hold Msg immediately" {
    const fixture = try Fixture.create();
    defer fixture.destroy();

    const crumb_id = fixture.widgetIdByText(.button, "Crumb").?;
    const crumb_frame = (try fixture.retainedFrame(crumb_id)).?;
    try fixture.harness.runtime.dispatchPlatformEvent(fixture.app, .{ .gpu_surface_input = .{
        .label = canvas_label,
        .kind = .pointer_down,
        .x = crumb_frame.center().x,
        .y = crumb_frame.center().y,
        .button = 1,
    } });
    try std.testing.expectEqual(@as(u32, 1), fixture.app_state.model.holds);
    // A right-click never acts as a primary press.
    try std.testing.expectEqual(@as(u32, 0), fixture.app_state.model.crumb_presses);
}

test "automation widget-hold drives on_hold through the real pointer+timer path" {
    const fixture = try Fixture.create();
    defer fixture.destroy();

    const crumb_id = fixture.widgetIdByText(.button, "Crumb").?;
    var command_buffer: [96]u8 = undefined;
    const hold = try std.fmt.bufPrint(&command_buffer, "widget-hold {s} {d}", .{ canvas_label, crumb_id });
    try fixture.harness.runtime.dispatchAutomationCommand(fixture.app, hold);

    // The down armed the reserved timer, the verb fired it, and the
    // release was suppressed: one gesture, one Msg — no press.
    try std.testing.expectEqual(@as(u32, 1), fixture.app_state.model.holds);
    try std.testing.expectEqual(@as(u32, 0), fixture.app_state.model.crumb_presses);
    // The verb cleans up the one-shot the down armed: no pending
    // wall-clock fire remains.
    try std.testing.expect(fixture.harness.null_platform.fireTimer(PickerApp.press_hold_timer_id, 5_000_000) == null);
}

test "automation widget-hold on a target without on_hold degrades to the click a real long press is" {
    const fixture = try Fixture.create();
    defer fixture.destroy();

    const trigger_id = fixture.widgetIdByText(.select, "Repo").?;
    var command_buffer: [96]u8 = undefined;
    const hold = try std.fmt.bufPrint(&command_buffer, "widget-hold {s} {d}", .{ canvas_label, trigger_id });
    try fixture.harness.runtime.dispatchAutomationCommand(fixture.app, hold);

    // Nothing armed, the fire no-oped, and the release pressed — exactly
    // what a real user holding a plain control and releasing gets.
    try std.testing.expect(fixture.app_state.model.open);
    try std.testing.expectEqual(@as(u32, 1), fixture.app_state.model.toggles);
    try std.testing.expectEqual(@as(u32, 0), fixture.app_state.model.holds);
}

test "automation widget-context-press dispatches the hold Msg when the route has no context menu" {
    const fixture = try Fixture.create();
    defer fixture.destroy();

    const crumb_id = fixture.widgetIdByText(.button, "Crumb").?;
    var command_buffer: [96]u8 = undefined;
    const press = try std.fmt.bufPrint(&command_buffer, "widget-context-press {s} {d}", .{ canvas_label, crumb_id });
    try fixture.harness.runtime.dispatchAutomationCommand(fixture.app, press);

    try std.testing.expectEqual(@as(u32, 1), fixture.app_state.model.holds);
    // A right-click never acts as a primary press.
    try std.testing.expectEqual(@as(u32, 0), fixture.app_state.model.crumb_presses);
}

test "automation gesture verbs reject unmounted targets loudly" {
    const fixture = try Fixture.create();
    defer fixture.destroy();

    // No widget carries this id: both gesture verbs fail like
    // widget-click on a stale target.
    var command_buffer: [96]u8 = undefined;
    const hold = try std.fmt.bufPrint(&command_buffer, "widget-hold {s} 424242", .{canvas_label});
    try std.testing.expectError(error.InvalidCommand, fixture.harness.runtime.dispatchAutomationCommand(fixture.app, hold));
    const press = try std.fmt.bufPrint(&command_buffer, "widget-context-press {s} 424242", .{canvas_label});
    try std.testing.expectError(error.InvalidCommand, fixture.harness.runtime.dispatchAutomationCommand(fixture.app, press));
    try std.testing.expectEqual(@as(u32, 0), fixture.app_state.model.holds);
}

test "the per-view anchored budget rejects a surface per row loudly" {
    const harness = try core.TestHarness().create(std.testing.allocator, .{ .size = geometry.SizeF.init(400, 300) });
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    const TestApp = struct {
        fn app(self: *@This()) core.App {
            return .{ .context = self, .name = "anchored-budget", .source = support.platform.WebViewSource.html("<h1>Hi</h1>") };
        }
    };
    var app_state: TestApp = .{};
    const app = app_state.app();
    try harness.start(app);
    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 400, 300),
    });

    var anchored: [17]canvas.Widget = undefined;
    for (&anchored, 0..) |*widget, index| {
        widget.* = .{
            .id = @intCast(index + 2),
            .kind = .dropdown_menu,
            .frame = geometry.RectF.init(0, 0, 40, 20),
            .layout = .{ .anchor = .{} },
        };
    }
    const root = canvas.Widget{ .id = 1, .kind = .stack, .children = &anchored };
    var nodes: [24]canvas.WidgetLayoutNode = undefined;

    // 16 anchored surfaces apply; 17 fail loudly with the budget's error.
    const at_budget = try canvas.layoutWidgetTree(.{ .id = 1, .kind = .stack, .children = anchored[0..16] }, geometry.RectF.init(0, 0, 400, 300), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", at_budget);
    const over_budget = try canvas.layoutWidgetTree(root, geometry.RectF.init(0, 0, 400, 300), &nodes);
    try std.testing.expectError(
        error.WidgetAnchoredSurfaceLimitReached,
        harness.runtime.setCanvasWidgetLayout(1, "canvas", over_budget),
    );
}
