const std = @import("std");
const sdk = @import("native_sdk");
const core = @import("surface_fixture_core");
const p = sdk.runtime.testing.context_menu_policy;
var calls = [_]usize{0} ** 7;
fn observed(input: []const u8, output: []u8) usize {
    if (input[0] == 98) calls[input[1]] += 1;
    return core.nativeWindowPolicy(input, output);
}
const Cases = sdk.runtime.testing.context_menu_test_cases.Cases(observed);
test "compiled context menus: right click over a widget with a declared menu presents it natively and dispatches the selection" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    try Cases.case0();
}
test "compiled context menus: a superseding presentation names the dismissed menu's view and keeps the successor selectable" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    try Cases.case1();
}
test "compiled context menus: a stale dismissal from a superseded menu never clears the successor's pending request" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    try Cases.case2();
}
test "compiled context menus: re-clicking the same widget mints a fresh token so the old menu's late dismissal is inert" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    try Cases.case3();
}
test "compiled context menus: right click on editable text presents the default edit menu wired to clipboard actions" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    try Cases.case4();
}
test "compiled context menus: a near-capacity multi-line context-menu paste sanitizes before it clamps" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    try Cases.case5();
}
test "compiled context menus: right click on a terminal presents Copy and Paste wired to selection and committed input" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    try Cases.case6();
}
test "compiled context menus: terminal Paste disables after exit and a pending live menu revalidates before dispatch" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    try Cases.case7();
}
test "compiled context menus: right click on selected static text presents a copy-only menu" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    try Cases.case8();
}
test "compiled context menus: right click with no menu target presents nothing" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    try Cases.case9();
}
test "compiled context menus: a declared menu on a presenter-less host becomes a fallback request, not a lost click" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    try Cases.case10();
}
test "compiled context menus: the widget-context-menu verb dispatches selections through context_menu_action and refuses dead items by name" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    try Cases.case11();
}
test "compiled context menus: the widget-context-menu verb's synthetic selection survives an erroring dismissal handler" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    try Cases.case12();
}
test "compiled context menus: the automation menu verb names its view from the request after the dismissal handler closes another view" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    try Cases.case13();
}
test "compiled context menus: the automation menu verb refuses by name when the dismissal handler presents a superseding menu" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    try Cases.case14();
}
test "compiled context menus: the automation menu verb refuses by name when the dismissal handler closes its target view" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    try Cases.case15();
}
test "compiled context menus: a presentation whose view the dismissal handler closes is disarmed and never announced" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    try Cases.case16();
}
test "compiled context menus: a presentation superseded mid-notice by the dismissal handler's own menu announces nothing" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    try Cases.case17();
}
test "compiled context menus: a superseding presentation's shown event names the presenting view after the dismissal handler closes another" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    try Cases.case18();
}
test "compiled context menus: automation snapshots list each widget's declared context-menu items in invocable order" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    try Cases.case19();
}
test "compiled context menus: automation snapshots report per-view context-menu item headroom" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    try Cases.case20();
}
test "compiled context menus: context-menu declarations sum across widgets to the budget and overflow loudly one past it" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    try Cases.case21();
}

test "compiled context menus preserve exact token carry wrap stale windows and copied ownership" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    for ([_]u64{ 0, 1, 4294967294, 4294967295, 9007199254740991, 9007199254740992, 9007199254740993, std.math.maxInt(u64) - 1, std.math.maxInt(u64) }) |token| {
        const next = p.nextToken(observed, token);
        core.rt.frameReset();
        try std.testing.expectEqual(if (token == std.math.maxInt(u64)) @as(u64, 1) else token + 1, next);
        for ([_]u64{ token, token ^ 1, token ^ (1 << 63) }) |received| {
            const event: sdk.platform.ContextMenuActionEvent = .{ .window_id = 9007199254740993, .view_label = "canvas", .token = received, .item_id = 1 };
            try std.testing.expectEqual(if (token == received) p.Admission.lookup else p.Admission.ignore, p.admission(observed, .app, 9007199254740993, token, event));
            try std.testing.expectEqual(p.Admission.ignore, p.admission(observed, .app, 9007199254740992, token, event));
        }
    }
    const plan = p.presentation(observed, .{ .flags = 1 | 2 | 16 | 32 | 64 });
    core.rt.frameReset();
    try std.testing.expectEqual(@as(usize, 5), plan.count);
    try std.testing.expectEqualStrings("Cut", plan.items[0].label);
    try std.testing.expect(plan.items[0].enabled and plan.items[3].separator);
    const Factory = struct {
        fn view(ui: *sdk.TsUiApp(core).App.Ui, _: *const core.Model) sdk.TsUiApp(core).App.Ui.Node {
            return ui.text(.{}, "Menu ownership");
        }
        fn windowView(ui: *sdk.TsUiApp(core).App.Ui, model: *const core.Model, _: []const u8) sdk.TsUiApp(core).App.Ui.Node {
            return view(ui, model);
        }
    };
    const app = try sdk.TsUiApp(core).create(std.testing.allocator, .{}, .{ .name = "menus", .scene = .{}, .canvas_label = "canvas", .view = Factory.view, .window_view = Factory.windowView });
    defer app.destroy();
    try std.testing.expect(app.app().context_menu_policy == core.nativeWindowPolicy);
    for (calls) |count| try std.testing.expect(count > 0);
}
