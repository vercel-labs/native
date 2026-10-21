//! Compiled `Cmd.keyboard` commands through the real runtime, permission check, and null platform.
const std = @import("std");
const sdk = @import("native_sdk");
const core = @import("keyboard_input_core");
const testing = std.testing;
const App = sdk.TsUiApp(core);
const views = [_]sdk.ShellView{.{ .label = "keys", .kind = .gpu_surface, .fill = true, .gpu_backend = .metal }};
const windows = [_]sdk.ShellWindow{.{ .label = "main", .title = "Keys", .width = 320, .height = 240, .views = &views }};

fn view(ui: *App.Ui, _: *const App.Model) App.Ui.Node {
    return ui.text(.{}, "keys");
}

const Fixture = struct {
    app: *App.App,
    harness: *sdk.TestHarness(),

    fn create(permitted: bool) !Fixture {
        const app = try App.create(testing.allocator, .{}, .{ .name = "keyboard-input", .scene = .{ .windows = &windows }, .canvas_label = "keys", .view = view });
        errdefer app.destroy();
        const harness = try sdk.TestHarness().create(testing.allocator, .{ .size = .init(320, 240) });
        errdefer harness.destroy(testing.allocator);
        harness.null_platform.gpu_surfaces = true;
        if (permitted) harness.runtime.options.security.permissions = &.{sdk.security.permission_keyboard_input};
        try harness.start(app.app());
        try harness.runtime.dispatchPlatformEvent(app.app(), .{ .gpu_surface_frame = .{ .label = "keys", .size = .init(320, 240), .frame_index = 1, .timestamp_ns = 1 } });
        return .{ .app = app, .harness = harness };
    }

    fn destroy(self: Fixture) void {
        self.harness.destroy(testing.allocator);
        self.app.destroy();
    }

    fn send(self: Fixture, msg: core.Msg) !*const core.Model {
        try self.app.dispatch(&self.harness.runtime, 1, msg);
        try self.harness.runtime.dispatchPlatformEvent(self.app.app(), .wake);
        return core.snapshotModel();
    }

    fn expectReply(self: Fixture, msg: core.Msg, last: []const u8, results: i64, failures: i64) !void {
        const model = try self.send(msg);
        try testing.expectEqualStrings(last, model.last);
        try testing.expectEqual(results, model.results);
        try testing.expectEqual(failures, model.failures);
    }
};

test "a chord and the access query reach the platform once keyboard_input is declared" {
    const fixture = try Fixture.create(true);
    defer fixture.destroy();
    try fixture.expectReply(.paste, "", 1, 0);
    try fixture.expectReply(.access, "granted", 2, 0);
    try testing.expectEqual(sdk.KeyChord.init("v", .{ .primary = true }).?, fixture.harness.null_platform.keyboardChords()[0]);
}

test "an undeclared permission is refused before reaching the platform" {
    const fixture = try Fixture.create(false);
    defer fixture.destroy();
    try fixture.expectReply(.paste, "rejected", 0, 1);
    try testing.expectEqual(@as(usize, 0), fixture.harness.null_platform.keyboardChords().len);
}

test "denied access and an unsupported host route an error Msg" {
    const fixture = try Fixture.create(true);
    defer fixture.destroy();
    fixture.harness.null_platform.keyboard_input_access = .denied;
    try fixture.expectReply(.paste, "denied", 0, 1);
    try fixture.expectReply(.access, "denied", 1, 1);
    try testing.expectEqual(@as(u32, 1), fixture.harness.null_platform.keyboard_input_prompt_count);
    fixture.harness.runtime.options.platform.services.send_key_chord_fn = null;
    try fixture.expectReply(.paste, "unsupported", 1, 2);
    try testing.expectEqual(@as(usize, 0), fixture.harness.null_platform.keyboardChords().len);
}
