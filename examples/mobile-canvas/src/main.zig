//! mobile-canvas: the smallest UiApp compiled into the mobile embed
//! static library. `zero_native.addMobileLib` wires this module as the
//! `"app"` import of the library root; the embed host instantiates the
//! UiApp on a gpu_surface canvas scene (window 1, "mobile-surface") and
//! pumps it from the shim's frame callback over the `zero_native_app_*`
//! C ABI.

const zero_native = @import("zero-native");
const canvas = zero_native.canvas;

pub const Model = struct {
    count: u32 = 0,
    note: canvas.TextBuffer(64) = .{},
};

pub const Msg = union(enum) {
    increment,
    reset,
    note_edit: canvas.TextInputEvent,
};

const App = zero_native.UiApp(Model, Msg);

pub fn initModel() Model {
    return .{};
}

pub fn mobileOptions() App.Options {
    return .{
        .name = "mobile-canvas",
        .scene = zero_native.embed.mobile_shell_scene,
        .canvas_label = zero_native.embed.mobile_gpu_surface_label,
        .update = update,
        .view = view,
    };
}

fn update(model: *Model, msg: Msg) void {
    switch (msg) {
        .increment => model.count += 1,
        .reset => model.count = 0,
        .note_edit => |edit| model.note.apply(edit),
    }
}

fn view(ui: *App.Ui, model: *const Model) App.Ui.Node {
    return ui.column(.{ .gap = 12, .padding = 16 }, .{
        ui.text(.{}, ui.fmt("Taps {d}", .{model.count})),
        ui.button(.{ .variant = .primary, .on_press = .increment }, "Tap"),
        ui.button(.{ .on_press = .reset }, "Reset"),
        ui.textField(.{
            .text = model.note.text(),
            .placeholder = "Note",
            .on_input = App.Ui.inputMsg(.note_edit),
        }),
    });
}
