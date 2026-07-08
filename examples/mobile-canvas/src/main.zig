//! mobile-canvas: the smallest UiApp compiled into the mobile embed
//! static library. `native_sdk.addMobileLib` wires this module as the
//! `"app"` import of the library root; the embed host instantiates the
//! UiApp on a gpu_surface canvas scene (window 1, "mobile-surface") and
//! pumps it from the shim's frame callback over the `native_sdk_app_*`
//! C ABI.
//!
//! Declared platform chrome: the scene declares a two-tab set and one
//! primary floating action. On iOS the toolkit host projects them as a
//! REAL system tab bar and a real button (system styling, template
//! icons rasterized from the icon vocabulary); a tab tap dispatches its
//! command id through `on_command` into update, and the model's
//! `selected_tab_fn` derivation drives which item the bar shows active
//! — the bar is a projection of the model, never the source of truth.
//! Hosts without a projection leave the declaration inert and this app
//! renders exactly as before.

const std = @import("std");
const native_sdk = @import("native_sdk");
const canvas = native_sdk.canvas;

pub const Model = struct {
    count: u32 = 0,
    note: canvas.TextBuffer(64) = .{},
    tab: Tab = .counter,
};

pub const Tab = enum { counter, notes };

pub const Msg = union(enum) {
    increment,
    reset,
    note_edit: canvas.TextInputEvent,
    show_counter,
    show_notes,
};

const App = native_sdk.UiApp(Model, Msg);

/// Tab/action command ids — what a projected control's tap dispatches
/// and what `on_command` maps back to Msgs.
const tab_counter_command = "tabs.counter";
const tab_notes_command = "tabs.notes";
const action_increment_command = "action.increment";

const chrome_tabs = [_]native_sdk.ShellTab{
    .{ .id = tab_counter_command, .label = "Counter", .icon = "circle-dot" },
    .{ .id = tab_notes_command, .label = "Notes", .icon = "edit" },
};

/// The canonical mobile surface plus this app's declared chrome.
const mobile_scene: native_sdk.ShellConfig = .{
    .windows = native_sdk.embed.mobile_shell_scene.windows,
    .chrome = .{
        .tabs = &chrome_tabs,
        .primary_action = .{ .id = action_increment_command, .label = "Add tap", .icon = "plus" },
    },
};

pub fn initModel() Model {
    return .{};
}

pub fn mobileOptions() App.Options {
    return .{
        .name = "mobile-canvas",
        .scene = mobile_scene,
        .canvas_label = native_sdk.embed.mobile_gpu_surface_label,
        .update = update,
        .view = view,
        .on_command = onCommand,
        .selected_tab_fn = selectedTab,
    };
}

fn update(model: *Model, msg: Msg) void {
    switch (msg) {
        .increment => model.count += 1,
        .reset => model.count = 0,
        .note_edit => |edit| model.note.apply(edit),
        .show_counter => model.tab = .counter,
        .show_notes => model.tab = .notes,
    }
}

/// Projected chrome taps arrive as command events with the declared ids.
fn onCommand(name: []const u8) ?Msg {
    if (std.mem.eql(u8, name, tab_counter_command)) return .show_counter;
    if (std.mem.eql(u8, name, tab_notes_command)) return .show_notes;
    if (std.mem.eql(u8, name, action_increment_command)) return .increment;
    return null;
}

/// The model's selected tab, as the declared command id — what the
/// projected bar mirrors.
fn selectedTab(model: *const Model) []const u8 {
    return switch (model.tab) {
        .counter => tab_counter_command,
        .notes => tab_notes_command,
    };
}

fn view(ui: *App.Ui, model: *const Model) App.Ui.Node {
    return switch (model.tab) {
        .counter => ui.column(.{ .gap = 12, .padding = 16 }, .{
            ui.text(.{}, ui.fmt("Taps {d}", .{model.count})),
            ui.button(.{ .variant = .primary, .on_press = .increment }, "Tap"),
            ui.button(.{ .on_press = .reset }, "Reset"),
        }),
        .notes => ui.column(.{ .gap = 12, .padding = 16 }, .{
            ui.text(.{}, "Notes"),
            ui.textField(.{
                .text = model.note.text(),
                .placeholder = "Note",
                .on_input = App.Ui.inputMsg(.note_edit),
            }),
        }),
    };
}
